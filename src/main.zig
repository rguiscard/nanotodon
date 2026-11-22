const std = @import("std");
const Io = std.Io;

const translated = @import("translated");
const cli = @import("cli.zig");
const kitty = @import("kitty.zig");
const loop = @import("loop.zig");
const proto = @import("proto.zig");
const poster = @import("poster.zig");
const server = @import("server.zig");
const socketpath = @import("socketpath.zig");

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

    // Must happen before nanotodon_prepare_paths(): config.profile_name feeds
    // dot_token/dot_domain *and* the socket name, and nano_config_init() runs
    // first thing in that phase. It also copies the profile name out of the
    // iterator's storage, so it has to run while `arg_it` is still alive
    // (deinit is deferred to the end).
    cli.apply(opts);

    // Startup phase 1: config paths and directories (no network, no stdin),
    // because the socket may live in one of those directories and has to exist
    // before we bind. This is what made the first run on macOS fail before.
    translated.nanotodon_prepare_paths();

    // Bind before touching the network: a failed bind must exit before reading
    // a token or running the OAuth dance. Requests queue in the kernel backlog
    // until the accept loop starts further down.
    const socket_path = socketpath.resolve(
        arena,
        socketpath.Env.fromMap(init.environ_map),
        opts.socket,
        opts.profile,
    ) catch |err| switch (err) {
        error.NameTooLong => {
            std.debug.print("nanotodon: socket path too long; pass -socket <path>\n", .{});
            std.process.exit(1);
        },
        error.NoHome => {
            std.debug.print("nanotodon: no $HOME or $XDG_RUNTIME_DIR for the socket; pass -socket <path>\n", .{});
            std.process.exit(1);
        },
        else => {
            std.debug.print("nanotodon: cannot build the socket path: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };

    var srv = server.listen(
        io,
        arena,
        socket_path,
        .{ .postFn = poster.post },
        server.default_max_concurrent,
    ) catch |err| {
        std.debug.print("nanotodon: cannot listen on {s}: {s}\n", .{ socket_path, @errorName(err) });
        std.process.exit(1);
    };
    std.debug.print("listening on {s}\n", .{socket_path});

    // Startup phases 2 and 3, only after the socket is bound: loading the token
    // can block on the OAuth prompt, and the queue has to exist before any
    // thread can enqueue into it.
    translated.nanotodon_authenticate();
    translated.nanotodon_runtime();

    // The stream loop blocks in curl forever, so it must not be an `Io` task:
    // an `io.async` task would occupy a pool worker permanently and, when
    // `async_limit` is 0 (single CPU, or `getCpuCount()` failing), would run
    // inline and never return to this function.
    const stream_thread = std.Thread.spawn(.{}, streamEntry, .{}) catch |err| {
        std.debug.print("nanotodon: cannot start the streaming thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    stream_thread.detach();

    // Same reasoning for the accept loop. It may start serving before
    // `loop.run` gets going; replies only depend on curl and the access token.
    const accept_thread = std.Thread.spawn(.{}, server.Server.acceptLoop, .{&srv}) catch |err| {
        std.debug.print("nanotodon: cannot start the accept thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    accept_thread.detach();

    // From here on all stdout writes go through libc stdio via the shims in
    // src/loop.zig; stdout_writer must not be used again.
    try loop.run(io);
}

/// Plain Zig entry point for `std.Thread.spawn`; the C side only exposes an
/// extern function, which is awkward to hand to `spawn` directly.
fn streamEntry() void {
    translated.nanotodon_stream_loop();
}

/// C entry point for src/image.c (declared in src/headers.h). It lives in the
/// root source file on purpose: Zig only emits `export` declarations from files
/// that get analysed, and nothing inside Zig calls this — only C does. From
/// src/kitty.zig the export was silently dropped and the link failed.
export fn nanotodon_kitty_emit(
    sbctx: ?*anyopaque,
    rgba: ?*const anyopaque,
    w: c_int,
    h: c_int,
) callconv(.c) void {
    kitty.emit(sbctx, rgba, w, h);
}

// `cli`, `loop`, `proto`, `server` and `socketpath` are only referenced from
// main(), which is not analyzed in a test build, so without touching them here
// the tests inside those files would never be collected. refAllDecls also
// forces analysis of `cli.apply()`, which otherwise only runs in the real
// executable.
test {
//    _ = cli;
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(kitty);
    std.testing.refAllDecls(loop);
    std.testing.refAllDecls(poster);
    std.testing.refAllDecls(proto);
    std.testing.refAllDecls(server);
    std.testing.refAllDecls(socketpath);
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
