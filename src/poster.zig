//! Posts a status through `zig-curl` (the former C `nanotodon_post_toot()`).
//!
//! It is deliberately allocation-free — every string it needs fits in a stack
//! buffer — so it matches the `server.Poster` callback signature exactly, which
//! has no allocator or `Io` parameter. One `Easy` handle per call, so the
//! concurrent connection handlers never share libcurl state.
//!
//! Everything here is read-only after startup: `Credentials` is filled in from
//! the config before the accept thread starts and then never changes, so the
//! concurrent connection handlers can read it without synchronisation.
//!
//! Note: this links against whatever libcurl `build.zig` selects. With
//! `link_vendor = false` (the current setting) the system libcurl provides the
//! CA store, so no bundle is passed. If you ever switch to the vendored build
//! (mbedtls), pass `curl.allocCABundle(allocator, io)` via `.ca_bundle`.

const std = @import("std");
const curl = @import("curl");
const proto = @import("proto.zig");

const request_timeout_ms = 30_000;

/// Mastodon's error JSON is tiny; anything longer is a success body we do not
/// need.
const max_body_capture = 2048;

/// Collects the response body *without* ever failing the transfer: libcurl
/// aborts with `CURLE_WRITE_ERROR` when a write callback returns short, which
/// would turn a successful post into a reported failure just because the status
/// JSON was bigger than our buffer.
const Capture = struct {
    head: []u8,
    len: usize = 0,

    fn slice(self: *const Capture) []const u8 {
        return self.head[0..self.len];
    }
};

fn captureWrite(
    ptr: [*c]c_char,
    size: c_uint,
    nmemb: c_uint,
    user_data: *anyopaque,
) callconv(.c) c_uint {
    const total: usize = @as(usize, size) * @as(usize, nmemb);
    if (total == 0) return 0;

    const capture: *Capture = @ptrCast(@alignCast(user_data));
    const data: [*]const u8 = @ptrCast(ptr);
    const n = @min(capture.head.len - capture.len, total);
    @memcpy(capture.head[capture.len..][0..n], data[0..n]);
    capture.len += n;

    return @intCast(total);
}

/// Mastodon answers API rejections with `{"error": "..."}`. Pulling that out is
/// the difference between `toot: HTTP 422` and
/// `toot: HTTP 422: Validation failed: Text can't be blank`.
fn errorMessage(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const Wire = struct { @"error": ?[]const u8 = null };
    const parsed = std.json.parseFromSliceLeaky(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed.@"error";
}

/// What posting needs, resolved once at startup. Passed to `server.Poster` as
/// its `ctx`, so `post()` needs no allocator and no C accessors.
pub const Credentials = struct {
    /// Instance hostname, no scheme.
    domain: [:0]const u8,
    /// The whole `Authorization: Bearer ...` line.
    header: [:0]const u8,
};

/// Signature must match `server.Poster.postFn`; `ctx` is a `*const Credentials`.
pub fn post(
    ctx: ?*anyopaque,
    status: [:0]const u8,
    visibility: proto.Visibility,
    err_out: []u8,
) ?[]const u8 {
    const creds: *const Credentials = @ptrCast(@alignCast(ctx orelse
        return fail(err_out, "no credentials", .{})));

    var url_buf: [512]u8 = undefined;
    const url = std.mem.printSentinel(
        &url_buf,
        "https://{s}/api/v1/statuses",
        .{creds.domain},
        0,
    ) catch return fail(err_out, "domain name too long", .{});

    // `setCommonOpts()` inside the package always applies a timeout, so a hung
    // instance cannot wedge a connection handler forever.
    var easy = curl.Easy.init(.{
        .default_timeout_ms = request_timeout_ms,
        .default_user_agent = "nanotodon",
    }) catch return fail(err_out, "curl easy init failed", .{});
    defer easy.deinit();

    var headers: curl.Easy.Headers = .{};
    defer headers.deinit();
    headers.add(creds.header) catch
        return fail(err_out, "cannot build request headers", .{});

    var mime = easy.createMultiPart() catch
        return fail(err_out, "cannot create multipart body", .{});
    defer mime.deinit();
    mime.addPart("status", .{ .data = status }) catch
        return fail(err_out, "cannot attach status", .{});
    mime.addPart("visibility", .{ .data = @tagName(visibility) }) catch
        return fail(err_out, "cannot attach visibility", .{});

    easy.setUrl(url) catch return fail(err_out, "cannot set URL", .{});
    easy.setMethod(.POST) catch return fail(err_out, "cannot set method", .{});
    easy.setFollowLocation(true) catch return fail(err_out, "cannot enable redirects", .{});
    easy.setMaxRedirects(50) catch return fail(err_out, "cannot set max redirects", .{});
    easy.setHeaders(headers) catch return fail(err_out, "cannot set headers", .{});
    easy.setMultiPart(mime) catch return fail(err_out, "cannot set multipart body", .{});

    var body_buf: [max_body_capture]u8 = undefined;
    var capture: Capture = .{ .head = &body_buf };
    easy.setWritedata(&capture) catch return fail(err_out, "cannot set write target", .{});
    easy.setWritefunction(captureWrite) catch return fail(err_out, "cannot set write callback", .{});

    const response = easy.perform() catch |err| {
        if (easy.diagnostics.getMessage()) |msg| return fail(err_out, "{s}", .{msg});
        return fail(err_out, "curl: {s}", .{@errorName(err)});
    };

    // libcurl is not told to fail on 4xx/5xx, so the code and the body are both
    // available here.
    if (response.status_code < 200 or response.status_code >= 300) {
        var scratch_buf: [1024]u8 = undefined;
        var scratch: std.heap.FixedBufferAllocator = .init(&scratch_buf);
        if (errorMessage(scratch.allocator(), capture.slice())) |msg| {
            return fail(err_out, "HTTP {d}: {s}", .{ response.status_code, msg });
        }
        return fail(err_out, "HTTP {d}", .{response.status_code});
    }

    return null;
}

fn fail(err_out: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const written = std.mem.print(err_out, fmt, args) catch return "post failed";
    return written;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "captureWrite copies what fits and still reports success" {
    var head: [4]u8 = undefined;
    var capture: Capture = .{ .head = &head };
    const payload = "abcdefgh";
    const returned = captureWrite(
        @ptrCast(@constCast(payload.ptr)),
        1,
        @intCast(payload.len),
        @ptrCast(&capture),
    );
    try testing.expectEqual(@as(c_uint, payload.len), returned);
    try testing.expectEqualStrings("abcd", capture.slice());
}

test "errorMessage reads Mastodon's error field" {
    var scratch_buf: [512]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&scratch_buf);
    const body = "{\"error\":\"Validation failed: Text can't be blank\"}";
    try testing.expectEqualStrings(
        "Validation failed: Text can't be blank",
        errorMessage(scratch.allocator(), body).?,
    );
}

test "errorMessage ignores bodies without an error field" {
    var scratch_buf: [512]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&scratch_buf);
    const allocator = scratch.allocator();

    try testing.expect(errorMessage(allocator, "not json") == null);
    try testing.expect(errorMessage(allocator, "{\"id\":\"123\"}") == null);
    try testing.expect(errorMessage(allocator, "") == null);
}
