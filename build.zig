const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Library modules
    // -----------------------------------------------------------------------
    const dicos_mod = b.addModule("dicos", .{
        .root_source_file = b.path("src/dicos/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const jpegrle_mod = b.addModule("jpegrle", .{
        .root_source_file = b.path("src/jpegrle/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    jpegrle_mod.addImport("dicos", dicos_mod);

    const jpegli_mod = b.addModule("jpegli", .{
        .root_source_file = b.path("src/jpegli/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    jpegli_mod.addImport("dicos", dicos_mod);

    const jpegls_mod = b.addModule("jpegls", .{
        .root_source_file = b.path("src/jpegls/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    jpegls_mod.addImport("dicos", dicos_mod);

    const jpeg2k_mod = b.addModule("jpeg2k", .{
        .root_source_file = b.path("src/jpeg2k/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    jpeg2k_mod.addImport("dicos", dicos_mod);

    // -----------------------------------------------------------------------
    // dicosctl executable
    // -----------------------------------------------------------------------
    const dicosctl_mod = b.createModule(.{
        .root_source_file = b.path("src/dicosctl/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    dicosctl_mod.addImport("dicos", dicos_mod);
    dicosctl_mod.addImport("jpegrle", jpegrle_mod);
    dicosctl_mod.addImport("jpegli", jpegli_mod);
    dicosctl_mod.addImport("jpegls", jpegls_mod);
    dicosctl_mod.addImport("jpeg2k", jpeg2k_mod);

    const dicosctl = b.addExecutable(.{
        .name = "dicosctl",
        .root_module = dicosctl_mod,
    });
    b.installArtifact(dicosctl);

    // -----------------------------------------------------------------------
    // zoxel executable — GPU-accelerated DICOS volume viewer
    // -----------------------------------------------------------------------
    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    const zgpu = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_wgpu,
    });

    const zoxel_mod = b.createModule(.{
        .root_source_file = b.path("src/zoxel/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zoxel_mod.addImport("dicos", dicos_mod);
    zoxel_mod.addImport("zglfw", zglfw.module("root"));
    zoxel_mod.addImport("zgpu", zgpu.module("root"));
    zoxel_mod.addImport("zgui", zgui.module("root"));

    const zoxel = b.addExecutable(.{
        .name = "zoxel",
        .root_module = zoxel_mod,
    });
    zoxel.linkLibrary(zglfw.artifact("glfw"));
    zoxel.linkLibrary(zgpu.artifact("zdawn"));
    zoxel.linkLibrary(zgui.artifact("imgui"));
    @import("zgpu").addLibraryPathsTo(zoxel);
    b.installArtifact(zoxel);

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------
    const test_step = b.step("test", "Run all unit tests");

    const test_modules = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "dicos", .path = "src/dicos/root.zig" },
        .{ .name = "jpegrle", .path = "src/jpegrle/root.zig" },
        .{ .name = "jpegli", .path = "src/jpegli/root.zig" },
        .{ .name = "jpegls", .path = "src/jpegls/root.zig" },
        .{ .name = "jpeg2k", .path = "src/jpeg2k/root.zig" },
    };

    for (test_modules) |mod_info| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(mod_info.path),
            .target = target,
            .optimize = optimize,
        });
        // Wire up inter-module imports for tests
        if (!std.mem.eql(u8, mod_info.name, "dicos")) {
            test_mod.addImport("dicos", dicos_mod);
        }
        const t = b.addTest(.{
            .root_module = test_mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
