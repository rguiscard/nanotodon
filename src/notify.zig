//! Notification formatting (the easy half of the former C
//! `stream_event_notify()`).
//!
//! Takes the JSON payload of one `notification` SSE event and renders a single
//! plain line. No colour, no emoji, no bell: the first version is deliberately
//! minimal so the streaming → queue → screen workflow stays obvious, and the
//! formatting can grow later without touching the transport.
//!
//! The reference to the notifying status (`"status"`) is parsed but ignored for
//! now; rendering it belongs with the rest of the toot display.
//!
//! The result is handed to `translated.nanotodon_enqueue_text()` so it leaves on
//! the same queue as every other message.

const std = @import("std");
const output = @import("out.zig");

/// The fields that are read. Everything else in a Mastodon notification is
/// ignored, which also means a schema addition cannot break formatting.
const Wire = struct {
    type: ?[]const u8 = null,
    account: ?Account = null,

    const Account = struct {
        acct: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
    };
};

/// Renders one notification into `out`.
///
/// Returns `false` when the payload is not a JSON object this code understands;
/// the caller then leaves the event alone (it has already been traced).
pub fn format(allocator: std.mem.Allocator, json: []const u8, out: *std.ArrayList(u8)) !bool {
    const parsed = std.json.parseFromSliceLeaky(Wire, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return false;

    // Degenerate payloads still produce a line: a notification that was sent is
    // worth seeing even if one of its fields is missing.
    const kind = parsed.type orelse "notification";
    const acct = if (parsed.account) |a| (a.acct orelse "?") else "?";
    const display = if (parsed.account) |a| (a.display_name orelse "") else "";

    // `{type} from {acct} ({display}): the C layout, minus the decoration.
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, " from ");
    try out.appendSlice(allocator, acct);
    if (display.len != 0 and !std.mem.eql(u8, display, acct)) {
        try out.appendSlice(allocator, " (");
        try out.appendSlice(allocator, display);
        try out.appendSlice(allocator, ")");
    }
    try out.append(allocator, '\n');
    return true;
}

/// Formats and queues one notification. Returns false if the payload was not
/// understood.
pub fn deliver(io: std.Io, allocator: std.mem.Allocator, json: []const u8) bool {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    const ok = format(allocator, json, &line) catch return false;
    if (!ok or line.items.len == 0) return false;

    output.write(io, line.items);
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn render(allocator: std.mem.Allocator, json: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try testing.expect(try format(allocator, json, &out));
    return out.toOwnedSlice(allocator);
}

test "mention with a display name" {
    const arena = testing.allocator;
    const line = try render(arena,
        \\{"type":"mention","account":{"acct":"alice","display_name":"Alice"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("mention from alice (Alice)\n", line);
}

test "follow with an empty display name has no parentheses" {
    const arena = testing.allocator;
    const line = try render(arena,
        \\{"type":"follow","account":{"acct":"bob","display_name":""}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("follow from bob\n", line);
}

test "display name equal to the acct is not repeated" {
    const arena = testing.allocator;
    const line = try render(arena,
        \\{"type":"favourite","account":{"acct":"carol","display_name":"carol"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("favourite from carol\n", line);
}

test "unknown fields and an attached status are ignored" {
    const arena = testing.allocator;
    const line = try render(arena,
        \\{"type":"reblog","id":"9","status":{"id":"1","content":"<p>hi</p>"},"account":{"acct":"dave","display_name":"Dave"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("reblog from dave (Dave)\n", line);
}

test "missing type and account still produce a line" {
    const arena = testing.allocator;
    const line = try render(arena, "{}");
    defer arena.free(line);
    try testing.expectEqualStrings("notification from ?\n", line);
}

test "a non-object payload is rejected" {
    const arena = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try testing.expect(!try format(arena, "[1,2,3]", &out));
    try testing.expect(!try format(arena, "not json", &out));
}
