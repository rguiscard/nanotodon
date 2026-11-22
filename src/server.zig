//! UNIX socket front end of the nanotodon server.
//!
//! One JSONL request per connection. Requests are handed to a `Poster`
//! callback (src/poster.zig in production, a stub in tests), so this file knows
//! nothing about curl, Mastodon or C.
//!
//! Concurrency: `Server.accept()` blocks and `Io.net` does not expose a
//! pollable handle, so accepting runs as one `Io.async` task and each
//! connection as another. Under `Io.Threaded` those are pooled worker threads;
//! when the pool is saturated `Io.async` runs the task inline, which is fine
//! but does stall the accept loop, hence `max_concurrent`.

const std = @import("std");
const net = std.Io.net;
const proto = @import("proto.zig");

/// Requests served at the same time before clients get "busy".
pub const default_max_concurrent: u32 = 8;

/// How long to back off after a failed `accept`, to avoid a hot error loop.
const accept_backoff_ns = 50 * std.time.ns_per_ms;

/// Something that can post a status. Returns null on success, or a message for
/// the client. `err_out` is scratch space owned by the caller.
///
/// `status` is NUL terminated so it can be handed straight to the C
/// `const char *` parameter.
pub const Poster = struct {
    ctx: ?*anyopaque = null,
    postFn: *const fn (
        ctx: ?*anyopaque,
        status: [:0]const u8,
        visibility: proto.Visibility,
        err_out: []u8,
    ) ?[]const u8,

    pub fn post(
        self: Poster,
        status: [:0]const u8,
        visibility: proto.Visibility,
        err_out: []u8,
    ) ?[]const u8 {
        return self.postFn(self.ctx, status, visibility, err_out);
    }
};

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    listener: net.Server,
    poster: Poster,
    max_concurrent: u32,
    active: std.atomic.Value(u32) = .init(0),

    pub fn deinit(srv: *Server) void {
        srv.listener.deinit(srv.io);
        srv.* = undefined;
    }

    /// Accepts forever. Started with `io.async` and intentionally never awaited.
    pub fn acceptLoop(srv: *Server) void {
        while (true) {
            const stream = srv.listener.accept(srv.io) catch |err| {
                std.debug.print("nanotodon: accept: {s}\n", .{@errorName(err)});
                std.Io.sleep(srv.io, .{ .nanoseconds = accept_backoff_ns }, .awake) catch {};
                continue;
            };

            const running = srv.active.fetchAdd(1, .monotonic);
            if (running >= srv.max_concurrent) {
                _ = srv.active.fetchSub(1, .monotonic);
                refuseBusy(srv, stream);
                continue;
            }

            // When the pool is saturated this runs inline and we come back
            // here afterwards; `active` stays consistent either way.
            _ = srv.io.async(handleConnection, .{ srv, stream });
        }
    }
};

/// Bind `path`, taking over a socket file left behind by a crashed run.
/// Any failure here is fatal for the caller: a server without its socket is
/// not a server.
pub fn listen(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    poster: Poster,
    max_concurrent: u32,
) !Server {
    const addr = try net.UnixAddress.init(path);

    const listener = addr.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            if (isLive(io, &addr)) return error.AlreadyRunning;
            // Nothing is listening: the file is a leftover. Drop it and retry
            // once, so Ctrl-C on a previous run is not a permanent failure.
            deleteFile(io, path);
            break :blk try addr.listen(io, .{});
        },
        else => |e| return e,
    };

    // Only the owner may talk to it.
    setOwnerOnly(io, path);

    return .{
        .io = io,
        .gpa = gpa,
        .listener = listener,
        .poster = poster,
        .max_concurrent = max_concurrent,
    };
}

/// Removes the socket file; safe to call when it is already gone.
pub fn deleteFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn isLive(io: std.Io, addr: *const net.UnixAddress) bool {
    const stream = addr.connect(io) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => return false,
        else => return true,
    };
    stream.close(io);
    return true;
}

fn setOwnerOnly(io: std.Io, path: []const u8) void {
    _ = io;
    if (!@hasDecl(std.c, "chmod")) return; // non-libc/Windows targets

    var zbuf: [net.UnixAddress.max_len + 1]u8 = undefined;
    if (path.len > net.UnixAddress.max_len) return;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    _ = std.c.chmod(@ptrCast(zbuf[0..].ptr), 0o600);
}

fn refuseBusy(srv: *Server, stream: net.Stream) void {
    var buf: [256]u8 = undefined;
    var writer = stream.writer(srv.io, &buf);
    proto.writeResponse(&writer.interface, false, "busy") catch {};
    writer.interface.flush() catch {};
    stream.close(srv.io);
}

fn handleConnection(srv: *Server, stream: net.Stream) void {
    defer _ = srv.active.fetchSub(1, .monotonic);
    defer stream.close(srv.io);

    handleOne(srv, stream) catch |err| {
        std.debug.print("nanotodon: client: {s}\n", .{@errorName(err)});
    };
}

/// Reads one request and writes one response. Does not close the stream.
fn handleOne(srv: *Server, stream: net.Stream) !void {
    var arena_state = std.heap.ArenaAllocator.init(srv.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The reader needs room for the whole line; `takeDelimiter` reports
    // `StreamTooLong` once this is exceeded.
    const read_buf = try arena.alloc(u8, proto.max_line + 1);
    var reader = stream.reader(srv.io, read_buf);

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(srv.io, &write_buf);

    const maybe_line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            try proto.writeResponse(&writer.interface, false, "request too long");
            try writer.interface.flush();
            return;
        },
        else => return err,
    };
    const line = maybe_line orelse return; // clean EOF, nothing to answer

    switch (proto.decode(arena, line)) {
        .reject => |msg| {
            std.debug.print("nanotodon: rejected request: {s}\n", .{msg});
            try proto.writeResponse(&writer.interface, false, msg);
        },
        .request => |req| {
            // C wants a `const char *`; allocate the terminator rather than
            // casting away the sentinel requirement.
            const status_z = try arena.allocSentinel(u8, req.status.len, 0);
            @memcpy(status_z, req.status);

            var err_buf: [512]u8 = @splat(0);
            if (srv.poster.post(status_z, req.visibility, &err_buf)) |message| {
                std.debug.print("nanotodon: post failed: {s}\n", .{message});
                try proto.writeResponse(&writer.interface, false, message);
            } else {
                std.debug.print(
                    "nanotodon: posted {d} chars ({s})\n",
                    .{ req.status.len, @tagName(req.visibility) },
                );
                try proto.writeResponse(&writer.interface, true, null);
            }
        },
    }
    try writer.interface.flush();
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testPost(
    _: ?*anyopaque,
    status: [:0]const u8,
    visibility: proto.Visibility,
    err_out: []u8,
) ?[]const u8 {
    _ = err_out;
    if (status.len == 0) return "empty status";
    if (visibility != .private) return "stub only accepts private";
    return null;
}

/// Starts a real listener on `path`, sends `request` + newline, serves it once
/// synchronously and returns the response line in `response`.
fn exchange(
    io: std.Io,
    path: []const u8,
    request: []const u8,
    response: []u8,
) ![]const u8 {
    deleteFile(io, path);
    defer deleteFile(io, path);

    var srv = try listen(io, testing.allocator, path, .{ .postFn = testPost }, default_max_concurrent);
    defer srv.deinit();

    const addr = try net.UnixAddress.init(path);
    const client = try addr.connect(io);
    defer client.close(io);

    var write_buf: [512]u8 = undefined;
    var writer = client.writer(io, &write_buf);
    try writer.interface.writeAll(request);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    const remote = try srv.listener.accept(io);
    handleOne(&srv, remote) catch |err| {
        remote.close(io);
        return err;
    };
    remote.close(io);

    var read_buf: [1024]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return error.NoResponse;
    if (line.len > response.len) return error.ResponseTooLong;
    @memcpy(response[0..line.len], line);
    return response[0..line.len];
}

test "a valid request is posted and acknowledged" {
    var response: [256]u8 = undefined;
    const line = try exchange(
        testing.io,
        "/tmp/nanotodon-test-ok.sock",
        "{\"v\":0,\"cmd\":\"toot\",\"status\":\"hi there\",\"visibility\":\"private\"}",
        &response,
    );
    try testing.expectEqualStrings("{\"ok\":true}", line);
}

test "the poster's error is passed to the client" {
    var response: [256]u8 = undefined;
    const line = try exchange(
        testing.io,
        "/tmp/nanotodon-test-fail.sock",
        "{\"v\":0,\"cmd\":\"toot\",\"status\":\"hi\",\"visibility\":\"public\"}",
        &response,
    );
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"stub only accepts private\"}", line);
}

test "malformed json is rejected" {
    var response: [256]u8 = undefined;
    const line = try exchange(
        testing.io,
        "/tmp/nanotodon-test-bad.sock",
        "hello",
        &response,
    );
    try testing.expectEqualStrings("{\"ok\":false,\"error\":\"malformed request\"}", line);
}

test "a stale socket file is taken over" {
    const io = testing.io;
    const path = "/tmp/nanotodon-test-stale.sock";
    deleteFile(io, path);
    defer deleteFile(io, path);

    // First server creates the file, then we pretend it crashed by deiniting
    // the listener without deleting the path.
    {
        var first = try listen(io, testing.allocator, path, .{ .postFn = testPost }, 1);
        first.deinit();
    }

    var second = try listen(io, testing.allocator, path, .{ .postFn = testPost }, 1);
    second.deinit();
}
