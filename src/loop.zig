//! The main event loop, moved out of c_main().
//!
//! Everything the loop touches is still C: the output queue (`squeue`), the two
//! pthreads, stdio, and `do_toot()`. What lives here is the control flow plus
//! the backslash unescaping of toot text, which is the only real logic the loop
//! had.
//!
//! Stdout discipline: once `translated.nanotodon_start()` has run, every write
//! to stdout goes through libc stdio via the C shims below. Never write to the
//! Zig `Io` writer from here, or the two independent buffers will interleave.

const std = @import("std");
const translated = @import("translated");

/// Same size the C code used for its on-stack `status`/`status2` buffers.
pub const max_line: usize = 1024;

/// Poll interval. Kept at the C value: the original comment says あまり短いと
/// 謎マシンが死ぬので100ms (too short and the machine dies).
pub const poll_ns: i96 = 100 * std.time.ns_per_ms;

/// Runs forever; there is no shutdown path in this program (Ctrl-C kills it).
pub fn run(io: std.Io) !void {
    var line: [max_line]u8 = undefined;
    var text: [max_line]u8 = undefined;

    while (true) {
        translated.nanotodon_pump_output();

        if (translated.nanotodon_prompt_pending() != 0) {
            // On EOF there is nothing to post, but the flag still has to be
            // cleared, otherwise the prompt thread stays latched and we would
            // spin here printing prompts forever.
            if (translated.nanotodon_read_toot(&line, @intCast(line.len)) != 0) {
                const input = std.mem.sliceTo(&line, 0);
                const status = unescapeZ(&text, input);
                translated.nanotodon_post_status(status.ptr);
            }
            translated.nanotodon_prompt_clear();
        } else {
            try std.Io.sleep(io, .{ .nanoseconds = poll_ns }, .awake);
        }
    }
}

/// Unescape toot text into `dst` and return the used part.
///
/// `\\` becomes `\`, `\n` becomes a newline, and a backslash followed by
/// anything else is kept as a literal backslash. The old C loop wrote an
/// uninitialized byte for the last case (neither `if` fired while the output
/// cursor still advanced) and could also double-consume characters, because its
/// two tests were sequential `if`s rather than `else if`s.
///
/// At most `dst.len - 1` bytes are produced so that `unescapeZ()` can always
/// append its NUL terminator.
fn unescape(dst: []u8, src: []const u8) []u8 {
    if (dst.len == 0) return dst[0..0];

    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len and n < dst.len - 1) : (i += 1) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            switch (src[i + 1]) {
                '\\' => {
                    dst[n] = '\\';
                    n += 1;
                    i += 1;
                },
                'n' => {
                    dst[n] = '\n';
                    n += 1;
                    i += 1;
                },
                else => {
                    dst[n] = c;
                    n += 1;
                },
            }
        } else {
            dst[n] = c;
            n += 1;
        }
    }
    return dst[0..n];
}

/// `unescape()` plus the NUL terminator the C side expects.
fn unescapeZ(dst: []u8, src: []const u8) [:0]u8 {
    const out = unescape(dst, src);
    dst[out.len] = 0;
    return dst[0..out.len :0];
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "plain text passes through" {
    var dst: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", unescape(&dst, "hello"));
}

test "the two supported escapes" {
    var dst: [16]u8 = undefined;
    try testing.expectEqualStrings("a\\b", unescape(&dst, "a\\\\b"));
    try testing.expectEqualStrings("a\nb", unescape(&dst, "a\\nb"));
}

test "backslashes in a row" {
    var dst: [16]u8 = undefined;
    // \\\\ -> \ \
    try testing.expectEqualStrings("\\\\", unescape(&dst, "\\\\\\\\"));
    // \\n -> backslash then 'n', i.e. one escape then a literal n
    try testing.expectEqualStrings("\\n", unescape(&dst, "\\\\n"));
}

test "an unsupported escape keeps its backslash" {
    var dst: [16]u8 = undefined;
    try testing.expectEqualStrings("a\\xb", unescape(&dst, "a\\xb"));
}

test "a trailing backslash is kept" {
    var dst: [16]u8 = undefined;
    try testing.expectEqualStrings("ab\\", unescape(&dst, "ab\\"));
}

test "unescapeZ NUL terminates" {
    var dst: [16]u8 = undefined;
    const out = unescapeZ(&dst, "a\\nb");
    try testing.expectEqualStrings("a\nb", out);
    try testing.expectEqual(@as(u8, 0), out.ptr[out.len]);
}

test "the destination is never overflowed" {
    var dst: [4]u8 = undefined;
    const out = unescape(&dst, "abcdefghij");
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("abc", out);

    // unescapeZ still has room for its terminator.
    const z = unescapeZ(&dst, "abcdefghij");
    try testing.expectEqual(@as(usize, 3), z.len);
    try testing.expectEqual(@as(u8, 0), z.ptr[z.len]);
}

test "empty input" {
    var dst: [8]u8 = undefined;
    try testing.expectEqualStrings("", unescape(&dst, ""));
    try testing.expectEqual(@as(usize, 0), unescapeZ(&dst, "").len);
}
