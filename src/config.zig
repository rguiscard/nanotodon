//! Configuration: paths, directories, the access token and the per-instance
//! app registration. Everything the old `config.c` and `setup_access_token()`
//! did lives here now. Names and file formats are unchanged from the C version,
//! so existing installations keep working:
//!
//!   <root>/token<profile>      raw JSON body of POST /oauth/token
//!   <root>/domain<profile>     instance hostname, no trailing newline
//!   <root>/app_token/<domain>  raw JSON body of POST /api/v1/apps
//!   <cache>/nanotodon/         image cache (image.c)
//!
//! Directory policy mirrors the old C code: prefer the XDG directories, fall
//! back to `~/.nanotodon` only when they cannot be created. The C version
//! `exit()`ed on failure; here it is an error the caller reports.

const std = @import("std");

/// Longest path we accept: the C side still stores them in `char[256]`.
pub const max_path = 255;

pub const Env = struct {
    runtime_dir: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    home: ?[]const u8 = null,

    pub fn fromMap(map: *const std.process.Environ.Map) Env {
        return .{
            .runtime_dir = map.get("XDG_RUNTIME_DIR"),
            .xdg_config_home = map.get("XDG_CONFIG_HOME"),
            .xdg_cache_home = map.get("XDG_CACHE_HOME"),
            .home = map.get("HOME"),
        };
    }
};

/// Errors of the pure path helpers: no allocation is involved.
pub const PathError = error{
    /// Neither `$XDG_CONFIG_HOME` nor `$HOME` is usable.
    NoHome,
    /// A computed path does not fit `max_path`.
    PathTooLong,
};

/// Errors of the helpers that allocate (the Config paths live for the process).
pub const Error = PathError || std.mem.Allocator.Error;

pub const Config = struct {
    profile: ?[]const u8,
    root_dir: [:0]const u8,
    cache_dir: [:0]const u8,
    token_path: [:0]const u8,
    domain_path: [:0]const u8,

    /// Resolve the directories and create them, then derive the token and
    /// domain paths. No network, no stdin, so it can run before the socket is
    /// bound — the socket may live in `root_dir`.
    pub fn init(
        arena: std.mem.Allocator,
        io: std.Io,
        env: Env,
        profile: ?[]const u8,
    ) !Config {
        const dirs = try createDirs(arena, io, env);
        return .{
            .profile = profile,
            .root_dir = dirs.root,
            .cache_dir = dirs.cache,
            .token_path = try withProfile(arena, dirs.root, "token", profile),
            .domain_path = try withProfile(arena, dirs.root, "domain", profile),
        };
    }

    /// `access_token` out of the token file, or null when the file is missing or
    /// carries none — both mean "needs registration".
    pub fn readToken(self: Config, arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
        const body = readFile(arena, io, self.token_path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        const Wire = struct { access_token: ?[]const u8 = null };
        const parsed = std.json.parseFromSliceLeaky(Wire, arena, body, .{
            .ignore_unknown_fields = true,
        }) catch return null;

        return parsed.access_token;
    }

    /// Instance hostname recorded at registration time, or null when missing.
    pub fn readDomain(self: Config, arena: std.mem.Allocator, io: std.Io) !?[:0]const u8 {
        const raw = readFile(arena, io, self.domain_path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try dupeZ(arena, trimmed);
    }

    /// `<root_dir>/app_token/<domain>`: one registered client per instance,
    /// shared by all profiles (that is what the C version did). Creates the
    /// `app_token` directory, so the returned path is always writable. The
    /// error set is inferred because this is the one path helper that does I/O.
    pub fn appTokenPath(
        self: Config,
        arena: std.mem.Allocator,
        io: std.Io,
        domain: []const u8,
    ) ![:0]const u8 {
        const dir = try printZ(arena, "{s}/app_token", .{self.root_dir});
        const path = try printZ(arena, "{s}/{s}", .{ dir, domain });
        try makeDir(io, dir);
        return path;
    }

    /// Raw body of the `/api/v1/apps` response, or null when the instance was
    /// never registered (or the file is unreadable, which just means "register
    /// again").
    pub fn readAppToken(
        self: Config,
        arena: std.mem.Allocator,
        io: std.Io,
        domain: []const u8,
    ) ?[]const u8 {
        const path = self.appTokenPath(arena, io, domain) catch return null;
        return readFile(arena, io, path) catch null;
    }

    /// Instance hostname, written without a trailing newline so the file stays
    /// byte-compatible with the C version.
    pub fn saveDomain(self: Config, io: std.Io, domain: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.domain_path, .data = domain });
    }

    /// Raw `/oauth/token` response body. The file holds an access token, so it
    /// is restricted to the owner; the C version left it to the umask.
    pub fn saveToken(self: Config, io: std.Io, body: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io, self.token_path, .{});
        defer file.close(io);
        file.setPermissions(io, ownerOnlyPermissions()) catch {};
        try file.writeStreamingAll(io, body);
    }
};

/// Directory the UNIX socket may live in: `$XDG_RUNTIME_DIR` when set, else
/// `config_root` (the server passes its verified root), else the pure env
/// candidate. Written into `buf` and returned as a slice: no allocation, so
/// callers cannot leak it, and `toot` — which has no Config — uses the same rule.
pub fn socketDir(
    buf: []u8,
    env: Env,
    config_root: ?[]const u8,
) PathError![]const u8 {
    if (usable(env.runtime_dir)) |dir| return copyInto(buf, dir);
    if (config_root) |dir| return copyInto(buf, dir);
    if (usable(env.xdg_config_home)) |dir| return printInto(buf, "{s}/nanotodon", .{dir});
    if (usable(env.home)) |dir| return printInto(buf, "{s}/.config/nanotodon", .{dir});
    return PathError.NoHome;
}

const Dirs = struct {
    root: [:0]const u8,
    cache: [:0]const u8,
};

fn createDirs(arena: std.mem.Allocator, io: std.Io, env: Env) !Dirs {
    // XDG first, exactly like the old init_xdg(): create both and fall back only
    // if either fails (e.g. ~/.config is not writable).
    const xdg: ?Dirs = blk: {
        const root = rootCandidate(arena, env) catch break :blk null;
        const cache = cacheCandidate(arena, env) catch break :blk null;
        makeDir(io, root) catch break :blk null;
        makeDir(io, cache) catch break :blk null;
        break :blk .{ .root = root, .cache = cache };
    };
    if (xdg) |dirs| return dirs;

    const home = usable(env.home) orelse return Error.NoHome;
    const root = try printZ(arena, "{s}/.nanotodon", .{home});
    const cache = try printZ(arena, "{s}/.nanotodon/cache", .{home});
    try makeDir(io, root);
    try makeDir(io, cache);
    return .{ .root = root, .cache = cache };
}

fn rootCandidate(arena: std.mem.Allocator, env: Env) Error![:0]const u8 {
    if (usable(env.xdg_config_home)) |dir| return printZ(arena, "{s}/nanotodon", .{dir});
    if (usable(env.home)) |dir| return printZ(arena, "{s}/.config/nanotodon", .{dir});
    return Error.NoHome;
}

fn cacheCandidate(arena: std.mem.Allocator, env: Env) Error![:0]const u8 {
    if (usable(env.xdg_cache_home)) |dir| return printZ(arena, "{s}/nanotodon", .{dir});
    if (usable(env.home)) |dir| return printZ(arena, "{s}/.cache/nanotodon", .{dir});
    return Error.NoHome;
}

fn withProfile(
    arena: std.mem.Allocator,
    dir: []const u8,
    base: []const u8,
    profile: ?[]const u8,
) Error![:0]const u8 {
    return printZ(arena, "{s}/{s}{s}", .{ dir, base, profile orelse "" });
}

/// `createDirPath` creates missing parents too, so `~/.config` (or `~/.cache`)
/// appears when needed — the same effect the old per-component mkdir had.
fn makeDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

/// `-rw-------` on POSIX: the token file is a secret. `Permissions` is an enum
/// over the platform's mode type, so it cannot be written as a literal.
fn ownerOnlyPermissions() std.Io.File.Permissions {
    // POSIX exposes `fromMode`; the Windows enum has no modes at all.
    if (comptime @hasDecl(std.Io.File.Permissions, "fromMode"))
        return .fromMode(0o600);
    return .default_file;
}

fn readFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024));
}

fn printZ(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error![:0]const u8 {
    var buf: [max_path + 1]u8 = undefined;
    const path = std.mem.printSentinel(&buf, fmt, args, 0) catch return Error.PathTooLong;
    return try dupeZ(arena, path);
}

fn copyInto(buf: []u8, s: []const u8) PathError![]const u8 {
    if (s.len > buf.len) return PathError.PathTooLong;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

fn printInto(buf: []u8, comptime fmt: []const u8, args: anytype) PathError![]const u8 {
    return std.mem.print(buf, fmt, args) catch PathError.PathTooLong;
}

fn dupeZ(arena: std.mem.Allocator, s: []const u8) Error![:0]const u8 {
    const out = try arena.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

fn usable(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "socketDir prefers the runtime dir" {
    var buf: [max_path]u8 = undefined;
    const env: Env = .{ .runtime_dir = "/run/user/1000", .home = "/home/pi" };
    const dir = try socketDir(&buf, env, "/home/pi/.config/nanotodon");
    try testing.expectEqualStrings("/run/user/1000", dir);
}

test "socketDir uses the config root when there is no runtime dir" {
    var buf: [max_path]u8 = undefined;
    const env: Env = .{ .home = "/home/pi" };
    try testing.expectEqualStrings("/cfg/nanotodon", try socketDir(&buf, env, "/cfg/nanotodon"));
    // Without a Config (i.e. `toot`) the pure candidate is used.
    try testing.expectEqualStrings("/home/pi/.config/nanotodon", try socketDir(&buf, env, null));
}

test "socketDir without any usable variable is an error" {
    var buf: [max_path]u8 = undefined;
    try testing.expectError(error.NoHome, socketDir(&buf, .{}, null));
}

test "readToken pulls access_token out of the API response" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token_path = "/tmp/nanotodon-test-token.json";
    const domain_path = "/tmp/nanotodon-test-domain.txt";
    defer std.Io.Dir.cwd().deleteFile(io, token_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, domain_path) catch {};

    const cfg = Config{
        .profile = null,
        .root_dir = "/tmp",
        .cache_dir = "/tmp",
        .token_path = token_path,
        .domain_path = domain_path,
    };

    // Missing files mean "needs registration", not an error.
    try testing.expect((try cfg.readToken(arena, io)) == null);
    try testing.expect((try cfg.readDomain(arena, io)) == null);

    // The token file is Mastodon's raw /oauth/token body, with extra fields.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = token_path,
        .data = "{\"access_token\":\"abc123\",\"token_type\":\"Bearer\",\"scope\":\"read write\",\"created_at\":1}",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = domain_path,
        .data = "mastodon.social\n",
    });

    try testing.expectEqualStrings("abc123", (try cfg.readToken(arena, io)).?);
    try testing.expectEqualStrings("mastodon.social", (try cfg.readDomain(arena, io)).?);
}

test "a token file without access_token needs registration" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const path = "/tmp/nanotodon-test-token-bad.json";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "{\"error\":\"invalid_grant\"}" });

    const cfg = Config{
        .profile = null,
        .root_dir = "/tmp",
        .cache_dir = "/tmp",
        .token_path = path,
        .domain_path = path,
    };

    try testing.expect((try cfg.readToken(arena, io)) == null);
}

test "appTokenPath lives under app_token and creates the directory" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = "/tmp/nanotodon-test-apptoken";
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    const cfg = Config{
        .profile = null,
        .root_dir = root,
        .cache_dir = root,
        .token_path = root ++ "/token",
        .domain_path = root ++ "/domain",
    };

    // Nothing cached yet, and no directory either.
    try testing.expect(cfg.readAppToken(arena, io, "example.social") == null);

    const path = try cfg.appTokenPath(arena, io, "example.social");
    try testing.expectEqualStrings("/tmp/nanotodon-test-apptoken/app_token/example.social", path);

    // Building the path created the directory, so it can be written right away.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "{\"client_id\":\"cid\",\"client_secret\":\"cs\"}",
    });
    try testing.expectEqualStrings(
        "{\"client_id\":\"cid\",\"client_secret\":\"cs\"}",
        cfg.readAppToken(arena, io, "example.social").?,
    );
}

test "saveDomain and saveToken round-trip through the readers" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = "/tmp/nanotodon-test-save";
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const cfg = Config{
        .profile = null,
        .root_dir = root,
        .cache_dir = root,
        .token_path = root ++ "/token",
        .domain_path = root ++ "/domain",
    };

    // The domain file must not gain a newline: older binaries read it back.
    try cfg.saveDomain(io, "example.social");
    try testing.expectEqualStrings("example.social", (try cfg.readDomain(arena, io)).?);

    try cfg.saveToken(io, "{\"access_token\":\"tok\",\"scope\":\"read\"}");
    try testing.expectEqualStrings("tok", (try cfg.readToken(arena, io)).?);
}
