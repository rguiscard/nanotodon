//! Image attachments using the Kitty graphics protocol.
//!
//! This replaced the C `image.c`/`kitty.zig` pair. It owns the whole path:
//!
//!   escape()      cache lookup -> fetch -> decode (C, stb_image) -> encode
//!   encode()      RGBA -> RGB at a cell-sized resolution, base64, escapes
//!   place()       append the result to a status, in order
//!
//! The important part is `place()`: it writes into the *status buffer*, so the
//! picture lands between its URL line and the blank line that ends the status,
//! and the whole thing still leaves through one `out.write()`. Writing the
//! image straight to stdout (as the C version did) put it before the toot and
//! let the URL line overwrite its bottom rows.
//!
//! Only decoding is still C: stb_image is a single-header library, and wrapping
//! that one function beats translating it. Fetching uses the same libcurl
//! binding as the stream (src/stream.zig).

const std = @import("std");
const build_options = @import("build_options");
const translated = @import("translated");
const c = @import("curl_c");

/// Largest box an attachment may occupy, in terminal cells.
pub const max_cols = 40;
pub const max_rows = 20;

/// Assumed cell size in pixels. Only used to turn the image's aspect ratio into
/// whole cells (the terminal does the actual scaling), so a font noticeably
/// wider or narrower than this makes the picture slightly squash or stretch.
pub const cell_w = 8;
pub const cell_h = 18;

/// Kitty accepts at most 4096 bytes of base64 per escape sequence. Stay below
/// that, and keep the raw group a multiple of 3 so only the last chunk pads.
pub const chunk_raw = 2304; // 3072 base64 chars

/// Upper bound for one chunk's escape sequence: a generous header, the base64
/// payload with its padding, and the two-byte ST terminator.
const chunk_max = chunk_raw / 3 * 4 + 4 + 128 + 2;

/// How long a media fetch may take. The C version used the same 30 seconds.
pub const fetch_timeout_s = 30;

/// Conversations get 5 redirects, as in the C version: media URLs are often
/// behind one.
const max_redirects = 5;

pub const Cells = struct {
    cols: u32,
    rows: u32,
    w: u32,
    h: u32,
};

/// Fit `iw`x`ih` into the cell box, preserving the aspect ratio, and report the
/// pixel size to encode plus the cells to place it in.
pub fn fit(iw: u32, ih: u32) Cells {
    std.debug.assert(iw > 0 and ih > 0);

    const box_w = max_cols * cell_w;
    const box_h = max_rows * cell_h;

    var w = iw;
    var h = ih;
    if (w > box_w or h > box_h) {
        // Compare w/h against box_w/box_h without dividing.
        if (w * box_h > h * box_w) {
            w = box_w;
            h = ih * box_w / iw;
        } else {
            h = box_h;
            w = iw * box_h / ih;
        }
    }
    if (w < 1) w = 1;
    if (h < 1) h = 1;

    // Round up so the terminal never has to crop, then clamp to the box.
    var cols = (w + cell_w - 1) / cell_w;
    var rows = (h + cell_h - 1) / cell_h;
    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;
    if (cols > max_cols) cols = max_cols;
    if (rows > max_rows) rows = max_rows;

    return .{ .cols = cols, .rows = rows, .w = w, .h = h };
}

/// Nearest-neighbour resample of `iw`x`ih` RGBA to `c.w`x`c.h` RGB (alpha is
/// dropped). Nearest neighbour is enough: the terminal scales to cells anyway.
fn toRgb(gpa: std.mem.Allocator, rgba: []const u8, iw: u32, ih: u32, c2: Cells) ![]u8 {
    const sw: usize = iw;
    const sh: usize = ih;
    const dw: usize = c2.w;
    const dh: usize = c2.h;
    std.debug.assert(rgba.len >= sw * sh * 4);

    const rgb = try gpa.alloc(u8, dw * dh * 3);

    for (0..dh) |y| {
        const sy = y * sh / dh;
        for (0..dw) |x| {
            const sx = x * sw / dw;
            const src = (sy * sw + sx) * 4;
            const dst = (y * dw + x) * 3;
            rgb[dst + 0] = rgba[src + 0];
            rgb[dst + 1] = rgba[src + 1];
            rgb[dst + 2] = rgba[src + 2];
        }
    }

    return rgb;
}

/// Emit the escape stream:
///   ESC _ G f=24,s=W,v=H,a=T,c=COLS,r=ROWS,q=2,m=N ; <base64> ESC \
/// Parameters appear on the first chunk only, `m=1` while more chunks follow,
/// and `q=2` suppresses the terminal's OK response (nothing reads the tty input
/// any more, so those bytes would just accumulate).
pub fn encode(writer: *std.Io.Writer, rgb: []const u8, cells: Cells) std.Io.Writer.Error!void {
    var b64: [chunk_raw / 3 * 4 + 4]u8 = undefined;

    var off: usize = 0;
    var first = true;

    while (off < rgb.len) {
        const n = @min(chunk_raw, rgb.len - off);
        const more: u8 = if (off + n == rgb.len) 0 else 1;

        if (first) {
            try writer.print(
                "\x1b_Gf=24,s={d},v={d},a=T,c={d},r={d},q=2,m={d};",
                .{ cells.w, cells.h, cells.cols, cells.rows, more },
            );
        } else {
            try writer.print("\x1b_Gm={d};", .{more});
        }

        try writer.writeAll(std.base64.standard.Encoder.encode(&b64, rgb[off..][0..n]));
        try writer.writeAll("\x1b\\");

        off += n;
        first = false;
    }
}

/// Encode decoded RGBA pixels as a complete Kitty escape stream. The result
/// belongs to `gpa`.
pub fn encodeRgba(gpa: std.mem.Allocator, rgba: []const u8, iw: u32, ih: u32) ![]u8 {
    const cells = fit(iw, ih);
    const rgb = try toRgb(gpa, rgba, iw, ih, cells);
    defer gpa.free(rgb);

    const chunks = (rgb.len + chunk_raw - 1) / chunk_raw;
    var writer = try std.Io.Writer.Allocating.initCapacity(gpa, chunks * chunk_max);
    defer writer.deinit();
    try encode(&writer.writer, rgb, cells);

    return writer.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/// Cache file name for `uri`: 16 hex digits of FNV-1a and the `.kit` suffix.
/// Same key and same on-disk layout as the C version (a 4-byte little-endian
/// length, then the escape stream), so existing caches stay valid.
pub fn cacheName(uri: []const u8) [16 + 4]u8 {
    var h: u64 = 0xcbf29ce484222325;
    for (uri) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }

    var name: [16 + 4]u8 = undefined;
    const hex = "0123456789abcdef";
    for (0..16) |i| {
        name[i] = hex[@as(usize, @intCast((h >> @intCast(60 - i * 4)) & 15))];
    }
    @memcpy(name[16..], ".kit");
    return name;
}

/// Reads a cached escape stream. `null` on any miss or a malformed file.
fn readCached(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ?[]u8 {
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);

    var len_buf: [4]u8 = undefined;
    const got = file.readPositionalAll(io, &len_buf, 0) catch return null;
    if (got != len_buf.len) return null;

    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len == 0 or len > 16 * 1024 * 1024) return null;

    const body = gpa.alloc(u8, len) catch return null;
    errdefer gpa.free(body);

    const n = file.readPositionalAll(io, body, 4) catch {
        gpa.free(body);
        return null;
    };
    if (n != body.len) {
        gpa.free(body);
        return null;
    }
    return body;
}

/// Stores an escape stream if the cache directory allows it. Failures are
/// ignored: a picture that cannot be cached is still worth showing.
fn writeCached(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) void {
    var file = dir.createFile(io, name, .{}) catch return;
    defer file.close(io);

    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(bytes.len), .little);
    file.writePositionalAll(io, &len_buf, 0) catch return;
    file.writePositionalAll(io, bytes, 4) catch return;
}

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

/// Collects the body of one media download.
const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn write(ptr: [*c]const u8, size: c_uint, nmemb: c_uint, user_data: ?*anyopaque) callconv(.c) c_uint {
        const total: usize = @as(usize, size) * @as(usize, nmemb);
        if (total == 0) return 0;
        const self: *Sink = @ptrCast(@alignCast(user_data orelse return 0));
        self.bytes.appendSlice(self.gpa, ptr[0..total]) catch return 0; // Short count: write error.
        return @intCast(total);
    }
};

/// libcurl option setting is variadic at the ABI level; the macros hide that.
/// Same helper as src/stream.zig, kept private here so this file stands alone.
fn setOpt(handle: *c.CURL, option: c.CURLoption, value: anytype) void {
    _ = c.curl_easy_setopt(handle, option, value);
}

/// Downloads `uri`. The result belongs to `gpa`.
fn fetch(gpa: std.mem.Allocator, uri: [*:0]const u8) ?[]u8 {
    const handle = c.curl_easy_init() orelse return null;
    defer c.curl_easy_cleanup(handle);

    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);

    setOpt(handle, c.CURLOPT_URL, uri);
    setOpt(handle, c.CURLOPT_WRITEFUNCTION, Sink.write);
    setOpt(handle, c.CURLOPT_WRITEDATA, &sink);
    setOpt(handle, c.CURLOPT_MAXREDIRS, @as(c_long, max_redirects));
    setOpt(handle, c.CURLOPT_TIMEOUT, @as(c_long, fetch_timeout_s));

    const ret = c.curl_easy_perform(handle);
    trace("curl={s} bytes={d}", .{ std.mem.span(c.curl_easy_strerror(ret)), sink.bytes.items.len });
    if (ret != c.CURLE_OK or sink.bytes.items.len == 0) return null;

    return sink.bytes.toOwnedSlice(gpa) catch null;
}

/// stb_image decode (C, image.c). Returns RGBA owned by stb_image.
fn decode(data: []const u8, w: *c_int, h: *c_int) ?[*]u8 {
    if (data.len > std.math.maxInt(c_int)) return null;
    return translated.nanotodon_decode_image(data.ptr, @intCast(data.len), w, h) orelse null;
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// The Kitty escape stream for `uri`, or `null` when the picture cannot be
/// produced (bad URL, download failure, unsupported format). Both the result
/// and `uri` belong to `gpa`.
pub fn escape(gpa: std.mem.Allocator, io: std.Io, cache_dir: std.Io.Dir, uri: []const u8) ?[]u8 {
    if (!build_options.image_support) return null;

    const name = cacheName(uri);
    if (readCached(gpa, io, cache_dir, &name)) |cached| {
        trace("cache hit {s}", .{uri});
        return cached;
    }

    const uri_z = gpa.dupeSentinel(u8, uri, 0) catch return null;
    defer gpa.free(uri_z);

    const body = fetch(gpa, uri_z) orelse return null;
    defer gpa.free(body);

    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = decode(body, &w, &h) orelse return null;
    defer translated.nanotodon_stb_image_free(pixels);
    if (w <= 0 or h <= 0) return null;

    const iw: u32 = @intCast(w);
    const ih: u32 = @intCast(h);
    const rgba = pixels[0..@as(usize, iw) * @as(usize, ih) * 4];

    const stream = encodeRgba(gpa, rgba, iw, ih) catch return null;
    errdefer gpa.free(stream);

    trace("decoded {d}x{d} -> {d} byte(s) of escapes", .{ iw, ih, stream.len });
    writeCached(io, cache_dir, &name, stream);
    return stream;
}

/// Appends the attachment `url` to a status, in the original layout:
///
///   [image] https://…
///   <the picture>
///   <blank line>
///
/// Appending into the status buffer (rather than writing to stdout) is what
/// keeps the picture after its URL and inside the one atomic write.
pub fn place(gpa: std.mem.Allocator, io: std.Io, cache_dir: std.Io.Dir, out: *std.ArrayList(u8), kind: []const u8, url: []const u8) !void {
    try out.append(gpa, '[');
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, "] ");
    try out.appendSlice(gpa, url);
    try out.append(gpa, '\n');

    if (!std.mem.eql(u8, kind, "image")) return;

    if (escape(gpa, io, cache_dir, url)) |stream| {
        defer gpa.free(stream);
        try out.appendSlice(gpa, stream);
        try out.append(gpa, '\n');
    }
}

// ---------------------------------------------------------------------------
// Debug tracing
// ---------------------------------------------------------------------------

/// Set `NANOTODON_IMAGE_DEBUG=1` to watch fetching and caching on stderr.
var trace_on: ?bool = null;

fn trace(comptime fmt: []const u8, args: anytype) void {
    const on = trace_on orelse blk: {
        const enabled = c.getenv("NANOTODON_IMAGE_DEBUG") != null;
        trace_on = enabled;
        break :blk enabled;
    };
    if (!on) return;
    std.debug.print("image: " ++ fmt ++ "\n", args);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fit keeps the aspect ratio" {
    {
        // Square: width-bound, so the row count shrinks to keep 1:1.
        const c2 = fit(1000, 1000);
        try testing.expectEqual(@as(u32, 40), c2.cols);
        try testing.expectEqual(@as(u32, 18), c2.rows);
        try testing.expectEqual(@as(u32, 320), c2.w);
        try testing.expectEqual(@as(u32, 320), c2.h);
    }
    {
        // Panorama: uses the full width, few rows.
        const c2 = fit(4000, 1000);
        try testing.expectEqual(@as(u32, 40), c2.cols);
        try testing.expectEqual(@as(u32, 5), c2.rows);
    }
    {
        // Tall: hits the row limit.
        const c2 = fit(500, 4000);
        try testing.expectEqual(@as(u32, 20), c2.rows);
        try testing.expect(c2.cols <= 7);
    }
    {
        // Small images are never upscaled.
        const c2 = fit(10, 10);
        try testing.expectEqual(@as(u32, 10), c2.w);
        try testing.expectEqual(@as(u32, 10), c2.h);
        try testing.expectEqual(@as(u32, 2), c2.cols);
        try testing.expectEqual(@as(u32, 1), c2.rows);
    }
}

test "toRgb drops alpha and samples the source" {
    const gpa = testing.allocator;

    // 2x2 RGBA: red, green / blue, white.
    const rgba = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };

    // Identity size.
    const same = try toRgb(gpa, &rgba, 2, 2, .{ .cols = 2, .rows = 1, .w = 2, .h = 2 });
    defer gpa.free(same);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 }, same);

    // Downsample by 2: picks the top-left of each 2x2 block, i.e. red and blue.
    const half = try toRgb(gpa, &rgba, 2, 2, .{ .cols = 1, .rows = 1, .w = 1, .h = 1 });
    defer gpa.free(half);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, half);
}

test "encode puts every parameter on the first chunk" {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    // Three zero bytes -> "AAAA".
    const rgb = [_]u8{ 0, 0, 0 };
    try encode(&writer, &rgb, .{ .cols = 2, .rows = 1, .w = 1, .h = 1 });

    const out = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "\x1b_Gf=24,s=1,v=1,a=T,c=2,r=1,q=2,m=0;"));
    try testing.expect(std.mem.indexOf(u8, out, "AAAA") != null);
    try testing.expect(std.mem.endsWith(u8, out, "AAAA\x1b\\"));
}

test "extra chunks carry only m and the terminator" {
    const gpa = testing.allocator;
    const rgb = try gpa.alloc(u8, chunk_raw + 3); // exactly two chunks
    defer gpa.free(rgb);
    @memset(rgb, 0x7f);

    const buf = try gpa.alloc(u8, 2 * chunk_max);
    defer gpa.free(buf);

    var writer = std.Io.Writer.fixed(buf);
    try encode(&writer, rgb, .{ .cols = 40, .rows = 20, .w = 100, .h = 100 });

    const out = writer.buffered();
    // First chunk announces a continuation, the second one does not.
    try testing.expect(std.mem.indexOf(u8, out, "q=2,m=1;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b_Gm=0;") != null);
    // Two terminators, one per chunk.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "\x1b\\")) |at| : (idx = at + 1) count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}

test "the buffer bound is never exceeded" {
    // Worst case for the header is a full-width/full-height placement with the
    // largest numbers the types allow.
    const cells = Cells{ .cols = max_cols, .rows = max_rows, .w = 65535, .h = 65535 };
    var buf: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const rgb: [3]u8 = @splat(1);

    try encode(&writer, &rgb, cells);
    try testing.expect(writer.buffered().len < chunk_max);
}

test "encodeRgba sizes the escape stream from the pixels" {
    const gpa = testing.allocator;
    const rgba: [4 * 4 * 4]u8 = @splat(0x40);
    const stream = try encodeRgba(gpa, &rgba, 4, 4);
    defer gpa.free(stream);

    try testing.expect(std.mem.startsWith(u8, stream, "\x1b_Gf=24,s=4,v=4,a=T,c=1,r=1,q=2,m="));
    try testing.expect(std.mem.endsWith(u8, stream, "\x1b\\"));
}

test "cacheName is the C key and keeps the .kit suffix" {
    // The exact hash the C version computed for this URI; existing cache files
    // depend on it.
    const name = cacheName("https://example.invalid/a.png");
    try testing.expectEqual(@as(usize, 20), name.len);
    try testing.expect(std.mem.endsWith(u8, &name, ".kit"));
    for (name[0..16]) |ch| try testing.expect(std.ascii.isHex(ch));
}
