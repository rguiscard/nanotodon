//! Command line option handling for nanotodon.
//!
//! Parsing, validation, clamping and the user facing messages all live here.
//! The result is handed to the C side with a single call to
//! `nanotodon_apply_cli_options()` (see src/headers.h), so C keeps ownership
//! of its static string literals and of `config.profile_name[256]`.
//!
//! `apply()` must run before `nanotodon_start()`: the C side reads these
//! globals while starting its streaming/prompt threads, and `nanotodon_start()`
//! calls `nano_config_init()` right at the top, which needs `profile_name`
//! already set.

const std = @import("std");
const translated = @import("translated");

/// Values must match `NANOTODON_TIMELINE_*` in src/headers.h.
pub const Timeline = enum(c_int) {
    home = 0,
    local = 1,
    public = 2,
};

/// `config.profile_name` is `char[256]`; the longest storable name is 255.
pub const max_profile_len = 255;

/// Hard upper bound the C code used to apply to `-tllimit` (the REST API caps
/// the `limit` parameter at 40).
pub const max_limit_timeline: c_int = 40;

pub const Options = struct {
    mono: bool = false,
    unlock: bool = false,
    no_emoji: bool = false,
    /// Borrows from the argument iterator's storage; valid for as long as the
    /// iterator handed to `parse()` is alive. `apply()` copies it out.
    profile: ?[]const u8 = null,
    /// -1 means "not specified": the C default (20) stays in effect.
    limit_timeline: c_int = -1,
    timeline: Timeline = .home,
    /// `-socket <path>`; when null the path is derived by socketpath.zig.
    socket: ?[]const u8 = null,
};

pub const ParseError = error{
    TooFewArguments,
    UnknownTimeline,
    ProfileTooLong,
};

pub const Error = ParseError || std.Io.Writer.Error;

/// Parse the command line from an argument *iterator*.
///
/// `it` is a pointer to anything exposing `skip() bool` and `next() ?[]const u8`.
/// In the real program that is `std.process.Args.Iterator` (see src/main.zig);
/// in the tests below it is a stub. Keeping it duck typed means this file never
/// has to name `std.process`, whose `Args` cannot be constructed portably
/// outside a real process.
///
/// The program name is dropped with `skip()`, so the loop only ever sees
/// actual options. Informational messages go to `writer` (pass null to discard
/// them), while errors go to stderr, matching the old printf/fprintf split.
/// Unknown options are *not* fatal, same as the C implementation.
pub fn parse(it: anytype, writer: ?*std.Io.Writer) Error!Options {
    var opts: Options = .{};

    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-mono")) {
            opts.mono = true;
            try info(writer, "Monochrome mode.\n", .{});
        } else if (std.mem.eql(u8, arg, "-unlock")) {
            opts.unlock = true;
            try info(writer, "Show DIRECT and PRIVATE.\n", .{});
        } else if (std.mem.eql(u8, arg, "-noemoji")) {
            opts.no_emoji = true;
            try info(writer, "Hide UI emojis.\n", .{});
        } else if (std.mem.eql(u8, arg, "-profile")) {
            const value = try nextValue(it);
            if (value.len > max_profile_len) {
                std.debug.print("Profile name too long (max {d} bytes)\n", .{max_profile_len});
                return ParseError.ProfileTooLong;
            }
            opts.profile = value;
            try info(writer, "Using profile: {s}\n", .{value});
        } else if (std.mem.eql(u8, arg, "-socket")) {
            opts.socket = try nextValue(it);
        } else if (std.mem.eql(u8, arg, "-tllimit")) {
            const value = try nextValue(it);
            // atoi() semantics: unparsable input becomes 0, then clamp.
            var limit = std.fmt.parseInt(c_int, value, 10) catch 0;
            limit = std.math.clamp(limit, 0, max_limit_timeline);
            opts.limit_timeline = limit;
            try info(writer, "Timeline limit: {d}\n", .{limit});
        } else if (std.mem.eql(u8, arg, "-timeline")) {
            const value = try nextValue(it);
            if (std.mem.eql(u8, value, "home")) {
                opts.timeline = .home;
            } else if (std.mem.eql(u8, value, "local")) {
                opts.timeline = .local;
            } else if (std.mem.eql(u8, value, "public")) {
                opts.timeline = .public;
            } else {
                std.debug.print("Unknown timeline {s}\n", .{value});
                return ParseError.UnknownTimeline;
            }
            // Historical quirk kept on purpose: "-timeline home" reports the
            // streaming endpoint ("user"), not the option value.
            try info(writer, "Using timeline: {s}\n", .{streamName(opts.timeline)});
        } else {
            std.debug.print("Unknown Option {s}\n", .{arg});
        }
    }

    return opts;
}

/// Copy the parsed options into the C side.
///
/// Must be called exactly once, before `translated.nanotodon_start()`. The
/// profile pointer handed to C refers to `profile_buf`, which is static so its
/// lifetime covers the whole process.
pub fn apply(opts: Options) void {
    var c_opts: C_Options = .{
        .mono = if (opts.mono) 1 else 0,
        .unlock = if (opts.unlock) 1 else 0,
        .no_emoji = if (opts.no_emoji) 1 else 0,
        .profile = null,
        .limit_timeline = opts.limit_timeline,
        .timeline = @intFromEnum(opts.timeline),
    };

    if (opts.profile) |name| {
        std.debug.assert(name.len <= max_profile_len);
        const len = @min(name.len, max_profile_len);
        @memcpy(profile_buf[0..len], name[0..len]);
        profile_buf[len] = 0;
        c_opts.profile = @as([*:0]const u8, @ptrCast(profile_buf[0..].ptr));
    }

    translated.nanotodon_apply_cli_options(&c_opts);
}

/// Backing storage for the NUL terminated profile name passed to C.
/// Only written by `apply()` before any C thread exists.
var profile_buf: [max_profile_len + 1]u8 = undefined;

/// translate-c exports a same-named typedef as a plain alias; fall back to the
/// raw tag name in case only that one is emitted.
const C_Options = if (@hasDecl(translated, "nanotodon_cli_options"))
    translated.nanotodon_cli_options
else
    translated.struct_nanotodon_cli_options;

fn streamName(timeline: Timeline) []const u8 {
    return switch (timeline) {
        .home => "user",
        .local => "public/local",
        .public => "public",
    };
}

/// Consume the following token as this option's value.
fn nextValue(it: anytype) ParseError![]const u8 {
    if (it.next()) |value| return value;
    std.debug.print("too few arguments\n", .{});
    return ParseError.TooFewArguments;
}

fn info(writer: ?*std.Io.Writer, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    if (writer) |w| try w.print(fmt, args);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Minimal stand-in for `std.process.Args.Iterator`: same duck-typed surface
/// (`skip() bool`, `next() ?[]const u8`) over a plain slice.
const TestArgs = struct {
    items: []const []const u8,
    idx: usize = 0,

    fn skip(self: *TestArgs) bool {
        if (self.idx >= self.items.len) return false;
        self.idx += 1;
        return true;
    }

    fn next(self: *TestArgs) ?[]const u8 {
        if (self.idx >= self.items.len) return null;
        defer self.idx += 1;
        return self.items[self.idx];
    }
};

fn parseArgv(argv: []const []const u8) Error!Options {
    var it: TestArgs = .{ .items = argv };
    return parse(&it, null);
}

test "the program name is skipped, not treated as an option" {
    const opts = try parseArgv(&.{"-mono"});
    try testing.expect(!opts.mono);
}

test "no arguments yields defaults" {
    const opts = try parseArgv(&.{"nanotodon"});
    try testing.expect(!opts.mono);
    try testing.expect(!opts.unlock);
    try testing.expect(!opts.no_emoji);
    try testing.expect(opts.profile == null);
    try testing.expectEqual(@as(c_int, -1), opts.limit_timeline);
    try testing.expectEqual(Timeline.home, opts.timeline);
}

test "flags" {
    const opts = try parseArgv(&.{ "nanotodon", "-mono", "-unlock", "-noemoji" });
    try testing.expect(opts.mono);
    try testing.expect(opts.unlock);
    try testing.expect(opts.no_emoji);
}

test "profile takes the next argument" {
    const opts = try parseArgv(&.{ "nanotodon", "-profile", "work" });
    try testing.expectEqualStrings("work", opts.profile.?);
}

test "socket takes the next argument" {
    const opts = try parseArgv(&.{ "nanotodon", "-socket", "/tmp/x.sock" });
    try testing.expectEqualStrings("/tmp/x.sock", opts.socket.?);
}

test "socket without a value is fatal" {
    try testing.expectError(ParseError.TooFewArguments, parseArgv(&.{ "nanotodon", "-socket" }));
}

test "profile without a value is fatal" {
    try testing.expectError(ParseError.TooFewArguments, parseArgv(&.{ "nanotodon", "-profile" }));
}

test "profile longer than the C buffer is rejected" {
    const too_long: [256]u8 = @splat('x');
    try testing.expectError(
        ParseError.ProfileTooLong,
        parseArgv(&.{ "nanotodon", "-profile", &too_long }),
    );
}

test "profile at the buffer limit is accepted" {
    const ok: [255]u8 = @splat('x');
    const opts = try parseArgv(&.{ "nanotodon", "-profile", &ok });
    try testing.expectEqual(@as(usize, 255), opts.profile.?.len);
}

test "tllimit is clamped to 0..40" {
    try testing.expectEqual(@as(c_int, 15), (try parseArgv(&.{ "nanotodon", "-tllimit", "15" })).limit_timeline);
    try testing.expectEqual(@as(c_int, 0), (try parseArgv(&.{ "nanotodon", "-tllimit", "-5" })).limit_timeline);
    try testing.expectEqual(@as(c_int, 40), (try parseArgv(&.{ "nanotodon", "-tllimit", "999" })).limit_timeline);
    // atoi() compatible: garbage parses as 0.
    try testing.expectEqual(@as(c_int, 0), (try parseArgv(&.{ "nanotodon", "-tllimit", "abc" })).limit_timeline);
}

test "tllimit without a value is fatal" {
    try testing.expectError(ParseError.TooFewArguments, parseArgv(&.{ "nanotodon", "-tllimit" }));
}

test "timeline selection" {
    try testing.expectEqual(Timeline.home, (try parseArgv(&.{ "nanotodon", "-timeline", "home" })).timeline);
    try testing.expectEqual(Timeline.local, (try parseArgv(&.{ "nanotodon", "-timeline", "local" })).timeline);
    try testing.expectEqual(Timeline.public, (try parseArgv(&.{ "nanotodon", "-timeline", "public" })).timeline);
}

test "unknown timeline is fatal" {
    try testing.expectError(
        ParseError.UnknownTimeline,
        parseArgv(&.{ "nanotodon", "-timeline", "bogus" }),
    );
}

test "timeline without a value is fatal" {
    try testing.expectError(ParseError.TooFewArguments, parseArgv(&.{ "nanotodon", "-timeline" }));
}

test "unknown option is not fatal" {
    const opts = try parseArgv(&.{ "nanotodon", "-bogus", "-mono" });
    try testing.expect(opts.mono);
}

test "stream endpoint names" {
    try testing.expectEqualStrings("user", streamName(.home));
    try testing.expectEqualStrings("public/local", streamName(.local));
    try testing.expectEqualStrings("public", streamName(.public));
}

test "timeline enum values match the C macros" {
    try testing.expectEqual(@as(c_int, 0), @intFromEnum(Timeline.home));
    try testing.expectEqual(@as(c_int, 1), @intFromEnum(Timeline.local));
    try testing.expectEqual(@as(c_int, 2), @intFromEnum(Timeline.public));
}
