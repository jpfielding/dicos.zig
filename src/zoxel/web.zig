//! zoxel browser entry point (wasm32-emscripten + WebGPU).
//!
//! The root of the Emscripten build. The window, input, ImGui and frame code
//! come from `main.zig`, shared with the desktop build. The differences:
//!
//! - `main` is exported for emcc (Zig builds a static library; emcc links).
//! - The page's JavaScript (`web/shell.html`) creates the WebGPU device
//!   before `main` runs; zgpu picks it up (see deps/zgpu/PATCHES.md).
//! - requestAnimationFrame drives frames through
//!   `emscripten_set_main_loop_arg`; `main` returns after setup.
//! - Files arrive as bytes from JavaScript (the file picker or a fetch of
//!   the bundled sample). For each file JS calls `zoxel_alloc` twice (name,
//!   contents), copies into `HEAPU8` and calls `zoxel_add_file`; then
//!   `zoxel_open_files` hands the batch to the loader, which parses it on the
//!   main thread one frame later, so "Loading…" is drawn first.

const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");
const app_mod = @import("app.zig");
const loader_mod = @import("loader.zig");
const main_mod = @import("main.zig");

extern fn emscripten_set_main_loop_arg(
    func: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
    fps: c_int,
    simulate_infinite_loop: c_int,
) void;
extern fn emscripten_get_element_css_size(target: [*:0]const u8, width: *f64, height: *f64) c_int;

/// Everything JS hands over is allocated (and freed) with this allocator.
const gpa = std.heap.c_allocator;

var window: *zglfw.Window = undefined;
var gctx: *zgpu.GraphicsContext = undefined;
var app: app_mod.App = undefined;
var ready = false;

/// Files added by JS since the last `zoxel_open_files`.
var batch: std.ArrayListUnmanaged(loader_mod.OwnedFile) = .empty;

/// Allocate `len` bytes for JS to fill (null when out of memory). Ownership
/// passes back to zoxel through `zoxel_add_file` or `zoxel_report_error`.
export fn zoxel_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, @max(len, 1)) catch return null;
    return buf.ptr;
}

/// Free a `zoxel_alloc` buffer JS could not hand over.
export fn zoxel_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..@max(len, 1)]);
}

/// Queue one file (takes ownership of both buffers).
export fn zoxel_add_file(name_ptr: [*]u8, name_len: usize, data_ptr: [*]u8, data_len: usize) void {
    const file: loader_mod.OwnedFile = .{ .name = ownedSlice(name_ptr, name_len), .bytes = ownedSlice(data_ptr, data_len) };
    batch.append(gpa, file) catch {
        gpa.free(file.name);
        gpa.free(file.bytes);
        std.log.err("zoxel_add_file: out of memory queueing {d} bytes", .{data_len});
    };
}

/// Open the queued files as one study: the largest is the CT, the rest are
/// searched for threat reports.
export fn zoxel_open_files() void {
    if (batch.items.len == 0) return;
    const files = batch.toOwnedSlice(gpa) catch {
        discardBatch();
        reportError("Out of memory opening the files.");
        return;
    };
    var largest: usize = 0;
    for (files, 0..) |f, i| if (f.bytes.len > files[largest].bytes.len) {
        largest = i;
    };
    const name = gpa.dupe(u8, files[largest].name) catch {
        var src: loader_mod.LoadSource = .{ .bytes = .{ .name = &.{}, .files = files } };
        src.deinit(gpa);
        reportError("Out of memory opening the files.");
        return;
    };
    if (!ready) {
        var src: loader_mod.LoadSource = .{ .bytes = .{ .name = name, .files = files } };
        src.deinit(gpa);
        return;
    }
    app.loadFiles(.{ .bytes = .{ .name = name, .files = files } });
}

/// Show a load failure from JS (e.g. a failed fetch) in the study panel.
/// Takes ownership of the message buffer.
export fn zoxel_report_error(ptr: [*]u8, len: usize) void {
    const msg = ownedSlice(ptr, len);
    defer gpa.free(msg);
    reportError(msg);
}

/// Exported so emcc runs it; returns once the frame loop is registered.
export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    _ = argc;
    _ = argv;
    init() catch |e| {
        std.log.err("zoxel init failed: {s}", .{@errorName(e)});
        return 1;
    };
    return 0;
}

/// zgpu's `wgpu.Device.tick()` is an extern Emscripten's WebGPU lacks. Only
/// `GraphicsContext.destroy` and desktop screenshots call it; neither runs in
/// the page, and a no-op avoids ASYNCIFY.
export fn wgpuDeviceTick(_: ?*anyopaque) void {}

/// A `zoxel_alloc` buffer of `len` bytes (it allocated at least one byte).
fn ownedSlice(ptr: [*]u8, len: usize) []u8 {
    if (len == 0) {
        gpa.free(ptr[0..1]);
        return gpa.alloc(u8, 0) catch unreachable;
    }
    return ptr[0..len];
}

fn discardBatch() void {
    for (batch.items) |f| {
        gpa.free(f.name);
        gpa.free(f.bytes);
    }
    batch.clearAndFree(gpa);
}

fn reportError(msg: []const u8) void {
    std.log.err("{s}", .{msg});
    if (ready) app.reportLoadError(msg);
}

fn init() !void {
    try zglfw.init();
    // Without this, Emscripten's GLFW creates a WebGL context on #canvas and
    // canvas.getContext("webgpu") then returns null.
    zglfw.windowHint(.client_api, .no_api);
    // Backing store = CSS size x devicePixelRatio (sharp on HiDPI screens).
    zglfw.windowHint(.scale_to_monitor, true);
    window = try zglfw.Window.create(1280, 800, "zoxel", null, null);
    fitWindowToStage();
    main_mod.installInputCallbacks(window);

    gctx = try zgpu.GraphicsContext.create(gpa, .{
        .window = window,
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = &main_mod.getFramebufferSize,
    }, .{});

    const fonts = main_mod.initImgui(gpa, window, gctx);
    app = app_mod.App.init(gpa, gctx, zgpu.GraphicsContext.swapchain_format);
    main_mod.useFonts(&app, fonts);
    ready = true;

    std.log.info("zoxel web: ready", .{});
    emscripten_set_main_loop_arg(&frame, null, 0, 0);
}

fn frame(_: ?*anyopaque) callconv(.c) void {
    fitWindowToStage();
    zglfw.pollEvents();
    var settled: u32 = 0;
    _ = main_mod.drawFrame(gpa, gctx, window, &app, null, &settled);
}

/// Size the GLFW window to the #stage element (the whole page). Emscripten's
/// GLFW pins the canvas' CSS size to the window size, so the canvas itself
/// cannot be measured to follow page resizes.
fn fitWindowToStage() void {
    var w: f64 = 0;
    var h: f64 = 0;
    if (emscripten_get_element_css_size("#stage", &w, &h) != 0) return;
    const iw: i32 = @intFromFloat(w);
    const ih: i32 = @intFromFloat(h);
    const cur = window.getSize();
    if (iw > 0 and ih > 0 and (cur[0] != iw or cur[1] != ih)) window.setSize(iw, ih);
}
