const std = @import("std");
const mem = std.mem;

const Buf = std.ArrayListAligned(u8, null);

fn normalizeCodeSpans(text: []u8) void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            var count: usize = 1;
            while (i + count < text.len and text[i + count] == '`') count += 1;
            const bt = text[i .. i + count];
            const close = mem.indexOfPos(u8, text, i + count, bt) orelse {
                i += 1;
                continue;
            };
            for (i + count .. close) |j| {
                if (text[j] == '\n') text[j] = ' ';
            }
            i = close + count;
        } else {
            i += 1;
        }
    }
}

pub fn toHtml(doc: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var norm = Buf{ .items = &.{}, .capacity = 0 };
    defer norm.deinit(allocator);
    try norm.appendSlice(allocator, doc);
    normalizeCodeSpans(norm.items);

    var buf = Buf{ .items = &.{}, .capacity = 0 };
    defer buf.deinit(allocator);

    var lines = mem.splitScalar(u8, norm.items, '\n');
    var para_lines: std.ArrayListAligned([]const u8, null) = .{ .items = &.{}, .capacity = 0 };
    defer para_lines.deinit(allocator);
    var list_items: std.ArrayListAligned([]const u8, null) = .{ .items = &.{}, .capacity = 0 };
    defer list_items.deinit(allocator);
    var list_ordered: bool = false;
    var in_list: bool = false;

    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");
        const is_blank = trimmed.len == 0;

        if (!is_blank) {
            if (try parseHeading(line, &buf, allocator)) {
                try flushPara(&para_lines, &buf, allocator);
                try flushList(&list_items, &buf, allocator, &in_list, &list_ordered);
                continue;
            }
            if (try parseThematicBreak(line, &buf, allocator)) {
                try flushPara(&para_lines, &buf, allocator);
                try flushList(&list_items, &buf, allocator, &in_list, &list_ordered);
                continue;
            }
            if (try parseListLine(line, &list_items, &buf, allocator, &in_list, &list_ordered)) continue;
            if (in_list) {
                try flushPara(&para_lines, &buf, allocator);
                try flushList(&list_items, &buf, allocator, &in_list, &list_ordered);
            }
            try para_lines.append(allocator, line);
            continue;
        }
        try flushList(&list_items, &buf, allocator, &in_list, &list_ordered);
        try flushPara(&para_lines, &buf, allocator);
    }
    try flushList(&list_items, &buf, allocator, &in_list, &list_ordered);
    try flushPara(&para_lines, &buf, allocator);

    return buf.toOwnedSlice(allocator);
}

fn flushPara(para_lines: *std.ArrayListAligned([]const u8, null), buf: *Buf, allocator: std.mem.Allocator) !void {
    if (para_lines.items.len == 0) return;
    defer para_lines.clearRetainingCapacity();
    try buf.appendSlice(allocator, "<p>");
    for (para_lines.items, 0..) |pl, idx| {
        if (idx > 0) try buf.append(allocator, ' ');
        try renderInline(pl, buf, allocator);
    }
    try buf.appendSlice(allocator, "</p>\n");
}

fn parseHeading(line: []const u8, buf: *Buf, allocator: std.mem.Allocator) !bool {
    var level: u8 = 0;
    for (line, 0..) |ch, j| {
        if (ch == '#') {
            level += 1;
        } else if (ch == ' ' and level > 0 and level <= 6) {
            const text = line[j + 1 ..];
            const trimmed = mem.trim(u8, text, " \t");
            var end = trimmed.len;
            while (end > 0 and trimmed[end - 1] == '#') end -= 1;
            const clean = mem.trim(u8, trimmed[0..end], " \t");
            try buf.appendSlice(allocator, "<h");
            try buf.append(allocator, '0' + level);
            try buf.appendSlice(allocator, ">");
            try renderInline(clean, buf, allocator);
            try buf.appendSlice(allocator, "</h");
            try buf.append(allocator, '0' + level);
            try buf.appendSlice(allocator, ">\n");
            return true;
        } else break;
    }
    return false;
}

fn parseThematicBreak(line: []const u8, buf: *Buf, allocator: std.mem.Allocator) !bool {
    if (line.len < 3) return false;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (line) |c| {
        if (c != ch and c != ' ' and c != '\t' and c != '\r') return false;
    }
    try buf.appendSlice(allocator, "<hr>\n");
    return true;
}

fn parseListLine(line: []const u8, list_items: *std.ArrayListAligned([]const u8, null), buf: *Buf, allocator: std.mem.Allocator, in_list: *bool, list_ordered: *bool) !bool {
    _ = buf;
    // bullet list
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*') and line[1] == ' ') {
        if (!in_list.*) {
            in_list.* = true;
            list_ordered.* = false;
        }
        try list_items.append(allocator, line[2..]);
        return true;
    }
    // ordered list
    var idx: usize = 0;
    while (idx < line.len and std.ascii.isDigit(line[idx])) idx += 1;
    if (idx > 0 and idx < line.len and line[idx] == '.' and idx + 1 < line.len and line[idx + 1] == ' ') {
        if (!in_list.*) {
            in_list.* = true;
            list_ordered.* = true;
        }
        try list_items.append(allocator, line[idx + 2 ..]);
        return true;
    }
    return false;
}

fn flushList(list_items: *std.ArrayListAligned([]const u8, null), buf: *Buf, allocator: std.mem.Allocator, in_list: *bool, list_ordered: *bool) !void {
    if (!in_list.*) return;
    defer {
        list_items.clearRetainingCapacity();
        in_list.* = false;
    }
    if (list_items.items.len == 0) return;
    if (list_ordered.*) {
        try buf.appendSlice(allocator, "<ol>\n");
    } else {
        try buf.appendSlice(allocator, "<ul>\n");
    }
    for (list_items.items) |item_text| {
        try buf.appendSlice(allocator, "<li>");
        try renderInline(item_text, buf, allocator);
        try buf.appendSlice(allocator, "</li>\n");
    }
    if (list_ordered.*) {
        try buf.appendSlice(allocator, "</ol>\n");
    } else {
        try buf.appendSlice(allocator, "</ul>\n");
    }
}

fn renderInline(text: []const u8, buf: *Buf, allocator: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];

        if (ch == '\\' and i + 1 < text.len) {
            try buf.append(allocator, text[i + 1]);
            i += 2;
            continue;
        }

        if (ch == '`') {
            var count: usize = 1;
            while (i + count < text.len and text[i + count] == '`') count += 1;
            const end_idx = mem.indexOfPos(u8, text, i + count, text[i .. i + count]) orelse {
                try buf.append(allocator, ch);
                i += 1;
                continue;
            };
            try buf.appendSlice(allocator, "<code>");
            var j = i + count;
            while (j < end_idx) {
                const c = if (text[j] == '\n') ' ' else text[j];
                // code spans render literal code — escape HTML entities so < > & " are visible, not executable
                switch (c) {
                    '<' => try buf.appendSlice(allocator, "&lt;"),
                    '>' => try buf.appendSlice(allocator, "&gt;"),
                    '&' => try buf.appendSlice(allocator, "&amp;"),
                    '"' => try buf.appendSlice(allocator, "&quot;"),
                    else => try buf.append(allocator, c),
                }
                j += 1;
            }
            try buf.appendSlice(allocator, "</code>");
            i = end_idx + count;
            continue;
        }

        if (ch == '!' and i + 1 < text.len and text[i + 1] == '[') {
            const close_bracket = mem.indexOfScalarPos(u8, text, i + 2, ']') orelse {
                try buf.append(allocator, ch);
                i += 1;
                continue;
            };
            if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                const close_paren = mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse {
                    try buf.append(allocator, ch);
                    i += 1;
                    continue;
                };
                const alt = text[i + 2 .. close_bracket];
                const raw_url = text[close_bracket + 2 .. close_paren];
                const url = if (safeUrl(raw_url)) raw_url else "#";
                try buf.appendSlice(allocator, "<img src=\"");
                try escapeHtml(url, buf, allocator);
                try buf.appendSlice(allocator, "\" alt=\"");
                try escapeHtml(alt, buf, allocator);
                try buf.appendSlice(allocator, "\">");
                i = close_paren + 1;
                continue;
            }
            try buf.append(allocator, ch);
            i += 1;
            continue;
        }

        if (ch == '[') {
            const close_bracket = mem.indexOfScalarPos(u8, text, i + 1, ']') orelse {
                try buf.append(allocator, ch);
                i += 1;
                continue;
            };
            if (close_bracket + 1 < text.len and text[close_bracket + 1] == '(') {
                const close_paren = mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse {
                    try buf.append(allocator, ch);
                    i += 1;
                    continue;
                };
                const link_text = text[i + 1 .. close_bracket];
                const raw_url = text[close_bracket + 2 .. close_paren];
                const url = if (safeUrl(raw_url)) raw_url else "#";
                try buf.appendSlice(allocator, "<a href=\"");
                try escapeHtml(url, buf, allocator);
                try buf.appendSlice(allocator, "\">");
                try renderInline(link_text, buf, allocator);
                try buf.appendSlice(allocator, "</a>");
                i = close_paren + 1;
                continue;
            }
            try buf.append(allocator, ch);
            i += 1;
            continue;
        }

        if (ch == '<') { try buf.appendSlice(allocator, "&lt;"); i += 1; continue; }
        if (ch == '>') { try buf.appendSlice(allocator, "&gt;"); i += 1; continue; }
        if (ch == '&') { try buf.appendSlice(allocator, "&amp;"); i += 1; continue; }
        if (ch == '"') { try buf.appendSlice(allocator, "&quot;"); i += 1; continue; }

        if (ch == '*' or ch == '_') {
            const delim = ch;
            var run_len: usize = 1;
            while (i + run_len < text.len and text[i + run_len] == delim) run_len += 1;
            if (run_len > 2) run_len = 2;

            // ponytail: simple delimiter matching — enough for blog content
            const can_open = i == 0 or text[i - 1] == ' ' or text[i - 1] == '\t' or text[i - 1] == '\n' or text[i - 1] == '(' or text[i - 1] == '[' or text[i - 1] == '{';
            const close_start = if (can_open) findCloseDelim(text, i + run_len, delim, run_len) else null;

            if (close_start) |cs| {
                const inner = text[i + run_len .. cs];
                if (run_len == 2) {
                    try buf.appendSlice(allocator, "<strong>");
                    try renderInline(inner, buf, allocator);
                    try buf.appendSlice(allocator, "</strong>");
                } else {
                    try buf.appendSlice(allocator, "<em>");
                    try renderInline(inner, buf, allocator);
                    try buf.appendSlice(allocator, "</em>");
                }
                i = cs + run_len;
                continue;
            }
            var j: usize = 0;
            while (j < run_len) : (j += 1) try buf.append(allocator, delim);
            i += run_len;
            continue;
        }

        try buf.append(allocator, ch);
        i += 1;
    }
}

fn findCloseDelim(text: []const u8, start: usize, delim: u8, run_len: usize) ?usize {
    var i = start;
    while (i < text.len) {
        if (text[i] == delim) {
            var count: usize = 1;
            while (i + count < text.len and text[i + count] == delim) count += 1;
            if (count >= run_len) return i;
            i += count;
        } else {
            i += 1;
        }
    }
    return null;
}

fn schemeEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != cb) return false;
    }
    return true;
}

fn safeUrl(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    if (colon == 0) return false;
    const scheme = url[0..colon];
    if (schemeEq(scheme, "http")) return true;
    if (schemeEq(scheme, "https")) return true;
    if (schemeEq(scheme, "mailto")) return true;
    return false;
}

fn escapeHtml(text: []const u8, buf: *Buf, allocator: std.mem.Allocator) !void {
    for (text) |ch| {
        switch (ch) {
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            else => try buf.append(allocator, ch),
        }
    }
}

fn testHtmlEqual(expected: []const u8, doc: []const u8, alloc: std.mem.Allocator) !void {
    const html = try toHtml(doc, alloc);
    defer alloc.free(html);
    try std.testing.expectEqualStrings(expected, html);
}

test "headings" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<h1>Hello</h1>\n", "# Hello", alloc);
    try testHtmlEqual("<h6>Deep</h6>\n", "###### Deep", alloc);
}

test "thematic break" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<hr>\n", "---", alloc);
    try testHtmlEqual("<hr>\n", "***", alloc);
}

test "paragraphs" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p>Hello</p>\n", "Hello", alloc);
}

test "multi-line paragraph" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p>Hello world</p>\n", "Hello\nworld", alloc);
}

test "blank line separation" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p>First</p>\n<p>Second</p>\n", "First\n\nSecond", alloc);
}

test "emphasis" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><em>italic</em></p>\n", "*italic*", alloc);
    try testHtmlEqual("<p><strong>bold</strong></p>\n", "**bold**", alloc);
}

test "code span" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><code>code</code></p>\n", "`code`", alloc);
}

test "link" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><a href=\"http://x.com\">link</a></p>\n", "[link](http://x.com)", alloc);
}

test "image" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><img src=\"img.png\" alt=\"alt\"></p>\n", "![alt](img.png)", alloc);
}

test "html escaping" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p>&lt;script&gt;</p>\n", "<script>", alloc);
}

test "backslash escape" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p>*</p>\n", "\\*", alloc);
}

test "heading + paragraph" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<h1>Title</h1>\n<p>Some text.</p>\n", "# Title\n\nSome text.", alloc);
}

test "code span escapes script tag" {
    const alloc = std.testing.allocator;
    try testHtmlEqual(
        "<p><code>&lt;script&gt;alert(1)&lt;/script&gt;</code></p>\n",
        "`<script>alert(1)</script>`",
        alloc,
    );
}

test "code span escapes ampersand" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><code>a &amp; b</code></p>\n", "`a & b`", alloc);
}

test "code span escapes quote" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><code>x=&quot;y&quot;</code></p>\n", "`x=\"y\"`", alloc);
}

test "code span replaces newline and escapes html" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><code>&lt;a b&gt;</code></p>\n", "`<a\nb>`", alloc);
}

test "link blocks javascript protocol" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](javascript:alert(1))", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"#\"") != null);
}

test "link blocks case-mixed javascript" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](JaVaScRiPt:alert(1))", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"#\"") != null);
}

test "link allows https" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](https://example.com)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"https://example.com\"") != null);
}

test "link allows relative path" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](/posts/hello-world)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"/posts/hello-world\"") != null);
}

test "image blocks unsafe protocol" {
    const alloc = std.testing.allocator;
    const result = try toHtml("![alt](javascript:alert(1))", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "src=\"#\"") != null);
}

test "link with leading space is rejected" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x]( https://example.com)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"#\"") != null);
}

test "link blocks data protocol" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](data:text/html,<script>)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "data:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"#\"") != null);
}

test "link blocks vbscript protocol" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](vbscript:msgbox(1))", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "vbscript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"#\"") != null);
}

test "link allows mailto" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](mailto:a@b.com)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"mailto:a@b.com\"") != null);
}

test "link blocks scheme-only url" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[x](:bad)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "href=\"#\"") != null);
}

test "code span preserves literal angle brackets" {
    const alloc = std.testing.allocator;
    try testHtmlEqual(
        "<p><code>&lt;div&gt;</code></p>\n",
        "`<div>`",
        alloc,
    );
}

test "ampersand in text is escaped" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p>a &amp; b</p>\n", "a & b", alloc);
}

test "link text containing HTML is escaped" {
    const alloc = std.testing.allocator;
    const result = try toHtml("[<script>](http://x.com)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "&lt;script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<script>") == null);
}

test "image alt containing HTML is escaped" {
    const alloc = std.testing.allocator;
    const result = try toHtml("![<x>](img.png)", alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "alt=\"&lt;x&gt;\"") != null);
}

test "single underscore emits literal" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p>a_b</p>\n", "a_b", alloc);
}

test "double underscore for strong" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<p><strong>x</strong></p>\n", "__x__", alloc);
}

test "unordered list" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<ul>\n<li>a</li>\n</ul>\n", "- a", alloc);
}

test "ordered list" {
    const alloc = std.testing.allocator;
    try testHtmlEqual("<ol>\n<li>a</li>\n</ol>\n", "1. a", alloc);
}

test "toHtml OOM propagates" {
    var alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, toHtml("Hello", alloc.allocator()));
}