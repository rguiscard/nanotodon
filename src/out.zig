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

// ---------------------------------------------------------------------------
// Writer adapter
// ---------------------------------------------------------------------------

/// The single writer handed to code that takes an `Io.Writer` (the registration
/// dialog, the option messages). Global, so its buffer has a stable address.
var writer_state: Writer = undefined;

/// An `Io.Writer` over `write`. The small buffer only exists to satisfy
/// `Io.Writer`'s contract; `drain` writes each slice straight out.
pub const Writer = struct {
    interface: std.Io.Writer,
    io: std.Io,
    buf: [256]u8 = undefined,
    initialised: bool = false,

    pub fn init(w: *Writer, io: std.Io) *std.Io.Writer {
        w.* = .{ .interface = undefined, .io = io };
        w.interface = .{
            .vtable = &.{ .drain = drain, .flush = flush },
            .buffer = &w.buf,
        };
        return &w.interface;
    }

    /// The process-wide writer, initialised on first use.
    pub fn shared(io: std.Io) *std.Io.Writer {
        if (!writer_state.initialised) {
            _ = init(&writer_state, io);
            writer_state.initialised = true;
        }
        return &writer_state.interface;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));

        const pending = w.buffered();
        if (pending.len != 0) {
            write(self.io, pending);
            w.end = 0;
        }

        if (data.len == 0) return 0;
        // The last slice repeats `splat` times; 1 is the common case.
        for (data[0 .. data.len - 1]) |slice| write(self.io, slice);
        const last = data[data.len - 1];
        var n: usize = 0;
        while (n < splat) : (n += 1) write(self.io, last);
        return 0;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", w));
        const pending = w.buffered();
        if (pending.len != 0) {
            write(self.io, pending);
            w.end = 0;
        }
    }
};
