//! The streaming side of the client: the Mastodon SSE endpoint (formerly the C
//! `nanotodon_stream_loop()`) and the timeline fetch that runs before it
//! (formerly `get_timeline()`).
//!
//! HTTP and the `text/event-stream` framing live here. Decoding the JSON and
//! drawing toots stays in C (`stream_event_update`): every complete event is
//! handed over as raw bytes through
//! `translated.nanotodon_stream_dispatch()`, which is all that remains of the old
//! loop on the C side.
//!
//! Failures are logged and return; they never exit the process. The stream runs
//! on a detached thread (src/main.zig), so a dropped connection must not take the
//! UI down with it.

const std = @import("std");
const translated = @import("translated");
const cli = @import("cli.zig");
const notify = @import("notify.zig");
const status_render = @import("status.zig");

/// Raw libcurl declarations, translated from src/curl_c.h in build.zig.
const c = @import("curl_c");

/// Mastodon's SSE events. The others (`delete`, `status.update`, filters, …)
/// exist but are not rendered, exactly as in the C version.
pub const EventKind = enum(c_int) {
    update = 0,
    notification = 1,
};

/// What the loop needs to build its URLs.
pub const Target = struct {
    /// Instance hostname, no scheme.
    domain: []const u8,
    /// The whole `Authorization: Bearer ...` line, NUL-terminated.
    auth_header: [:0]const u8,
    /// Last segment of `api/v1/streaming/`: `user`, `public`, `public/local`.
    stream: []const u8,
    /// What follows `api/v1/timelines/`: `home`, `public?local=true`, …
    timeline: []const u8,
    limit: u31,
};

// ---------------------------------------------------------------------------
// URLs
// ---------------------------------------------------------------------------

/// Writes `https://<domain>/api/v1/<path>` into `buf`. No allocation: the caller
/// owns both the buffer and the result, like src/poster.zig.
pub fn apiUrl(buf: []u8, domain: []const u8, path: []const u8) ![:0]const u8 {
    return std.mem.printSentinel(buf, "https://{s}/api/v1/{s}", .{ domain, path }, 0);
}

/// Builds the loop's `Target` from the parsed command line and the credentials.
/// The strings all outlive the loop: `cli.Options` is a value on `main`'s stack
/// frame and the credentials live in the process arena.
pub fn targetOf(opts: cli.Options, domain: [:0]const u8, auth_header: [:0]const u8) Target {
    return .{
        .domain = domain,
        .auth_header = auth_header,
        .stream = cli.streamName(opts.timeline),
        .timeline = cli.timelineName(opts.timeline),
        // `-1` means "not given": the REST default the C side used.
        .limit = if (opts.limit_timeline < 0) 20 else @intCast(opts.limit_timeline),
    };
}

pub fn streamingPath(buf: []u8, stream: []const u8) ![]const u8 {
    return std.mem.print(buf, "streaming/{s}", .{stream});
}

pub fn timelinePath(buf: []u8, timeline: []const u8, limit: u31) ![]const u8 {
    return std.mem.print(buf, "timelines/{s}?limit={d}", .{ timeline, limit });
}

// ---------------------------------------------------------------------------
// SSE framing
// ---------------------------------------------------------------------------

/// Reassembles a `text/event-stream` body into events.
///
/// libcurl delivers the body in arbitrary chunks, so a line can be split across
/// callbacks; everything is held in `line` until a newline arrives. An event is
/// `event: <name>` plus `data: <json>`, terminated by a blank line. A bare `:`
/// line is the keep-alive and carries nothing.
///
/// The C version appended each chunk to a NUL-terminated string with `strncat`
/// (quadratic, and truncated at the first NUL byte) and dispatched as soon as the
/// buffer ended in a newline, so it could act on a half-received event.
/// Accumulating here fixes both, and makes the framing testable without a server.
pub const SseFramer = struct {
    /// The line being assembled, without its newline.
    line: std.ArrayList(u8) = .empty,
    /// `data:` payload of the event being assembled.
    data: std.ArrayList(u8) = .empty,
    /// Set by `event:`; the event is dispatched under this kind.
    pending: ?EventKind = null,

    pub const Out = struct {
        kind: EventKind,
        /// The JSON payload, NUL-terminated one byte past `len` so C parsers that
        /// scan for the terminator can take `json.ptr` directly.
        /// Valid until the next `feed` call on the same framer.
        json: []const u8,
    };

    pub fn deinit(self: *SseFramer, allocator: std.mem.Allocator) void {
        self.line.deinit(allocator);
        self.data.deinit(allocator);
    }

    /// Drops a half-received event. Kept for callers that want to resynchronise;
    /// `feed` never needs it.
    pub fn reset(self: *SseFramer) void {
        self.line.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.pending = null;
    }

    /// Feeds one chunk and reports one complete event, if any. Call it again
    /// with an empty chunk until it returns `false` to drain the rest.
    pub fn feed(
        self: *SseFramer,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        out: *Out,
    ) !bool {
        try self.line.appendSlice(allocator, chunk);
        return self.next(allocator, out);
    }

    /// Consumes buffered lines until an event is complete or the buffer runs
    /// out. Split from `feed` so a single chunk holding several events yields
    /// them one at a time without re-appending.
    pub fn next(self: *SseFramer, allocator: std.mem.Allocator, out: *Out) !bool {
        while (std.mem.indexOfScalar(u8, self.line.items, '\n')) |nl| {
            const text = std.mem.trimEnd(u8, self.line.items[0..nl], "\r");
            try self.consumeLine(text, allocator);

            // Drop the consumed line, newline included.
            const rest = self.line.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.line.items[0..rest], self.line.items[nl + 1 ..]);
            self.line.shrinkRetainingCapacity(rest);

            if (text.len != 0) continue;

            // Blank line: the event is complete.
            const kind = self.pending orelse {
                self.data.clearRetainingCapacity();
                continue;
            };
            if (self.data.items.len == 0) continue;
            // `sjson_decode()` on the C side scans for a terminating NUL, and the
            // payload here is an unterminated slice, so terminate it. The NUL is
            // not part of `out.json.len`, so callers still see just the JSON.
            try self.data.append(allocator, 0);
            out.* = .{ .kind = kind, .json = self.data.items[0 .. self.data.items.len - 1] };
            return true;
        }
        return false;
    }

    /// Marks the current event as handed out, so the next `next()` starts fresh.
    pub fn eventTaken(self: *SseFramer) void {
        self.data.clearRetainingCapacity();
        self.pending = null;
    }

    fn consumeLine(self: *SseFramer, line: []const u8, allocator: std.mem.Allocator) !void {
        if (line.len == 0) return;
        if (std.mem.eql(u8, line, ":")) return; // keep-alive

        if (std.mem.startsWith(u8, line, "event:")) {
            const name = std.mem.trimStart(u8, line["event:".len..], " ");
            self.pending = kindOf(name);
            return;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            // Per the SSE spec one optional space follows the colon.
            const after = line["data:".len..];
            const payload = if (after.len > 0 and after[0] == ' ') after[1..] else after;
            if (self.data.items.len != 0) try self.data.append(allocator, '\n');
            try self.data.appendSlice(allocator, payload);
            return;
        }
        // `id:` and `retry:` are unused; unknown fields are ignored.
    }
};

fn kindOf(name: []const u8) ?EventKind {
    if (std.mem.eql(u8, name, "update")) return .update;
    if (std.mem.eql(u8, name, "notification")) return .notification;
    return null;
}

// ---------------------------------------------------------------------------
// curl plumbing
// ---------------------------------------------------------------------------

/// Context handed to libcurl as `WRITEDATA`. The callback has no allocator
/// parameter, so the allocator travels with the context.
const Sink = struct {
    framer: SseFramer,
    allocator: std.mem.Allocator,
    /// Set when framing failed; makes libcurl abort with a write error.
    failed: bool = false,
    chunks: usize = 0,
    events: usize = 0,

    fn write(ptr: [*c]const u8, size: c_uint, nmemb: c_uint, user_data: ?*anyopaque) callconv(.c) c_uint {
        const total: usize = @as(usize, size) * @as(usize, nmemb);
        if (total == 0) return 0;

        const self: *Sink = @ptrCast(@alignCast(user_data orelse return 0));
        self.chunks += 1;
        traceBytes("chunk", ptr[0..total]);
        if (!self.consume(ptr[0..total])) {
            self.failed = true;
            return 0; // Short count: libcurl reports a write error.
        }
        return @intCast(total);
    }

    fn consume(self: *Sink, chunk: []const u8) bool {
        var pending = chunk;
        while (true) {
            var out: SseFramer.Out = undefined;
            const got = self.framer.feed(self.allocator, pending, &out) catch return false;
            pending = &.{};
            if (!got) return true;
            self.events += 1;
            traceBytes(@tagName(out.kind), out.json);

            switch (out.kind) {
                // Notifications are formatted here; the toot display is still C.
                .notification => {
                    if (!notify.deliver(self.allocator, out.json)) {
                        trace("notification was not understood; dropped", .{});
                    }
                },
                .update => {
                    if (!status_render.deliver(self.allocator, out.json)) {
                        trace("status was not understood; dropped", .{});
                    }
                },
            }
            self.framer.eventTaken();
        }
    }
};

/// The timeline response, buffered whole and then handed to C in one call.
const Body = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn write(ptr: [*c]const u8, size: c_uint, nmemb: c_uint, user_data: ?*anyopaque) callconv(.c) c_uint {
        const total: usize = @as(usize, size) * @as(usize, nmemb);
        if (total == 0) return 0;
        const self: *Body = @ptrCast(@alignCast(user_data orelse return 0));
        self.bytes.appendSlice(self.allocator, ptr[0..total]) catch return 0;
        return @intCast(total);
    }
};

fn newHandle() ?*c.CURL {
    return c.curl_easy_init();
}

/// libcurl option setting is variadic at the ABI level; the macros hide that.
fn setOpt(handle: *c.CURL, option: c.CURLoption, value: anytype) void {
    _ = c.curl_easy_setopt(handle, option, value);
}

const HeaderList = struct {
    list: ?*c.struct_curl_slist = null,

    fn init(header: [*:0]const u8) HeaderList {
        return .{ .list = c.curl_slist_append(null, header) };
    }

    fn deinit(self: HeaderList) void {
        c.curl_slist_free_all(self.list);
    }
};

/// `CURLE_OK`, `CURLE_WRITE_ERROR`, … straight from libcurl.
fn codeName(ret: c.CURLcode) []const u8 {
    return std.mem.span(c.curl_easy_strerror(ret));
}

fn userAgent() [*:0]const u8 {
    return "curl/" ++ c.LIBCURL_VERSION;
}

fn report(comptime what: []const u8, ret: c.CURLcode, errbuf: *const [c.CURL_ERROR_SIZE]u8) void {
    const msg = std.mem.sliceTo(errbuf, 0);
    if (msg.len != 0) {
        std.debug.print("nanotodon: " ++ what ++ ": {s}\n", .{msg});
    } else {
        std.debug.print("nanotodon: " ++ what ++ ": {s}\n", .{std.mem.span(c.curl_easy_strerror(ret))});
    }
}

// ---------------------------------------------------------------------------
// Debug tracing
// ---------------------------------------------------------------------------

/// Set `NANOTODON_STREAM_DEBUG=1` to watch the stream on stderr. Tracing is off
/// by default so a normal run stays quiet.
var trace_on: ?bool = null;

fn trace(comptime fmt: []const u8, args: anytype) void {
    const on = trace_on orelse blk: {
        // libc, because a detached thread cannot reach the `Io` environment map.
        const raw = c.getenv("NANOTODON_STREAM_DEBUG");
        const v = if (raw == null) false else blk2: {
            const val = std.mem.span(raw);
            break :blk2 val.len != 0 and !std.mem.eql(u8, val, "0");
        };
        trace_on = v;
        break :blk v;
    };
    if (!on) return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
        std.debug.print("nanotodon[stream]: <trace line too long>\n", .{});
        return;
    };
    std.debug.print("nanotodon[stream]: {s}\n", .{msg});
}

/// Bytes are shown escaped and truncated so a binary-ish body stays readable.
fn traceBytes(what: []const u8, bytes: []const u8) void {
    var buf: [256]u8 = undefined;
    const shown = bytes[0..@min(bytes.len, 120)];
    const escaped = std.fmt.bufPrint(&buf, "{f}", .{std.zig.fmtString(shown)}) catch "<unprintable>";
    trace("{s}: {d} byte(s) {s}{s}", .{
        what,
        bytes.len,
        escaped,
        if (bytes.len > shown.len) "..." else "",
    });
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

/// Fetches the first page of the timeline, then streams forever. Returns after
/// logging the first failure; it never exits the process.
pub fn run(allocator: std.mem.Allocator, target: Target) void {
    fetchTimeline(allocator, target);
    streamForever(allocator, target);
}

fn streamForever(allocator: std.mem.Allocator, target: Target) void {
    var path_buf: [256]u8 = undefined;
    var url_buf: [512]u8 = undefined;
    const path = streamingPath(&path_buf, target.stream) catch
        return std.debug.print("nanotodon: the streaming URL is too long\n", .{});
    const url = apiUrl(&url_buf, target.domain, path) catch
        return std.debug.print("nanotodon: the streaming URL is too long\n", .{});

    const handle = newHandle() orelse
        return std.debug.print("nanotodon: cannot initialise curl for streaming\n", .{});
    defer c.curl_easy_cleanup(handle);

    const headers = HeaderList.init(target.auth_header.ptr);
    defer headers.deinit();

    var sink: Sink = .{ .framer = .{}, .allocator = allocator };
    defer sink.framer.deinit(allocator);

    var errbuf: [c.CURL_ERROR_SIZE]u8 = @splat(0);

    setOpt(handle, c.CURLOPT_URL, url.ptr);
    setOpt(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 1));
    setOpt(handle, c.CURLOPT_USERAGENT, userAgent());
    setOpt(handle, c.CURLOPT_HTTPHEADER, headers.list);
    setOpt(handle, c.CURLOPT_MAXREDIRS, @as(c_long, 50));
    setOpt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    setOpt(handle, c.CURLOPT_CUSTOMREQUEST, "GET");
    setOpt(handle, c.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1));
    // No timeout: the stream is idle whenever nobody posts.
    setOpt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 0));
    setOpt(handle, c.CURLOPT_WRITEDATA, &sink);
    setOpt(handle, c.CURLOPT_WRITEFUNCTION, Sink.write);
    setOpt(handle, c.CURLOPT_ERRORBUFFER, &errbuf);

    trace("opening {s} ({s})", .{ url, target.auth_header });
    const ret = c.curl_easy_perform(handle);
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status);
    trace("stream ended: curl={s} http={d} chunk(s)={d} events={d}", .{
        codeName(ret),
        status,
        sink.chunks,
        sink.events,
    });
    if (sink.failed) return std.debug.print("nanotodon: cannot parse the event stream\n", .{});
    if (ret != c.CURLE_OK) report("stream", ret, &errbuf);
}

fn fetchTimeline(allocator: std.mem.Allocator, target: Target) void {
    var path_buf: [256]u8 = undefined;
    var url_buf: [512]u8 = undefined;
    const path = timelinePath(&path_buf, target.timeline, target.limit) catch
        return std.debug.print("nanotodon: the timeline URL is too long\n", .{});
    const url = apiUrl(&url_buf, target.domain, path) catch
        return std.debug.print("nanotodon: the timeline URL is too long\n", .{});

    const handle = newHandle() orelse
        return std.debug.print("nanotodon: cannot initialise curl for the timeline\n", .{});
    defer c.curl_easy_cleanup(handle);

    const headers = HeaderList.init(target.auth_header.ptr);
    defer headers.deinit();

    var body: Body = .{ .allocator = allocator };
    defer body.bytes.deinit(allocator);

    var errbuf: [c.CURL_ERROR_SIZE]u8 = @splat(0);

    setOpt(handle, c.CURLOPT_URL, url.ptr);
    setOpt(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 1));
    setOpt(handle, c.CURLOPT_USERAGENT, userAgent());
    setOpt(handle, c.CURLOPT_HTTPHEADER, headers.list);
    setOpt(handle, c.CURLOPT_MAXREDIRS, @as(c_long, 50));
    setOpt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    setOpt(handle, c.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1));
    // A bounded request, unlike the stream: a hung instance must not wedge
    // startup forever.
    setOpt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 30));
    setOpt(handle, c.CURLOPT_WRITEDATA, &body);
    setOpt(handle, c.CURLOPT_WRITEFUNCTION, Body.write);
    setOpt(handle, c.CURLOPT_ERRORBUFFER, &errbuf);

    trace("fetching {s} ({s})", .{ url, target.auth_header });
    const ret = c.curl_easy_perform(handle);
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status);
    trace("timeline: curl={s} http={d} {d} byte(s)", .{ codeName(ret), status, body.bytes.items.len });
    if (ret != c.CURLE_OK) return report("timeline", ret, &errbuf);
    traceBytes("timeline body", body.bytes.items);
    if (status < 200 or status >= 300) {
        return std.debug.print("nanotodon: timeline: HTTP {d}\n", .{status});
    }
    if (body.bytes.items.len == 0) return;
    renderTimeline(allocator, body.bytes.items);
}

/// Renders a whole `api/v1/timelines/*` array. Statuses are queued oldest first
/// (the array is walked backwards) so the newest ends up at the bottom, matching
/// the C version.
fn renderTimeline(allocator: std.mem.Allocator, json: []const u8) void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{}) catch {
        trace("timeline body is not JSON", .{});
        return;
    };
    if (root != .array) {
        trace("timeline body is not a JSON array", .{});
        return;
    }

    // Each element is re-encoded so `status.render` keeps its byte-based entry
    // point (the same one the SSE path uses), rather than growing a second
    // `std.json.Value` code path that would drift from this one.
    var scratch: std.Io.Writer.Allocating = .init(allocator);
    defer scratch.deinit();

    var shown: usize = 0;
    var i = root.array.items.len;
    while (i > 0) {
        i -= 1;
        const item = root.array.items[i];
        if (item != .object) continue;

        scratch.clearRetainingCapacity();
        std.json.Stringify.value(item, .{}, &scratch.writer) catch continue;
        if (status_render.deliver(allocator, scratch.written())) shown += 1;
    }
    trace("timeline: {d} item(s), {d} rendered", .{ root.array.items.len, shown });
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn drainAll(framer: *SseFramer, allocator: std.mem.Allocator, chunk: []const u8, list: *std.ArrayList(u8)) !void {
    var pending = chunk;
    while (true) {
        var out: SseFramer.Out = undefined;
        const got = try framer.feed(allocator, pending, &out);
        pending = &.{};
        if (!got) return;
        try list.appendSlice(allocator, @tagName(out.kind));
        try list.append(allocator, ':');
        try list.appendSlice(allocator, out.json);
        try list.append(allocator, '|');
        framer.eventTaken();
    }
}

test "sse: one update event" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(&framer, testing.allocator, "event: update\ndata: {\"id\":1}\n\n", &seen);
    try testing.expectEqualStrings("update:{\"id\":1}|", seen.items);
}

test "sse: a line split across chunks is reassembled" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(&framer, testing.allocator, "event: up", &seen);
    try testing.expectEqual(@as(usize, 0), seen.items.len);
    try drainAll(&framer, testing.allocator, "date\ndata: {", &seen);
    try testing.expectEqual(@as(usize, 0), seen.items.len);
    try drainAll(&framer, testing.allocator, "\"id\":2}\n\n", &seen);
    try testing.expectEqualStrings("update:{\"id\":2}|", seen.items);
}

test "sse: the keep-alive line produces nothing" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(&framer, testing.allocator, ":\n\n:\n", &seen);
    try testing.expectEqual(@as(usize, 0), seen.items.len);
}

test "sse: CRLF line endings are accepted" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(&framer, testing.allocator, "event: notification\r\ndata: {\"type\":\"follow\"}\r\n\r\n", &seen);
    try testing.expectEqualStrings("notification:{\"type\":\"follow\"}|", seen.items);
}

test "sse: several events in one chunk are all reported" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(
        &framer,
        testing.allocator,
        "event: update\ndata: a\n\nevent: update\ndata: b\n\nevent: update\ndata: c\n\n",
        &seen,
    );
    try testing.expectEqualStrings("update:a|update:b|update:c|", seen.items);
}

test "sse: unrendered events are dropped" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(&framer, testing.allocator, "event: delete\ndata: {\"id\":3}\n\n", &seen);
    try testing.expectEqual(@as(usize, 0), seen.items.len);
}

test "sse: data without an event line is ignored" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(&framer, testing.allocator, "data: {}\n\n", &seen);
    try testing.expectEqual(@as(usize, 0), seen.items.len);
}

test "sse: a payload with embedded newlines keeps them" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    try drainAll(&framer, testing.allocator, "event: update\ndata: {\"a\":\ndata: 1}\n\n", &seen);
    try testing.expectEqualStrings("update:{\"a\":\n1}|", seen.items);
}

test "sse: the payload is NUL-terminated one byte past json.len" {
    var framer: SseFramer = .{};
    defer framer.deinit(testing.allocator);

    var out: SseFramer.Out = undefined;
    try testing.expect(try framer.feed(testing.allocator, "event: update\ndata: {\"a\":1}\n\n", &out));
    // C parses `out.json.ptr` as a C string, so the byte after the slice must
    // be a NUL even though `len` does not count it.
    try testing.expectEqual(@as(u8, 0), out.json.ptr[out.json.len]);
    try testing.expectEqualStrings("{\"a\":1}", out.json);
}

test "apiUrl builds the endpoint under the domain" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "https://example.social/api/v1/streaming/user",
        try apiUrl(&buf, "example.social", "streaming/user"),
    );
    try testing.expectEqualStrings(
        "https://example.social/api/v1/timelines/home?limit=20",
        try apiUrl(&buf, "example.social", "timelines/home?limit=20"),
    );
}

// Kept in the exe tests (src/main.zig's `refAllDecls` block) so the libcurl
// binding is compiled even when nothing else in the test build touches it.
test "userAgent reports the system libcurl version" {
    try testing.expect(std.mem.startsWith(u8, std.mem.span(userAgent()), "curl/"));
}
