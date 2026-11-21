//! The render loop, moved out of c_main().
//!
//! All it does is drain the output queue that the C streaming thread fills,
//! at the same 100 ms cadence the C code used. Posting no longer happens here:
//! toots arrive over the UNIX socket (src/server.zig), so nothing reads stdin
//! at run time any more.
//!
//! Stdout discipline: once `translated.nanotodon_start()` has run, every write
//! to stdout goes through libc stdio via `nanotodon_pump_output()`. Never write
//! to the Zig `Io` writer from here, or the two independent buffers will
//! interleave.

const std = @import("std");
const translated = @import("translated");

/// Poll interval. Kept at the C value: the original comment says あまり短いと
/// 謎マシンが死ぬので100ms (too short and the machine dies).
pub const poll_ns: i96 = 100 * std.time.ns_per_ms;

/// Runs forever; there is no shutdown path in this program (Ctrl-C kills it).
pub fn run(io: std.Io) !void {
    while (true) {
        translated.nanotodon_pump_output();
        try std.Io.sleep(io, .{ .nanoseconds = poll_ns }, .awake);
    }
}

