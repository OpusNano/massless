const std = @import("std");
const config = @import("config.zig");

fn escapeHtml(text: []const u8, buf: *std.ArrayListAligned(u8, null), allocator: std.mem.Allocator) !void {
    for (text) |ch| switch (ch) {
        '<' => try buf.appendSlice(allocator, "&lt;"),
        '>' => try buf.appendSlice(allocator, "&gt;"),
        '&' => try buf.appendSlice(allocator, "&amp;"),
        '"' => try buf.appendSlice(allocator, "&quot;"),
        else => try buf.append(allocator, ch),
    };
}

fn escapeString(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayListAligned(u8, null){ .items = &.{}, .capacity = 0 };
    defer buf.deinit(allocator);
    try escapeHtml(text, &buf, allocator);
    return try buf.toOwnedSlice(allocator);
}

pub fn home(content: []const u8, page_title: []const u8, hot_reload: bool, allocator: std.mem.Allocator) ![]u8 {
    const title_esc = try escapeString(page_title, allocator);
    defer allocator.free(title_esc);
    const site_esc = try escapeString(config.site_title, allocator);
    defer allocator.free(site_esc);
    const reload_script = if (hot_reload)
        "<script>\nnew EventSource(\"/events\").onmessage = () => location.reload();\n</script>\n"
    else
        "";

    return std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>{s}</title>
        \\<link rel="stylesheet" href="/public/style.css">
        \\{s}</head>
        \\<body>
        \\<header><a href="/">{s}</a></header>
        \\<main>
        \\{s}
        \\</main>
        \\</body>
        \\</html>
    , .{ title_esc, reload_script, site_esc, content });
}

pub fn postListItem(slug: []const u8, title: []const u8, date: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const title_esc = try escapeString(title, allocator);
    defer allocator.free(title_esc);
    const date_esc = try escapeString(date, allocator);
    defer allocator.free(date_esc);
    return std.fmt.allocPrint(allocator, "<article><time>{s}</time> <a href=\"/posts/{s}\">{s}</a></article>\n", .{ date_esc, slug, title_esc });
}

pub fn postPage(title: []const u8, date: []const u8, body: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const title_esc = try escapeString(title, allocator);
    defer allocator.free(title_esc);
    const date_esc = try escapeString(date, allocator);
    defer allocator.free(date_esc);
    return std.fmt.allocPrint(allocator, "<article><h1>{s}</h1><time>{s}</time>{s}</article>\n", .{ title_esc, date_esc, body });
}

pub fn notFound(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "<h1>404</h1><p>Not found.</p>", .{});
}

test "escapeString escapes HTML special chars" {
    const alloc = std.testing.allocator;
    const result = try escapeString("<script>alert(1)</script>", alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("&lt;script&gt;alert(1)&lt;/script&gt;", result);
}

test "escapeString escapes quotes and ampersands" {
    const alloc = std.testing.allocator;
    const result = try escapeString("a\"b&c", alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("a&quot;b&amp;c", result);
}

test "escapeString pass-through for safe text" {
    const alloc = std.testing.allocator;
    const result = try escapeString("Hello, World!", alloc);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Hello, World!", result);
}

test "home escapes page title" {
    const alloc = std.testing.allocator;
    const result = try home("body", "<script>", false, alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
}

test "postListItem date and title same line" {
    const alloc = std.testing.allocator;
    const result = try postListItem("slug", "Title", "2026-01-01", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<time>2026-01-01</time> <a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</article>") != null);
}

test "home header contains site title link, no archive link" {
    const alloc = std.testing.allocator;
    const result = try home("body", "Page", false, alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"/\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "archive") == null);
}

test "postListItem renders timestamped display date" {
    const alloc = std.testing.allocator;
    const result = try postListItem("slug", "Title", "2026-06-25 14:03:09", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<time>2026-06-25 14:03:09</time>") != null);
}