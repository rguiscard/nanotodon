const std = @import("std");
const Io = std.Io;

const translated = @import("translated");
const build_options = @import("build_options");
const curl = @import("curl");
const auth = @import("auth.zig");
const config = @import("config.zig");
const cli = @import("cli.zig");
const image = @import("image.zig");
const proto = @import("proto.zig");
const poster = @import("poster.zig");
const server = @import("server.zig");
const socketpath = @import("socketpath.zig");
const notify = @import("notify.zig");
const output = @import("out.zig");
const status_render = @import("status.zig");
const stream = @import("stream.zig");

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
    // Option handling lives on the Zig side now. The old C main() used to
    // `return -1` on bad arguments, which the shell reports as 255, so keep
    // that exit status.
    const opts = cli.parse(&arg_it, io) catch |err| {
        switch (err) {
            // These were already reported to stderr by cli.parse().
            error.TooFewArguments, error.UnknownTimeline, error.BadProfile => {},
            else => std.debug.print("nanotodon: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(255);
    };

    // Only the flags go to C now; the profile is Zig's business (it feeds the
    // config paths and the socket name).

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

    // Declared here, filled in below: bind failures must exit before the token
    // is read, but the poster needs a stable location to read from once
    // requests start. Nothing dereferences it before `creds` is set.
    var creds: poster.Credentials = undefined;

    var srv = server.listen(
        io,
        arena,
        socket_path,
        .{ .ctx = @ptrCast(&creds), .postFn = poster.post },
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
    creds = loadCredentials(arena, io, cfg) orelse blk: {
        auth.register(io, arena, cfg) catch |err| {
            std.debug.print("nanotodon: registration failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        // The dialog writes the token file; loading it is the same step as on a
        // normal start.
        break :blk loadCredentials(arena, io, cfg) orelse {
            std.debug.print("nanotodon: registration did not produce an access token\n", .{});
            std.process.exit(1);
        };
    };

    // Startup phase 3: locale, then the little state C still keeps. The locale
    // call moved here from C; nothing formats dates any more, but libc's numeric
    // formatting still depends on it, so the process-wide call stays.
    _ = std.c.setlocale(std.c.LC.ALL, "");

    translated.nanotodon_runtime();

    // The image cache is opened once, here, so the render path never has to
    // care whether the directory is usable. Without -Dimage there is nothing to
    // open and statuses are rendered as plain text.
    const image_cache: ?Io.Dir = if (build_options.image_support)
        Io.Dir.openDirAbsolute(io, cfg.cache_dir, .{}) catch |err| blk: {
            std.debug.print("nanotodon: image attachments disabled: {s}: {s}\n", .{ cfg.cache_dir, @errorName(err) });
            break :blk null;
        }
    else
        null;

    // The stream loop blocks in curl forever, so it must not be an `Io` task:
    // an `io.async` task would occupy a pool worker permanently and, when
    // `async_limit` is 0 (single CPU, or `getCpuCount()` failing), would run
    // inline and never return to this function.
    var stream_target = stream.targetOf(opts, creds.domain, creds.header);
    stream_target.image_cache = image_cache;
    const stream_thread = std.Thread.spawn(.{}, streamEntry, .{ io, stream_target }) catch |err| {
        std.debug.print("nanotodon: cannot start the streaming thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    stream_thread.detach();

    // Same reasoning for the accept loop. It may start serving immediately;
    // replies only depend on curl and the credentials.
    const accept_thread = std.Thread.spawn(.{}, server.Server.acceptLoop, .{&srv}) catch |err| {
        std.debug.print("nanotodon: cannot start the accept thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    accept_thread.detach();

    // Nothing left for `main` to do: the stream thread and the accept thread
    // own the work, and output goes straight out through src/out.zig. Park here
    // so the process does not exit; the futex is never woken and a spurious
    // wakeup must not return, hence the loop.
    var parked: u32 = 0;
    while (true) io.futexWaitUncancelable(u32, &parked, 0);
}

/// Plain Zig entry point for `std.Thread.spawn`. The loop logs and returns on
/// failure; it never exits the process.
fn streamEntry(io: std.Io, target: stream.Target) void {
    // The thread owns no arena of its own: the pages it allocates stay for the
    // lifetime of the process (the loop itself never ends), and it runs
    // concurrently with the UI, so it must not touch a scratch arena that
    // another thread frees.
    stream.run(io, std.heap.smp_allocator, target);
}

/// Reads the token and domain from the config and hands them to C, which keeps
/// them as statics for the poster. Returns `null` when there is no token yet,
/// i.e. the first run needs registration.
fn loadCredentials(arena: std.mem.Allocator, io: std.Io, cfg: config.Config) ?poster.Credentials {
    const token = (cfg.readToken(arena, io) catch return null) orelse return null;
    const domain = (cfg.readDomain(arena, io) catch return null) orelse return null;

    // Both strings must outlive this function: the streaming thread reads the
    // header much later, so a stack buffer here would be dead by then.
    var hdr_buf: [256 + 32]u8 = undefined;
    const header_tmp = std.mem.printSentinel(
        &hdr_buf,
        "Authorization: Bearer {s}",
        .{token},
        0,
    ) catch {
        std.debug.print("nanotodon: access token is too long\n", .{});
        return null;
    };
    const header = arena.dupeSentinel(u8, header_tmp, 0) catch return null;
    const domain_z = arena.dupeSentinel(u8, domain, 0) catch return null;

    return .{ .domain = domain_z, .header = header };
}

// No C file drives Zig output any more: images are assembled in Zig
// (src/image.zig) and leave with their status through one output.write(), so
// there is no `export` that has to smuggle a std.Io through C. Anything C
// writes to stdout directly would break that atomicity.

// `cli`, `proto`, `server`, `socketpath` and `stream` are only referenced from
// main(), which is not analyzed in a test build, so without touching them here
// the tests inside those files would never be collected.
test {
    //    _ = cli;
    std.testing.refAllDecls(auth);
    std.testing.refAllDecls(cli);
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(image);
    std.testing.refAllDecls(output);
    std.testing.refAllDecls(poster);
    std.testing.refAllDecls(proto);
    std.testing.refAllDecls(server);
    std.testing.refAllDecls(socketpath);
    std.testing.refAllDecls(notify);
    std.testing.refAllDecls(status_render);
    std.testing.refAllDecls(stream);
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
