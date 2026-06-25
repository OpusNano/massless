const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "massless",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the blog server");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const test_files = [_][]const u8{ "src/main.zig", "src/posts.zig", "src/template.zig", "src/markdown.zig" };
    for (test_files) |tf| {
        const tm = b.createModule(.{
            .root_source_file = b.path(tf),
            .target = target,
            .optimize = optimize,
        });
        const te = b.addTest(.{ .root_module = tm });
        const rt = b.addRunArtifact(te);
        test_step.dependOn(&rt.step);
    }
}