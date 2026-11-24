//! Turns the HTML of a Mastodon status `content` field into terminal text.
//!
//! This is not a general HTML renderer: toots are small, server-sanitised
//! documents with a closed tag set (`p`, `br`, `a`, `span`, `ul`/`li`,
//! `blockquote`, `pre`, and `img` for custom emoji). The rewriter is a single
//! pass over the source with no tree, no recursion and no dependency.
//!
//! Media is *not* handled here: `media_attachments` comes from the status JSON.
//! The one `img` case that does matter is a custom emoji, whose shortcode only
//! exists as the `alt` text.
//!
//! ## Invariants (these are what keep future features from becoming refactors)
//!
//! 1. `Text.body` is append-only and final. Nothing is rewritten afterwards and
//!    no placeholder is searched for later, so every `Span` in `Text` is valid
//!    in final coordinates the moment it is recorded.
//! 2. Every byte reaches `body` through `Ctx.emit` (or `Ctx.emitRaw` inside a
//!    `pre`). Suppression, line-start trimming and any future "hide this
//!    element" rule are one gate in one function.
//! 3. Element semantics are driven by an open-tag stack with flags, never by a
//!    depth counter keyed on a tag *name*: `<span class="h-card"><span>u</span>`
//!    is enough to break naive counters.
//! 4. Attribute access is generic (`AttrIter`) and yields raw spans; decoding
//!    happens only where a value is actually emitted.
//! 5. New behaviour is additive: a bit in the flag word, a side list in `Text`,
//!    a few lines in `startTag`/`endTag`. The tokenizer, entity decoder,
//!    whitespace rules and `emit` gate do not change.
//! 6. Bad markup never causes an error: only `OutOfMemory` escapes.

const std = @import("std");

const Error = std.mem.Allocator.Error;

pub const Span = struct {
    start: usize = 0,
    len: usize = 0,

    pub fn slice(self: Span, source: []const u8) []const u8 {
        return source[self.start..][0..self.len];
    }
};

/// One `<a href>` found in the body.
pub const Link = struct {
    /// Entity-decoded href, owned by `Text`.
    href: []const u8,
    /// Where the anchor's visible text sits in `Text.body`. `len == 0` when the
    /// anchor had no text (the href was then emitted inline instead).
    text: Span,
};

/// The result of one rewriter run. Free with `deinit`.
pub const Text = struct {
    body: std.ArrayList(u8) = .empty,
    links: std.ArrayList(Link) = .empty,
    /// Where each emitted `:shortcode:` sits in `body`. Unused today; it is the
    /// seam for rendering custom emoji as images or replacing them with unicode.
    emoji: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Text, gpa: std.mem.Allocator) void {
        for (self.links.items) |link| gpa.free(link.href);
        self.links.deinit(gpa);
        self.emoji.deinit(gpa);
        self.body.deinit(gpa);
    }
};

/// Which anchors end up in `Text.links`.
pub const LinkPolicy = enum {
    /// No link list at all.
    none,
    /// Only when the visible text is not already the URL. Quietest, but on
    /// Mastodon this is usually empty (the visible text reconstructs the URL).
    differs,
    /// Every http(s)/mailto href, deduplicated, in document order.
    always,
};

pub const Options = struct {
    links: LinkPolicy = .always,
    /// Emit `:shortcode:` for `<img class="custom-emoji" alt=":x:">`.
    emoji_shortcodes: bool = true,
    /// Drop the text of `<span class="invisible">`. Mastodon uses these spans to
    /// show a shortened URL while keeping the full URL in the href.
    suppress_invisible: bool = false,
    /// Resolve a shortcode to replacement bytes. `null` emits `:shortcode:`.
    /// Called during the pass, before any span is recorded, so the replacement
    /// inherits the shortcode's span.
    emoji_resolve: ?*const fn (shortcode: []const u8, ctx: ?*anyopaque) ?[]const u8 = null,
    emoji_ctx: ?*anyopaque = null,
};

// --- element flags --------------------------------------------------------
//
// Recording a flag costs one bit on the open-tag stack. The behaviour behind a
// flag can be added later without touching the parser, which is why the unused
// ones stay: elliptic, quote and code are deliberate seams, not dead weight.

const f_invisible: u8 = 1 << 0;
const f_elliptic: u8 = 1 << 1;
const f_mention: u8 = 1 << 2;
const f_hashtag: u8 = 1 << 3;
const f_quote: u8 = 1 << 4;
const f_code: u8 = 1 << 5;
const f_pre: u8 = 1 << 6;

const stack_cap = 32;

const OpenTag = struct {
    name: Span,
    flags: u8 = 0,
};

const Anchor = struct {
    href: ?[]const u8,
    start: usize,
    flags: u8,
};

/// One decoded character reference. Four bytes cover every case: the named
/// entities below are one byte each and numeric ones are at most a UTF-8 long.
const Decoded = struct {
    bytes: [4]u8 = undefined,
    len: u8 = 0,
    /// Bytes consumed from the `&`.
    consumed: usize = 0,
};

/// Rewrites `html` into text. Never fails on markup; `error.OutOfMemory` only.
pub fn render(gpa: std.mem.Allocator, html: []const u8, opts: Options) Error!Text {
    var text: Text = .{};
    errdefer text.deinit(gpa);

    // Output can never exceed the input: tags shrink to nothing and every
    // character reference decodes to fewer bytes than it occupies.
    try text.body.ensureTotalCapacity(gpa, html.len);

    var ctx: Ctx = .{ .gpa = gpa, .html = html, .out = &text, .opts = opts };
    try ctx.run();

    // Trailing spaces can only survive at the very end, where no break follows.
    var n = text.body.items.len;
    while (n > 0 and isSpace(text.body.items[n - 1])) n -= 1;
    text.body.items.len = n;

    return text;
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    html: []const u8,
    out: *Text,
    opts: Options,

    stack: [stack_cap]OpenTag = undefined,
    depth: usize = 0,
    /// Pushes that did not fit. Their close tags are matched against this
    /// counter, so an overflowing document degrades (no flags) instead of
    /// corrupting the entries it did track.
    untracked: usize = 0,

    /// Driven by push/pop of entries carrying the matching flag, never by an
    /// unconditional increment on a tag name.
    suppress: usize = 0,
    pre: usize = 0,

    /// Inside `<script>`/`<style>`/`<title>`/`<textarea>`: everything up to the
    /// matching close tag is dropped.
    raw_end: ?[]const u8 = null,

    at_line_start: bool = true,
    pending_break: bool = false,

    anchor: ?Anchor = null,

    // --- the pass ---------------------------------------------------------

    fn run(self: *Ctx) Error!void {
        const h = self.html;
        var i: usize = 0;

        while (i < h.len) {
            if (self.raw_end) |end_name| {
                i = self.skipRaw(i, end_name);
                continue;
            }

            switch (h[i]) {
                '<' => i = try self.angle(i),
                '&' => {
                    if (entityAt(h[i..])) |d| {
                        try self.emit(d.bytes[0..d.len]);
                        i += d.consumed;
                    } else {
                        try self.emit("&");
                        i += 1;
                    }
                },
                else => {
                    var j = i;
                    while (j < h.len and h[j] != '<' and h[j] != '&') j += 1;
                    try self.emitText(h[i..j]);
                    i = j;
                },
            }
        }
    }

    /// Handles one `<`, returning the index after it.
    fn angle(self: *Ctx, i: usize) Error!usize {
        const h = self.html;

        if (startsWithIgnoreCase(h[i..], "<!--")) return skipComment(h, i);

        if (i + 1 >= h.len) {
            try self.emit(h[i..]);
            return h.len;
        }

        const next = h[i + 1];
        if (next == '!' or next == '?') {
            const scan = scanTagTail(h, i + 2);
            return if (scan.end < h.len) scan.end + 1 else h.len;
        }
        if (next == '/') {
            if (i + 2 < h.len and std.ascii.isAlphabetic(h[i + 2])) return self.endTag(i);
            try self.emit("<");
            return i + 1;
        }
        if (std.ascii.isAlphabetic(next)) return self.startTag(i);

        // A bare `<` in text (`a < b`), which sanitised toot HTML should not
        // contain but other servers sometimes do.
        try self.emit("<");
        return i + 1;
    }

    fn startTag(self: *Ctx, i: usize) Error!usize {
        const h = self.html;
        const name_start = i + 1;
        var j = name_start;
        while (j < h.len and isNameChar(h[j])) j += 1;
        const name = h[name_start..j];

        const scan = scanTagTail(h, j);
        const attr_raw = h[j..scan.end];
        const next_i = if (scan.end < h.len) scan.end + 1 else h.len;

        const attrs = scanAttrs(attr_raw);
        const flags = classFlags(attrs.class);

        if (nameEql(name, "br") or nameEql(name, "hr")) {
            self.newline();
            return next_i;
        }
        if (nameEql(name, "img")) {
            try self.emitImage(attr_raw);
            return next_i;
        }
        if (isBlock(name)) {
            self.newline();
            self.pushTag(name, flags);
            return next_i;
        }
        if (nameEql(name, "pre")) {
            self.newline();
            self.pushTag(name, flags | f_pre);
            return next_i;
        }
        if (isRawTag(name)) {
            // Script/style/title/textarea text is not content: drop it verbatim.
            self.newline();
            self.raw_end = name;
            self.pushTag(name, flags);
            return next_i;
        }
        if (nameEql(name, "a")) {
            // An unterminated anchor is closed here rather than ignored, so a
            // broken toot cannot swallow the links of everything after it.
            if (self.anchor != null) try self.finishAnchor();
            self.anchor = .{ .href = attrs.href, .start = self.out.body.items.len, .flags = flags };
            self.pushTag(name, flags);
            return next_i;
        }

        self.pushTag(name, flags);
        return next_i;
    }

    fn endTag(self: *Ctx, i: usize) Error!usize {
        const h = self.html;
        var j = i + 2;
        while (j < h.len and isNameChar(h[j])) j += 1;
        const name = h[i + 2 .. j];

        const scan = scanTagTail(h, j);
        const next_i = if (scan.end < h.len) scan.end + 1 else h.len;

        if (isBlock(name) or nameEql(name, "pre") or isRawTag(name)) self.newline();
        if (nameEql(name, "a")) try self.finishAnchor();

        self.popTag(name);
        return next_i;
    }

    fn skipRaw(self: *Ctx, i: usize, end_name: []const u8) usize {
        const h = self.html;
        var k = i;
        while (k < h.len) {
            while (k < h.len and h[k] != '<') k += 1;
            if (k >= h.len) return h.len;

            const after_name = k + 2 + end_name.len;
            if (k + 2 < h.len and h[k + 1] == '/' and after_name <= h.len and
                nameEql(h[k + 2 .. after_name], end_name))
            {
                var m = after_name;
                while (m < h.len and h[m] != '>') m += 1;
                self.raw_end = null;
                self.popTag(end_name);
                return if (m < h.len) m + 1 else h.len;
            }
            k += 1;
        }
        return h.len;
    }

    // --- stack ------------------------------------------------------------

    fn pushTag(self: *Ctx, name: []const u8, flags: u8) void {
        if (self.depth == stack_cap) {
            self.untracked += 1;
            return;
        }
        const start = @intFromPtr(name.ptr) - @intFromPtr(self.html.ptr);
        self.stack[self.depth] = .{ .name = .{ .start = start, .len = name.len }, .flags = flags };
        self.depth += 1;
        if ((flags & f_invisible) != 0) self.suppress += 1;
        if ((flags & f_pre) != 0) self.pre += 1;
    }

    fn popTag(self: *Ctx, name: []const u8) void {
        var i = self.depth;
        while (i > 0) {
            i -= 1;
            if (nameEql(self.stack[i].name.slice(self.html), name)) {
                while (self.depth > i) {
                    self.depth -= 1;
                    self.leave(self.stack[self.depth].flags);
                }
                return;
            }
        }
        if (self.untracked > 0) self.untracked -= 1;
    }

    fn leave(self: *Ctx, flags: u8) void {
        if ((flags & f_invisible) != 0 and self.suppress > 0) self.suppress -= 1;
        if ((flags & f_pre) != 0 and self.pre > 0) self.pre -= 1;
    }

    // --- emitting ---------------------------------------------------------

    fn newline(self: *Ctx) void {
        self.pending_break = true;
        self.at_line_start = true;
    }

    /// Appends one pending break. Consecutive breaks collapse, so `<p>a</p><p>b</p>`,
    /// `<br><br>` and a source blank line all produce a single newline.
    fn flushBreak(self: *Ctx) Error!void {
        if (!self.pending_break) return;
        self.pending_break = false;

        const body = &self.out.body;
        if (body.items.len == 0) return;

        var n = body.items.len;
        while (n > 0 and (body.items[n - 1] == ' ' or body.items[n - 1] == '\t')) n -= 1;
        body.items.len = n;

        if (n == 0 or body.items[n - 1] == '\n') return;
        try body.append(self.gpa, '\n');
    }

    fn emit(self: *Ctx, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        if (self.opts.suppress_invisible and self.suppress > 0) return;

        var from: usize = 0;
        if (self.at_line_start and self.pre == 0) {
            while (from < bytes.len and (bytes[from] == ' ' or bytes[from] == '\t')) from += 1;
            if (from == bytes.len) return;
        }

        try self.flushBreak();
        try self.out.body.appendSlice(self.gpa, bytes[from..]);
        self.at_line_start = false;
    }

    /// Verbatim append for `pre`: keeps indentation and blank lines as written.
    fn emitRaw(self: *Ctx, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        if (self.opts.suppress_invisible and self.suppress > 0) return;

        try self.flushBreak();
        try self.out.body.appendSlice(self.gpa, bytes);
        self.at_line_start = bytes[bytes.len - 1] == '\n';
    }

    fn emitText(self: *Ctx, run_slice: []const u8) Error!void {
        if (self.pre > 0) return self.emitRaw(run_slice);

        var i: usize = 0;
        while (i < run_slice.len) {
            const c = run_slice[i];
            if (c == '\n' or c == '\r') {
                self.newline();
                i += 1;
                continue;
            }
            var j = i;
            while (j < run_slice.len and run_slice[j] != '\n' and run_slice[j] != '\r') j += 1;
            try self.emit(run_slice[i..j]);
            i = j;
        }
    }

    // --- links and images -------------------------------------------------

    fn finishAnchor(self: *Ctx) Error!void {
        const anchor = self.anchor orelse return;
        self.anchor = null;

        const body = self.out.body.items;
        const start = @min(anchor.start, body.len);
        const slice = body[start..];
        const trimmed = std.mem.trim(u8, slice, " \t\n\r\x0c");
        const lead = @intFromPtr(trimmed.ptr) - @intFromPtr(slice.ptr);

        const href_raw = anchor.href orelse return;
        if (href_raw.len == 0) return;

        const href = try decodeAlloc(self.gpa, href_raw);
        if (!startsWithIgnoreCase(href, "http://") and
            !startsWithIgnoreCase(href, "https://") and
            !startsWithIgnoreCase(href, "mailto:"))
        {
            self.gpa.free(href);
            return;
        }

        // Everything that reads `trimmed` is decided before anything is
        // emitted: emitting can reallocate `body`, which would leave `trimmed`
        // dangling.
        const text_span: Span = .{ .start = start + lead, .len = trimmed.len };
        // Mentions and hashtags point at the fediverse, not at something to
        // open. The class flags cover Mastodon; the text prefix covers servers
        // that mark them differently.
        const social = (anchor.flags & (f_mention | f_hashtag)) != 0 or
            (trimmed.len > 0 and (trimmed[0] == '@' or trimmed[0] == '#'));
        const keep = switch (self.opts.links) {
            .none => false,
            .always => true,
            .differs => !std.mem.eql(u8, trimmed, href),
        };

        // An empty anchor loses its target unless the href goes inline.
        if (trimmed.len == 0) {
            self.emit(href) catch |err| {
                self.gpa.free(href);
                return err;
            };
        }

        if (social or !keep) {
            self.gpa.free(href);
            return;
        }
        for (self.out.links.items) |link| {
            if (std.mem.eql(u8, link.href, href)) {
                self.gpa.free(href);
                return;
            }
        }

        self.out.links.append(self.gpa, .{ .href = href, .text = text_span }) catch |err| {
            self.gpa.free(href);
            return err;
        };
    }

    /// The single place where an `img` is interpreted. Media comes from the
    /// status JSON; only a custom-emoji shortcode lives in the HTML alone.
    fn emitImage(self: *Ctx, attr_raw: []const u8) Error!void {
        if (!self.opts.emoji_shortcodes) return;
        // Checked before flushing a break, so a hidden image cannot leave a
        // stray newline behind.
        if (self.opts.suppress_invisible and self.suppress > 0) return;

        const attrs = scanAttrs(attr_raw);
        const alt_raw = attrs.alt orelse attrs.title orelse return;
        if (alt_raw.len == 0) return;

        const alt = try decodeAlloc(self.gpa, alt_raw);
        defer self.gpa.free(alt);

        const is_shortcode = alt.len > 2 and alt[0] == ':' and alt[alt.len - 1] == ':';
        if (!is_shortcode) return;

        var replacement: []const u8 = alt;
        if (self.opts.emoji_resolve) |resolve| {
            if (resolve(alt, self.opts.emoji_ctx)) |resolved| replacement = resolved;
        }

        // Flush first so the recorded span starts at the shortcode, not at a break.
        try self.flushBreak();
        const start = self.out.body.items.len;
        try self.emit(replacement);
        const len = self.out.body.items.len - start;
        if (len == 0) return;
        try self.out.emoji.append(self.gpa, .{ .start = start, .len = len });
    }
};

// --- character classes and small helpers -----------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isNameChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ':' => true,
        else => false,
    };
}

fn nameEql(name: []const u8, other: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, other);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn skipComment(h: []const u8, i: usize) usize {
    var k = i + 4;
    while (k + 2 < h.len) : (k += 1) {
        if (h[k] == '-' and h[k + 1] == '-' and h[k + 2] == '>') return k + 3;
    }
    return h.len;
}

const TagScan = struct {
    /// Index of `>` (or `h.len` when the tag is unterminated).
    end: usize,
    self_closing: bool,
};

/// Finds the end of a tag, skipping quoted attribute values so a `>` inside a
/// value cannot truncate the tag.
///
/// A quote only opens a quoted value when it sits in value position (right after
/// `=`, spaces allowed). That keeps a stray `'` in an unquoted value
/// (`href=https://x/it's`) from swallowing the rest of the document.
fn scanTagTail(h: []const u8, from: usize) TagScan {
    var k = from;
    var quote: u8 = 0;
    var value_next = false;
    while (k < h.len) : (k += 1) {
        const c = h[k];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '>') return .{ .end = k, .self_closing = k > from and h[k - 1] == '/' };
        if (c == '=') {
            value_next = true;
            continue;
        }
        if (isSpace(c)) continue;
        if (value_next) {
            value_next = false;
            if (c == '"' or c == '\'') quote = c;
        }
    }
    return .{ .end = h.len, .self_closing = false };
}

// --- entity decoding ------------------------------------------------------

fn digitValue(c: u8, base: u32) ?u32 {
    const d: u32 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return null,
    };
    if (d >= base) return null;
    return d;
}

/// The named references Mastodon (and the common non-Mastodon servers) emit.
///
/// Deliberate limitation: this is not the WHATWG table. A full table is a few
/// thousand entries for a problem that sanitised toot HTML does not have.
fn namedEntity(name: []const u8) ?[]const u8 {
    const table = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "amp;", .value = "&" },
        .{ .name = "lt;", .value = "<" },
        .{ .name = "gt;", .value = ">" },
        .{ .name = "quot;", .value = "\"" },
        .{ .name = "apos;", .value = "'" },
        .{ .name = "nbsp;", .value = " " },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

/// Decodes the character reference at `s[0] == '&'`. `null` means "not a
/// reference", in which case the caller emits a literal `&`.
fn entityAt(s: []const u8) ?Decoded {
    if (s.len < 3 or s[0] != '&') return null;

    if (s[1] == '#') {
        var k: usize = 2;
        var base: u32 = 10;
        if (k < s.len and (s[k] == 'x' or s[k] == 'X')) {
            base = 16;
            k += 1;
        }
        const digits_from = k;
        var cp: u32 = 0;
        var too_big = false;
        while (k < s.len) : (k += 1) {
            const d = digitValue(s[k], base) orelse break;
            if (!too_big) {
                cp = cp * base + d;
                if (cp > 0x10FFFF) too_big = true;
            }
        }
        if (k == digits_from) return null;

        var consumed = k;
        if (consumed < s.len and s[consumed] == ';') consumed += 1;

        var decoded_num: Decoded = .{ .consumed = consumed };
        if (too_big or cp == 0 or (cp >= 0xD800 and cp <= 0xDFFF)) {
            @memcpy(decoded_num.bytes[0..3], "\u{FFFD}");
            decoded_num.len = 3;
            return decoded_num;
        }
        const n = std.unicode.utf8Encode(@intCast(cp), &decoded_num.bytes) catch {
            @memcpy(decoded_num.bytes[0..3], "\u{FFFD}");
            decoded_num.len = 3;
            return decoded_num;
        };
        decoded_num.len = n;
        return decoded_num;
    }

    var m: usize = 1;
    while (m < s.len and m <= 8 and s[m] != ';' and std.ascii.isAlphabetic(s[m])) m += 1;
    if (m >= s.len or s[m] != ';') return null;

    const value = namedEntity(s[1 .. m + 1]) orelse return null;
    var decoded: Decoded = .{ .consumed = m + 1, .len = @intCast(value.len) };
    @memcpy(decoded.bytes[0..value.len], value);
    return decoded;
}

/// Decodes a whole attribute value (href, alt) into an owned string.
fn decodeAlloc(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, raw.len);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (entityAt(raw[i..])) |d| {
                try out.appendSlice(gpa, d.bytes[0..d.len]);
                i += d.consumed;
                continue;
            }
        }
        try out.append(gpa, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// --- attributes -----------------------------------------------------------
//
// The scanner is generic on purpose: `href` is the only attribute used today,
// but `class` is already read (it drives the flags) and `alt`/`title` drive the
// emoji case. Adding another attribute is one line in `scanAttrs`.

const Attr = struct {
    name: []const u8,
    value: ?[]const u8,
};

const AttrIter = struct {
    rest: []const u8,
    i: usize = 0,

    pub fn next(self: *AttrIter) ?Attr {
        const s = self.rest;

        while (self.i < s.len and (isSpace(s[self.i]) or s[self.i] == '/')) self.i += 1;
        if (self.i >= s.len) return null;

        const name_start = self.i;
        while (self.i < s.len) : (self.i += 1) {
            const c = s[self.i];
            if (isSpace(c) or c == '=' or c == '/' or c == '>') break;
        }
        const name = s[name_start..self.i];
        // Malformed attribute: bail out instead of looping without progress.
        if (name.len == 0) return null;

        while (self.i < s.len and isSpace(s[self.i])) self.i += 1;

        var value: ?[]const u8 = null;
        if (self.i < s.len and s[self.i] == '=') {
            self.i += 1;
            while (self.i < s.len and isSpace(s[self.i])) self.i += 1;
            if (self.i < s.len and (s[self.i] == '"' or s[self.i] == '\'')) {
                const quote = s[self.i];
                self.i += 1;
                const value_start = self.i;
                while (self.i < s.len and s[self.i] != quote) self.i += 1;
                value = s[value_start..self.i];
                if (self.i < s.len) self.i += 1;
            } else {
                const value_start = self.i;
                while (self.i < s.len and !isSpace(s[self.i]) and s[self.i] != '>') self.i += 1;
                value = s[value_start..self.i];
            }
        }

        return .{ .name = name, .value = value };
    }
};

const TagAttrs = struct {
    href: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    title: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

/// One pass over a start tag's attributes. First occurrence wins, as HTML says.
fn scanAttrs(raw: []const u8) TagAttrs {
    var out: TagAttrs = .{};
    var it: AttrIter = .{ .rest = raw };
    while (it.next()) |attr| {
        if (nameEql(attr.name, "href")) {
            if (out.href == null) out.href = attr.value orelse "";
        } else if (nameEql(attr.name, "alt")) {
            if (out.alt == null) out.alt = attr.value orelse "";
        } else if (nameEql(attr.name, "title")) {
            if (out.title == null) out.title = attr.value orelse "";
        } else if (nameEql(attr.name, "class")) {
            if (out.class == null) out.class = attr.value orelse "";
        }
    }
    return out;
}

/// Maps the whitespace-separated tokens of `class` onto element flags.
fn classFlags(value: ?[]const u8) u8 {
    const v = value orelse return 0;
    var flags: u8 = 0;
    var it = std.mem.tokenizeAny(u8, v, " \t\n\r\x0c");
    while (it.next()) |token| {
        if (nameEql(token, "invisible")) {
            flags |= f_invisible;
        } else if (nameEql(token, "ellipsis")) {
            flags |= f_elliptic;
        } else if (nameEql(token, "mention")) {
            flags |= f_mention;
        } else if (nameEql(token, "hashtag")) {
            flags |= f_hashtag;
        } else if (nameEql(token, "quote-inline") or nameEql(token, "quote")) {
            flags |= f_quote;
        }
    }
    return flags;
}

fn isBlock(name: []const u8) bool {
    const blocks = [_][]const u8{
        "p",          "div",   "li",    "ul",  "ol",      "blockquote", "table",
        "tr",         "td",    "th",    "h1",  "h2",      "h3",         "h4",
        "h5",         "h6",    "dl",    "dt",  "dd",      "figure",     "figcaption",
        "article",    "section", "header", "footer", "aside", "main",    "nav",
    };
    for (blocks) |block| {
        if (nameEql(name, block)) return true;
    }
    return false;
}

fn isRawTag(name: []const u8) bool {
    const tags = [_][]const u8{ "script", "style", "title", "textarea" };
    for (tags) |tag| {
        if (nameEql(name, tag)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Convenience for `expectLinks` calls that must find nothing.
const no_links: []const []const u8 = &.{};

fn expectBody(gpa: std.mem.Allocator, html: []const u8, expected: []const u8) !void {
    var text = try render(gpa, html, .{});
    defer text.deinit(gpa);
    try testing.expectEqualStrings(expected, text.body.items);
}

fn expectLinks(
    gpa: std.mem.Allocator,
    html: []const u8,
    opts: Options,
    expected: []const []const u8,
) !void {
    var text = try render(gpa, html, opts);
    defer text.deinit(gpa);
    try testing.expectEqual(expected.len, text.links.items.len);
    for (expected, text.links.items) |want, got| {
        try testing.expectEqualStrings(want, got.href);
    }
}

test "a paragraph is its text" {
    try expectBody(testing.allocator, "<p>hello</p>", "hello");
}

test "each block starts a new line" {
    try expectBody(testing.allocator, "<p>a</p><p>b</p>", "a\nb");
    try expectBody(testing.allocator, "<div>a</div><div>b</div>", "a\nb");
    try expectBody(testing.allocator, "<ul><li>a</li><li>b</li></ul>", "a\nb");
}

test "br is a line break and repeats collapse" {
    try expectBody(testing.allocator, "<p>a<br>b</p>", "a\nb");
    try expectBody(testing.allocator, "<p>a<br/><br/><br/>b</p>", "a\nb");
    try expectBody(testing.allocator, "<p>a<br />b</p>", "a\nb");
}

test "inline elements contribute only their text" {
    try expectBody(
        testing.allocator,
        "<p>a <strong>b</strong> <em>c</em></p>",
        "a b c",
    );
}

test "character references are decoded once" {
    try expectBody(testing.allocator, "a &amp; b &lt; c &#39;q&#39;", "a & b < c 'q'");
    try expectBody(testing.allocator, "&#x1F600;", "\u{1F600}");
    try expectBody(testing.allocator, "&amp;amp;", "&amp;");
    try expectBody(testing.allocator, "a&nbsp;b", "a b");
}

test "unknown references stay literal" {
    try expectBody(testing.allocator, "&foo;", "&foo;");
    try expectBody(testing.allocator, "&#xZZ;", "&#xZZ;");
}

test "an empty body stays empty" {
    try expectBody(testing.allocator, "<p></p>", "");
    try expectBody(testing.allocator, "", "");
    try expectBody(testing.allocator, "   \n  ", "");
}

test "mentions and hashtags are not listed as links" {
    try expectLinks(
        testing.allocator,
        "<p><span class=\"h-card\"><a href=\"https://x/@u\" class=\"u-url mention\">@<span>u</span></a></span></p>",
        .{},
        no_links,
    );
    try expectLinks(
        testing.allocator,
        "<p><a href=\"https://x/tags/t\" class=\"mention hashtag\" rel=\"tag\">#<span>t</span></a></p>",
        .{},
        no_links,
    );
    try expectBody(
        testing.allocator,
        "<p><span class=\"h-card\"><a href=\"https://x/@u\" class=\"u-url mention\">@<span>u</span></a></span></p>",
        "@u",
    );
}

test "a link is listed and its visible text is kept" {
    const html = "<p>look <a href=\"https://example.com/a\" rel=\"nofollow noopener\">https://example.com/a</a></p>";
    try expectBody(testing.allocator, html, "look https://example.com/a");
    try expectLinks(testing.allocator, html, .{}, &.{"https://example.com/a"});
    // .differs drops it, because the text already shows the URL.
    try expectLinks(testing.allocator, html, .{ .links = .differs }, no_links);
    try expectLinks(testing.allocator, html, .{ .links = .none }, no_links);
}

test "an ellipsis link reconstructs the full URL" {
    const html =
        "<p><a href=\"https://example.com/path\" target=\"_blank\">" ++
        "<span class=\"invisible\">https://</span>" ++
        "<span class=\"ellipsis\">example.com/pa</span>" ++
        "<span class=\"invisible\">th</span></a></p>";

    try expectBody(testing.allocator, html, "https://example.com/path");
    try expectLinks(testing.allocator, html, .{}, &.{"https://example.com/path"});

    // Hiding the invisible spans leaves the shortened text Mastodon actually
    // displays ("https://" and "th" are the hidden halves), so .differs now
    // reports the real target instead of the shortened label.
    var text = try render(testing.allocator, html, .{ .links = .differs, .suppress_invisible = true });
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("example.com/pa", text.body.items);
    try testing.expectEqual(@as(usize, 1), text.links.items.len);
}

test "hrefs are entity-decoded" {
    try expectLinks(
        testing.allocator,
        "<p><a href=\"https://x/?a=1&amp;b=2\">l</a></p>",
        .{},
        &.{"https://x/?a=1&b=2"},
    );
}

test "links are deduplicated" {
    const html =
        "<p><a href=\"https://x/a\">https://x/a</a> <a href=\"https://x/a\">https://x/a</a></p>";
    try expectLinks(testing.allocator, html, .{}, &.{"https://x/a"});
}

test "an empty anchor emits its href inline" {
    const html = "<p><a href=\"https://x/a\"></a></p>";
    try expectBody(testing.allocator, html, "https://x/a");
    try expectLinks(testing.allocator, html, .{}, &.{"https://x/a"});
}

test "attribute syntax variations are accepted" {
    try expectLinks(testing.allocator, "<a HREF='https://x/a'>l</a>", .{}, &.{"https://x/a"});
    try expectLinks(testing.allocator, "<a href=https://x/a>l</a>", .{}, &.{"https://x/a"});
    try expectLinks(testing.allocator, "<a href>l</a>", .{}, no_links);
    try expectLinks(testing.allocator, "<a href=\"\">l</a>", .{}, no_links);
}

test "non-web schemes are not listed" {
    try expectLinks(testing.allocator, "<a href=\"javascript:alert(1)\">x</a>", .{}, no_links);
    try expectLinks(testing.allocator, "<a href=\"https://x\">x</a>", .{}, &.{"https://x"});
}

test "custom emoji shortcodes survive as text" {
    const html = "<p>hi <img class=\"custom-emoji\" alt=\":blobcat:\" src=\"https://x/e.png\"> there</p>";
    var text = try render(testing.allocator, html, .{});
    defer text.deinit(testing.allocator);

    try testing.expectEqualStrings("hi :blobcat: there", text.body.items);
    try testing.expectEqual(@as(usize, 1), text.emoji.items.len);
    const span = text.emoji.items[0];
    try testing.expectEqualStrings(":blobcat:", span.slice(text.body.items));
}

test "an emoji resolver replaces the shortcode in place" {
    const Resolver = struct {
        fn resolve(shortcode: []const u8, ctx: ?*anyopaque) ?[]const u8 {
            _ = ctx;
            if (std.mem.eql(u8, shortcode, ":blobcat:")) return "\u{1F431}";
            return null;
        }
    };

    var text = try render(
        testing.allocator,
        "<p>hi <img alt=\":blobcat:\"></p>",
        .{ .emoji_resolve = Resolver.resolve },
    );
    defer text.deinit(testing.allocator);

    try testing.expectEqualStrings("hi \u{1F431}", text.body.items);
    try testing.expectEqualStrings("\u{1F431}", text.emoji.items[0].slice(text.body.items));
}

test "other images are dropped, not listed as media" {
    try expectBody(testing.allocator, "<p>a<img alt=\"a photo\" src=\"https://x/p.jpg\">b</p>", "ab");
}

test "pre keeps its indentation and its own newlines" {
    const html = "<pre>a\n   b</pre><p>c</p>";
    var text = try render(testing.allocator, html, .{});
    defer text.deinit(testing.allocator);
    try testing.expectEqualStrings("a\n   b\nc", text.body.items);
}

test "script and style content is dropped" {
    try expectBody(
        testing.allocator,
        "<p>a</p><script>var x = 1 < 2;</script><style>p{color:red}</style><p>b</p>",
        "a\nb",
    );
    try expectBody(testing.allocator, "<title>x</title><p>a</p>", "a");
}

test "comments and doctypes are dropped" {
    try expectBody(testing.allocator, "<!-- hi --><p>a</p>", "a");
    try expectBody(testing.allocator, "<!DOCTYPE html><p>a</p>", "a");
}

test "pretty-printed source does not leak indentation" {
    try expectBody(testing.allocator, "<p>\n   a\n   b\n</p>", "a\nb");
}

test "unclosed markup degrades instead of failing" {
    try expectBody(testing.allocator, "<p>a<b>b", "ab");
    try expectBody(testing.allocator, "</span>x", "x");
    try expectBody(testing.allocator, "a < b", "a < b");
    // An unterminated attribute value swallows the rest; nothing may hang.
    try expectBody(testing.allocator, "<a href=\"x class=y>l</a>", "");
}

test "deep nesting degrades without losing text" {
    const html =
        "<div><div><div><div><div><div><div><div>" ++
        "<div><div><div><div><div><div><div><div>" ++
        "<div><div><div><div><div><div><div><div>" ++
        "<div><div><div><div><div><div><div><div>" ++
        "<div><div><div><div>x</div></div></div></div></div></div></div></div>" ++
        "</div></div></div></div></div></div></div></div>" ++
        "</div></div></div></div></div></div></div></div>" ++
        "</div></div></div></div></div></div></div></div>" ++
        "</div></div></div></div>";
    try expectBody(testing.allocator, html, "x");
}

test "render allocates nothing it does not free" {
    // testing.allocator fails the test on any leak in the helpers above; this
    // case exercises every allocation site at once.
    var text = try render(
        testing.allocator,
        "<p>a <a href=\"https://x/?a=1&amp;b=2\">link</a>" ++
            "<img alt=\":e:\"><a href=\"https://x/?a=1&amp;b=2\">link</a></p>",
        .{},
    );
    defer text.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), text.links.items.len);
    try testing.expectEqual(@as(usize, 1), text.emoji.items.len);
}
