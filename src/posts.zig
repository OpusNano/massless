const std = @import("std");
const Io = std.Io;
const markdown = @import("markdown.zig");

pub const Post = struct {
    slug: []const u8,
    title: []const u8,
    date: []const u8,
    body_md: []const u8,
    body_html: []const u8,
};

pub const Index = struct {
    posts: []Post,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
    }
};

const FileStamp = struct {
    name: []const u8,
    size: u64,
    mtime_ns: i96,
};

fn snapshotsEqual(a: []const FileStamp, b: []const FileStamp) bool {
    if (a.len != b.len) return false;
    for (a, b) |fa, fb| {
        if (!std.mem.eql(u8, fa.name, fb.name)) return false;
        if (fa.size != fb.size) return false;
        if (fa.mtime_ns != fb.mtime_ns) return false;
    }
    return true;
}

pub const PostsSnapshot = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    files: []const FileStamp,
    missing_warned: bool,

    pub fn init(allocator: std.mem.Allocator) PostsSnapshot {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .files = &.{},
            .missing_warned = false,
        };
    }

    pub fn deinit(self: *PostsSnapshot) void {
        self.arena.deinit();
    }

    pub fn refresh(self: *PostsSnapshot, io: std.Io) !bool {
        var new_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer new_arena.deinit();
        const aa = new_arena.allocator();

        var list = std.ArrayListAligned(FileStamp, null){ .items = &.{}, .capacity = 0 };
        defer list.deinit(aa);

        const dir = Io.Dir.cwd().openDir(io, "posts", .{ .iterate = true }) catch |err| {
            if (!self.missing_warned) {
                std.log.err("cannot open posts/ directory: {s}", .{@errorName(err)});
                self.missing_warned = true;
            }
            if (self.files.len == 0) {
                new_arena.deinit();
                return false;
            }
            self.arena.deinit();
            self.arena = new_arena;
            self.files = &.{};
            return true;
        };
        defer dir.close(io);
        self.missing_warned = false;

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!isValidFilename(entry.name)) continue;

            const stat = dir.statFile(io, entry.name, .{}) catch |err| {
                std.log.err("statFile failed for {s}: {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            try list.append(aa, .{
                .name = try aa.dupe(u8, entry.name),
                .size = stat.size,
                .mtime_ns = stat.mtime.nanoseconds,
            });
        }

        std.sort.pdq(FileStamp, list.items, {}, struct {
            fn lessThan(_: void, a: FileStamp, b: FileStamp) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);

        const new_files = try list.toOwnedSlice(aa);

        if (snapshotsEqual(self.files, new_files)) {
            new_arena.deinit();
            return false;
        }

        self.arena.deinit();
        self.arena = new_arena;
        self.files = new_files;
        return true;
    }
};

fn parseFilename(name: []const u8) struct { date: []const u8, slug: []const u8 } {
    const no_ext = name[0 .. name.len - 3];
    return .{
        .date = no_ext[0..10],
        .slug = no_ext[11..],
    };
}

fn parseFrontmatter(content: []const u8, allocator: std.mem.Allocator) !struct { title: []const u8, body_start: usize } {
    if (content.len < 4 or content[0] != '-' or content[1] != '-' or content[2] != '-' or content[3] != '\n') {
        return .{ .title = "", .body_start = 0 };
    }
    const end_idx = std.mem.indexOfPos(u8, content, 4, "\n---\n") orelse {
        const end_idx_line = std.mem.indexOfPos(u8, content, 4, "\n---\r\n") orelse
            return .{ .title = "", .body_start = 0 };
        return .{ .title = "", .body_start = end_idx_line + 6 };
    };
    const front = content[4..end_idx];
    var title: []const u8 = "";
    var lines = std.mem.splitScalar(u8, front, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "title: ")) {
            title = line[7..];
        }
    }
    return .{ .title = try allocator.dupe(u8, title), .body_start = end_idx + 5 };
}

fn isValidFilename(name: []const u8) bool {
    if (name.len < 15) return false;
    if (!std.mem.eql(u8, name[name.len - 3 ..], ".md")) return false;
    for (0..4) |i| if (!std.ascii.isDigit(name[i])) return false;
    if (name[4] != '-') return false;
    for (5..7) |i| if (!std.ascii.isDigit(name[i])) return false;
    if (name[7] != '-') return false;
    for (8..10) |i| if (!std.ascii.isDigit(name[i])) return false;
    if (name[10] != '-') return false;
    for (name[11 .. name.len - 3]) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    }
    return true;
}

pub fn scanAndRender(allocator: std.mem.Allocator, io: std.Io) !Index {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const dir = Io.Dir.cwd().openDir(io, "posts", .{ .iterate = true }) catch |err| {
        std.log.err("cannot open posts/ directory: {s}", .{@errorName(err)});
        return Index{ .posts = &.{}, .arena = arena };
    };
    defer dir.close(io);

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isValidFilename(entry.name)) {
            std.log.warn("skipping invalid filename: {s}", .{entry.name});
            continue;
        }

        const parsed = parseFilename(entry.name);
        const date = try aa.dupe(u8, parsed.date);
        const slug = try aa.dupe(u8, parsed.slug);

        const content = dir.readFileAlloc(io, entry.name, aa, .unlimited) catch |err| {
            std.log.err("failed to read {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };

        const fm = try parseFrontmatter(content, aa);
        const title = fm.title;
        const body_md = try aa.dupe(u8, content[fm.body_start..]);
        const body_html = try markdown.toHtml(body_md, aa);

        try posts.append(aa, Post{
            .slug = slug,
            .title = title,
            .date = date,
            .body_md = body_md,
            .body_html = body_html,
        });
    }

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const date_order = std.mem.order(u8, a.date, b.date);
            if (date_order == .eq) {
                return std.mem.order(u8, a.slug, b.slug) == .lt;
            }
            return date_order == .gt;
        }
    }.lessThan);

    return Index{ .posts = try posts.toOwnedSlice(aa), .arena = arena };
}

test "isValidFilename: valid names" {
    try std.testing.expect(isValidFilename("2026-06-25-hello.md"));
    try std.testing.expect(isValidFilename("2026-06-25-a.md"));
}

test "isValidFilename: rejects too short" {
    try std.testing.expect(!isValidFilename(".md"));
    try std.testing.expect(!isValidFilename("a.md"));
    try std.testing.expect(!isValidFilename("2026-06-25-.md"));
}

test "isValidFilename: rejects non-.md" {
    try std.testing.expect(!isValidFilename("2026-06-25-hello.txt"));
}

test "isValidFilename: rejects bad format" {
    try std.testing.expect(!isValidFilename("aaaa-bb-cc-hello.md"));
    try std.testing.expect(!isValidFilename("2026/06/25-hello.md"));
    try std.testing.expect(!isValidFilename("2026-06-25hello.md"));
}

test "isValidFilename: rejects unsafe slug chars" {
    try std.testing.expect(!isValidFilename("2026-06-25-he\"lo.md"));
    try std.testing.expect(!isValidFilename("2026-06-25-<x>.md"));
    try std.testing.expect(!isValidFilename("2026-06-25-bad>.md"));
    try std.testing.expect(!isValidFilename("2026-06-25-he'llo.md"));
}

test "isValidFilename: rejects uppercase in slug" {
    try std.testing.expect(!isValidFilename("2026-06-25-Hello.md"));
}

test "isValidFilename: rejects space in slug" {
    try std.testing.expect(!isValidFilename("2026-06-25-he llo.md"));
}

test "parseFrontmatter: no frontmatter returns empty title" {
    const result = try parseFrontmatter("Hello world\n", std.testing.allocator);
    defer std.testing.allocator.free(result.title);
    try std.testing.expectEqualStrings("", result.title);
    try std.testing.expectEqual(@as(usize, 0), result.body_start);
}

test "parseFrontmatter: title extracted" {
    const content =
        \\---
        \\title: My Post
        \\---
        \\Body text
    ;
    const result = try parseFrontmatter(content, std.testing.allocator);
    defer std.testing.allocator.free(result.title);
    try std.testing.expectEqualStrings("My Post", result.title);
    try std.testing.expectEqualStrings("Body text", content[result.body_start..]);
}

test "parseFrontmatter: OOM propagates" {
    var alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const content = "---\ntitle: X\n---\nbody";
    const result = parseFrontmatter(content, alloc.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
}

test "snapshotsEqual: identical in-order" {
    const a = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
        .{ .name = "2026-01-02-b.md", .size = 200, .mtime_ns = 2000 },
    };
    const b = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
        .{ .name = "2026-01-02-b.md", .size = 200, .mtime_ns = 2000 },
    };
    try std.testing.expect(snapshotsEqual(&a, &b));
}

test "snapshotsEqual: same files different order returns false" {
    const a = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
        .{ .name = "2026-01-02-b.md", .size = 200, .mtime_ns = 2000 },
    };
    const b = [_]FileStamp{
        .{ .name = "2026-01-02-b.md", .size = 200, .mtime_ns = 2000 },
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
    };
    try std.testing.expect(!snapshotsEqual(&a, &b));
}

test "snapshotsEqual: detects added file" {
    const a = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
    };
    const b = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
        .{ .name = "2026-01-02-b.md", .size = 200, .mtime_ns = 2000 },
    };
    try std.testing.expect(!snapshotsEqual(&a, &b));
}

test "snapshotsEqual: detects deleted file" {
    const a = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
        .{ .name = "2026-01-02-b.md", .size = 200, .mtime_ns = 2000 },
    };
    const b = [_]FileStamp{
        .{ .name = "2026-01-02-b.md", .size = 200, .mtime_ns = 2000 },
    };
    try std.testing.expect(!snapshotsEqual(&a, &b));
}

test "snapshotsEqual: detects size change" {
    const a = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
    };
    const b = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 200, .mtime_ns = 1000 },
    };
    try std.testing.expect(!snapshotsEqual(&a, &b));
}

test "snapshotsEqual: detects mtime change" {
    const a = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
    };
    const b = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 2000 },
    };
    try std.testing.expect(!snapshotsEqual(&a, &b));
}

test "snapshotsEqual: empty slices equal" {
    try std.testing.expect(snapshotsEqual(&[_]FileStamp{}, &[_]FileStamp{}));
}

test "snapshotsEqual: no change returns true" {
    const a = [_]FileStamp{
        .{ .name = "2026-01-01-a.md", .size = 100, .mtime_ns = 1000 },
    };
    try std.testing.expect(snapshotsEqual(&a, &a));
}

test "posts sorted newest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    try posts.append(aa, Post{ .slug = "a", .title = "", .date = "2024-01-01", .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "b", .title = "", .date = "2025-06-15", .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "c", .title = "", .date = "2026-12-31", .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const date_order = std.mem.order(u8, a.date, b.date);
            if (date_order == .eq) {
                return std.mem.order(u8, a.slug, b.slug) == .lt;
            }
            return date_order == .gt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("2026-12-31", posts.items[0].date);
    try std.testing.expectEqualStrings("2025-06-15", posts.items[1].date);
    try std.testing.expectEqualStrings("2024-01-01", posts.items[2].date);
}

test "same-date posts sorted by slug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    try posts.append(aa, Post{ .slug = "zebra", .title = "", .date = "2026-06-25", .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "alpha", .title = "", .date = "2026-06-25", .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "moon", .title = "", .date = "2026-06-25", .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const date_order = std.mem.order(u8, a.date, b.date);
            if (date_order == .eq) {
                return std.mem.order(u8, a.slug, b.slug) == .lt;
            }
            return date_order == .gt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("alpha", posts.items[0].slug);
    try std.testing.expectEqualStrings("moon", posts.items[1].slug);
    try std.testing.expectEqualStrings("zebra", posts.items[2].slug);
}

test "snapshot comparison order-independent for same files" {
    const files_a = [_]FileStamp{
        .{ .name = "2026-06-25-alpha.md", .size = 100, .mtime_ns = 1000 },
        .{ .name = "2026-06-24-beta.md", .size = 200, .mtime_ns = 2000 },
    };
    const files_b = [_]FileStamp{
        .{ .name = "2026-06-24-beta.md", .size = 200, .mtime_ns = 2000 },
        .{ .name = "2026-06-25-alpha.md", .size = 100, .mtime_ns = 1000 },
    };
    try std.testing.expect(!snapshotsEqual(&files_a, &files_b));
    try std.testing.expect(snapshotsEqual(&files_a, &files_a));
    try std.testing.expect(snapshotsEqual(&files_b, &files_b));
}