//! Where the UNIX socket lives. Shared by the server (`nanotodon`) and the
//! client (`toot`) so the two can never disagree.
//!
//! Resolution order:
//!   1. explicit `-socket <path>`
//!   2. `$XDG_RUNTIME_DIR/nanotodon[-<profile>].sock`
//!   3. `$XDG_CONFIG_HOME/nanotodon/nanotodon[-<profile>].sock`
//!   4. `$HOME/.config/nanotodon/nanotodon[-<profile>].sock`
//!
//! Rules 3 and 4 mirror `root_dir` in config.c: the server calls
//! `nanotodon_prepare_paths()` *before* binding, which creates exactly that
//! directory. `toot` has no C to ask, hence both sides use this same pure
//! environment rule. On Linux `$XDG_RUNTIME_DIR` wins, so the socket stays out
//! of the config directory there; on macOS/BSD it lands next to token/domain.
//!
//! `/var` is deliberately not used: it needs root. `/tmp` is avoided because a
//! predictable name in a sticky-bit directory invites pre-creation games and
//! leaves a stale inode behind after a reboot.

const std = @import("std");

pub const Error = error{
    /// Neither `$XDG_RUNTIME_DIR`, `$XDG_CONFIG_HOME` nor `$HOME` is usable.
    NoHome,
    /// Longer than the kernel's `sun_path` limit; pass `-socket`.
    NameTooLong,
};

pub const Env = struct {
    runtime_dir: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,

    pub fn fromMap(map: *const std.process.Environ.Map) Env {
        return .{
            .runtime_dir = map.get("XDG_RUNTIME_DIR"),
            .xdg_config_home = map.get("XDG_CONFIG_HOME"),
            .home = map.get("HOME"),
        };
    }
};

/// Returns an allocated path. `explicit` wins over everything, `profile`
/// follows the same naming convention as the token/domain files
/// (`token<profile>`), except with a dash for readability.
///
/// Exactly one allocation is made, and none at all on the error paths.
pub fn resolve(
    allocator: std.mem.Allocator,
    env: Env,
    explicit: ?[]const u8,
    profile: ?[]const u8,
) ![]const u8 {
    if (explicit) |p| {
        if (p.len > max_path_len) return Error.NameTooLong;
        return allocator.dupe(u8, p);
    }

    // Format into a stack buffer first: the length limit is then exactly the
    // buffer size, and a failure cannot leave a half-built allocation behind.
    var buf: [max_path_len + 1]u8 = undefined;
    const path = formatPath(&buf, env, profile) catch |err| switch (err) {
        error.NoSpaceLeft => return Error.NameTooLong,
        error.NoHome => return Error.NoHome,
    };

    return allocator.dupe(u8, path);
}

const max_path_len = std.Io.net.UnixAddress.max_len;

const PathError = error{ NoSpaceLeft, NoHome };

fn formatPath(buf: []u8, env: Env, profile: ?[]const u8) PathError![]const u8 {
    const p = profile orelse "";
    const dash: []const u8 = if (p.len == 0) "" else "-";

    if (usable(env.runtime_dir)) |dir| {
        return std.fmt.bufPrint(buf, "{s}/nanotodon{s}{s}.sock", .{ dir, dash, p }) catch
            PathError.NoSpaceLeft;
    }
    if (usable(env.xdg_config_home)) |dir| {
        return std.fmt.bufPrint(buf, "{s}/nanotodon/nanotodon{s}{s}.sock", .{ dir, dash, p }) catch
            PathError.NoSpaceLeft;
    }
    if (usable(env.home)) |dir| {
        return std.fmt.bufPrint(buf, "{s}/.config/nanotodon/nanotodon{s}{s}.sock", .{ dir, dash, p }) catch
            PathError.NoSpaceLeft;
    }
    return PathError.NoHome;
}

fn usable(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "explicit path wins" {
    const path = try resolve(testing.allocator, .{}, "/tmp/x.sock", "work");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/tmp/x.sock", path);
}

test "runtime dir is preferred over home" {
    const env: Env = .{ .runtime_dir = "/run/user/1000", .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/run/user/1000/nanotodon.sock", path);
}

test "falls back to the XDG config dir without a runtime dir" {
    const env: Env = .{ .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/pi/.config/nanotodon/nanotodon.sock", path);
}

test "XDG_CONFIG_HOME wins over HOME" {
    const env: Env = .{ .xdg_config_home = "/cfg", .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/cfg/nanotodon/nanotodon.sock", path);
}

test "an empty runtime dir is treated as unset" {
    const env: Env = .{ .runtime_dir = "", .home = "/home/pi" };
    const path = try resolve(testing.allocator, env, null, null);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/home/pi/.config/nanotodon/nanotodon.sock", path);
}

test "profile goes into the file name" {
    const env: Env = .{ .runtime_dir = "/run/user/1000" };
    const path = try resolve(testing.allocator, env, null, "work");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/run/user/1000/nanotodon-work.sock", path);
}

test "an empty profile behaves like no profile" {
    const env: Env = .{ .runtime_dir = "/run/user/1000" };
    const path = try resolve(testing.allocator, env, null, "");
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/run/user/1000/nanotodon.sock", path);
}

test "no home at all is an error" {
    try testing.expectError(Error.NoHome, resolve(testing.allocator, .{}, null, null));
}

test "paths longer than sun_path are rejected" {
    const long = try testing.allocator.alloc(u8, std.Io.net.UnixAddress.max_len + 1);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(
        Error.NameTooLong,
        resolve(testing.allocator, .{}, long, null),
    );
}
