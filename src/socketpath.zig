//! Where the UNIX socket lives. Shared by the server (`nanotodon`) and the
//! client (`toot`) so the two can never disagree.
//!
//! Resolution order:
//!   1. explicit `-socket <path>`
//!   2. `$XDG_RUNTIME_DIR/nanotodon[-<profile>].sock`
//!   3. `<config root>/nanotodon[-<profile>].sock`, where the config root comes
//!      from `config.socketDir()`: the server passes its verified root, `toot`
//!      falls back to `$XDG_CONFIG_HOME/nanotodon` or `$HOME/.config/nanotodon`.
//!
//! The environment rules live in src/config.zig so there is exactly one copy of
//! them; this file only appends the socket file name and enforces sun_path.
//!
//! `/var` is deliberately not used: it needs root. `/tmp` is avoided because a
//! predictable name in a sticky-bit directory invites pre-creation games and
//! leaves a stale inode behind after a reboot.

const std = @import("std");
const config = @import("config.zig");

pub const Error = error{
    /// Neither `$XDG_RUNTIME_DIR`, `$XDG_CONFIG_HOME` nor `$HOME` is usable.
    NoHome,
    /// Longer than the kernel's `sun_path` limit; pass `-socket`.
    NameTooLong,
};

pub const Env = config.Env;

/// Returns an allocated path. `explicit` wins over everything, `profile`
/// follows the same naming convention as the token/domain files
/// (`token<profile>`), except with a dash for readability.
///
/// `config_root` is the server's already-created config directory; pass null
/// (as `toot` does) to derive it from the environment instead.
///
/// Exactly one allocation is made, and none at all on the error paths.
pub fn resolve(
    allocator: std.mem.Allocator,
    env: Env,
    explicit: ?[]const u8,
    profile: ?[]const u8,
    config_root: ?[]const u8,
) ![]const u8 {
    if (explicit) |p| {
        if (p.len > max_path_len) return Error.NameTooLong;
        return allocator.dupe(u8, p);
    }

    // Both the directory and the final path are built in stack buffers, so the
    // only allocation is the returned path.
    var dir_buf: [config.max_path + 1]u8 = undefined;
    const dir = config.socketDir(&dir_buf, env, config_root) catch |err| switch (err) {
        error.NoHome => return Error.NoHome,
        error.PathTooLong => return Error.NameTooLong,
    };

    var buf: [max_path_len + 1]u8 = undefined;
    const path = formatPath(&buf, dir, profile) catch return Error.NameTooLong;

    return allocator.dupe(u8, path);
}

const max_path_len = std.Io.net.UnixAddress.max_len;

fn formatPath(buf: []u8, dir: []const u8, profile: ?[]const u8) error{NoSpaceLeft}![]const u8 {
    const p = profile orelse "";
    const dash: []const u8 = if (p.len == 0) "" else "-";

    return std.mem.print(buf, "{s}/nanotodon{s}{s}.sock", .{ dir, dash, p }) catch
        error.NoSpaceLeft;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "explicit path wins" {
    const path = try resolve(testing.allocator, .{}, "/tmp/x.sock", "work", null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/x.sock", path);
}

test "runtime dir is preferred over home" {
    const env: Env = .{ .runtime_dir = "/run/user/1000", .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/run/user/1000/nanotodon.sock", path);
}

test "falls back to the XDG config dir without a runtime dir" {
    const env: Env = .{ .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/pi/.config/nanotodon/nanotodon.sock", path);
}

test "XDG_CONFIG_HOME wins over HOME" {
    const env: Env = .{ .xdg_config_home = "/cfg", .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/cfg/nanotodon/nanotodon.sock", path);
}

test "an empty runtime dir is treated as unset" {
    const env: Env = .{ .runtime_dir = "", .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/pi/.config/nanotodon/nanotodon.sock", path);
}

test "profile goes into the file name" {
    const env: Env = .{ .runtime_dir = "/run/user/1000" };
    const path = try resolve(testing.allocator, env, null, "work", null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/run/user/1000/nanotodon-work.sock", path);
}

test "an empty profile behaves like no profile" {
    const env: Env = .{ .runtime_dir = "/run/user/1000" };
    const path = try resolve(testing.allocator, env, null, "", null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/run/user/1000/nanotodon.sock", path);
}

test "no home at all is an error" {
    try testing.expectError(Error.NoHome, resolve(testing.allocator, .{}, null, null, null));
}

test "paths longer than sun_path are rejected" {
    const long = try testing.allocator.alloc(u8, std.Io.net.UnixAddress.max_len + 1);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(
        Error.NameTooLong,
        resolve(testing.allocator, .{}, long, null, null),
    );
}
