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
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    return "application/octet-stream";
}

fn handleRoute(route: Route, index: *const posts_mod.Index, hot_reload: bool, io: Io, aa: std.mem.Allocator) !Response {
    switch (route) {
        .home => {
            var list = std.ArrayListAligned(u8, null){ .items = &.{}, .capacity = 0 };
            defer list.deinit(aa);
            const limit = @min(@as(usize, 5), index.posts.len);
            for (index.posts[0..limit]) |p| {
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
        .posts_list => {
            var list = std.ArrayListAligned(u8, null){ .items = &.{}, .capacity = 0 };
            defer list.deinit(aa);
            for (index.posts) |p| {
                const item = try template.postListItem(p.slug, p.title, p.date, aa);
                try list.appendSlice(aa, item);
                aa.free(item);
            }
            return Response{
                .body = try template.home(list.items, "Archive — " ++ config.site_title, config.hot_reload, aa),
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
            if (std.mem.indexOf(u8, rel, "..") != null) {
                return Response{
                    .body = try template.notFound(aa),
                    .status = .not_found,
                    .content_type = "text/html",
                };
            }
            const prefixed = try std.fmt.allocPrint(aa, "public/{s}", .{rel});
            const file_content = Io.Dir.cwd().readFileAlloc(io, prefixed, aa, .unlimited) catch {
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
        .events => return Response{
            .body = "",
            .status = .ok,
            .content_type = "text/event-stream",
        },
        .not_found => return Response{
            .body = try template.notFound(aa),
            .status = .not_found,
            .content_type = "text/html",
        },
    }
}

fn handleSSE(stream: net.Stream, io: Io) void {
    var sse_recv: [256]u8 = undefined;
    var sse_send: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &sse_recv);
    var conn_writer = stream.writer(io, &sse_send);
    var server = http.Server.init(&conn_reader.interface, &conn_writer.interface);

    var request = server.receiveHead() catch return;

    var sse_buf: [256]u8 = undefined;
    var bw = request.respondStreaming(&sse_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/event-stream" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        },
    }) catch {
        stream.close(io);
        return;
    };

    bw.writer.writeAll(": connected\n\n") catch {
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
        bw.writer.writeAll(": keepalive\n") catch break;
        if (hotreload.check()) {
            bw.writer.writeAll("data: reload\n\n") catch break;
            break;
        }
        if (sse_snapshot.refresh(io) catch false) {
            hotreload.notify();
        }
        Io.sleep(io, Io.Duration.fromMilliseconds(3000), .awake) catch break;
    }

    bw.end() catch {};
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

            const route = match(request.head.target);

            if (route == .events) {
                const sse_thread = std.Thread.spawn(.{}, handleSSE, .{ stream, io }) catch |err| {
                    std.log.err("failed to spawn SSE thread: {s}", .{@errorName(err)});
                    break;
                };
                sse_thread.detach();
                sse_detached = true;
                break;
            }

            _ = arena.reset(.retain_capacity);
            const aa = arena.allocator();

            if (snapshot.refresh(io) catch |err| blk: {
                std.log.err("snapshot refresh error: {s}", .{@errorName(err)});
                break :blk false;
            }) {
                const new_index = try posts_mod.scanAndRender(std.heap.smp_allocator, io);
                index.deinit();
                index = new_index;
            }

            const result = try handleRoute(route, &index, config.hot_reload, io, aa);

            request.respond(result.body, .{
                .status = result.status,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = result.content_type },
                },
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

test "match: path traversal treated as not-found" {
    const r = match("/posts/../build.zig");
    try std.testing.expect(r == .post);
    try std.testing.expectEqualStrings("../build.zig", @as(@TypeOf(r.post), r.post));
}

test "path traversal check: blocks .. in public path" {
    const rel = "../build.zig";
    try std.testing.expect(std.mem.indexOf(u8, rel, "..") != null);
}

test "path traversal check: allows safe paths" {
    const rel = "style.css";
    try std.testing.expect(std.mem.indexOf(u8, rel, "..") == null);
}

test "path traversal check: blocks nested .." {
    const rel = "foo/../../etc/passwd";
    try std.testing.expect(std.mem.indexOf(u8, rel, "..") != null);
}
