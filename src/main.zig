const std = @import("std");
const Io = std.Io;

const translated = @import("translated");
const cli = @import("cli.zig");

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

    // Option handling lives on the Zig side now. The C implementation used to
    // `return -1` from c_main() on bad arguments, which the shell reports as
    // 255, so keep that exit status.
    const opts = cli.parse(&arg_it, stdout_writer) catch |err| {
        try stdout_writer.flush();
        switch (err) {
            // These were already reported to stderr by cli.parse().
            error.TooFewArguments, error.UnknownTimeline, error.ProfileTooLong => {},
            else => std.debug.print("nanotodon: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(255);
    };

    // c_main() writes through libc stdio, which buffers independently of our
    // writer. Flush first so the option messages keep their order relative to
    // the C output.
    try stdout_writer.flush();

    // Must happen before c_main(): it fills the globals C reads from its
    // threads and sets config.profile_name before nano_config_init() runs.
    // It also copies the profile name out of the iterator's storage, so it has
    // to run while `arg_it` is still alive (deinit is deferred to the end).
    cli.apply(opts);

    const rc = translated.c_main();
    if (rc != 0) std.process.exit(@intCast(rc & 0xff));
}

// `cli` is only referenced from main(), and main() is not analyzed in a test
// build, so without an explicit reference the tests in src/cli.zig would never
// be collected. Also forces analysis of `apply()`, which only runs in the real
// executable otherwise.
test {
//    _ = cli;
    std.testing.refAllDecls(cli);
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
