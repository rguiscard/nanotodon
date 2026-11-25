//! Renders one status (a Mastodon `update` event, or an element of the
//! `api/v1/timelines/*` array) as plain text.
//!
//! This replaces the C `stream_event_update()`. The HTML `content` is reduced
//! to terminal text by `htmltext.zig`: block tags become line breaks, character
//! references are decoded and the links an anchor pointed at are listed after
//! the body. Colour and real emoji are still out of scope; a custom emoji
//! survives as its `:shortcode:`.
//!
//! A boost (`reblog`) is expanded: a `Boosted by {acct}` line names the
//! booster, then the boosted status is rendered underneath it exactly as a
//! top-level status would be (its own author line, body, links and media),
//! flush left. The wrapper's own author line is not printed: it would repeat
//! the booster, and Mastodon leaves the wrapper's content empty anyway.
//!
//! Every status becomes one string, images included, and the rule that opens it
//! is part of that string: the rule is the status's first line, so whoever
//! renders a status decides what a status looks like, and `out.zig` only has to
//! serialise bytes. Every status gets one, the first included, because in a
//! scrolling terminal even the first status has text above it to be set apart
//! from.
//!
//! One buffer per status also keeps pictures with their text: a boost stays one
//! unit, with the nested status and its media in the same buffer as the text
//! that names them.

const std = @import("std");
const zz = @import("zigzag");
const output = @import("out.zig");
const images = @import("image.zig");
const htmltext = @import("htmltext.zig");

/// How deep a chain of boosts is followed. Mastodon never returns a boost of a
/// boost (the API flattens it to one level), but a hand-made payload could nest
/// without end: past this the `Boosted by` line is still printed and the
/// descent stops, so a hostile status cannot exhaust the stack.
const max_depth = 3;

/// Width of the rule above a status, in columns. Fixed rather than measured:
/// asking the terminal costs a syscall per status and makes `render` depend on
/// the terminal, while a fixed rule keeps rendering a pure function of the
/// status. A narrow rule also reads as a divider between toots rather than as a
/// frame around each one.
const rule_width = 30;

/// The account line's look: a background bar behind `{acct} ({display})
/// [{visibility}] - {date}`, so the eye lands on who wrote the toot. Only the
/// text is wrapped — the newline after it is written outside the style, so the
/// background covers exactly one line and stops before the body.
///
/// An experiment: swap `background` for a `foreground`, add `.bold_attr = true`,
/// or try another `zz.Color`. Nothing else in the file needs to change.
const account_style: zz.Style = .{ .background = zz.Color.blue, .inline_mode = true };

/// The `Boosted by {acct}` line's look, driven the same way as `account_style`.
/// A different colour because it labels the wrapper, not the author of the toot
/// underneath it.
const boost_style: zz.Style = .{ .background = zz.Color.green, .inline_mode = true };

/// Renders `text` with `style` and appends it to `out`. The slice `Style.render`
/// returns is freed straight away: the bytes are copied into `out`, which is the
/// buffer the caller keeps.
fn appendStyled(allocator: std.mem.Allocator, style: zz.Style, text: []const u8, out: *std.ArrayList(u8)) !void {
    const styled = try style.render(allocator, text);
    defer allocator.free(styled);
    try out.appendSlice(allocator, styled);
}

/// Glyph the rule is drawn with: box-drawing U+2500, one column wide in every
/// font that has it.
const rule_glyph = "\u{2500}";

/// The rule, ready to prepend, ending in the newline that makes it a line.
const rule: [rule_width * rule_glyph.len + 1]u8 = blk: {
    var buf: [rule_width * rule_glyph.len + 1]u8 = undefined;
    var n: usize = 0;
    while (n < rule_width * rule_glyph.len) : (n += rule_glyph.len) {
        @memcpy(buf[n..][0..rule_glyph.len], rule_glyph);
    }
    buf[n] = '\n';
    break :blk buf;
};

/// Renders one status into `out`. Returns false when the payload is not a JSON
/// object this code understands.
///
/// `cache_dir` is where image attachments are cached; pass `null` to skip them
/// (tests, or a build without -Dimage).
///
/// This is the byte-based entry point the stream and the startup timeline share.
/// The element is parsed once into a `std.json.Value`; rendering then walks
/// values (`renderValue`), so a boost can hand its nested object to the same
/// formatter without re-encoding it as JSON.
///
/// Every status opens with the rule, the first one included: this is a scrolling
/// terminal, so the text above a status may be a prompt or whatever a previous
/// run left there. The rule says where the status starts, and keeping it on all
/// of them means `render` needs no memory of what came before.
///
/// The rule is drawn here, once, above everything else: a boost gets one rule
/// over its `Boosted by` line, and `renderValue` never draws one while it
/// recurses into the boosted status.
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
    var parsed_state = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return false;
    defer parsed_state.deinit();
    // The object check comes before the rule: a payload that is not a status is
    // rejected with nothing written, not even a rule with no status under it.
    if (parsed_state.value != .object) return false;
    try out.appendSlice(allocator, &rule);
    return renderValue(io, allocator, cache_dir, parsed_state.value, out, 0) catch return false;
}

/// Renders one already-parsed status (a JSON object) into `out`.
///
/// `depth` counts the boosts already followed; the caller's status is 0. The
/// field walk never fails on a missing or mistyped member: such a field degrades
/// to the placeholder the old `Wire` struct produced (`?`, empty body), because a
/// status that arrived is worth showing even when one field is odd. Only a
/// non-object status is rejected, which is how a payload the caller should drop
/// is recognised.
///
/// A boost is expanded: `Boosted by {booster}` then the nested status rendered
/// in full, flush left, under the same author/body/links/media rules. The
/// wrapper contributes only that line — its author line would repeat the
/// booster, and its content is empty in Mastodon's own payloads.
fn renderValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_dir: ?std.Io.Dir,
    status: std.json.Value,
    out: *std.ArrayList(u8),
    depth: usize,
) !bool {
    if (status != .object) return false;
    const object = status.object;

    if (boosterName(object)) |by| {
        // Styled as one string, like the account line, so the bar covers the
        // booster's name and nothing else.
        var label: std.ArrayList(u8) = .empty;
        defer label.deinit(allocator);
        try label.appendSlice(allocator, "Boosted by ");
        try label.appendSlice(allocator, by);
        try appendStyled(allocator, boost_style, label.items, out);
        try out.append(allocator, '\n');

        if (depth < max_depth) {
            if (object.get("reblog")) |reblog| {
                if (try renderValue(io, allocator, cache_dir, reblog, out, depth + 1)) return true;
            }
        }
        // No usable nested status (a mistyped `reblog`, or the depth cap): the
        // header is all there is to show for this one.
        try out.append(allocator, '\n');
        return true;
    }

    const acct = optString(object, &.{ "account", "acct" }) orelse "?";
    const display = optString(object, &.{ "account", "display_name" }) orelse "";
    const visibility = optString(object, &.{"visibility"}) orelse "?";
    const created_at = optString(object, &.{"created_at"}) orelse "?";

    // `{acct} ({display}) [{visibility}] - {date}`, one line on a background
    // bar. Built into a scratch buffer first because `Style.render` needs the
    // whole line as one string, then styled and appended in one go.
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(allocator);
    try header.appendSlice(allocator, acct);
    if (display.len != 0 and !std.mem.eql(u8, display, acct)) {
        try header.appendSlice(allocator, " (");
        try header.appendSlice(allocator, display);
        try header.appendSlice(allocator, ")");
    }
    try header.appendSlice(allocator, " [");
    try header.appendSlice(allocator, visibility);
    try header.appendSlice(allocator, "] - ");
    try header.appendSlice(allocator, created_at);
    try appendStyled(allocator, account_style, header.items, out);
    try out.append(allocator, '\n');

    // The body as terminal text, the links it pointed at, then a blank line to
    // separate it from the next status. A rendering failure must not drop the
    // status itself, so it degrades to an empty body.
    var text = htmltext.render(allocator, optString(object, &.{"content"}) orelse "", .{}) catch htmltext.Text{};
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

    if (object.get("media_attachments")) |value| {
        if (value == .array) {
            for (value.array.items) |m| {
                if (m != .object) continue;
                const url = optString(m.object, &.{"url"}) orelse continue;
                const kind = optString(m.object, &.{"type"}) orelse "media";

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
    }

    return true;
}

/// The booster's `acct` when this status is a boost, or null when it is not.
///
/// A boost is a `reblog` member that holds an object. Mastodon sends
/// `"reblog": null` on every ordinary status, and the boosted status itself
/// carries `"reblog": null` too, so testing for the key's presence alone made
/// every status look like a boost: the nested one produced a second
/// `Boosted by` line and stopped, which is why no content ever appeared.
fn boosterName(object: std.json.ObjectMap) ?[]const u8 {
    const reblog = object.get("reblog") orelse return null;
    if (reblog != .object) return null;
    return optString(object, &.{ "account", "acct" }) orelse "?";
}

/// A string member of `object`, or of the (possibly absent) member `section`.
/// `optString(o, &.{"content"})` reads `o.content`;
/// `optString(o, &.{ "account", "acct" })` reads `o.account.acct`. Anything that
/// is not a JSON string — a number, null, an absent or non-object section —
/// reads as null, so the caller's default applies.
fn optString(object: std.json.ObjectMap, path: []const []const u8) ?[]const u8 {
    var current = object;
    for (path, 0..) |key, i| {
        const value = current.get(key) orelse return null;
        if (i + 1 == path.len) {
            return switch (value) {
                .string => |s| s,
                else => null,
            };
        }
        if (value != .object) return null;
        current = value.object;
    }
    return null;
}

/// Renders and queues one status. Returns false if the payload was not
/// understood. `cache_dir` is the image cache, or `null` for text only.
pub fn deliver(io: std.Io, allocator: std.mem.Allocator, cache_dir: ?std.Io.Dir, json: []const u8) bool {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    const ok = render(io, allocator, cache_dir, json, &line) catch return false;
    if (!ok or line.items.len == 0) return false;

    // `writeLineStart`, not `write`: a prompt or an image escape may have left
    // the cursor mid-line, and the rule must not land on the end of that line.
    output.writeLineStart(io, line.items);
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

/// Renders `json` with its rule stripped and its ANSI codes removed. Every
/// status opens with the rule and its account line is styled, so taking both off
/// lets the tests below assert the visible text; the rule and the styling have
/// their own tests.
fn renderAlloc(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try testing.expect(try render(testIo(), allocator, null, json, &out));
    try testing.expect(std.mem.startsWith(u8, out.items, &rule));
    return plain(allocator, out.items[rule.len..]);
}

/// `text` with every SGR sequence (`ESC [ … m`) removed: the bytes a reader
/// sees, without the colour. No other escape kind is expected in a status.
fn plain(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "\x1b[")) {
            const end = std.mem.indexOfScalarPos(u8, text, i + 2, 'm') orelse break;
            i = end + 1;
            continue;
        }
        try buf.append(allocator, text[i]);
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

test "the account line is styled and the body is not" {
    const arena = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try testing.expect(try render(testIo(), arena, null,
        \\{"content":"<p>hello</p>","created_at":"t","visibility":"public",
        \\ "account":{"acct":"alice"}}
    , &out));

    // The account line opens with the background colour and is closed with a
    // reset before its newline; the body after it carries no escape at all.
    const status = out.items[rule.len..];
    try testing.expect(std.mem.indexOf(u8, status, "\x1b[44m") != null);
    const header_end = std.mem.indexOfScalar(u8, status, '\n') orelse unreachable;
    try testing.expect(std.mem.indexOf(u8, status[0..header_end], "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, status[header_end..], "\x1b[") == null);

    // Stripped, it is exactly the text the other tests compare against.
    const text = try plain(arena, out.items[rule.len..]);
    defer arena.free(text);
    try testing.expectEqualStrings("alice [public] - t\nhello\n\n", text);
}

test "the rule is the status's first line" {
    const arena = testing.allocator;
    const json =
        \\{"content":"<p>hello</p>","created_at":"t","visibility":"public",
        \\ "account":{"acct":"alice"}}
    ;
    const full = try renderAlloc(arena, json);
    defer arena.free(full);
    try testing.expectEqualStrings("alice [public] - t\nhello\n\n", full);

    // The full buffer is the rule followed by that text, and a second call
    // yields the same bytes: `render` remembers nothing between statuses.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try testing.expect(try render(testIo(), arena, null, json, &out));
    // The rule, then the styled account line and body; compared as visible text
    // because the account line carries colour.
    const text = try plain(arena, out.items);
    defer arena.free(text);
    try testing.expectEqualStrings(
        "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}" ++
            "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}" ++
            "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n" ++
            "alice [public] - t\nhello\n\n",
        text,
    );

    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(arena);
    try testing.expect(try render(testIo(), arena, null, json, &again));
    try testing.expectEqualStrings(out.items, again.items);
}

test "a boost gets one rule, above the boost line" {
    const arena = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    const json =
        \\{"created_at":"t","visibility":"public","account":{"acct":"dave"},
        \\ "reblog":{"content":"inner","created_at":"u","visibility":"public",
        \\           "account":{"acct":"carol"}}}
    ;
    try testing.expect(try render(testIo(), arena, null, json, &out));
    const text = try plain(arena, out.items[rule.len..]);
    defer arena.free(text);
    try testing.expectEqualStrings(
        "Boosted by dave\ncarol [public] - u\ninner\n\n",
        text,
    );
    // Exactly one rule: the nested status must not draw its own.
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, out.items[rule.len..], rule_glyph));
}

test "the boost line is green and the nested author line is blue" {
    const arena = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try testing.expect(try render(testIo(), arena, null,
        \\{"created_at":"t","visibility":"public","account":{"acct":"dave"},
        \\ "reblog":{"content":"inner","created_at":"u","visibility":"public",
        \\           "account":{"acct":"carol"}}}
    , &out));

    // First line after the rule: the green `Boosted by`. Second: the blue
    // account line of the boosted status.
    const body = out.items[rule.len..];
    const line1_end = std.mem.indexOfScalar(u8, body, '\n') orelse unreachable;
    const line1 = body[0..line1_end];
    const line2_end = std.mem.indexOfScalarPos(u8, body, line1_end + 1, '\n') orelse unreachable;
    const line2 = body[line1_end + 1 .. line2_end];

    try testing.expect(std.mem.indexOf(u8, line1, "\x1b[42m") != null);
    try testing.expect(std.mem.indexOf(u8, line2, "\x1b[44m") != null);
    // The body of the boosted toot carries no colour.
    try testing.expect(std.mem.indexOf(u8, body[line2_end..], "\x1b[") == null);
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

test "a boost renders the boosted status" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"","created_at":"t","visibility":"public",
        \\ "reblog":{"content":"inner","created_at":"u","visibility":"unlisted",
        \\           "account":{"acct":"carol","display_name":"Carol"}},
        \\ "account":{"acct":"dave","display_name":"Dave"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings(
        "Boosted by dave\n" ++
            "carol (Carol) [unlisted] - u\n" ++
            "inner\n\n",
        line,
    );
    // The wrapper's own author line is gone: `Boosted by` already names dave.
    try testing.expect(std.mem.indexOf(u8, line, "dave (Dave)") == null);
}

test "the wrapper's own body is not printed" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"<p>wrapper</p>","created_at":"t","visibility":"public",
        \\ "reblog":{"content":"inner","created_at":"u","visibility":"public",
        \\           "account":{"acct":"carol"}},
        \\ "account":{"acct":"dave"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings(
        "Boosted by dave\ncarol [public] - u\ninner\n\n",
        line,
    );
    try testing.expect(std.mem.indexOf(u8, line, "wrapper") == null);
}

test "links and media of a boosted status are rendered" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"","created_at":"t","visibility":"public","account":{"acct":"dave"},
        \\ "reblog":{"content":"<a href='https://e/x'>link</a>","created_at":"u",
        \\           "visibility":"public","account":{"acct":"carol"},
        \\           "media_attachments":[{"url":"https://h/1.png","type":"image"}]}}
    );
    defer arena.free(line);
    try testing.expect(std.mem.indexOf(u8, line, "Boosted by dave\ncarol [public] - u\n") != null);
    try testing.expect(std.mem.indexOf(u8, line, "Links:\n  https://e/x\n") != null);
    try testing.expect(std.mem.indexOf(u8, line, "[image] https://h/1.png\n") != null);
    // One status, one blank line at the end: the rule from out.zig still lands.
    try testing.expect(std.mem.endsWith(u8, line, "[image] https://h/1.png\n"));
}

test "a null reblog is not a boost" {
    // Every ordinary Mastodon status carries `"reblog": null`, and so does the
    // boosted status itself. Treating the key's presence as "is a boost" made
    // the nested status print a second header and hide its own content.
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"<p>just a toot</p>","created_at":"t","visibility":"public",
        \\ "reblog":null,"account":{"acct":"alice"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("alice [public] - t\njust a toot\n\n", line);
}

test "a boost whose nested status has reblog null" {
    // The shape mastodon actually sends: the nested status is not a boost.
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"","created_at":"t","visibility":"public","reblog":
        \\ {"content":"<p>original</p>","created_at":"u","visibility":"public",
        \\  "reblog":null,"account":{"acct":"carol","display_name":"Carol"}},
        \\ "account":{"acct":"dave"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings(
        "Boosted by dave\ncarol (Carol) [public] - u\noriginal\n\n",
        line,
    );
}

test "a mistyped reblog is not a boost" {
    // `reblog` that is not an object cannot be expanded, and it does not make
    // the status a boost either: the status renders as its own toot.
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"content":"<p>mine</p>","created_at":"t","visibility":"public",
        \\ "reblog":5,"account":{"acct":"dave"}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("dave [public] - t\nmine\n\n", line);
}

test "deep nested boosts stop at the depth cap" {
    // A private arena: the intermediate wrappers are built by `allocPrint` and
    // never freed one by one, so `deinit` clears them all at once.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Five boosters wrap one plain status. Built from the inside out because
    // hand-written JSON at that nesting is unreadable: `{reblog:{...},account}`
    // for booster `e4`, then for `e3`, and so on, with `e0` outermost.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(arena);
    try json.appendSlice(arena,
        \\{"content":"bottom","created_at":"t","visibility":"public","account":{"acct":"zed"}}
    );
    var i: usize = 4;
    while (true) {
        const wrapped = try std.fmt.allocPrint(arena,
            "{{\"reblog\":{s},\"account\":{{\"acct\":\"e{d}\"}}}}", .{ json.items, i });
        json.clearRetainingCapacity();
        try json.appendSlice(arena, wrapped);
        if (i == 0) break;
        i -= 1;
    }

    const line = try renderAlloc(arena, json.items);
    defer arena.free(line);
    // depth 0..2 follow the nesting; the fourth header prints and stops.
    try testing.expectEqualStrings(
        "Boosted by e0\nBoosted by e1\nBoosted by e2\nBoosted by e3\n\n",
        line,
    );
    try testing.expect(std.mem.indexOf(u8, line, "zed") == null);
}

test "a boost without a booster acct still renders" {
    const arena = testing.allocator;
    const line = try renderAlloc(arena,
        \\{"reblog":{"content":"inner","created_at":"u","visibility":"public",
        \\           "account":{"acct":"carol"}}}
    );
    defer arena.free(line);
    try testing.expectEqualStrings("Boosted by ?\ncarol [public] - u\ninner\n\n", line);
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
    // Rejected before anything is written, not even the rule.
    try testing.expectEqual(@as(usize, 0), out.items.len);

    // A non-object `reblog` is not a boost either; the status renders as a
    // plain toot with the usual degraded placeholders.
    try testing.expect(try render(testIo(), arena, null, "{\"reblog\":[1]}", &out));
    try testing.expect(std.mem.startsWith(u8, out.items, &rule));
    const text = try plain(arena, out.items[rule.len..]);
    defer arena.free(text);
    try testing.expectEqualStrings("? [?] - ?\n\n", text);
}

