//! JSON Lines protocol spoken over the UNIX socket between the nanotodon
//! server and the `toot` client.
//!
//! One request per line, one response per line, connection closed afterwards:
//!
//!   {"v":0,"cmd":"toot","status":"<text>","visibility":"public"}
//!   {"ok":true}
//!   {"ok":false,"error":"<human readable>"}
//!
//! Status text is JSON-escaped, so newlines and quotes need no extra framing
//! (the old stdin path had to invent `\n`/`\\` escapes because `fgets` splits
//! on newlines).

const std = @import("std");

/// Bumped when the request shape changes incompatibly. A client sending any
/// other value is rejected with "unsupported protocol version".
pub const version: u32 = 0;

pub const cmd_toot = "toot";

/// Longest accepted request line, excluding the newline. Bounds what a single
/// connection can make the server buffer; the status length itself is left to
/// the Mastodon API (instances choose their own limit).
pub const max_line: usize = 64 * 1024;

/// Must match `NANOTODON_VISIBILITY_*` in src/headers.h, which is what
/// `nanotodon_post_toot()` expects as an int.
pub const Visibility = enum {
    public,
    unlisted,
    private,
    direct,
};

/// A validated request. `status` borrows from the decode arena/line.
pub const Request = struct {
    status: []const u8,
    visibility: Visibility = .public,
};

/// A validated response. `@"error"` borrows from the decode arena/line.
/// (Quoted identifier because `error` is a keyword; the JSON key is still
/// `"error"`.)
pub const Response = struct {
    ok: bool,
    @"error": ?[]const u8 = null,
};

/// Wire shape as it appears in JSON. Kept separate from `Request` so that
/// validation can produce specific messages instead of a generic parse error.
const WireRequest = struct {
    v: u32,
    cmd: []const u8,
    status: []const u8 = "",
    visibility: ?[]const u8 = null,
};

pub const Decoded = union(enum) {
    request: Request,
    /// Static message to send back in `{"ok":false,"error":...}`.
    reject: []const u8,
};

/// Parse and validate one request line. Unknown JSON fields are an error
/// (`ignore_unknown_fields` defaults to false), which turns a typo like
/// "visiblity" into a visible rejection instead of a silently defaulted value.
pub fn decode(arena: std.mem.Allocator, line: []const u8) Decoded {
    const wire = std.json.parseFromSliceLeaky(WireRequest, arena, line, .{}) catch {
        return .{ .reject = "malformed request" };
    };

    if (wire.v != version) return .{ .reject = "unsupported protocol version" };
    if (!std.mem.eql(u8, wire.cmd, cmd_toot)) return .{ .reject = "unknown command" };
    if (wire.status.len == 0) return .{ .reject = "empty status" };

    var visibility: Visibility = .public;
    if (wire.visibility) |name| {
        visibility = std.meta.stringToEnum(Visibility, name) orelse
            return .{ .reject = "unknown visibility" };
    }

    return .{ .request = .{ .status = wire.status, .visibility = visibility } };
}

/// Parse a response line. Returns null when the line is not a response this
/// client understands.
pub fn decodeResponse(arena: std.mem.Allocator, line: []const u8) ?Response {
    return std.json.parseFromSliceLeaky(Response, arena, line, .{}) catch null;
}

pub fn writeRequest(
    writer: *std.Io.Writer,
    status: []const u8,
    visibility: Visibility,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"v\":");
    try writer.print("{d}", .{version});
    try writer.writeAll(",\"cmd\":\"");
    try writer.writeAll(cmd_toot);
    try writer.writeAll("\",\"status\":");
    try std.json.Stringify.encodeJsonString(status, .{}, writer);
    try writer.writeAll(",\"visibility\":\"");
    try writer.writeAll(@tagName(visibility));
    try writer.writeAll("\"}\n");
}

/// Always exactly one line; `error` is only emitted when `ok` is false.
pub fn writeResponse(
    writer: *std.Io.Writer,
    ok: bool,
    err: ?[]const u8,
) std.Io.Writer.Error!void {
    if (ok) {
        try writer.writeAll("{\"ok\":true}\n");
        return;
    }
    try writer.writeAll("{\"ok\":false,\"error\":");
    try std.json.Stringify.encodeJsonString(err orelse "unknown error", .{}, writer);
    try writer.writeAll("}\n");
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn requestLine(buf: []u8, status: []const u8, visibility: Visibility) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeRequest(&w, status, visibility) catch unreachable;
    return w.buffered();
}

fn responseLine(buf: []u8, ok: bool, err: ?[]const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    writeResponse(&w, ok, err) catch unreachable;
    return w.buffered();
}

test "request round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [256]u8 = undefined;

    {
        const line = requestLine(&buf, "hello world", .public);
        const decoded = decode(arena_state.allocator(), line);
        try testing.expectEqualStrings("hello world", decoded.request.status);
        try testing.expectEqual(Visibility.public, decoded.request.visibility);
    }

    {
        const line = requestLine(&buf, "a\nb\t\"c\"\\d", .private);
        const decoded = decode(arena_state.allocator(), line);
        try testing.expectEqualStrings("a\nb\t\"c\"\\d", decoded.request.status);
        try testing.expectEqual(Visibility.private, decoded.request.visibility);
    }
}

test "visibility defaults to public when absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const decoded = decode(arena_state.allocator(), "{\"v\":0,\"cmd\":\"toot\",\"status\":\"x\"}");
    try testing.expectEqual(Visibility.public, decoded.request.visibility);
}

test "rejections" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("malformed request", decode(arena, "not json").reject);
    try testing.expectEqualStrings(
        "unsupported protocol version",
        decode(arena, "{\"v\":1,\"cmd\":\"toot\",\"status\":\"x\"}").reject,
    );
    try testing.expectEqualStrings(
        "unknown command",
        decode(arena, "{\"v\":0,\"cmd\":\"like\",\"status\":\"x\"}").reject,
    );
    try testing.expectEqualStrings(
        "empty status",
        decode(arena, "{\"v\":0,\"cmd\":\"toot\",\"status\":\"\"}").reject,
    );
    try testing.expectEqualStrings(
        "unknown visibility",
        decode(arena, "{\"v\":0,\"cmd\":\"toot\",\"status\":\"x\",\"visibility\":\"secret\"}").reject,
    );
    // Typo in a field name is caught rather than silently defaulted.
    try testing.expectEqualStrings(
        "malformed request",
        decode(arena, "{\"v\":0,\"cmd\":\"toot\",\"status\":\"x\",\"visiblity\":\"private\"}").reject,
    );
    // Missing required field.
    try testing.expectEqualStrings("malformed request", decode(arena, "{\"cmd\":\"toot\"}").reject);
}

test "response round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var buf: [256]u8 = undefined;

    {
        const line = responseLine(&buf, true, null);
        // writeResponse always ends the line, that is the JSONL framing.
        try testing.expectEqualStrings("{\"ok\":true}\n", line);
        const resp = decodeResponse(arena_state.allocator(), line).?;
        try testing.expect(resp.ok);
        try testing.expect(resp.@"error" == null);
    }

    {
        const line = responseLine(&buf, false, "boom \"quoted\"\n");
        const resp = decodeResponse(arena_state.allocator(), line).?;
        try testing.expect(!resp.ok);
        try testing.expectEqualStrings("boom \"quoted\"\n", resp.@"error".?);
    }
}
