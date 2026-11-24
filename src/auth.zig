//! First-run registration: ask for the instance, register the client and run
//! the OAuth authorization-code exchange (the former C `nanotodon_register()`,
//! `do_create_client()` and `do_oauth()`).
//!
//! The files it writes are exactly the ones the C version wrote, so existing
//! installs and older/newer binaries keep working with each other:
//!
//!   <root>/domain/<profile>       plain hostname, no trailing newline
//!   <root>/app_token/<domain>     raw body of POST /api/v1/apps
//!   <root>/token/<profile>        raw body of POST /oauth/token
//!
//! Only this dialog reads stdin, and it does so one byte at a time: a buffered
//! reader could swallow keystrokes that the terminal reader needs afterwards.

const std = @import("std");
const Io = std.Io;

const curl = @import("curl");
const config = @import("config.zig");

const user_agent = "nanotodon";
const request_timeout_ms = 30_000;

/// Same limit the old `scanf("%255s")` enforced.
const max_input = 255;

/// Mastodon's app and token responses are a few hundred bytes. A larger body
/// (an HTML error page from a proxy, say) makes the fixed writer fail, which
/// surfaces as a transfer error instead of a truncated parse.
const max_body = 8192;

const redirect_uri = "urn:ietf:wg:oauth:2.0:oob";
const scopes = "read write follow";

/// Errors this dialog reports itself. File-system failures come up from
/// `config.Config` unchanged, and `register()` keeps its error set inferred so
/// those propagate without being enumerated here.
pub const Error = error{
    /// A URL or path did not fit its buffer.
    TooLong,
    /// stdin is closed, or a line was longer than the input buffer.
    BadInput,
    /// curl refused the request; the reason was already printed.
    Transfer,
    /// The instance answered with something other than 2xx.
    HttpStatus,
};

/// Interactive registration. Returns once `<root>/token/<profile>` holds an
/// access token; the caller re-reads it through `config.Config`.
pub fn register(
    io: Io,
    arena: std.mem.Allocator,
    cfg: config.Config,
    out: *Io.Writer,
) !void {
    const stdin = Io.File.stdin();

    try out.writeAll(
        \\Hello! Welcome to nanotodon!
        \\
    );
    try out.flush();

    // Separate buffers: `domain` is still needed after the code has been read.
    var domain_buf: [max_input + 1]u8 = undefined;
    var code_buf: [max_input + 1]u8 = undefined;
    var body_buf: [max_body]u8 = undefined;

    // The C version jumped back to the domain prompt on any inconsistency and
    // never gave up, so a typo costs nothing.
    while (true) {
        try prompt(out, "First, please tell me the server where you live.\n" ++
            "(https://[please enter this part]/)\n> ");
        const domain = try readField(io, stdin, &domain_buf);
        if (domain.len == 0) continue;

        try cfg.saveDomain(io, domain);

        // The app registration is cached per instance; only POST if missing.
        const app_body = cfg.readAppToken(arena, io, domain) orelse body: {
            const body = try createClient(domain, &body_buf);
            const path = try cfg.appTokenPath(arena, io, domain);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
            break :body body;
        };

        const client = parseClient(arena, app_body) orelse {
            try restart(io, arena, cfg, domain, out, "Something is wrong.\n" ++
                "Let me start over from the beginning.\n");
            continue;
        };

        try out.writeAll("Next, let's authenticate the application.\n" ++
            "Open the URL below, authorize nanotodon, then paste the code it shows.\n");

        var url_buf: [1024]u8 = undefined;
        const url = try authorizeUrl(&url_buf, domain, client.client_id);
        try out.writeAll(url);
        try out.writeAll("\n");

        try prompt(out, "> ");
        const code = try readField(io, stdin, &code_buf);
        if (code.len == 0) continue;

        try exchangeCode(io, cfg, domain, client, code, &body_buf);

        // Believe the file, not the response: this is what the next start will
        // use, and it also catches a token response without access_token.
        if ((cfg.readToken(arena, io) catch null) == null) {
            try restart(io, arena, cfg, domain, out, "Something is wrong.\n" ++
                "Is the authorization code correct?\n" ++
                "Let me start over from the beginning.\n");
            continue;
        }

        try out.writeAll("It's done! Enjoy your nanotodon life!\n");
        try out.flush();
        return;
    }
}

/// Reports a failed attempt and removes everything it wrote, mirroring the C
/// version's `remove()` calls. Only reached while there is no usable token, so
/// nothing that works is thrown away.
fn restart(
    io: Io,
    arena: std.mem.Allocator,
    cfg: config.Config,
    domain: []const u8,
    out: *Io.Writer,
    message: []const u8,
) !void {
    try out.writeAll(message);
    try out.flush();

    if (cfg.appTokenPath(arena, io, domain)) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    } else |_| {}
    std.Io.Dir.cwd().deleteFile(io, cfg.domain_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, cfg.token_path) catch {};
}

fn prompt(out: *Io.Writer, text: []const u8) !void {
    try out.writeAll(text);
    try out.flush();
}

/// One line from stdin without its line ending. Bytes past the newline stay
/// unread, so the terminal reader that runs later sees the same stream.
fn readField(io: Io, file: Io.File, buf: []u8) Error![]const u8 {
    var len: usize = 0;
    var too_long = false;
    var byte: [1]u8 = undefined;
    const one: []u8 = &byte;

    while (true) {
        const n = file.readStreaming(io, &.{one}) catch return Error.BadInput;
        if (n == 0) return Error.BadInput; // EOF: nobody left to prompt
        if (byte[0] == '\n') break;

        if (len == buf.len) {
            // Keep consuming the line so the next prompt does not read its tail
            // as an answer of its own.
            too_long = true;
            continue;
        }
        buf[len] = byte[0];
        len += 1;
    }

    if (too_long) return Error.BadInput;
    return std.mem.trim(u8, buf[0..len], " \t\r");
}

const Client = struct {
    client_id: []const u8,
    client_secret: []const u8,
};

fn parseClient(arena: std.mem.Allocator, body: []const u8) ?Client {
    return std.json.parseFromSliceLeaky(Client, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

/// `https://<domain>/oauth/authorize?...` exactly as the C version printed it,
/// including the literal `%20`s: Mastodon wants space-separated scopes.
fn authorizeUrl(buf: []u8, domain: []const u8, client_id: []const u8) Error![:0]const u8 {
    return std.mem.printSentinel(
        buf,
        "https://{s}/oauth/authorize?client_id={s}&response_type=code" ++
            "&redirect_uri=" ++ redirect_uri ++ "&scope=read%20write%20follow",
        .{ domain, client_id },
        0,
    ) catch Error.TooLong;
}

/// `POST /api/v1/apps`. The response body is the client credential cache.
fn createClient(domain: []const u8, body_buf: []u8) Error![]const u8 {
    var url_buf: [512]u8 = undefined;
    const url = std.mem.printSentinel(&url_buf, "https://{s}/api/v1/apps", .{domain}, 0) catch
        return Error.TooLong;

    return postMultipart(url, &.{
        .{ .name = "client_name", .value = "nanotodon" },
        .{ .name = "redirect_uris", .value = redirect_uri },
        .{ .name = "scopes", .value = scopes },
    }, body_buf);
}

/// `POST /oauth/token`: trades the authorization code for an access token and
/// writes the response body to the token file.
fn exchangeCode(
    io: Io,
    cfg: config.Config,
    domain: []const u8,
    client: Client,
    code: []const u8,
    body_buf: []u8,
) !void {
    var url_buf: [512]u8 = undefined;
    const url = std.mem.printSentinel(&url_buf, "https://{s}/oauth/token", .{domain}, 0) catch
        return Error.TooLong;

    const body = try postMultipart(url, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "client_id", .value = client.client_id },
        .{ .name = "client_secret", .value = client.client_secret },
        .{ .name = "code", .value = code },
    }, body_buf);

    try cfg.saveToken(io, body);
}

const Part = struct {
    name: [:0]const u8,
    value: []const u8,
};

/// One multipart POST. Multipart rather than form-urlencoded because the client
/// secret and the code are user data that would otherwise need escaping.
fn postMultipart(url: [:0]const u8, parts: []const Part, body_buf: []u8) Error![]const u8 {
    var easy = curl.Easy.init(.{
        .default_timeout_ms = request_timeout_ms,
        .default_user_agent = user_agent,
    }) catch return fail("cannot create a curl handle", .{});
    defer easy.deinit();

    var mime = easy.createMultiPart() catch return fail("cannot create a request body", .{});
    defer mime.deinit();
    for (parts) |part| {
        mime.addPart(part.name, .{ .data = part.value }) catch
            return fail("cannot add the form field {s}", .{part.name});
    }

    easy.setUrl(url) catch return fail("cannot set the URL", .{});
    easy.setMethod(.POST) catch return fail("cannot set the method", .{});
    easy.setFollowLocation(true) catch return fail("cannot enable redirects", .{});
    easy.setMaxRedirects(50) catch return fail("cannot set max redirects", .{});
    easy.setMultiPart(mime) catch return fail("cannot set the request body", .{});

    var body_writer: Io.Writer = .fixed(body_buf);
    easy.setWriter(&body_writer) catch return fail("cannot set the write target", .{});

    const response = easy.perform() catch |err| {
        if (easy.diagnostics.getMessage()) |msg| {
            std.debug.print("nanotodon: {s}\n", .{msg});
            return Error.Transfer;
        }
        return fail("curl: {s}", .{@errorName(err)});
    };

    const body = body_writer.buffered();
    if (response.status_code < 200 or response.status_code >= 300) {
        std.debug.print("nanotodon: HTTP {d}: {s}\n", .{ response.status_code, head(body) });
        return Error.HttpStatus;
    }
    return body;
}

/// First line of an error body, so an HTML page does not flood the terminal.
fn head(body: []const u8) []const u8 {
    const limit = 200;
    const end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    return body[0..@min(end, limit)];
}

fn fail(comptime fmt: []const u8, args: anytype) Error {
    std.debug.print("nanotodon: " ++ fmt ++ "\n", args);
    return error.Transfer;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseClient reads the app registration response" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const body =
        \\{"id":"42","name":"nanotodon","client_id":"cid-1","client_secret":"cs-2",
        \\ "redirect_uri":"urn:ietf:wg:oauth:2.0:oob","vapid_key":"nope"}
    ;
    const client = parseClient(arena_state.allocator(), body).?;
    try testing.expectEqualStrings("cid-1", client.client_id);
    try testing.expectEqualStrings("cs-2", client.client_secret);
}

test "parseClient rejects a response without both credentials" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(parseClient(arena, "{\"client_id\":\"only\"}") == null);
    try testing.expect(parseClient(arena, "{\"error\":\"bad scopes\"}") == null);
    try testing.expect(parseClient(arena, "<html>502</html>") == null);
}

test "authorizeUrl keeps the scopes and the out-of-band redirect" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "https://example.social/oauth/authorize?client_id=cid-1&response_type=code" ++
            "&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=read%20write%20follow",
        try authorizeUrl(&buf, "example.social", "cid-1"),
    );
}

test "authorizeUrl reports a buffer that is too small" {
    var buf: [16]u8 = undefined;
    try testing.expectError(Error.TooLong, authorizeUrl(&buf, "example.social", "cid-1"));
}

test "readField takes one line and leaves the rest of the file unread" {
    const io = testing.io;
    const path = "/tmp/nanotodon-test-readfield.txt";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = "example.social\r\nCODE123\n",
    });

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("example.social", try readField(io, file, &buf));
    try testing.expectEqualStrings("CODE123", try readField(io, file, &buf));
    // EOF: the dialog cannot ask anything else.
    try testing.expectError(Error.BadInput, readField(io, file, &buf));
}

test "readField drains an oversized line before failing" {
    const io = testing.io;
    const path = "/tmp/nanotodon-test-readfield-long.txt";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "abcdefgh\nnext\n" });

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var small: [3]u8 = undefined;
    try testing.expectError(Error.BadInput, readField(io, file, &small));
    // The line was consumed, so the next answer is still readable.
    var big: [16]u8 = undefined;
    try testing.expectEqualStrings("next", try readField(io, file, &big));
}

test "head trims an error body to its first line" {
    try testing.expectEqualStrings("boom", head("boom\ntraceback..."));
    try testing.expectEqualStrings("boom", head("boom"));
}
