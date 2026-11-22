//! `toot` — the command line client of the nanotodon server.
//!
//! Connects to the server's UNIX socket, sends one JSONL request and waits for
//! the reply, so the exit status reflects whether the toot really went out.
//!
//!   toot [-socket <path>] [-profile <name>] [-v <vis>] <text...>
//!   toot [-socket <path>] [-profile <name>] [-v <vis>] < status.txt
//!
//! With positional words the status is those words joined by single spaces;
//! with no positional words it is read from stdin, so heredocs and pipes work.
//! argv wins when both are present.
//!
//! Exit status: 0 posted, 1 the server could not post, 2 usage/connection
//! problems (including a status that does not fit `toot`'s own buffer). Nothing
//! is printed on success.

const std = @import("std");
const net = std.Io.net;
const proto = @import("proto.zig");
const socketpath = @import("socketpath.zig");

/// `toot`'s own bound for the encoded request. Deliberately *not* the protocol
/// limit (`proto.max_line` = 64 KiB, enforced by the server), and far above
/// Mastodon's typical 500-character instance limit. Keeping it fixed means the
/// client never has to grow a buffer.
const max_status = 4096;

const usage =
    "usage: toot [-socket <path>] [-profile <name>] " ++
    "[-v public|unlisted|private|direct] <text...>\n" ++
       "       toot [-socket <path>] [-profile <name>] " ++
       "[-v public|unlisted|private|direct] < status.txt\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.skip(); // program name

    var socket_opt: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var visibility: proto.Visibility = .public;
    var text_buf: [max_status]u8 = undefined;
    var text_writer = std.Io.Writer.fixed(&text_buf);
    var have_text = false;
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
        if (have_text) text_writer.writeByte(' ') catch
            dieFatal("status too long (max {d} bytes)\n", .{max_status});
        text_writer.writeAll(a) catch
            dieFatal("status too long (max {d} bytes)\n", .{max_status});
        have_text = true;
    }

    // No positional text: read the status from stdin so heredocs and pipes
    // work (`toot -v private << EOF`). argv wins when both are present.
    var raw_buf: [max_status + 1]u8 = undefined;
    const text: []const u8 = if (have_text) text_writer.buffered() else blk: {
        const stdin = std.Io.File.stdin();
        if (stdin.isTty(io) catch false) {
            std.debug.print("toot: reading the status from stdin; press Ctrl-D to send\n", .{});
        }
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = stdin.reader(io, &stdin_buf);
        // Returns fewer bytes only at EOF, so a full `raw_buf` means overflow.
        const n = stdin_reader.interface.readSliceShort(&raw_buf) catch |err|
            dieFatal("cannot read stdin: {s}\n", .{@errorName(err)});
        if (n > max_status) dieFatal("status too long (max {d} bytes)\n", .{max_status});
        break :blk trimTrailingNewline(raw_buf[0..n]);
    };

    if (text.len == 0) dieUsage("no text\n");

    // Encode before connecting: with a fixed buffer the writer itself becomes
    // the escaped-length check, so nothing is sent when the request cannot fit.
    var payload_buf: [max_status]u8 = undefined;
    var payload_writer = std.Io.Writer.fixed(&payload_buf);
    proto.writeRequest(&payload_writer, text, visibility) catch
        dieFatal("status too long after JSON escaping (max {d} bytes)\n", .{max_status});
    const payload = payload_writer.buffered();

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
    writer.interface.writeAll(payload) catch dieFatal("cannot send the request\n", .{});
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
    std.debug.print("toot: " ++ fmt, args);
    std.process.exit(2);
}

/// Heredocs and most editors end the text with a newline. Drop exactly one (plus
/// a preceding `\r`) so a multi-line status does not gain a trailing blank
/// line; internal newlines are preserved.
fn trimTrailingNewline(s: []const u8) []const u8 {
    var end = s.len;
    if (end > 0 and s[end - 1] == '\n') end -= 1;
    if (end > 0 and s[end - 1] == '\r') end -= 1;
    return s[0..end];
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "trimTrailingNewline drops only one line ending" {
    try testing.expectEqualStrings("", trimTrailingNewline(""));
    try testing.expectEqualStrings("a", trimTrailingNewline("a"));
    try testing.expectEqualStrings("a", trimTrailingNewline("a\n"));
    try testing.expectEqualStrings("a", trimTrailingNewline("a\r\n"));
    try testing.expectEqualStrings("a", trimTrailingNewline("a\r"));
    // Only the last one goes; a deliberate blank line survives.
    try testing.expectEqualStrings("a\n", trimTrailingNewline("a\n\n"));
}

test "trimTrailingNewline keeps internal newlines" {
    try testing.expectEqualStrings("a\nb\nc", trimTrailingNewline("a\nb\nc\n"));
    try testing.expectEqualStrings("a\r\nb", trimTrailingNewline("a\r\nb"));
}

// `toot` only runs `main()`, which a test build never analyzes, so reference
// everything here to at least keep this file compiling under `zig build test`.
test {
    std.testing.refAllDecls(@This());
}
