//! `toot` — the command line client of the nanotodon server.
//!
//! Connects to the server's UNIX socket, sends one JSONL request and waits for
//! the reply, so the exit status reflects whether the toot really went out.
//!
//!   toot [-socket <path>] [-profile <name>] [-v public|unlisted|private|direct] <text...>
//!
//! Exit status: 0 posted, 1 the server could not post, 2 usage/connection
//! problems. Nothing is printed on success.

const std = @import("std");
const net = std.Io.net;
const proto = @import("proto.zig");
const socketpath = @import("socketpath.zig");

const usage =
    "usage: toot [-socket <path>] [-profile <name>] " ++
    "[-v public|unlisted|private|direct] <text...>\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.skip(); // program name

    var socket_opt: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var visibility: proto.Visibility = .public;
    var text: std.ArrayList(u8) = .empty;
    var options_done = false;

    while (args.next()) |arg| {
        const a: []const u8 = arg;

        if (!options_done and a.len > 0 and a[0] == '-') {
            if (std.mem.eql(u8, a, "-socket")) {
                socket_opt = args.next() orelse dieUsage("-socket needs a value\n");
            } else if (std.mem.eql(u8, a, "-profile")) {
                profile = args.next() orelse dieUsage("-profile needs a value\n");
            } else if (std.mem.eql(u8, a, "-v")) {
                const name = args.next() orelse dieUsage("-v needs a value\n");
                visibility = std.meta.stringToEnum(proto.Visibility, name) orelse
                    dieUsage("-v takes public, unlisted, private or direct\n");
            } else {
                dieUsage("unknown option\n");
            }
            continue;
        }

        // Everything from the first non-option on is text; words are joined
        // with single spaces, so embedded whitespace needs shell quoting.
        options_done = true;
        if (text.items.len != 0) try text.append(arena, ' ');
        try text.appendSlice(arena, a);
    }

    if (text.items.len == 0) dieUsage("no text\n");

    const path = socketpath.resolve(
        arena,
        socketpath.Env.fromMap(init.environ_map),
        socket_opt,
        profile,
    ) catch |err| switch (err) {
        error.NameTooLong => dieFatal("socket path too long; pass -socket\n", .{}),
        error.NoHome => dieFatal("no $HOME or $XDG_RUNTIME_DIR to look for the socket in\n", .{}),
        else => dieFatal("cannot build the socket path: {s}\n", .{@errorName(err)}),
    };

    const addr = net.UnixAddress.init(path) catch
        dieFatal("socket path too long: {s}\n", .{path});
    const stream = addr.connect(io) catch |err|
        dieFatal("cannot connect to {s}: {s} (is nanotodon running?)\n", .{ path, @errorName(err) });
    defer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    proto.writeRequest(&writer.interface, text.items, visibility) catch
        dieFatal("cannot send the request\n", .{});
    writer.interface.flush() catch dieFatal("cannot send the request\n", .{});

    var read_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const line = (reader.interface.takeDelimiter('\n') catch
        dieFatal("cannot read the reply\n", .{})) orelse
        dieFatal("the server closed the connection without answering\n", .{});

    const response = proto.decodeResponse(arena, line) orelse
        dieFatal("malformed reply from the server\n", .{});

    if (!response.ok) {
        std.debug.print("toot: {s}\n", .{response.@"error" orelse "failed"});
        std.process.exit(1);
    }
}

fn dieUsage(comptime message: []const u8) noreturn {
    std.debug.print("toot: {s}{s}", .{ message, usage });
    std.process.exit(2);
}

fn dieFatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(2);
}

// `toot` only runs `main()`, which a test build never analyzes, so reference
// everything here to at least keep this file compiling under `zig build test`.
test {
    std.testing.refAllDecls(@This());
}
