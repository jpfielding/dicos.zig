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

    // dicos codec registry: Rust feature flags as build options. Each codec
    // defaults on; a disabled codec's module is never imported by dicos.
    const dicos_opts = b.addOptions();
    dicos_opts.addOption(bool, "rle", b.option(bool, "dicos-rle", "dicos registry: RLE codec (default true)") orelse true);
    dicos_opts.addOption(bool, "jpegls", b.option(bool, "dicos-jpegls", "dicos registry: JPEG-LS codec (default true)") orelse true);
    dicos_opts.addOption(bool, "jpegli", b.option(bool, "dicos-jpegli", "dicos registry: JPEG Lossless codec (default true)") orelse true);
    dicos_opts.addOption(bool, "jpeg2k", b.option(bool, "dicos-jpeg2k", "dicos registry: JPEG 2000 codec (default true)") orelse true);
    dicos_mod.addOptions("dicos_options", dicos_opts);
    dicos_mod.addImport("jpegrle", jpegrle_mod);
    dicos_mod.addImport("jpegls", jpegls_mod);
    dicos_mod.addImport("jpegli", jpegli_mod);
    dicos_mod.addImport("jpeg2k", jpeg2k_mod);

    // -----------------------------------------------------------------------
    // Browser build of zoxel:
    //   zig build -Dtarget=wasm32-emscripten -Doptimize=ReleaseFast [-Demsdk=<dir>]
    // writes zig-out/web/{index.html,index.js,index.wasm}. Zig compiles static
    // libraries and emsdk's emcc links them; no other steps exist for this
    // target.
    // -----------------------------------------------------------------------
    if (target.result.os.tag == .emscripten) {
        buildWeb(b, target, optimize, dicos_mod);
        return;
    }

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

    // gen-luggage-fishtank example (port of the Rust example):
    //   zig build gen-luggage-fishtank -- --size 64,64,48 --out <path>
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/dicos/examples/gen_luggage_fishtank.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_mod.addImport("dicos", dicos_mod);
    const gen_exe = b.addExecutable(.{ .name = "gen-luggage-fishtank", .root_module = gen_mod });
    const run_gen = b.addRunArtifact(gen_exe);
    if (b.args) |args| run_gen.addArgs(args);
    b.step("gen-luggage-fishtank", "Generate a synthetic DICOS luggage CT (example)").dependOn(&run_gen.step);

    // dicosctl + example unit tests (JSON formatting, generator round-trip).
    const tools_test_step = b.step("test-dicos-tools", "Run dicosctl and example unit tests");
    for ([_]*std.Build.Module{ dicosctl_mod, gen_mod }) |m| {
        const run_tool_tests = b.addRunArtifact(b.addTest(.{ .root_module = m }));
        tools_test_step.dependOn(&run_tool_tests.step);
    }

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
    // Works around zgui's ImTextureRef/ImTextureID ABI mismatch in AddImage.
    zoxel.addCSourceFile(.{ .file = b.path("src/zoxel/imgui_shim.cpp"), .flags = &.{ "-fno-sanitize=undefined", "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS" } });
    zoxel.addIncludePath(b.path("deps/zgui/libs/imgui"));
    zoxel.linkLibCpp();
    @import("zgpu").addLibraryPathsTo(zoxel);
    b.installArtifact(zoxel);

    // zoxel tests need no window or GPU (volume, loading, camera, transfer,
    // slices, and headless UI layout/interaction): `zig build zoxel-test`.
    const zoxel_test_mod = b.createModule(.{
        .root_source_file = b.path("src/zoxel/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    zoxel_test_mod.addImport("dicos", dicos_mod);
    // UI layout tests run headless through the same kit (ImGui text metrics,
    // no window or GPU).
    zoxel_test_mod.addImport("zgui", zgui.module("root"));
    const zoxel_tests = b.addTest(.{ .root_module = zoxel_test_mod });
    zoxel_tests.linkLibrary(zgui.artifact("imgui"));
    zoxel_tests.addCSourceFile(.{ .file = b.path("src/zoxel/imgui_shim.cpp"), .flags = &.{ "-fno-sanitize=undefined", "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS" } });
    zoxel_tests.addIncludePath(b.path("deps/zgui/libs/imgui"));
    zoxel_tests.linkLibCpp();
    const run_zoxel_tests = b.addRunArtifact(zoxel_tests);
    const zoxel_test_step = b.step("zoxel-test", "Run zoxel unit tests");
    zoxel_test_step.dependOn(&run_zoxel_tests.step);

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
        const is_dicos = std.mem.eql(u8, mod_info.name, "dicos");
        // dicos is tested through its real module so its codec imports and
        // build options apply (and src/dicos lives in exactly one module).
        const test_mod = if (is_dicos) dicos_mod else b.createModule(.{
            .root_source_file = b.path(mod_info.path),
            .target = target,
            .optimize = optimize,
        });
        // Wire up inter-module imports for tests
        if (!is_dicos) {
            test_mod.addImport("dicos", dicos_mod);
        }
        const t = b.addTest(.{
            .root_module = test_mod,
        });
        const run_t = b.addRunArtifact(t);
        // Tests resolve testdata/ relative to the repository root.
        run_t.setCwd(b.path("."));
        test_step.dependOn(&run_t.step);
        if (is_dicos) b.step("test-dicos", "Run only the dicos unit tests").dependOn(&run_t.step);
    }
    test_step.dependOn(tools_test_step);
}

/// Pinned emsdk release. 4.0.3 is the last one with the legacy
/// `-sUSE_WEBGPU` bindings (webgpu.h) that zgpu and imgui_impl_wgpu target.
/// Keep in sync with .github/workflows and .devcontainer/Dockerfile.
const emsdk_version = "4.0.3";

fn buildWeb(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dicos_mod: *std.Build.Module,
) void {
    const emsdk = b.option([]const u8, "emsdk", "emsdk " ++ emsdk_version ++ " directory (default $EMSDK, then ~/.local/share/emsdk)") orelse
        b.graph.env_map.get("EMSDK") orelse
        b.pathJoin(&.{ b.graph.env_map.get("HOME") orelse "", ".local/share/emsdk" });
    const emscripten_dir = b.pathJoin(&.{ emsdk, "upstream", "emscripten" });
    // zgui's emscripten branch reads b.sysroot for <webgpu/webgpu.h>.
    if (b.sysroot == null) b.sysroot = b.pathJoin(&.{ emscripten_dir, "cache", "sysroot" });
    const sysroot_include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ b.sysroot.?, "include" }) };

    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    const zgui = b.dependency("zgui", .{ .target = target, .optimize = optimize, .backend = .glfw_wgpu });

    const web_mod = b.createModule(.{
        .root_source_file = b.path("src/zoxel/web.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    web_mod.addImport("dicos", dicos_mod);
    web_mod.addImport("zglfw", zglfw.module("root"));
    web_mod.addImport("zgpu", zgpu.module("root"));
    web_mod.addImport("zgui", zgui.module("root"));
    web_mod.addSystemIncludePath(sysroot_include);

    const lib = b.addLibrary(.{ .name = "zoxel", .linkage = .static, .root_module = web_mod });
    // Same ImTextureRef/ImTextureID workaround as the desktop build.
    lib.addCSourceFile(.{ .file = b.path("src/zoxel/imgui_shim.cpp"), .flags = &.{ "-fno-sanitize=undefined", "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS" } });
    lib.addIncludePath(b.path("deps/zgui/libs/imgui"));
    lib.linkLibCpp();

    const emcc = b.addSystemCommand(&.{b.pathJoin(&.{ emscripten_dir, "emcc" })});
    emcc.setName("emcc");
    emcc.addArtifactArg(lib);
    emcc.addArtifactArg(zgui.artifact("imgui"));
    emcc.addArgs(&.{
        if (optimize == .Debug) "-O1" else "-O3",
        "-sUSE_WEBGPU=1",
        "-sUSE_GLFW=3",
        "-sSTACK_SIZE=1MB",
        // A CT parses into a few hundred MB of heap; grow on demand.
        "-sALLOW_MEMORY_GROWTH=1",
        "-sINITIAL_MEMORY=64MB",
        "-sMAXIMUM_MEMORY=2GB",
        "-sENVIRONMENT=web",
        "-sEXPORTED_FUNCTIONS=_main,_zoxel_alloc,_zoxel_free,_zoxel_add_file,_zoxel_open_files,_zoxel_report_error",
        "-sEXPORTED_RUNTIME_METHODS=HEAPU8",
        "-sERROR_ON_UNDEFINED_SYMBOLS=1",
    });
    if (optimize == .Debug) emcc.addArg("-sASSERTIONS=1");
    emcc.addArg("--shell-file");
    emcc.addFileArg(b.path("web/shell.html"));
    emcc.addArg("-o");
    const out_html = emcc.addOutputFileArg("index.html");

    const install = b.addInstallDirectory(.{
        .source_dir = out_html.dirname(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    b.getInstallStep().dependOn(&install.step);
}
