//! Process output.
//!
//! Replaces the old C output path (`sbuf.c`'s buffer and queue, `squeue.c`, and
//! the 100 ms `nanotodon_pump_output()` poll; those files are gone now): one
//! mutex around a straight write to stdout.
//!
//! Why no queue: every producer already assembles a whole status, notification
//! or image escape sequence in one buffer, so atomicity is solved where the
//! bytes are made. All the threads have to share is the terminal, and a mutex
//! covers that without a ring buffer, a consumer thread, a drop policy or a
//! hand-off of ownership.
//!
//! Output goes to fd 1 directly rather than through a buffered `Io.File.Writer`,
//! so a prompt is visible before the process blocks on stdin and there is
//! nothing to flush at exit.
//!
//! Statuses go through `writeSeparated`, which puts a full-width rule above
//! everything except the first status. The rule is drawn here, not in
//! `status.zig`, for the same reason `at_line_start` lives here: it is a
//! property of the byte stream (what came before, how wide the terminal is),
//! not of a status. `status.zig` therefore keeps producing plain text and its
//! tests keep comparing plain text.

const std = @import("std");

var mutex: std.Io.Mutex = .init;

/// Whether the cursor sits in column 0, i.e. the last byte written was `'\n'`.
/// Protected by `mutex`. A Kitty image is placed at the cursor, so its escape
/// sequence must not start mid-line: otherwise the picture is drawn in the
/// middle of the previous text and the status line that follows it begins in
/// the image's bottom row and is overwritten.
var at_line_start = true;

/// Set by the first status written, so the separator rule appears *between*
/// statuses rather than above the first one. Prompts and CLI chatter do not set
/// it: they are not toots, so they must not make the first toot look like a
/// continuation. Protected by `mutex`.
var wrote_status = false;

/// Glyph the separator is drawn with: box-drawing U+2500, one column wide in
/// every font that has it. `zz.Border.normal.horizontal` is this same character,
/// if the border palette is ever pulled in.
const separator_glyph = "─";

/// Columns assumed when stdout is not a terminal. This is the width zigzag's
/// `platform.getSize` falls back to for a pipe as well.
const fallback_columns = 80;

/// True when `bytes` leaves the cursor in column 0. Empty output changes
/// nothing, so it keeps the current position.
fn lineStartAfter(current: bool, bytes: []const u8) bool {
    if (bytes.len == 0) return current;
    return bytes[bytes.len - 1] == '\n';
}

/// Writes `bytes` to stdout as one unit, serialised against every other caller.
/// Errors are dropped on purpose: there is nothing useful to do when the
/// terminal has gone away, and the callers are background threads.
pub fn write(io: std.Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
    at_line_start = lineStartAfter(at_line_start, bytes);
}

/// The same write, but for the terminal, not for a pager or a file: starts on a
/// fresh line first if the previous output left the cursor mid-line. Callers
/// must be prepared for the extra newline, since it separates this output from
/// whatever came before it.
pub fn writeLineStart(io: std.Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const stdout = std.Io.File.stdout();
    if (!at_line_start) stdout.writeStreamingAll(io, "\n") catch {};
    stdout.writeStreamingAll(io, bytes) catch {};
    at_line_start = lineStartAfter(at_line_start, bytes);
}

/// Writes one rendered status, preceded by a separator rule unless it is the
/// first status of the process.
///
/// The rule spans the terminal, so the width is measured here instead of being
/// passed in from startup: a resize then affects the next separator rather than
/// leaving one stale width for the rest of the session. Streamed output cannot
/// be reflowed anyway, so only future rules can follow the window.
pub fn writeSeparated(io: std.Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const stdout = std.Io.File.stdout();
    // A status always starts on a fresh line: a prompt or an image escape may
    // have left the cursor mid-line.
    if (!at_line_start) stdout.writeStreamingAll(io, "\n") catch {};
    if (wrote_status) {
        writeRule(io, stdout, columns(io));
        stdout.writeStreamingAll(io, "\n") catch {};
    }
    stdout.writeStreamingAll(io, bytes) catch {};
    wrote_status = true;
    at_line_start = lineStartAfter(at_line_start, bytes);
}

/// Writes `cols` copies of `separator_glyph`, no trailing newline. One fixed
/// chunk is filled once and repeated, so a width beyond the buffer cannot
/// truncate the rule and nothing has to be allocated.
fn writeRule(io: std.Io, file: std.Io.File, cols: usize) void {
    const max_chunk = 120;
    var buf: [max_chunk * separator_glyph.len]u8 = undefined;
    const chunk_cols = @min(cols, max_chunk);
    if (fillRule(&buf, separator_glyph, chunk_cols) == 0) return;

    var left = cols;
    while (left > 0) {
        const take = @min(left, chunk_cols);
        file.writeStreamingAll(io, buf[0 .. take * separator_glyph.len]) catch {};
        left -= take;
    }
}

/// Column count of the terminal on fd 1, or `fallback_columns` for a pipe. One
/// `ioctl(TIOCGWINSZ)`, no allocation: the same request zigzag's
/// `platform.getSize` makes (src/terminal/platform/posix.zig:50).
fn columns(io: std.Io) usize {
    var window: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &window,
    } }) catch return fallback_columns;
    if (result.device_io_control < 0) return fallback_columns;
    return if (window.col > 0) window.col else fallback_columns;
}

/// Fills `buf` with whole copies of `glyph` for `cols` columns and returns the
/// byte length written. A partial glyph is never emitted: a buffer that cannot
/// hold one more copy stops on the glyph boundary.
fn fillRule(buf: []u8, glyph: []const u8, cols: usize) usize {
    if (glyph.len == 0) return 0;
    var n: usize = 0;
    while (n / glyph.len < cols and n + glyph.len <= buf.len) : (n += glyph.len) {
        @memcpy(buf[n..][0..glyph.len], glyph);
    }
    return n;
}

test "line start tracking" {
    const testing = std.testing;
    // A status ends in "\n\n", so the next image starts on its own line.
    try testing.expect(lineStartAfter(true, "hello\n\n"));
    try testing.expect(lineStartAfter(false, "hello\n\n"));
    // A partial line leaves the cursor where it is.
    try testing.expect(!lineStartAfter(true, "> "));
    // No output keeps the current position either way.
    try testing.expect(lineStartAfter(true, ""));
    try testing.expect(!lineStartAfter(false, ""));
}

test "rule is a whole number of glyphs" {
    const testing = std.testing;
    var buf: [10]u8 = undefined;

    try testing.expectEqual(@as(usize, 9), fillRule(&buf, separator_glyph, 3));
    try testing.expectEqualStrings("───", buf[0..9]);

    // One byte short of a fourth three-byte glyph: stop on the boundary rather
    // than cut a sequence in half.
    try testing.expectEqual(@as(usize, 9), fillRule(&buf, separator_glyph, 4));

    // An ASCII glyph fills the buffer exactly.
    try testing.expectEqual(@as(usize, 10), fillRule(&buf, "-", 10));
    try testing.expectEqualStrings("----------", buf[0..10]);

    // Degenerate cases ask for nothing, so nothing is written.
    try testing.expectEqual(@as(usize, 0), fillRule(&buf, separator_glyph, 0));
    try testing.expectEqual(@as(usize, 0), fillRule(&buf, "", 4));
}
