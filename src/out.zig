//! Process output.
//!
//! Replaces the C output path (`sbuf.c`'s buffer and queue, `squeue.c`, and the
//! 100 ms `nanotodon_pump_output()` poll): one mutex around a straight write to
//! stdout.
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

/// Writes `bytes` to stdout as one unit, serialised against every other caller.
/// Errors are dropped on purpose: there is nothing useful to do when the
/// terminal has gone away, and the callers are background threads.
pub fn write(io: std.Io, bytes: []const u8) void {
    if (bytes.len == 0) return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}
