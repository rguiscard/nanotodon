//! Renders one status (a Mastodon `update` event, or an element of the
//! `api/v1/timelines/*` array) as plain text.
//!
//! This replaces the C `stream_event_update()`. The HTML `content` is reduced
//! to terminal text by `htmltext.zig`: block tags become line breaks, character
//! references are decoded and the links an anchor pointed at are listed after
//! the body. Colour and real emoji are still out of scope; a custom emoji
//! survives as its `:shortcode:`.
//!
//! A boost (`reblog`) is **not** expanded: the status is rendered as it stands,
//! preceded by a `Boosted by {acct}` line, so a boost is recognisable without
//! rendering someone else's toot in its place.
//!
//! Every status becomes one string, images included, and leaves through a
//! single `output.writeSeparated()`, so a status, its pictures and the rule
//! above it print atomically.

const std = @import("std");
const output = @import("out.zig");
const images = @import("image.zig");
const htmltext = @import("htmltext.zig");

/// The fields that are read. Everything else in a status is ignored, so a schema
/// addition cannot break rendering.
const Wire = struct {
    content: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    visibility: ?[]const u8 = null,
    reblog: ?std.json.Value = null,
    account: ?Account = null,
    media_attachments: ?[]const Media = null,

    const Account = struct {
        acct: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
    };

    const Media = struct {
        url: ?[]const u8 = null,
        type: ?[]const u8 = null,
    };
};

/// Renders one status into `out`. Returns false when the payload is not a JSON
/// object this code understands.
///
/// `cache_dir` is where image attachments are cached; pass `null` to skip them
/// (tests, or a build without -Dimage).
pub fn render(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_dir: ?std.Io.Dir,
    json: []const u8,
    out: *std.ArrayList(u8),
) !bool {
    // `parseFromSlice` (not the leaky variant): every string field is copied
    // into `allocator`, and the stream thread runs on `smp_allocator`, which
    // never frees. Without the `deinit()` each status would cost its own JSON
    // permanently. `out` already holds copies, so it stays valid afterwards.
    var parsed_state = std.json.parseFromSlice(Wire, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed_state.deinit();
    const parsed = parsed_state.value;
    // A boost is marked, not expanded: the nested status is left alone.
    if (parsed.reblog) |_| {
        const by = if (parsed.account) |a| (a.acct orelse "?") else "?";
        try out.appendSlice(allocator, "Boosted by ");
        try out.appendSlice(allocator, by);
        try out.append(allocator, '\n');
    }

    const acct = if (parsed.account) |a| (a.acct orelse "?") else "?";
    const display = if (parsed.account) |a| (a.display_name orelse "") else "";
    const visibility = parsed.visibility orelse "?";
    const created_at = parsed.created_at orelse "?";

    // `{acct} ({display}) [{visibility}] - {date}`, one line.
    try out.appendSlice(allocator, acct);
    if (display.len != 0 and !std.mem.eql(u8, display, acct)) {
        try out.appendSlice(allocator, " (");
        try out.appendSlice(allocator, display);
        try out.appendSlice(allocator, ")");
    }
    try out.appendSlice(allocator, " [");
    try out.appendSlice(allocator, visibility);
    try out.appendSlice(allocator, "] - ");
    try out.appendSlice(allocator, created_at);
    try out.append(allocator, '\n');

    // The body as terminal text, the links it pointed at, then a blank line to
    // separate it from the next status. A rendering failure must not drop the
    // status itself, so it degrades to an empty body.
    var text = htmltext.render(allocator, parsed.content orelse "", .{}) catch htmltext.Text{};
    defer text.deinit(allocator);

    if (text.body.items.len != 0) {
        try out.appendSlice(allocator, text.body.items);
        try out.append(allocator, '\n');
    }
    if (text.links.items.len != 0) {
        try out.appendSlice(allocator, "\nLinks:\n");
        for (text.links.items) |link| {
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, link.href);
            try out.append(allocator, '\n');
        }
    }
    try out.append(allocator, '\n');

    if (parsed.media_attachments) |media| {
        for (media) |m| {
            const url = m.url orelse continue;
            const kind = m.type orelse "media";

            // The picture, if there is one, is appended right after its URL
            // line, inside the same buffer: writing it to stdout here put it
            // before the toot and let the URL line overwrite its bottom rows.
            if (cache_dir) |dir| {
                try images.place(allocator, io, dir, out, kind, url);
            } else {
                try out.append(allocator, '[');
                try out.appendSlice(allocator, kind);
                try out.appendSlice(allocator, "] ");
                try out.appendSlice(allocator, url);
                try out.append(allocator, '\n');
            }
        }
    }

    return true;
}

/// Renders and queues one status. Returns false if the payload was not
/// understood. `cache_dir` is the image cache, or `null` for text only.
pub fn deliver(io: std.Io, allocator: std.mem.Allocator, cache_dir: ?std.Io.Dir, json: []const u8) bool {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    const ok = render(io, allocator, cache_dir, json, &line) catch return false;
    if (!ok or line.items.len == 0) return false;

    // `writeSeparated`, not `write`: the rule above everything but the first
    // status is drawn in `out.zig`, so `render` keeps producing plain text.
    output.writeSeparated(io, line.items);
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// `render` takes an `Io` for its image lookups. These tests use no cache, so a
/// fresh single-threaded instance is enough, and it needs no cleanup.
fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init_single_threaded;
    return threaded.io();
}

fn renderAlloc(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try testing.expect(try render(testIo(), allocator, null, json, &out));
    return out.toOwnedSlice(allocator);
}

test "plain status" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"<p>hello</p>","created_at":"2026-11-24T10:00:00.000Z",
        \\ "visibility":"public","account":{"acct":"alice","display_name":"Alice"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings(
        "alice (Alice) [public] - 2026-11-24T10:00:00.000Z\n" ++
            "hello\n\n",
        line,
    );
}

test "empty display name is omitted" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"hi","created_at":"t","visibility":"unlisted",
        \\ "account":{"acct":"bob","display_name":""}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("bob [unlisted] - t\nhi\n\n", line);
}

test "a boost is marked but not expanded" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"","created_at":"t","visibility":"public",
        \\ "reblog":{"content":"inner","account":{"acct":"carol"}},
        \\ "account":{"acct":"dave","display_name":"Dave"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings(
        "Boosted by dave\ndave (Dave) [public] - t\n\n",
        line,
    );
    // The nested author must not appear: it belongs to the boosted status.
    try testing.expect(std.mem.indexOf(u8, line, "carol") == null);
}

test "HTML is reduced to text" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"<p>a &amp; b</p><br/>c","created_at":"t","visibility":"public",
        \\ "account":{"acct":"e"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("e [public] - t\na & b\nc\n\n", line);
}

test "links are listed after the body" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"<p>see <a href='https://example.com/a'>this</a></p>",
        \\ "created_at":"t","visibility":"public","account":{"acct":"g"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings(
        "g [public] - t\nsee this\n\nLinks:\n  https://example.com/a\n\n",
        line,
    );
}

test "media attachments are listed with their type" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"x","created_at":"t","visibility":"public","account":{"acct":"f"},
        \\ "media_attachments":[{"url":"https://h/1.png","type":"image"},{"type":"video"}]}
    );
    defer arena.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "[image] https://h/1.png") != null);
    // No url: nothing is printed for that entry.
    try testing.expect(std.mem.indexOf(u8, line, "[video]") == null);
}

test "missing fields degrade instead of failing" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena, "{}");
    defer arena.free(line);
    try testing.expectEqualStrings("? [?] - ?\n\n", line);
}

test "a non-object payload is rejected" {
    const arena = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try testing.expect(!try render(testIo(), arena, null, "[1,2,3]", &out));
    try testing.expect(!try render(testIo(), arena, null, "nope", &out));
}

