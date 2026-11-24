const std = @import("std");
const Io = std.Io;

const translated = @import("translated");
const curl = @import("curl");
const auth = @import("auth.zig");
const config = @import("config.zig");
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
            error.TooFewArguments, error.UnknownTimeline, error.BadProfile => {},
            else => std.debug.print("nanotodon: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(255);
    };

    // The C runtime writes through libc stdio, which buffers independently of
    // our writer. Flush first so the option messages keep their order relative
    // to the C output.
    try stdout_writer.flush();

    // Only the flags go to C now; the profile is Zig's business (it feeds the
    // config paths and the socket name).
    cli.apply(opts);

    // Startup phase 1: configuration. Paths are a pure function of the
    // environment and the profile, and the directories are created here — before
    // the socket is bound, because the socket may live in the config root.
    const env = config.Env.fromMap(init.environ_map);
    var blocked: ?[]const u8 = null;
    const cfg = config.Config.init(arena, io, env, opts.profile, &blocked) catch |err| {
        switch (err) {
            error.NoHome => std.debug.print(
                "nanotodon: no $HOME or $XDG_CONFIG_HOME for the config directory\n",
                .{},
            ),
            error.PathTooLong => std.debug.print(
                "nanotodon: config path too long (max {d} bytes)\n",
                .{config.max_path},
            ),
            // An older version kept `token` and `domain` as plain files; they
            // are directories holding one entry per profile now.
            error.NotDir => if (blocked) |path|
                std.debug.print(
                    "nanotodon: {s} is a file, but it must now be a directory holding one\n" ++
                        "  entry per profile. Move it in as {s}/{s}, then start again.\n",
                    .{ path, path, opts.profile orelse config.default_profile },
                )
            else
                std.debug.print(
                    "nanotodon: cannot create the config directories: {s}\n",
                    .{@errorName(err)},
                ),
            else => std.debug.print(
                "nanotodon: cannot create the config directories: {s}\n",
                .{@errorName(err)},
            ),
        }
        std.process.exit(1);
    };

    // Hand the one path C still needs to C: it no longer computes anything and
    // the image cache is all that is left there (src/image.c).
    translated.nanotodon_set_cache_dir(cfg.cache_dir.ptr);

    // Bind before touching the network: a failed bind must exit before reading
    // a token or running the OAuth dance. Requests queue in the kernel backlog
    // until the accept loop starts further down.
    const socket_path = socketpath.resolve(
        arena,
        env,
        opts.socket,
        cfg.profile,
        cfg.root_dir,
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

    // libcurl's lazy init is not thread-safe, so it happens once, before the
    // registration below and before any thread exists.
    curl.globalInit() catch |err| {
        std.debug.print("nanotodon: cannot initialise libcurl: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Startup phase 2: credentials. Both reading the token and the whole
    // first-run dialog are Zig now.
    if (!loadCredentials(arena, io, cfg)) {
        auth.register(io, arena, cfg, stdout_writer) catch |err| {
            std.debug.print("nanotodon: registration failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        // The dialog writes the token file; handing it to C is the same step as
        // on a normal start.
        if (!loadCredentials(arena, io, cfg)) {
            std.debug.print("nanotodon: registration did not produce an access token\n", .{});
            std.process.exit(1);
        }
    }

    // Startup phase 3: locale, output queue and the image cache directory.
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

/// Reads the token and domain from the config and hands them to C, which keeps
/// them as statics for the curl calls. Returns false when there is no token yet,
/// i.e. the first run needs registration.
fn loadCredentials(arena: std.mem.Allocator, io: std.Io, cfg: config.Config) bool {
    const token = (cfg.readToken(arena, io) catch return false) orelse return false;
    const domain = (cfg.readDomain(arena, io) catch return false) orelse return false;

    var hdr_buf: [256 + 32]u8 = undefined;
    const header = std.mem.printSentinel(
        &hdr_buf,
        "Authorization: Bearer {s}",
        .{token},
        0,
    ) catch {
        std.debug.print("nanotodon: access token is too long\n", .{});
        return false;
    };

    translated.nanotodon_set_credentials(header.ptr, domain.ptr);
    return true;
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
    std.testing.refAllDecls(auth);
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(config);
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
