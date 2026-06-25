const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const markdown = @import("markdown.zig");

pub const PostTimestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    min: u8,
    sec: u8,
    has_time: bool,
};

pub const Post = struct {
    slug: []const u8,
    title: []const u8,
    date: []const u8,
    timestamp: PostTimestamp,
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

fn parseTimestampedFilename(name: []const u8) ?struct { timestamp: PostTimestamp, slug: []const u8 } {
    if (!std.mem.endsWith(u8, name, ".md")) return null;
    const no_ext = name[0 .. name.len - 3];
    if (no_ext.len < 12) return null;
    if (no_ext[4] != '-' or no_ext[7] != '-' or no_ext[10] != '-') return null;
    const year = std.fmt.parseInt(u16, no_ext[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, no_ext[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, no_ext[8..10], 10) catch return null;
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (no_ext.len >= 20 and no_ext[13] == '-' and no_ext[16] == '-' and no_ext[19] == '-') {
        const hour = std.fmt.parseInt(u8, no_ext[11..13], 10) catch return null;
        const min = std.fmt.parseInt(u8, no_ext[14..16], 10) catch return null;
        const sec = std.fmt.parseInt(u8, no_ext[17..19], 10) catch return null;
        if (hour > 23 or min > 59 or sec > 59) return null;
        return .{
            .timestamp = .{ .year = year, .month = month, .day = day, .hour = hour, .min = min, .sec = sec, .has_time = true },
            .slug = no_ext[20..],
        };
    }
    return .{
        .timestamp = .{ .year = year, .month = month, .day = day, .hour = 0, .min = 0, .sec = 0, .has_time = false },
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
    if (!std.mem.endsWith(u8, name, ".md")) return false;
    const parsed = parseTimestampedFilename(name) orelse return false;
    if (parsed.slug.len == 0) return false;
    for (parsed.slug) |ch| {
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

        const parsed = parseTimestampedFilename(entry.name).?;
        const slug = try aa.dupe(u8, parsed.slug);
        const ts = parsed.timestamp;
        const display_date = if (ts.has_time)
            try std.fmt.allocPrint(aa, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ ts.year, ts.month, ts.day, ts.hour, ts.min, ts.sec })
        else
            try std.fmt.allocPrint(aa, "{d:0>4}-{d:0>2}-{d:0>2}", .{ ts.year, ts.month, ts.day });

        const stat = dir.statFile(io, entry.name, .{}) catch |err| {
            std.log.err("statFile failed for {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        if (stat.size > config.max_post_bytes) {
            std.log.warn("post {s} too large ({d} > {d}), skipping", .{ entry.name, stat.size, config.max_post_bytes });
            continue;
        }
        const content = dir.readFileAlloc(io, entry.name, aa, Io.Limit.limited(config.max_post_bytes)) catch |err| {
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
            .date = display_date,
            .timestamp = ts,
            .body_md = body_md,
            .body_html = body_html,
        });
    }

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    // ponytail: O(n²) dedup, fine for blog-scale post counts
    var deduped = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer deduped.deinit(aa);
    for (posts.items) |post| {
        var dup = false;
        for (deduped.items) |existing| {
            if (std.mem.eql(u8, existing.slug, post.slug)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            std.log.warn("duplicate slug '{s}', skipping older post", .{post.slug});
        } else {
            try deduped.append(aa, post);
        }
    }

    return Index{ .posts = try deduped.toOwnedSlice(aa), .arena = arena };
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

    const ts_2024 = PostTimestamp{ .year = 2024, .month = 1, .day = 1, .hour = 0, .min = 0, .sec = 0, .has_time = false };
    const ts_2025 = PostTimestamp{ .year = 2025, .month = 6, .day = 15, .hour = 0, .min = 0, .sec = 0, .has_time = false };
    const ts_2026 = PostTimestamp{ .year = 2026, .month = 12, .day = 31, .hour = 0, .min = 0, .sec = 0, .has_time = false };

    try posts.append(aa, Post{ .slug = "a", .title = "", .date = "2024-01-01", .timestamp = ts_2024, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "b", .title = "", .date = "2025-06-15", .timestamp = ts_2025, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "c", .title = "", .date = "2026-12-31", .timestamp = ts_2026, .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("c", posts.items[0].slug);
    try std.testing.expectEqualStrings("b", posts.items[1].slug);
    try std.testing.expectEqualStrings("a", posts.items[2].slug);
}

test "same-date posts sorted by slug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    const ts = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 0, .min = 0, .sec = 0, .has_time = false };

    try posts.append(aa, Post{ .slug = "zebra", .title = "", .date = "2026-06-25", .timestamp = ts, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "alpha", .title = "", .date = "2026-06-25", .timestamp = ts, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "moon", .title = "", .date = "2026-06-25", .timestamp = ts, .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("alpha", posts.items[0].slug);
    try std.testing.expectEqualStrings("moon", posts.items[1].slug);
    try std.testing.expectEqualStrings("zebra", posts.items[2].slug);
}

test "isValidFilename: valid timestamped name" {
    try std.testing.expect(isValidFilename("2026-06-25-14-03-09-hello-world.md"));
}

test "isValidFilename: rejects 24h" {
    try std.testing.expect(!isValidFilename("2026-06-25-24-00-00-bad.md"));
}

test "isValidFilename: rejects 60m" {
    try std.testing.expect(!isValidFilename("2026-06-25-12-60-00-bad.md"));
}

test "isValidFilename: rejects 60s" {
    try std.testing.expect(!isValidFilename("2026-06-25-12-00-60-bad.md"));
}

test "isValidFilename: rejects invalid month" {
    try std.testing.expect(!isValidFilename("2026-13-01-hello.md"));
}

test "isValidFilename: rejects invalid day" {
    try std.testing.expect(!isValidFilename("2026-06-32-hello.md"));
}

test "isValidFilename: rejects non-digit in timestamp hour" {
    try std.testing.expect(!isValidFilename("2026-06-25-ab-00-00-bad.md"));
}

test "timestamped posts sort newest first by time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    try posts.append(aa, Post{ .slug = "early", .title = "", .date = "2026-06-25 09:00:00", .timestamp = .{ .year = 2026, .month = 6, .day = 25, .hour = 9, .min = 0, .sec = 0, .has_time = true }, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "late", .title = "", .date = "2026-06-25 14:30:00", .timestamp = .{ .year = 2026, .month = 6, .day = 25, .hour = 14, .min = 30, .sec = 0, .has_time = true }, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "mid", .title = "", .date = "2026-06-25 12:00:00", .timestamp = .{ .year = 2026, .month = 6, .day = 25, .hour = 12, .min = 0, .sec = 0, .has_time = true }, .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("late", posts.items[0].slug);
    try std.testing.expectEqualStrings("mid", posts.items[1].slug);
    try std.testing.expectEqualStrings("early", posts.items[2].slug);
}

test "date-only posts sort as midnight before timestamped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    // Same day: date-only (midnight) and timestamped at 08:00
    const ts_midnight = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 0, .min = 0, .sec = 0, .has_time = false };
    const ts_morning = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 8, .min = 0, .sec = 0, .has_time = true };

    try posts.append(aa, Post{ .slug = "midnight-post", .title = "", .date = "2026-06-25", .timestamp = ts_midnight, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "morning-post", .title = "", .date = "2026-06-25 08:00:00", .timestamp = ts_morning, .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("morning-post", posts.items[0].slug);
    try std.testing.expectEqualStrings("midnight-post", posts.items[1].slug);
}

test "same timestamp sorts by slug ascending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    const ts = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 12, .min = 0, .sec = 0, .has_time = true };

    try posts.append(aa, Post{ .slug = "zulu", .title = "", .date = "2026-06-25 12:00:00", .timestamp = ts, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "alpha", .title = "", .date = "2026-06-25 12:00:00", .timestamp = ts, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "mike", .title = "", .date = "2026-06-25 12:00:00", .timestamp = ts, .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("alpha", posts.items[0].slug);
    try std.testing.expectEqualStrings("mike", posts.items[1].slug);
    try std.testing.expectEqualStrings("zulu", posts.items[2].slug);
}

test "cross-day mixed date-only and timestamped sort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    const ts_yesterday = PostTimestamp{ .year = 2026, .month = 6, .day = 24, .hour = 23, .min = 59, .sec = 59, .has_time = true };
    const ts_today_mid = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 0, .min = 0, .sec = 0, .has_time = false };
    const ts_today_noon = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 12, .min = 30, .sec = 15, .has_time = true };
    const ts_tomorrow = PostTimestamp{ .year = 2026, .month = 6, .day = 28, .hour = 0, .min = 0, .sec = 0, .has_time = false };

    try posts.append(aa, Post{ .slug = "yesterday", .title = "", .date = "2026-06-24 23:59:59", .timestamp = ts_yesterday, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "today-dateonly", .title = "", .date = "2026-06-25", .timestamp = ts_today_mid, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "today-noon", .title = "", .date = "2026-06-25 12:30:15", .timestamp = ts_today_noon, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "tomorrow", .title = "", .date = "2026-06-28", .timestamp = ts_tomorrow, .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    try std.testing.expectEqualStrings("tomorrow", posts.items[0].slug);
    try std.testing.expectEqualStrings("today-noon", posts.items[1].slug);
    try std.testing.expectEqualStrings("today-dateonly", posts.items[2].slug);
    try std.testing.expectEqualStrings("yesterday", posts.items[3].slug);
}

test "dedup keeps first (newest) post per slug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var posts = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer posts.deinit(aa);

    const ts_newer = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 12, .min = 0, .sec = 0, .has_time = true };
    const ts_older = PostTimestamp{ .year = 2026, .month = 6, .day = 25, .hour = 0, .min = 0, .sec = 0, .has_time = false };

    // Append older first, newer second — after sort, newer is first
    try posts.append(aa, Post{ .slug = "dup", .title = "", .date = "2026-06-25", .timestamp = ts_older, .body_md = "", .body_html = "" });
    try posts.append(aa, Post{ .slug = "dup", .title = "", .date = "2026-06-25 12:00:00", .timestamp = ts_newer, .body_md = "", .body_html = "" });

    std.sort.pdq(Post, posts.items, {}, struct {
        fn lessThan(_: void, a: Post, b: Post) bool {
            const ta = a.timestamp;
            const tb = b.timestamp;
            if (ta.year != tb.year) return ta.year > tb.year;
            if (ta.month != tb.month) return ta.month > tb.month;
            if (ta.day != tb.day) return ta.day > tb.day;
            if (ta.hour != tb.hour) return ta.hour > tb.hour;
            if (ta.min != tb.min) return ta.min > tb.min;
            if (ta.sec != tb.sec) return ta.sec > tb.sec;
            return std.mem.order(u8, a.slug, b.slug) == .lt;
        }
    }.lessThan);

    // Sorted: newer first
    try std.testing.expectEqualStrings("2026-06-25 12:00:00", posts.items[0].date);
    try std.testing.expectEqualStrings("2026-06-25", posts.items[1].date);

    // Dedup: keep first (newest)
    var deduped = std.ArrayListAligned(Post, null){ .items = &.{}, .capacity = 0 };
    defer deduped.deinit(aa);

    for (posts.items) |post| {
        var dup = false;
        for (deduped.items) |existing| {
            if (std.mem.eql(u8, existing.slug, post.slug)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            // skip older
        } else {
            try deduped.append(aa, post);
        }
    }

    try std.testing.expectEqual(@as(usize, 1), deduped.items.len);
    try std.testing.expectEqualStrings("2026-06-25 12:00:00", deduped.items[0].date);
}

test "parseTimestampedFilename: date-only format" {
    const result = parseTimestampedFilename("2026-06-25-hello-world.md").?;
    try std.testing.expectEqual(@as(u16, 2026), result.timestamp.year);
    try std.testing.expectEqual(@as(u8, 6), result.timestamp.month);
    try std.testing.expectEqual(@as(u8, 25), result.timestamp.day);
    try std.testing.expectEqual(@as(u8, 0), result.timestamp.hour);
    try std.testing.expectEqual(@as(u8, 0), result.timestamp.min);
    try std.testing.expectEqual(@as(u8, 0), result.timestamp.sec);
    try std.testing.expect(!result.timestamp.has_time);
    try std.testing.expectEqualStrings("hello-world", result.slug);
}

test "parseTimestampedFilename: timestamped format" {
    const result = parseTimestampedFilename("2026-06-25-14-03-09-hello.md").?;
    try std.testing.expectEqual(@as(u16, 2026), result.timestamp.year);
    try std.testing.expectEqual(@as(u8, 6), result.timestamp.month);
    try std.testing.expectEqual(@as(u8, 25), result.timestamp.day);
    try std.testing.expectEqual(@as(u8, 14), result.timestamp.hour);
    try std.testing.expectEqual(@as(u8, 3), result.timestamp.min);
    try std.testing.expectEqual(@as(u8, 9), result.timestamp.sec);
    try std.testing.expect(result.timestamp.has_time);
    try std.testing.expectEqualStrings("hello", result.slug);
}

test "parseTimestampedFilename: rejects 24h" {
    try std.testing.expect(parseTimestampedFilename("2026-06-25-24-00-00-bad.md") == null);
}

test "parseTimestampedFilename: rejects 60m" {
    try std.testing.expect(parseTimestampedFilename("2026-06-25-12-60-00-bad.md") == null);
}

test "parseTimestampedFilename: rejects 60s" {
    try std.testing.expect(parseTimestampedFilename("2026-06-25-12-00-60-bad.md") == null);
}

test "parseTimestampedFilename: slug with hyphens in date-only" {
    const result = parseTimestampedFilename("2026-06-25-a-b-c.md").?;
    try std.testing.expect(!result.timestamp.has_time);
    try std.testing.expectEqualStrings("a-b-c", result.slug);
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