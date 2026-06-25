const std = @import("std");
const Io = std.Io;
const net = Io.net;
const http = std.http;
const config = @import("config.zig");
const template = @import("template.zig");
const posts_mod = @import("posts.zig");
const hotreload = @import("hotreload.zig");

const Response = struct {
    body: []const u8,
    status: http.Status,
    content_type: []const u8,
};

const Route = union(enum) {
    home,
    posts_list,
    post: []const u8,
    public: []const u8,
    events,
    not_found,
};

fn match(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/")) return .home;
    if (std.mem.eql(u8, path, "/posts")) return .posts_list;
    if (std.mem.eql(u8, path, "/events")) return .events;
    if (std.mem.startsWith(u8, path, "/posts/")) return .{ .post = path[7..] };
    if (std.mem.startsWith(u8, path, "/public/")) return .{ .public = path[8..] };
    return .not_found;
}

fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    return "application/octet-stream";
}

fn isSafeRelPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return false;
    for (path) |ch| {
        if (ch == '\\') return false;
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn handleRoute(route: Route, index: *const posts_mod.Index, hot_reload: bool, io: Io, aa: std.mem.Allocator) !Response {
    switch (route) {
        .home, .posts_list => {
            var list = std.ArrayListAligned(u8, null){ .items = &.{}, .capacity = 0 };
            defer list.deinit(aa);
            for (index.posts) |p| {
                const item = try template.postListItem(p.slug, p.title, p.date, aa);
                try list.appendSlice(aa, item);
                aa.free(item);
            }
            return Response{
                .body = try template.home(list.items, config.site_title, config.hot_reload, aa),
                .status = .ok,
                .content_type = "text/html",
            };
        },
        .post => |slug| {
            for (index.posts) |p| {
                if (std.mem.eql(u8, p.slug, slug)) {
                    return Response{
                        .body = try template.home(
                            try template.postPage(p.title, p.date, p.body_html, aa),
                            try std.fmt.allocPrint(aa, "{s} — " ++ config.site_title, .{p.title}),
                            hot_reload,
                            aa,
                        ),
                        .status = .ok,
                        .content_type = "text/html",
                    };
                }
            }
            return Response{
                .body = try template.notFound(aa),
                .status = .not_found,
                .content_type = "text/html",
            };
        },
        .public => |rel| {
            if (!isSafeRelPath(rel)) {
                return Response{
                    .body = try template.notFound(aa),
                    .status = .not_found,
                    .content_type = "text/html",
                };
            }
            const prefixed = try std.fmt.allocPrint(aa, "public/{s}", .{rel});
            const file_content = Io.Dir.cwd().readFileAlloc(io, prefixed, aa, Io.Limit.limited(config.max_public_file_bytes)) catch {
                return Response{
                    .body = try template.notFound(aa),
                    .status = .not_found,
                    .content_type = "text/html",
                };
            };
            return Response{
                .body = file_content,
                .status = .ok,
                .content_type = mimeType(rel),
            };
        },
        .events => return if (hot_reload)
            Response{
                .body = "",
                .status = .ok,
                .content_type = "text/event-stream",
            }
        else
            Response{
                .body = try template.notFound(aa),
                .status = .not_found,
                .content_type = "text/html",
            },
        .not_found => return Response{
            .body = try template.notFound(aa),
            .status = .not_found,
            .content_type = "text/html",
        },
    }
}

fn handleSSE(stream: net.Stream, io: Io) void {
    var sse_send: [4096]u8 = undefined;
    var cw = stream.writer(io, &sse_send);
    var w: *Io.Writer = &cw.interface;

    w.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n") catch {
        stream.close(io);
        return;
    };
    _ = w.flush() catch {
        stream.close(io);
        return;
    };

    w.writeAll(": connected\n\n") catch {
        stream.close(io);
        return;
    };
    _ = w.flush() catch {
        stream.close(io);
        return;
    };

    var sse_snapshot = posts_mod.PostsSnapshot.init(std.heap.smp_allocator);
    defer sse_snapshot.deinit();
    _ = sse_snapshot.refresh(io) catch {
        stream.close(io);
        return;
    };

    while (true) {
        w.writeAll(": keepalive\n") catch break;
        if (hotreload.check()) {
            w.writeAll("data: reload\n\n") catch break;
            break;
        }
        if (sse_snapshot.refresh(io) catch false) {
            hotreload.notify();
        }
        Io.sleep(io, Io.Duration.fromMilliseconds(3000), .awake) catch break;
    }

    stream.close(io);
}

pub fn main() !void {
    hotreload.init();

    var threaded = Io.Threaded.init(std.heap.smp_allocator, .{});
    const io = threaded.io();

    var index = try posts_mod.scanAndRender(std.heap.smp_allocator, io);
    defer index.deinit();

    var snapshot = posts_mod.PostsSnapshot.init(std.heap.smp_allocator);
    defer snapshot.deinit();
    _ = try snapshot.refresh(io);

    std.log.info("found {d} posts", .{index.posts.len});

    var addr_buf: [30]u8 = undefined;
    const addr_str = try std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ config.bind_addr, config.port });
    const addr = try net.IpAddress.parseLiteral(addr_str);

    var tcp_server = try addr.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    std.log.info("{s} listening on http://{s}:{d}/", .{ config.site_title, config.bind_addr, config.port });

    var recv_buf: [8192]u8 = undefined;
    var send_buf: [8192]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    while (true) {
        var stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };

        var conn_reader = stream.reader(io, &recv_buf);
        var conn_writer = stream.writer(io, &send_buf);
        var server = http.Server.init(&conn_reader.interface, &conn_writer.interface);

        var sse_detached = false;

        while (true) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => break,
                else => {
                    std.log.err("receiveHead failed: {s}", .{@errorName(err)});
                    break;
                },
            };

            var target_path = request.head.target;
            if (std.mem.indexOfScalar(u8, target_path, '?')) |pos| target_path = target_path[0..pos];
            if (std.mem.indexOfScalar(u8, target_path, '#')) |pos| target_path = target_path[0..pos];
            const route = match(target_path);

            if (request.head.method != .GET and request.head.method != .HEAD) {
                _ = request.respond("", .{
                    .status = .method_not_allowed,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/html" },
                        .{ .name = "x-content-type-options", .value = "nosniff" },
                        .{ .name = "referrer-policy", .value = "no-referrer" },
                    },
                }) catch {};
                continue;
            }

            if (config.hot_reload and route == .events) {
                const sse_thread = std.Thread.spawn(.{}, handleSSE, .{ stream, io }) catch |err| {
                    std.log.err("failed to spawn SSE thread: {s}", .{@errorName(err)});
                    break;
                };
                sse_thread.detach();
                sse_detached = true;
                break;
            }

            if (route == .posts_list) {
                _ = request.respond("", .{
                    .status = .see_other,
                    .extra_headers = &.{
                        .{ .name = "location", .value = "/" },
                        .{ .name = "x-content-type-options", .value = "nosniff" },
                        .{ .name = "referrer-policy", .value = "no-referrer" },
                    },
                }) catch {};
                continue;
            }

            _ = arena.reset(.retain_capacity);
            const aa = arena.allocator();

            if (config.hot_reload) {
                if (snapshot.refresh(io) catch |err| blk: {
                    std.log.err("snapshot refresh error: {s}", .{@errorName(err)});
                    break :blk false;
                }) {
                    const new_index = try posts_mod.scanAndRender(std.heap.smp_allocator, io);
                    index.deinit();
                    index = new_index;
                }
            }

            const result = try handleRoute(route, &index, config.hot_reload, io, aa);

            var hdr_buf: [4]http.Header = undefined;
            var hdr_count: usize = 0;
            hdr_buf[hdr_count] = .{ .name = "content-type", .value = result.content_type };
            hdr_count += 1;
            hdr_buf[hdr_count] = .{ .name = "x-content-type-options", .value = "nosniff" };
            hdr_count += 1;
            hdr_buf[hdr_count] = .{ .name = "referrer-policy", .value = "no-referrer" };
            hdr_count += 1;
            if (std.mem.eql(u8, result.content_type, "text/html")) {
                const csp = if (config.hot_reload)
                    "default-src 'self'; script-src 'unsafe-inline'; style-src 'self'; img-src 'self' http: https:; object-src 'none'; base-uri 'none'"
                else
                    "default-src 'self'; script-src 'none'; style-src 'self'; img-src 'self' http: https:; object-src 'none'; base-uri 'none'";
                hdr_buf[hdr_count] = .{ .name = "content-security-policy", .value = csp };
                hdr_count += 1;
            }

            request.respond(result.body, .{
                .status = result.status,
                .extra_headers = hdr_buf[0..hdr_count],
            }) catch |err| {
                std.log.err("respond failed: {s}", .{@errorName(err)});
            };
        }

        if (!sse_detached) {
            stream.close(io);
        }
    }
}

test "match: routes correctly" {
    try std.testing.expect(match("/") == .home);
    try std.testing.expect(match("/posts") == .posts_list);
    try std.testing.expect(match("/events") == .events);
    try std.testing.expect(match("/unknown") == .not_found);
}

test "match: post slug extraction" {
    const r = match("/posts/hello-world");
    try std.testing.expect(r == .post);
    try std.testing.expectEqualStrings("hello-world", @as(@TypeOf(r.post), r.post));
}

test "match: public path extraction" {
    const r = match("/public/style.css");
    try std.testing.expect(r == .public);
    try std.testing.expectEqualStrings("style.css", @as(@TypeOf(r.public), r.public));
}

test "match: path traversal treated as post route" {
    const r = match("/posts/../build.zig");
    try std.testing.expect(r == .post);
    try std.testing.expectEqualStrings("../build.zig", @as(@TypeOf(r.post), r.post));
}

test "isSafeRelPath: blocks empty" {
    try std.testing.expect(!isSafeRelPath(""));
}

test "isSafeRelPath: blocks absolute" {
    try std.testing.expect(!isSafeRelPath("/etc/passwd"));
}

test "isSafeRelPath: blocks backslash" {
    try std.testing.expect(!isSafeRelPath("a\\b"));
}

test "isSafeRelPath: blocks dot segment" {
    try std.testing.expect(!isSafeRelPath("./foo"));
    try std.testing.expect(!isSafeRelPath("foo/./bar"));
}

test "isSafeRelPath: blocks dot-dot segment" {
    try std.testing.expect(!isSafeRelPath("../build.zig"));
    try std.testing.expect(!isSafeRelPath("foo/../../etc/passwd"));
    try std.testing.expect(!isSafeRelPath("foo/bar/.."));
}

test "isSafeRelPath: allows simple name" {
    try std.testing.expect(isSafeRelPath("style.css"));
}

test "isSafeRelPath: allows nested path" {
    try std.testing.expect(isSafeRelPath("css/site.css"));
}

test "isSafeRelPath: blocks double slash" {
    try std.testing.expect(!isSafeRelPath("a//b"));
}

test "isSafeRelPath: blocks trailing slash" {
    try std.testing.expect(!isSafeRelPath("a/"));
}

test "isSafeRelPath: blocks NUL" {
    try std.testing.expect(!isSafeRelPath("a\x00b"));
}
