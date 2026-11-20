//! Application: bridges the UI state, the background loader and the GPU
//! renderer (port of roxel `app.rs`). Platform-neutral: the window/event
//! loop (`main.zig`) feeds input and asks for frames.

const std = @import("std");
const zgpu = @import("zgpu");
const zgui = @import("zgui");
const wgpu = zgpu.wgpu;

const camera_mod = @import("camera.zig");
const volume_mod = @import("volume.zig");
const transfer = @import("transfer.zig");
const slice_view = @import("slice_view.zig");
const state_mod = @import("state.zig");
const renderer_mod = @import("renderer.zig");
const loader_mod = @import("loader.zig");
const platform = @import("platform.zig");
const touch = @import("touch.zig");
const kit = @import("ui/kit.zig");
const ui = @import("ui/mod.zig");
const slice_panel = @import("ui/slice_panel.zig");

const Vec3 = camera_mod.Vec3;
const UiState = state_mod.UiState;

/// Map a normalised volume point into the renderer's physical world space.
pub fn cameraTarget(vol: *const volume_mod.Volume, com: [3]f32) Vec3 {
    return Vec3.fromArray(com).mul(camera_mod.physicalExtent(.{ vol.dim_x, vol.dim_y, vol.dim_z }, vol.voxel_spacing));
}

/// Frame the whole volume consistently with its physical geometry.
pub fn fitCameraToVolume(cam: *camera_mod.Camera, vol: *const volume_mod.Volume, aspect: f32) void {
    cam.fitBounds(Vec3.zero, cameraTarget(vol, .{ 1, 1, 1 }), aspect);
}

pub const App = struct {
    gpa: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    ctx: kit.Ctx,
    state: UiState,
    renderer: renderer_mod.VolumeRenderer,
    loader: loader_mod.VolumeLoader,

    slice_tex: ?zgpu.TextureHandle = null,
    slice_view_h: ?zgpu.TextureViewHandle = null,
    slice_size: [2]usize = .{ 0, 0 },
    /// Last CPU-rendered slice (kept to re-upload at another scale).
    slice_img: ?slice_view.Image = null,
    /// Integer nearest-neighbour upsampling of the uploaded slice.
    slice_k: usize = 1,
    /// Replaced slice textures, released once the frame using them is done.
    retired: [4]?zgpu.TextureViewHandle = .{ null, null, null, null },
    retired_tex: [4]?zgpu.TextureHandle = .{ null, null, null, null },

    // Camera drag state.
    dragging: bool = false,
    touches: touch.TouchTracker = .{},

    pub fn init(gpa: std.mem.Allocator, gctx: *zgpu.GraphicsContext, target_format: wgpu.TextureFormat) App {
        var cam = camera_mod.Camera{};
        cam.setCoronal();
        var app = App{
            .gpa = gpa,
            .gctx = gctx,
            .ctx = kit.Ctx.init(gpa),
            .state = UiState.init(cam),
            .renderer = renderer_mod.VolumeRenderer.init(gpa, gctx, target_format),
            .loader = loader_mod.VolumeLoader.init(gpa),
        };
        app.state.can_pick_folder = platform.has_folder_picker;
        return app;
    }

    pub fn deinit(self: *App) void {
        self.loader.deinit();
        self.releaseSliceTexture();
        self.flushRetired();
        if (self.slice_img) |*img| img.deinit(self.gpa);
        self.renderer.deinit();
        self.state.deinit(self.gpa);
        self.ctx.deinit();
    }

    pub fn isLoading(self: *const App) bool {
        return self.loader.loading() != null;
    }

    pub fn enableCutaway(self: *App) void {
        self.state.cutaway = true;
    }
    pub fn focusVolume(self: *App) void {
        self.state.focus_volume = true;
        self.state.fit_camera = true;
    }
    pub fn expandSliceView(self: *App) void {
        self.state.slice_expanded = true;
    }

    /// Load a file or directory path (native).
    pub fn loadPath(self: *App, path: []const u8) void {
        const owned = self.gpa.dupe(u8, path) catch return;
        self.requestLoad(.{ .path = owned });
    }

    /// Load in-memory files (e.g. a browser picker). Takes ownership.
    pub fn loadFiles(self: *App, source: loader_mod.LoadSource) void {
        self.requestLoad(source);
    }

    fn requestLoad(self: *App, source: loader_mod.LoadSource) void {
        self.state.setLoadError(self.gpa, null);
        self.loader.request(source);
    }

    // -----------------------------------------------------------------------
    // Frame
    // -----------------------------------------------------------------------

    /// Build the UI and update state for one frame. Call between
    /// `zgui.backend.newFrame` and rendering. `screen` is in points.
    pub fn update(self: *App, screen: kit.Rect, pixels_per_point: f32) void {
        const gpa = self.gpa;
        self.flushRetired();
        if (self.loader.poll()) |outcome_in| {
            var outcome = outcome_in;
            switch (outcome.result) {
                .loaded => |layers| {
                    self.installLoaded(outcome.path, layers);
                    // Layers moved into the library; free only the shells.
                    gpa.free(layers);
                    outcome.result = .{ .failed = &.{} };
                },
                .failed => |msg| {
                    const text = std.fmt.allocPrint(gpa, "Failed to load {s}: {s}", .{ outcome.path, msg }) catch null;
                    if (text) |t| {
                        self.state.setLoadError(gpa, t);
                        gpa.free(t);
                    }
                },
            }
            outcome.deinit(gpa);
        }
        if (self.state.loading_file) |f| gpa.free(f);
        self.state.loading_file = if (self.loader.loading()) |p| gpa.dupe(u8, platform.baseName(p)) catch null else null;

        self.state.actions.preset_changed = false;
        self.state.transfer.bands_changed = false;
        self.state.actions.upload_3d_index = null;
        self.state.actions.pick_file = false;
        self.state.actions.pick_folder = false;
        self.state.slice_texture_size = if (self.slice_view_h != null) self.slice_size else null;
        slice_panel.slice_texture = if (self.slice_view_h) |h| textureRef(self.gctx, h) else null;

        // A fullscreen, invisible ImGui window hosts the one ImGui widget
        // (the number box text field) and provides the draw lists.
        zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
        // ImGui runs in physical pixels; the kit scales from points.
        zgui.setNextWindowSize(.{ .w = screen.width() * pixels_per_point, .h = screen.height() * pixels_per_point });
        zgui.pushStyleVar2f(.{ .idx = .window_padding, .v = .{ 0, 0 } });
        zgui.pushStyleVar1f(.{ .idx = .window_border_size, .v = 0 });
        _ = zgui.begin("##zoxel", .{ .flags = .{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_scrollbar = true,
            .no_scroll_with_mouse = true,
            .no_collapse = true,
            .no_background = true,
            .no_saved_settings = true,
            .no_bring_to_front_on_focus = true,
            .no_nav_inputs = true,
            .no_nav_focus = true,
        } });
        zgui.popStyleVar(.{ .count = 2 });
        self.ctx.pixels_per_point = pixels_per_point;
        self.ctx.beginFrame(screen, zgui.getWindowDrawList(), zgui.getForegroundDrawList());
        ui.drawUi(&self.ctx, &self.state);
        self.handleCameraInput();
        self.ctx.endFrame();
        zgui.end();

        self.afterUi();
    }

    fn afterUi(self: *App) void {
        const st = &self.state;
        if (st.fit_camera) {
            if (st.library.active_3d_index) |i| if (st.library.get(i)) |layer| {
                fitCameraToVolume(&st.camera, &layer.volume, st.viewport.width() / @max(st.viewport.height(), 1));
            };
            st.fit_camera = false;
        }
        if (st.actions.pick_file) {
            if (platform.pick(self.gpa, .file)) |p| self.requestLoad(.{ .path = p });
        }
        if (st.actions.pick_folder) {
            if (platform.pick(self.gpa, .folder)) |p| self.requestLoad(.{ .path = p });
        }
        if (st.actions.upload_3d_index) |i| self.uploadVolume(i);
        if (st.actions.preset_changed) {
            st.transfer.bands_debounce_deadline = null;
            const tf = st.transfer.current();
            self.renderer.uploadTransferFunction(&tf);
            st.slice_view.transfer_func = tf;
            st.slice_dirty = true;
        }
        // Debounce the transfer rebuild while band handles are dragged.
        const now = self.ctx.input.time;
        if (st.transfer.bands_changed) st.transfer.bands_debounce_deadline = now + 0.06;
        if (st.transfer.preset != .default) st.transfer.bands_debounce_deadline = null;
        if (st.transfer.bands_debounce_deadline) |deadline| {
            if (now >= deadline) {
                st.transfer.bands_debounce_deadline = null;
                const tf = transfer.TransferFunction.fromBands(&st.transfer.bands);
                self.renderer.uploadTransferFunction(&tf);
                st.slice_view.transfer_func = tf;
                st.slice_dirty = true;
            } else self.ctx.wants_repaint = true;
        }
        st.syncCompositeOpacity();
        if (st.slice_dirty) {
            self.updateSliceTexture();
            st.slice_dirty = false;
        } else if (self.slice_img) |*img| {
            const k = upsampleFactor(img.width, img.height, slice_panel.slice_display_scale);
            if (k != self.slice_k) self.uploadSlice(img, k);
        }
    }

    /// Whether another frame is wanted soon (animation, load, debounce).
    pub fn wantsRepaint(self: *const App) bool {
        return self.ctx.wants_repaint or self.isLoading() or self.dragging or self.state.transfer.bands_debounce_deadline != null;
    }

    /// Ray-cast into `target` (clearing it) when the 3D view is on screen.
    pub fn renderVolume(self: *App, encoder: wgpu.CommandEncoder, target: wgpu.TextureView, pixels_per_point: f32) void {
        const st = &self.state;
        if (!st.volumeVisible()) {
            self.renderer.render(encoder, target, null);
            return;
        }
        const vp = st.viewport;
        const threats: []const volume_mod.ThreatBox = if (st.library.active_3d_index) |i| (if (st.library.get(i)) |l| l.volume.threats.items else &.{}) else &.{};
        var clip: ?[4]f32 = null;
        if (st.cutaway and !st.slice_view.composite and st.library.active_3d_index != null and st.library.active_3d_index.? == st.slice_view.volume_index) {
            if (st.library.get(st.slice_view.volume_index)) |l| clip = st.slice_view.clipPlane(&l.volume, st.reverse_cutaway);
        }
        self.renderer.render(encoder, target, .{
            .camera = &st.camera,
            .viewport = .{ @max(vp.width(), 1), @max(vp.height(), 1) },
            .viewport_rect = .{ vp.min.x * pixels_per_point, vp.min.y * pixels_per_point, @max(vp.width(), 1) * pixels_per_point, @max(vp.height(), 1) * pixels_per_point },
            .clip_plane = clip,
            .threats = threats,
            .show_threats = st.library.show_threats,
            .settings = &st.settings,
        });
    }

    // -----------------------------------------------------------------------
    // Camera input
    // -----------------------------------------------------------------------

    /// Orbit / pan / zoom with the mouse in the 3D viewport. Drag deltas are
    /// scaled to physical pixels, as roxel receives them from winit.
    fn handleCameraInput(self: *App) void {
        const in = &self.ctx.input;
        const st = &self.state;
        if (!in.down) self.dragging = false;
        if (!st.volumeVisible() or !self.renderer.isReady()) {
            self.dragging = false;
            return;
        }
        const p = in.pointer orelse return;
        const over_view = st.viewport.contains(p) and !(self.ctx.popupOpen() and (self.ctx.popup_rect != null and self.ctx.popup_rect.?.contains(p)));
        if (in.pressed and over_view and self.ctx.active_id == null and !self.ctx.popupOpen()) {
            self.dragging = true;
        }
        if (self.dragging) {
            if (self.ctx.last_pointer) |last| {
                const s = self.ctx.pixels_per_point;
                const dx = (p.x - last.x) * s;
                const dy = (p.y - last.y) * s;
                if (dx != 0 or dy != 0) {
                    if (in.shift) st.camera.panPixels(dx, dy) else st.camera.rotate(dx * 0.005, -dy * 0.005);
                }
            }
        }
        if (over_view and in.scroll_lines != 0 and !self.ctx.popupOpen()) {
            // roxel: wheel lines -> 1 + 0.1 * lines; trackpad physical
            // pixels -> 1 + 0.001 * pixels (0.1 of its 0.01 per pixel).
            const factor = if (in.scroll_precise)
                1.0 + in.scroll_lines * 10.0 * self.ctx.pixels_per_point * 0.001
            else
                1.0 + in.scroll_lines * 0.1;
            st.camera.zoom(factor);
        }
    }

    /// Feed one touch event (physical pixels). Returns true on camera change.
    pub fn handleTouch(self: *App, id: u64, phase: touch.Phase, pos_px: [2]f32) bool {
        const st = &self.state;
        if (!st.volumeVisible() or !self.renderer.isReady()) return false;
        const s = self.ctx.pixels_per_point;
        const inside = st.viewport.contains(.{ .x = pos_px[0] / s, .y = pos_px[1] / s });
        const gestures = self.touches.update(id, phase, pos_px, inside);
        for (gestures.slice()) |g| switch (g) {
            .orbit => |o| if (st.drag_pans) st.camera.panPixels(o.dx, o.dy) else st.camera.rotate(o.dx * 0.005, -o.dy * 0.005),
            .pan => |o| st.camera.panPixels(o.dx, o.dy),
            .zoom => |f| st.camera.zoom(f),
        };
        return gestures.len > 0;
    }

    // -----------------------------------------------------------------------
    // Loading and uploads
    // -----------------------------------------------------------------------

    fn installLoaded(self: *App, path: []const u8, layers: []loader_mod.LoadedLayer) void {
        const gpa = self.gpa;
        const st = &self.state;
        st.setLoadError(gpa, null);
        if (layers.len == 0) return;
        st.library.clear(gpa);
        var first_pack: ?[]u16 = null;
        var first_com: [3]f32 = .{ 0.5, 0.5, 0.5 };
        for (layers, 0..) |*l, i| {
            if (i == 0) {
                first_pack = l.packed_buf;
                first_com = l.center_of_mass;
            } else gpa.free(l.packed_buf);
            st.library.volumes.append(gpa, .{ .name = l.name, .volume = l.volume }) catch {
                l.deinit(gpa);
                continue;
            };
        }
        defer if (first_pack) |p| gpa.free(p);
        if (st.library.loaded_path) |p| gpa.free(p);
        st.library.loaded_path = gpa.dupe(u8, path) catch null;
        // A new study starts on the 3D view with its controls open.
        st.phone_tab = .view3d;
        st.sheet_open = true;
        st.bands_open = false;
        self.activateVolumes(first_pack, first_com);
        var total: usize = 0;
        for (st.library.volumes.items) |l| total += l.volume.threats.items.len;
        if (total == 0) std.log.info("No threat boxes found in loaded data", .{}) else std.log.info("Loaded {d} threat box(es)", .{total});
    }

    fn activateVolumes(self: *App, first_pack: ?[]u16, com: [3]f32) void {
        const st = &self.state;
        if (st.library.isEmpty()) return;
        // A spatial view; orthogonal views stay one click away.
        st.camera = .{};
        if (first_pack) |p| self.uploadVolumePacked(0, p, com) else self.uploadVolume(0);
        st.slice_view.volume_index = 0;
        st.library.selected_threat = null;
        const vol = &st.library.volumes.items[0].volume;
        // Mid-coronal slice.
        st.slice_view.orientation = .coronal;
        st.slice_view.updateForVolume(vol);
        st.slice_view.slice_index = st.slice_view.max_slices / 2;
        st.slice_view.window_center = @floatCast(vol.window_center);
        st.slice_view.window_width = @floatCast(vol.window_width);
        st.settings.window_center = @floatCast(vol.window_center);
        st.settings.window_width = @floatCast(vol.window_width);
        st.slice_view.transfer_func = st.transfer.current();
        st.slice_view.alpha_scale = st.settings.global_opacity;
        st.slice_dirty = true;
    }

    fn uploadVolume(self: *App, idx: usize) void {
        const layer = self.state.library.get(idx) orelse return;
        const p = layer.volume.packForGpu(self.gpa) catch return;
        defer self.gpa.free(p);
        self.uploadVolumePacked(idx, p, layer.volume.centerOfMass());
    }

    fn uploadVolumePacked(self: *App, idx: usize, packed_buf: []const u16, com: [3]f32) void {
        const st = &self.state;
        const layer = st.library.get(idx) orelse return;
        const vol = &layer.volume;
        st.settings.window_center = @floatCast(vol.window_center);
        st.settings.window_width = @floatCast(vol.window_width);
        st.camera.target = cameraTarget(vol, com);
        st.volume_extent = cameraTarget(vol, .{ 1, 1, 1 });
        self.renderer.uploadVolumePacked(vol, packed_buf) catch |e| {
            std.log.err("volume upload failed: {s}", .{@errorName(e)});
            return;
        };
        const tf = st.transfer.current();
        self.renderer.uploadTransferFunction(&tf);
        st.library.active_3d_index = idx;
        st.fit_camera = true;
    }

    /// Retire the current slice texture: this frame's draw list may still
    /// reference it, so it is released at the start of the next update.
    fn releaseSliceTexture(self: *App) void {
        for (&self.retired, &self.retired_tex) |*v, *t| {
            if (v.* == null and t.* == null) {
                v.* = self.slice_view_h;
                t.* = self.slice_tex;
                break;
            }
        } else {
            self.flushRetired();
            self.retired[0] = self.slice_view_h;
            self.retired_tex[0] = self.slice_tex;
        }
        self.slice_view_h = null;
        self.slice_tex = null;
    }

    fn flushRetired(self: *App) void {
        for (&self.retired, &self.retired_tex) |*v, *t| {
            if (v.*) |h| self.gctx.releaseResource(h);
            if (t.*) |h| self.gctx.releaseResource(h);
            v.* = null;
            t.* = null;
        }
    }

    /// Re-render the 2D slice on the CPU and upload it.
    fn updateSliceTexture(self: *App) void {
        const st = &self.state;
        const layer = st.library.get(st.slice_view.volume_index) orelse return;
        const img = st.slice_view.render(self.gpa, &layer.volume, st.library.show_threats) catch return;
        if (self.slice_img) |*old| old.deinit(self.gpa);
        self.slice_img = img;
        self.uploadSlice(&self.slice_img.?, upsampleFactor(img.width, img.height, slice_panel.slice_display_scale));
    }

    /// Upload `img` upsampled by `k` with nearest neighbour. ImGui's WebGPU
    /// backend samples every texture linearly; at about 1:1 display that
    /// keeps voxel edges hard, as roxel's NEAREST texture does.
    fn uploadSlice(self: *App, img: *const slice_view.Image, k: usize) void {
        const g = self.gctx;
        const w = img.width * k;
        const h = img.height * k;
        const up = self.gpa.alloc([4]u8, w * h) catch return;
        defer self.gpa.free(up);
        for (0..h) |y| {
            const src = img.pixels[(y / k) * img.width ..][0..img.width];
            const dst = up[y * w ..][0..w];
            for (0..w) |x| dst[x] = src[x / k];
        }
        if (self.slice_tex == null or self.slice_size[0] != img.width or self.slice_size[1] != img.height or self.slice_k != k) {
            self.releaseSliceTexture();
            const tex = g.createTexture(.{
                .usage = .{ .texture_binding = true, .copy_dst = true },
                .size = .{ .width = @intCast(w), .height = @intCast(h), .depth_or_array_layers = 1 },
                .format = .rgba8_unorm,
            });
            self.slice_tex = tex;
            self.slice_view_h = g.createTextureView(tex, .{});
            self.slice_size = .{ img.width, img.height };
            self.slice_k = k;
        }
        g.queue.writeTexture(
            .{ .texture = g.lookupResource(self.slice_tex.?).? },
            .{ .bytes_per_row = @intCast(w * 4), .rows_per_image = @intCast(h) },
            .{ .width = @intCast(w), .height = @intCast(h), .depth_or_array_layers = 1 },
            [4]u8,
            up,
        );
    }
};

/// Integer upsampling for a slice shown at `display_scale` physical pixels
/// per texel, keeping the texture within 4096 texels on its long side.
pub fn upsampleFactor(w: usize, h: usize, display_scale: f32) usize {
    const long = @max(@max(w, h), 1);
    const cap = @max(4096 / long, 1);
    const want: usize = @intFromFloat(@max(@ceil(display_scale), 1));
    return std.math.clamp(want, 1, cap);
}

/// The ImGui texture id of a WebGPU texture view.
fn textureRef(gctx: *zgpu.GraphicsContext, h: zgpu.TextureViewHandle) ?u64 {
    const view = gctx.lookupResource(h) orelse return null;
    return @intFromPtr(view);
}

test "app fit uses physical y extent and center" {
    var vol = try volume_mod.testVolume(std.testing.allocator, 1, 1, 1, 0);
    defer vol.deinit(std.testing.allocator);
    vol.dim_x = 256;
    vol.dim_y = 128;
    vol.dim_z = 256;
    vol.voxel_spacing = .{ 1.7421875, 1.7821531, 2.6796875 };
    var cam = camera_mod.Camera{};
    fitCameraToVolume(&cam, &vol, 1.5);
    const extent = cameraTarget(&vol, .{ 1, 1, 1 });
    try std.testing.expect(cam.target.eql(extent.scale(0.5)));
    try std.testing.expect(@abs(cam.target.y - 0.25573722) < 0.00001);
}
