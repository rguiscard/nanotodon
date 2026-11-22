//! Kitty graphics encoding, moved out of image.c.
//!
//! This runs after `image.c` has fetched and decoded an attachment: pick a cell
//! size that keeps the aspect ratio, convert RGBA to RGB at that resolution,
//! then emit the protocol's chunked base64 escape stream.
//!
//! `encode` is pure (it writes to whatever `std.Io.Writer` it is given) and is
//! the part worth testing. The only impurity is `emit`, which hands the finished
//! bytes back to C through `nanotodon_sbuf_put`, so this file never needs to know
//! what an `sbctx_t` is. `emit` is reached from C via the `export fn` in
//! src/main.zig, not from Zig.

const std = @import("std");
const translated = @import("translated");

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
fn toRgb(gpa: std.mem.Allocator, rgba: []const u8, iw: u32, ih: u32, c: Cells) ![]u8 {
    const sw: usize = iw;
    const sh: usize = ih;
    const dw: usize = c.w;
    const dh: usize = c.h;
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
pub fn encode(writer: *std.Io.Writer, rgb: []const u8, c: Cells) std.Io.Writer.Error!void {
    var b64: [chunk_raw / 3 * 4 + 4]u8 = undefined;

    var off: usize = 0;
    var first = true;

    while (off < rgb.len) {
        const n = @min(chunk_raw, rgb.len - off);
        const more: u8 = if (off + n == rgb.len) 0 else 1;

        if (first) {
            try writer.print(
                "\x1b_Gf=24,s={d},v={d},a=T,c={d},r={d},q=2,m={d};",
                .{ c.w, c.h, c.cols, c.rows, more },
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

/// Encode decoded RGBA pixels as Kitty graphics and hand the escape stream to
/// C. Called through the `export fn nanotodon_kitty_emit` in src/main.zig: an
/// `export` from this file would only be emitted if something analysed it, and
/// nothing inside Zig references it (only C does).
pub fn emit(
    sbctx: ?*anyopaque,
    rgba: ?*const anyopaque,
    w: c_int,
    h: c_int,
) void {
    const sb = sbctx orelse return;
    const pixels = rgba orelse return;
    if (w <= 0 or h <= 0) return;

    const iw: u32 = @intCast(w);
    const ih: u32 = @intCast(h);
    const cells = fit(iw, ih);

    // The stream thread calls this, so use the thread-safe allocator that needs
    // no setup rather than threading an allocator through C.
    const gpa = std.heap.smp_allocator;

    const bytes: [*]const u8 = @ptrCast(pixels);
    const src = bytes[0 .. @as(usize, iw) * @as(usize, ih) * 4];

    const rgb = toRgb(gpa, src, iw, ih, cells) catch return;
    defer gpa.free(rgb);

    const chunks = (rgb.len + chunk_raw - 1) / chunk_raw;
    const out_buf = gpa.alloc(u8, chunks * chunk_max) catch return;
    defer gpa.free(out_buf);

    var writer = std.Io.Writer.fixed(out_buf);
    encode(&writer, rgb, cells) catch return; // WriteFailed would mean chunk_max is too small

    const out = writer.buffered();
    translated.nanotodon_sbuf_put(sb, out.ptr, @intCast(out.len));
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fit keeps the aspect ratio" {
    {
        // Square: width-bound, so the row count shrinks to keep 1:1.
        const c = fit(1000, 1000);
        try testing.expectEqual(@as(u32, 40), c.cols);
        try testing.expectEqual(@as(u32, 18), c.rows);
        try testing.expectEqual(@as(u32, 320), c.w);
        try testing.expectEqual(@as(u32, 320), c.h);
    }
    {
        // Panorama: uses the full width, few rows.
        const c = fit(4000, 1000);
        try testing.expectEqual(@as(u32, 40), c.cols);
        try testing.expectEqual(@as(u32, 5), c.rows);
    }
    {
        // Tall: hits the row limit.
        const c = fit(500, 4000);
        try testing.expectEqual(@as(u32, 20), c.rows);
        try testing.expect(c.cols <= 7);
    }
    {
        // Small images are never upscaled.
        const c = fit(10, 10);
        try testing.expectEqual(@as(u32, 10), c.w);
        try testing.expectEqual(@as(u32, 10), c.h);
        try testing.expectEqual(@as(u32, 2), c.cols);
        try testing.expectEqual(@as(u32, 1), c.rows);
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
