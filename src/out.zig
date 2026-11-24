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

const std = @import("std");

var mutex: std.Io.Mutex = .init;

/// Whether the cursor sits in column 0, i.e. the last byte written was `'\n'`.
/// Protected by `mutex`. A Kitty image is placed at the cursor, so its escape
/// sequence must not start mid-line: otherwise the picture is drawn in the
/// middle of the previous text and the status line that follows it begins in
/// the image's bottom row and is overwritten.
var at_line_start = true;

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
