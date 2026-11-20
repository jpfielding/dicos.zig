//! zoxel -- GPU-accelerated DICOS volume viewer (native entry point).
//!
//! Usage:
//!   zoxel                      Launch with the first-use screen
//!   zoxel scan.dcs             Load a single DICOS file
//!   zoxel /path/to/study/      Load the files of a folder as volume layers
//!
//! Screenshots (reproducible captures of the real GPU frame):
//!   ZOXEL_SCREENSHOT=out.png [ZOXEL_SCREENSHOT_SIZE=WxH]
//!   [ZOXEL_SCREENSHOT_EXPANDED=1] [ZOXEL_SCREENSHOT_FOCUS=1]
//!   [ZOXEL_SCREENSHOT_CUTAWAY=1] [ZOXEL_SCREENSHOT_CLICK=x,y;x,y]
//!   zoxel [path]

const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");
const wgpu = zgpu.wgpu;
const app_mod = @import("app.zig");
const kit = @import("ui/kit.zig");
const platform = @import("platform.zig");
const png = @import("png.zig");

const ubuntu_light = @embedFile("assets/Ubuntu-Light.ttf");
const hack_regular = @embedFile("assets/Hack-Regular.ttf");

/// Input gathered by GLFW callbacks between frames (logical points).
var g_input: kit.Input = .{};
var g_window: ?*zglfw.Window = null;

fn cursorPosCb(_: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
    g_input.pointer = .{ .x = @floatCast(x), .y = @floatCast(y) };
}

fn mouseButtonCb(_: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    g_input.shift = mods.shift;
    g_input.ctrl = mods.control or mods.super;
    if (button != .left) return;
    switch (action) {
        .press => {
            g_input.down = true;
            g_input.pressed = true;
        },
        .release => {
            g_input.down = false;
            g_input.released = true;
        },
        else => {},
    }
}

fn scrollCb(_: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
    const yf: f32 = @floatCast(y);
    const xf: f32 = @floatCast(x);
    // Trackpads report fractional deltas (GLFW scales them by 0.1).
    const precise = yf != @round(yf) or xf != @round(xf);
    if (g_input.ctrl) {
        const per_point: f32 = if (precise) 10.0 else 40.0;
        g_input.zoom_delta *= @exp(yf * per_point / 200.0);
        return;
    }
    const pts: f32 = if (precise) 10.0 else 50.0;
    g_input.scroll = g_input.scroll.add(.{ .x = xf * pts, .y = yf * pts });
    g_input.scroll_lines += yf;
    g_input.scroll_precise = g_input.scroll_precise or precise;
}

fn keyCb(_: *zglfw.Window, key: zglfw.Key, _: c_int, action: zglfw.Action, mods: zglfw.Mods) callconv(.c) void {
    g_input.shift = mods.shift;
    g_input.ctrl = mods.control or mods.super;
    if (key == .left_shift or key == .right_shift) g_input.shift = action != .release;
    if (key == .left_control or key == .right_control or key == .left_super or key == .right_super) g_input.ctrl = action != .release;
    if (action == .release) return;
    switch (key) {
        .escape => if (action == .press) g_input.keys_pressed.insert(.escape),
        .enter, .kp_enter => g_input.keys_pressed.insert(.enter),
        .left => g_input.left_presses += 1,
        .right => g_input.right_presses += 1,
        else => {},
    }
}

fn focusCb(_: *zglfw.Window, focused: zglfw.Bool) callconv(.c) void {
    if (focused == zglfw.FALSE) {
        g_input.down = false;
        g_input.released = true;
    }
}

fn getFramebufferSize(win: *const anyopaque) [2]u32 {
    const w: *zglfw.Window = @ptrCast(@alignCast(@constCast(win)));
    const s = w.getFramebufferSize();
    return .{ @intCast(@max(s[0], 1)), @intCast(@max(s[1], 1)) };
}

const Capture = struct {
    path: []const u8,
    size: [2]i32,
    expanded: bool,
    focus: bool,
    cutaway: bool,
    /// Points (logical) tapped once loading settles, before the capture.
    clicks: ?[]const u8,
};

fn captureOptions() ?Capture {
    const path = platform.getenv("ZOXEL_SCREENSHOT") orelse return null;
    var size = [2]i32{ 1440, 900 };
    if (platform.getenv("ZOXEL_SCREENSHOT_SIZE")) |v| {
        if (std.mem.indexOfScalar(u8, v, 'x')) |i| {
            const w = std.fmt.parseInt(i32, v[0..i], 10) catch 1440;
            const h = std.fmt.parseInt(i32, v[i + 1 ..], 10) catch 900;
            size = .{ std.math.clamp(w, 320, 3840), std.math.clamp(h, 320, 2160) };
        }
    }
    return .{
        .path = path,
        .size = size,
        .expanded = platform.getenv("ZOXEL_SCREENSHOT_EXPANDED") != null,
        .focus = platform.getenv("ZOXEL_SCREENSHOT_FOCUS") != null,
        .cutaway = platform.getenv("ZOXEL_SCREENSHOT_CUTAWAY") != null,
        .clicks = platform.getenv("ZOXEL_SCREENSHOT_CLICK"),
    };
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    const initial_path = args.next();
    const capture = captureOptions();

    zglfw.init() catch {
        platform.showFatal("Failed to initialize GLFW.");
        return;
    };
    defer zglfw.terminate();

    zglfw.windowHint(.client_api, .no_api);
    const size = if (capture) |c| c.size else [2]i32{ 1440, 900 };
    const window = zglfw.Window.create(size[0], size[1], "Zoxel \u{2014} Volume workspace", null, null) catch {
        platform.showFatal("Failed to create a window.");
        return;
    };
    defer window.destroy();
    g_window = window;
    // Minimum window; a capture may request a smaller (phone) viewport.
    window.setSizeLimits(@min(size[0], 1100), @min(size[1], 720), -1, -1);

    // Our callbacks first: the ImGui GLFW backend chains to them.
    _ = window.setCursorPosCallback(cursorPosCb);
    _ = window.setMouseButtonCallback(mouseButtonCb);
    _ = window.setScrollCallback(scrollCb);
    _ = window.setKeyCallback(keyCb);
    _ = window.setFocusCallback(focusCb);

    const gctx = zgpu.GraphicsContext.create(gpa, .{
        .window = window,
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = &getFramebufferSize,
        .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
    }, .{}) catch {
        platform.showFatal("Failed to create a GPU device. zoxel needs WebGPU through Metal, Vulkan or D3D12.");
        return;
    };
    defer gctx.destroy(gpa);

    zgui.init(gpa);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);
    var cfg = zgui.FontConfig.init();
    cfg.font_data_owned_by_atlas = false;
    const font = zgui.io.addFontFromMemoryWithConfig(ubuntu_light, 13.5 * 1.121, cfg, null);
    zgui.io.setDefaultFont(font);
    var mcfg = zgui.FontConfig.init();
    mcfg.font_data_owned_by_atlas = false;
    const mono = zgui.io.addFontFromMemoryWithConfig(hack_regular, 11.0, mcfg, null);
    zgui.backend.init(window, gctx.device, @intFromEnum(zgpu.GraphicsContext.swapchain_format), @intFromEnum(wgpu.TextureFormat.undef));
    defer zgui.backend.deinit();

    var app = app_mod.App.init(gpa, gctx, zgpu.GraphicsContext.swapchain_format);
    defer app.deinit();
    app.ctx.proportional.font = font;
    // Hack: ascent 0.759 + descent 0.241 = 1 em; row adds the 0.164 gap.
    app.ctx.monospace = .{ .font = mono, .em_to_px = 1.0, .row_factor = 1.164 };

    if (capture) |c| {
        if (c.expanded) app.expandSliceView();
        if (c.focus) app.focusVolume();
        if (c.cutaway) app.enableCutaway();
    }
    if (initial_path) |p| app.loadPath(p);

    var settled: u32 = 0;
    while (!window.shouldClose()) {
        if (app.wantsRepaint() or capture != null) zglfw.pollEvents() else zglfw.waitEventsTimeout(0.25);
        if (!gctx.canRender()) continue;

        const fb = window.getFramebufferSize();
        const ws = window.getSize();
        if (ws[0] <= 0 or ws[1] <= 0) continue;
        const ppp = @as(f32, @floatFromInt(fb[0])) / @as(f32, @floatFromInt(ws[0]));

        // Keep held state current even without events.
        if (g_input.pointer == null) {
            const cp = window.getCursorPos();
            g_input.pointer = .{ .x = @floatCast(cp[0]), .y = @floatCast(cp[1]) };
        }
        g_input.time = zglfw.getTime();
        app.ctx.input = g_input;
        g_input.endFrame();

        newImguiFrame(fb, ppp, g_input.pointer);
        const screen = kit.Rect.fromMinSize(.{}, .{ .x = @floatFromInt(ws[0]), .y = @floatFromInt(ws[1]) });
        app.update(screen, ppp);

        var shoot = false;
        if (capture) |c| {
            settled = if (app.isLoading()) 0 else settled + 1;
            shoot = settled >= 8 + 4 * clickCount(c.clicks);
            if (settled >= 4) injectClick(c.clicks, settled - 4);
        }

        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();
        var off_tex: ?wgpu.Texture = null;
        var target: wgpu.TextureView = undefined;
        if (shoot) {
            off_tex = gctx.device.createTexture(.{
                .usage = .{ .render_attachment = true, .copy_src = true },
                .size = .{ .width = @intCast(fb[0]), .height = @intCast(fb[1]), .depth_or_array_layers = 1 },
                .format = zgpu.GraphicsContext.swapchain_format,
            });
            target = off_tex.?.createView(.{});
        } else {
            target = gctx.swapchain.getCurrentTextureView();
        }
        defer target.release();

        app.renderVolume(encoder, target, ppp);
        {
            const attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = target, .load_op = .load, .store_op = .store }};
            const pass = encoder.beginRenderPass(.{ .color_attachment_count = attachments.len, .color_attachments = &attachments });
            zgui.backend.draw(pass);
            pass.end();
            pass.release();
        }
        const cmd = encoder.finish(null);
        defer cmd.release();
        gctx.submit(&.{cmd});

        if (shoot) {
            const c = capture.?;
            saveScreenshot(gpa, gctx, off_tex.?, @intCast(fb[0]), @intCast(fb[1]), c.path) catch |e| {
                std.debug.print("screenshot failed: {s}\n", .{@errorName(e)});
            };
            off_tex.?.release();
            break;
        }
        _ = gctx.present();
    }
}

extern fn ImGui_ImplWGPU_NewFrame() void;
extern fn ImGui_ImplGlfw_NewFrame() void;

/// Start an ImGui frame in physical pixels. The GLFW backend reports the
/// logical window size with a framebuffer scale; ImGui then anti-aliases
/// with a one-*point* fringe (two pixels at 2x). egui feathers one pixel, so
/// zoxel overrides the display size and scale and draws in pixels.
fn newImguiFrame(fb: [2]c_int, ppp: f32, pointer: ?kit.Vec2) void {
    ImGui_ImplWGPU_NewFrame();
    ImGui_ImplGlfw_NewFrame();
    zgui.io.setDisplaySize(@floatFromInt(fb[0]), @floatFromInt(fb[1]));
    zgui.io.setDisplayFramebufferScale(1, 1);
    if (pointer) |p| zgui.io.addMousePositionEvent(p.x * ppp, p.y * ppp);
    zgui.newFrame();
}

fn clickCount(spec: ?[]const u8) u32 {
    const s = spec orelse return 0;
    return @intCast(std.mem.count(u8, s, ";") + 1);
}

/// Replay scripted taps for captures: press on frame 4k, release on 4k+1.
fn injectClick(spec: ?[]const u8, frame: u32) void {
    const s = spec orelse return;
    var it = std.mem.splitScalar(u8, s, ';');
    var i: u32 = 0;
    while (it.next()) |pt| : (i += 1) {
        if (frame / 4 != i) continue;
        const comma = std.mem.indexOfScalar(u8, pt, ',') orelse return;
        const x = std.fmt.parseFloat(f32, pt[0..comma]) catch return;
        const y = std.fmt.parseFloat(f32, pt[comma + 1 ..]) catch return;
        g_input.pointer = .{ .x = x, .y = y };
        switch (frame % 4) {
            0 => {
                g_input.pressed = true;
                g_input.down = true;
            },
            1 => {
                g_input.released = true;
                g_input.down = false;
            },
            else => {},
        }
    }
}

const MapState = struct { done: bool = false, ok: bool = false };

fn mapCallback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.c) void {
    const st: *MapState = @ptrCast(@alignCast(userdata.?));
    st.done = true;
    st.ok = status == .success;
}

/// Read back the rendered frame (volume and interface) and write a PNG.
fn saveScreenshot(gpa: std.mem.Allocator, gctx: *zgpu.GraphicsContext, tex: wgpu.Texture, width: u32, height: u32, path: []const u8) !void {
    const stride = (width * 4 + 255) / 256 * 256;
    const buf = gctx.device.createBuffer(.{ .usage = .{ .copy_dst = true, .map_read = true }, .size = @as(u64, stride) * height });
    defer buf.release();
    const enc = gctx.device.createCommandEncoder(null);
    defer enc.release();
    enc.copyTextureToBuffer(
        .{ .texture = tex },
        .{ .layout = .{ .offset = 0, .bytes_per_row = stride, .rows_per_image = height }, .buffer = buf },
        .{ .width = width, .height = height, .depth_or_array_layers = 1 },
    );
    const cmd = enc.finish(null);
    defer cmd.release();
    gctx.queue.submit(&.{cmd});
    var st = MapState{};
    buf.mapAsync(.{ .read = true }, 0, @as(usize, stride) * height, mapCallback, &st);
    var spins: usize = 0;
    while (!st.done and spins < 20000) : (spins += 1) {
        gctx.device.tick();
        std.Thread.sleep(std.time.ns_per_ms / 2);
    }
    if (!st.ok) return error.MapFailed;
    const mapped = buf.getConstMappedRange(u8, 0, @as(usize, stride) * height) orelse return error.MapFailed;
    const rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(rgba);
    for (0..height) |y| {
        const src = mapped[y * stride ..][0 .. width * 4];
        const dst = rgba[y * width * 4 ..][0 .. width * 4];
        @memcpy(dst, src);
        // BGRA -> RGBA.
        var i: usize = 0;
        while (i < dst.len) : (i += 4) std.mem.swap(u8, &dst[i], &dst[i + 2]);
    }
    buf.unmap();
    const out = try png.encodeRgba(gpa, width, height, rgba);
    defer gpa.free(out);
    try platform.writeFile(path, out);
    std.debug.print("Screenshot saved: {s}\n", .{path});
}

test {
    _ = @import("tests.zig");
}
