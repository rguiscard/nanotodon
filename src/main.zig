const std = @import("std");
const Io = std.Io;

const translated = @import("translated");
const cli = @import("cli.zig");
const loop = @import("loop.zig");

pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Command line as an iterator: `next()` is infallible, and on POSIX this
    // allocates nothing (it walks the startup argv). `deinit()` only matters
    // on Windows/WASI, but call it unconditionally.
    var arg_it = try init.minimal.args.iterateAllocator(arena);
    defer arg_it.deinit();

    // In order to do I/O operations need an `Io` instance.
    const io = init.io;

    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // Option handling lives on the Zig side now. The old C main() used to
    // `return -1` on bad arguments, which the shell reports as 255, so keep
    // that exit status.
    const opts = cli.parse(&arg_it, stdout_writer) catch |err| {
        try stdout_writer.flush();
        switch (err) {
            // These were already reported to stderr by cli.parse().
            error.TooFewArguments, error.UnknownTimeline, error.ProfileTooLong => {},
            else => std.debug.print("nanotodon: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(255);
    };

    // The C runtime writes through libc stdio, which buffers independently of
    // our writer. Flush first so the option messages keep their order relative
    // to the C output.
    try stdout_writer.flush();

    // Must happen before nanotodon_start(): it fills the globals C reads from
    // its threads and sets config.profile_name before nano_config_init() runs.
    // It also copies the profile name out of the iterator's storage, so it has
    // to run while `arg_it` is still alive (deinit is deferred to the end).
    cli.apply(opts);

    // Config, access token, locale, and the stream/prompt pthreads. The event
    // loop itself is Zig now (src/loop.zig) and never returns.
    if (translated.nanotodon_start() != 0) std.process.exit(1);

    // From here on all stdout writes go through libc stdio via the shims in
    // src/loop.zig; stdout_writer must not be used again.
    try loop.run(io);
}

// `cli` and `loop` are only referenced from main(), and main() is not analyzed
// in a test build, so without touching them here the tests inside those files
// would never be collected. refAllDecls also forces analysis of `cli.apply()`,
// which otherwise only runs in the real executable.
test {
//    _ = cli;
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(loop);
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try command `zig build test --fuzz -Doptimize=ReleaseFast` to see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
