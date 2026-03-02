//! Main application state and UI for zoxel volume viewer.

const std = @import("std");
const zgpu = @import("zgpu");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const camera_mod = @import("camera.zig");
const volume_mod = @import("volume.zig");
const transfer_fn = @import("transfer_fn.zig");
const slice_view_mod = @import("slice_view.zig");
const renderer_mod = @import("renderer.zig");
const wgpu = zgpu.wgpu;

const ArrayList = std.array_list.AlignedManaged;

pub const App = struct {
    camera: camera_mod.Camera,
    volumes: ArrayList(volume_mod.Volume, null),
    active_volume: usize,
    slice_view: slice_view_mod.SliceView,
    transfer_preset: transfer_fn.TransferPreset,
    bands: [5]transfer_fn.ColorBand,
    band_thresholds: [5]i32,
    show_threats: bool,
    allocator: std.mem.Allocator,

    renderer: renderer_mod.VolumeRenderer,
    dpi_scale: f32,

    // Rendering params
    opacity: f32,
    quality_idx: i32,
    density_threshold: f32,
    window_center: f32,
    window_width: f32,
    lighting_ambient: f32,
    lighting_diffuse: f32,
    lighting_specular: f32,

    // Band slider drag state
    active_band_handle: i32, // -1 = none

    // Slice view state
    slice_orientation: i32,
    slice_index: i32,
    slice_dirty: bool,
    slice_tex: ?zgpu.TextureHandle,
    slice_texv: ?zgpu.TextureViewHandle,
    slice_w: u32,
    slice_h: u32,

    // Window dimensions (logical, for UI layout)
    win_w: f32,
    win_h: f32,

    // Mouse tracking
    last_mouse_x: f64,
    last_mouse_y: f64,
    mouse_dragging: bool,
    shift_held: bool,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext, dpi_scale: f32) App {
        var rend = renderer_mod.VolumeRenderer.init(allocator, gctx);
        const tf = transfer_fn.TransferFunction.fromPreset(.default);
        rend.uploadTransferFunction(&tf);

        return .{
            .camera = .{},
            .volumes = ArrayList(volume_mod.Volume, null).init(allocator),
            .active_volume = 0,
            .slice_view = .{},
            .transfer_preset = .default,
            .bands = transfer_fn.defaultBands(),
            .band_thresholds = .{ 8000, 15000, 20000, 25000, 30000 },
            .active_band_handle = -1,
            .show_threats = true,
            .allocator = allocator,
            .renderer = rend,
            .dpi_scale = dpi_scale,
            .opacity = 0.50,
            .quality_idx = 1,
            .density_threshold = 0.0,
            .window_center = 2000,
            .window_width = 4000,
            .lighting_ambient = 0.30,
            .lighting_diffuse = 0.60,
            .lighting_specular = 0.30,
            .slice_orientation = 0,
            .slice_index = 0,
            .slice_dirty = true,
            .slice_tex = null,
            .slice_texv = null,
            .slice_w = 0,
            .slice_h = 0,
            .win_w = 1920,
            .win_h = 1000,
            .last_mouse_x = 0,
            .last_mouse_y = 0,
            .mouse_dragging = false,
            .shift_held = false,
        };
    }

    pub fn deinit(self: *App) void {
        if (self.slice_texv) |h| self.renderer.gctx.releaseResource(h);
        if (self.slice_tex) |h| self.renderer.gctx.releaseResource(h);
        self.renderer.deinit();
        for (self.volumes.items) |*vol| {
            vol.deinit();
        }
        self.volumes.deinit();
    }

    pub fn loadPath(self: *App, path: []const u8) !void {
        var vol = try volume_mod.Volume.loadFile(self.allocator, path);
        errdefer vol.deinit();
        try self.volumes.append(vol);
        self.active_volume = self.volumes.items.len - 1;

        const v = &self.volumes.items[self.active_volume];
        self.slice_view.updateForVolume(v);
        self.slice_index = @intCast(self.slice_view.max_slices / 2);

        // Use volume metadata window/level if reasonable, otherwise auto-compute
        if (v.window_width > 1 and v.window_width < 60000) {
            self.window_center = v.window_center;
            self.window_width = v.window_width;
        } else if (v.data.len > 0) {
            // Auto-compute from 1st/99th percentile
            var min_val: u16 = std.math.maxInt(u16);
            var max_val: u16 = 0;
            const stride = @max(v.data.len / 10000, 1);
            var i: usize = 0;
            while (i < v.data.len) : (i += stride) {
                const val = v.data[i];
                if (val > 0 and val < min_val) min_val = val;
                if (val > max_val) max_val = val;
            }
            if (max_val > min_val) {
                self.window_center = @as(f32, @floatFromInt(min_val + max_val)) / 2.0;
                self.window_width = @as(f32, @floatFromInt(max_val - min_val));
            }
        }
        self.syncUniforms();

        // Compute scale_z for anisotropic voxels
        if (v.pixel_spacing_x > 0 and v.dim_z > 1) {
            self.renderer.uniforms.scale_z = (v.slice_thickness * @as(f32, @floatFromInt(v.dim_z))) /
                (v.pixel_spacing_x * @as(f32, @floatFromInt(@max(v.dim_x, v.dim_y))));
        }

        self.renderer.uniforms.rescale_intercept = v.rescale_intercept;
        try self.renderer.uploadVolume(v);
        self.slice_dirty = true;
    }

    fn syncUniforms(self: *App) void {
        self.renderer.uniforms.window_min = self.window_center - self.window_width * 0.5;
        self.renderer.uniforms.window_range = self.window_width;
        self.renderer.uniforms.alpha_scale = self.opacity;
        self.renderer.uniforms.density_threshold = self.density_threshold;
        self.renderer.uniforms.ambient_intensity = self.lighting_ambient;
        self.renderer.uniforms.diffuse_intensity = self.lighting_diffuse;
        self.renderer.uniforms.specular_intensity = self.lighting_specular;
        self.renderer.quality = @enumFromInt(@as(u2, @intCast(self.quality_idx)));
    }

    pub fn handleInputEvent(self: *App, window: *zglfw.Window) void {
        const cursor = window.getCursorPos();
        const mx: f64 = cursor[0];
        const my: f64 = cursor[1];

        self.shift_held = (window.getKey(.left_shift) == .press or window.getKey(.right_shift) == .press);
        const left_pressed = window.getMouseButton(.left) == .press;

        // Don't handle camera input when ImGui wants the mouse
        if (left_pressed and !zgui.io.getWantCaptureMouse()) {
            if (self.mouse_dragging) {
                const dx: f32 = @floatCast(mx - self.last_mouse_x);
                const dy: f32 = @floatCast(my - self.last_mouse_y);
                if (self.shift_held) {
                    self.camera.panPixels(dx, dy);
                } else {
                    self.camera.rotate(dx * 0.005, dy * 0.005);
                }
            }
            self.mouse_dragging = true;
        } else {
            self.mouse_dragging = false;
        }
        self.last_mouse_x = mx;
        self.last_mouse_y = my;
    }

    pub fn handleScroll(self: *App, y_offset: f64) void {
        const factor: f32 = if (y_offset > 0) 1.1 else 1.0 / 1.1;
        self.camera.zoom(factor);
    }

    pub fn renderFrame(self: *App, gctx: *zgpu.GraphicsContext, window: *zglfw.Window) void {
        const fb_size = gctx.window_provider.fn_getFramebufferSize(gctx.window_provider.window);
        const fb_w = fb_size[0];
        const fb_h = fb_size[1];
        if (fb_w == 0 or fb_h == 0) return;

        const win_size = window.getSize();
        const win_w: u32 = @intCast(win_size[0]);
        const win_h: u32 = @intCast(win_size[1]);
        if (win_w == 0 or win_h == 0) return;

        // 1. Begin ImGui frame
        self.win_w = @floatFromInt(win_w);
        self.win_h = @floatFromInt(win_h);
        zgui.backend.newFrame(win_w, win_h);

        // 2. Draw UI
        self.drawLeftSidebar();
        self.drawBottomPanel();
        self.drawRightPanel();

        // 3. Handle camera input after UI
        self.handleInputEvent(window);

        // 4. Update renderer state
        self.renderer.updateCamera(&self.camera, fb_w, fb_h);
        self.syncUniforms();

        if (self.transfer_preset == .default) {
            const tf = transfer_fn.TransferFunction.fromBands(&self.bands);
            self.renderer.uploadTransferFunction(&tf);
        }

        if (self.volumes.items.len > 0 and self.show_threats) {
            const vol = &self.volumes.items[self.active_volume];
            self.renderer.updateThreatLines(&self.camera, vol.threats, vol);
        }

        // 5. GPU render — always finish the ImGui frame
        const encoder = gctx.device.createCommandEncoder(null);
        const back_buffer_view = gctx.swapchain.getCurrentTextureView();
        const pass = self.renderer.render(encoder, back_buffer_view);
        zgui.backend.draw(pass);
        pass.end();
        pass.release();
        back_buffer_view.release();

        var cmd_buf = encoder.finish(null);
        gctx.submit(&.{cmd_buf});
        cmd_buf.release();
        encoder.release();

        _ = gctx.present();
    }

    // -------------------------------------------------------------------------
    // Left Sidebar — metadata, threats, view, help
    // -------------------------------------------------------------------------
    fn drawLeftSidebar(self: *App) void {
        const sidebar_w: f32 = 220;

        zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
        zgui.setNextWindowSize(.{ .w = sidebar_w, .h = self.win_h });

        if (zgui.begin("##sidebar", .{ .flags = .{
            .no_move = true,
            .no_resize = true,
            .no_collapse = true,
            .no_title_bar = true,
        } })) {
            zgui.textColored(.{ 0.4, 0.7, 1.0, 1.0 }, "zoxel", .{});
            zgui.separator();
            zgui.spacing();

            // Metadata
            if (self.volumes.items.len > 0) {
                const vol = &self.volumes.items[self.active_volume];
                zgui.textColored(.{ 0.7, 0.7, 0.7, 1.0 }, "Metadata", .{});
                zgui.text("{d}x{d}x{d} ({s})", .{ vol.dim_x, vol.dim_y, vol.dim_z, vol.modality });
                zgui.text("{d} volume(s)", .{self.volumes.items.len});
                zgui.separator();
                zgui.spacing();
            }

            // Threats
            zgui.textColored(.{ 0.7, 0.7, 0.7, 1.0 }, "Threats", .{});
            _ = zgui.checkbox("Show threat boxes", .{ .v = &self.show_threats });
            if (self.volumes.items.len > 0) {
                const vol = &self.volumes.items[self.active_volume];
                if (vol.threats.len == 0) {
                    zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "No threats in selected volume", .{});
                } else {
                    for (vol.threats) |*threat| {
                        zgui.bulletText("{s} ({d:.2})", .{ threat.name, threat.confidence });
                    }
                }
            }
            zgui.separator();
            zgui.spacing();

            // View
            zgui.textColored(.{ 0.7, 0.7, 0.7, 1.0 }, "View", .{});
            zgui.spacing();
            const bw = (sidebar_w - 24) / 3.0;
            if (zgui.button("Axial", .{ .w = bw })) self.camera.setAxial();
            zgui.sameLine(.{});
            if (zgui.button("Coronal", .{ .w = bw })) self.camera.setCoronal();
            zgui.sameLine(.{});
            if (zgui.button("Sagittal", .{ .w = bw })) self.camera.setSagittal();
            zgui.separator();
            zgui.spacing();

            // Interaction key
            zgui.textColored(.{ 0.7, 0.7, 0.7, 1.0 }, "Interaction Key", .{});
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "LMB drag: Orbit 3D", .{});
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Shift + LMB drag: Pan 3D", .{});
            zgui.textColored(.{ 0.6, 0.6, 0.6, 1.0 }, "Mouse wheel: Zoom 3D", .{});
        }
        zgui.end();
    }

    // -------------------------------------------------------------------------
    // Bottom Panel — Rendering | Transfer | Lighting (3 columns)
    // -------------------------------------------------------------------------
    fn drawBottomPanel(self: *App) void {
        const sidebar_w: f32 = 220;
        const panel_h: f32 = 340;
        const total_w = self.win_w - sidebar_w;

        zgui.setNextWindowPos(.{ .x = sidebar_w, .y = self.win_h - panel_h });
        zgui.setNextWindowSize(.{ .w = total_w, .h = panel_h });

        if (zgui.begin("##bottom", .{ .flags = .{
            .no_move = true,
            .no_resize = true,
            .no_collapse = true,
            .no_title_bar = true,
        } })) {
            const col_w = (total_w - 36) / 3.0;

            // --- Column 1: Rendering ---
            if (zgui.beginChild("##rendering", .{ .w = col_w, .h = -1 })) {
                zgui.textColored(.{ 0.4, 0.7, 1.0, 1.0 }, "Rendering", .{});
                zgui.spacing();

                // Quality
                zgui.text("Quality:", .{});
                zgui.sameLine(.{});
                if (self.quality_idx == 0) zgui.textColored(.{ 0.2, 0.6, 1.0, 1.0 }, "Fast", .{}) else {
                    if (zgui.smallButton("Fast")) self.quality_idx = 0;
                }
                zgui.sameLine(.{});
                if (self.quality_idx == 1) zgui.textColored(.{ 0.2, 0.6, 1.0, 1.0 }, "Med", .{}) else {
                    if (zgui.smallButton("Med")) self.quality_idx = 1;
                }
                zgui.sameLine(.{});
                if (self.quality_idx == 2) zgui.textColored(.{ 0.2, 0.6, 1.0, 1.0 }, "High", .{}) else {
                    if (zgui.smallButton("High")) self.quality_idx = 2;
                }

                zgui.spacing();
                zgui.pushItemWidth(-55);
                _ = zgui.sliderFloat("WC", .{ .v = &self.window_center, .min = 0.0, .max = 65535.0 });
                _ = zgui.sliderFloat("WW", .{ .v = &self.window_width, .min = 1.0, .max = 65536.0 });
                _ = zgui.sliderFloat("Opacity", .{ .v = &self.opacity, .min = 0.0, .max = 1.0 });
                _ = zgui.sliderFloat("Density", .{ .v = &self.density_threshold, .min = 0.0, .max = 1.0 });
                zgui.popItemWidth();
            }
            zgui.endChild();

            zgui.sameLine(.{});

            // --- Column 2: Transfer ---
            if (zgui.beginChild("##transfer", .{ .w = col_w, .h = -1 })) {
                zgui.textColored(.{ 0.4, 0.7, 1.0, 1.0 }, "Transfer", .{});
                zgui.spacing();

                const tbw = (col_w - 18) / 3.0;
                if (self.transfer_preset == .default) {
                    zgui.textColored(.{ 0.2, 0.6, 1.0, 1.0 }, "Default", .{});
                } else {
                    if (zgui.button("Default##t", .{ .w = tbw })) self.setPreset(.default);
                }
                zgui.sameLine(.{});
                if (self.transfer_preset == .threat) {
                    zgui.textColored(.{ 0.2, 0.6, 1.0, 1.0 }, "Threat", .{});
                } else {
                    if (zgui.button("Threat##t", .{ .w = tbw })) self.setPreset(.threat);
                }
                zgui.sameLine(.{});
                if (self.transfer_preset == .monochrome) {
                    zgui.textColored(.{ 0.2, 0.6, 1.0, 1.0 }, "Mono", .{});
                } else {
                    if (zgui.button("Mono##t", .{ .w = tbw })) self.setPreset(.monochrome);
                }

                if (self.transfer_preset == .default) {
                    zgui.spacing();
                    self.drawBandRangeSlider();

                    zgui.spacing();
                    zgui.text("Band alpha", .{});
                    zgui.pushItemWidth(-60);
                    const color_ids = [_][:0]const u8{ "##ac0", "##ac1", "##ac2", "##ac3", "##ac4" };
                    const slider_ids = [_][:0]const u8{ "Air##a", "Organic##a", "Inorg.##a", "Metal##a", "Dense##a" };
                    for (&self.bands, 0..) |*band, i| {
                        const color = [4]f32{
                            @as(f32, @floatFromInt(band.color[0])) / 255.0,
                            @as(f32, @floatFromInt(band.color[1])) / 255.0,
                            @as(f32, @floatFromInt(band.color[2])) / 255.0,
                            1.0,
                        };
                        _ = zgui.colorButton(color_ids[i], .{ .col = color, .w = 10, .h = 10 });
                        zgui.sameLine(.{});
                        _ = zgui.sliderFloat(slider_ids[i], .{ .v = &band.alpha, .min = 0.0, .max = 2.0 });
                    }
                    zgui.popItemWidth();
                }
            }
            zgui.endChild();

            zgui.sameLine(.{});

            // --- Column 3: Lighting ---
            if (zgui.beginChild("##lighting", .{ .w = col_w, .h = -1 })) {
                zgui.textColored(.{ 0.4, 0.7, 1.0, 1.0 }, "Lighting", .{});
                zgui.spacing();
                zgui.pushItemWidth(-60);
                _ = zgui.sliderFloat("Ambient", .{ .v = &self.lighting_ambient, .min = 0.0, .max = 1.0 });
                _ = zgui.sliderFloat("Diffuse", .{ .v = &self.lighting_diffuse, .min = 0.0, .max = 1.0 });
                _ = zgui.sliderFloat("Specular", .{ .v = &self.lighting_specular, .min = 0.0, .max = 1.0 });
                zgui.popItemWidth();
            }
            zgui.endChild();
        }
        zgui.end();
    }

    // -------------------------------------------------------------------------
    // Right Panel — 2D Slice view
    // -------------------------------------------------------------------------
    fn drawRightPanel(self: *App) void {
        const panel_w: f32 = 320;
        const bottom_h: f32 = 340;
        const panel_x = self.win_w - panel_w;

        zgui.setNextWindowPos(.{ .x = panel_x, .y = 0 });
        zgui.setNextWindowSize(.{ .w = panel_w, .h = self.win_h - bottom_h });

        if (zgui.begin("2D Slice", .{ .flags = .{
            .no_move = true,
            .no_resize = true,
            .no_collapse = true,
        } })) {
            if (self.volumes.items.len == 0) {
                zgui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "No volume loaded", .{});
            } else {
                const vol = &self.volumes.items[self.active_volume];

                // Slice image
                if (self.slice_dirty) {
                    self.updateSliceTexture();
                    self.slice_dirty = false;
                }
                // Slice image placeholder (TODO: fix TextureRef for WebGPU backend)
                {
                    const avail = zgui.getContentRegionAvail();
                    const img_h = avail[1] - 120;
                    if (img_h > 10) {
                        // Draw a dark rect as placeholder
                        const pos = zgui.getCursorScreenPos();
                        const draw_list = zgui.getWindowDrawList();
                        draw_list.addRectFilled(.{
                            .pmin = pos,
                            .pmax = .{ pos[0] + avail[0], pos[1] + img_h },
                            .col = zgui.colorConvertFloat4ToU32(.{ 0.15, 0.15, 0.15, 1.0 }),
                        });

                        // Render slice info text on top
                        if (self.slice_w > 0 and self.slice_h > 0) {
                            const ori = self.slice_view.orientation.label();
                            draw_list.addText(.{ pos[0] + 8, pos[1] + 8 }, zgui.colorConvertFloat4ToU32(.{ 0.7, 0.7, 0.7, 1.0 }), "{s}", .{ori});
                        }

                        zgui.dummy(.{ .w = avail[0], .h = img_h });
                    }
                }

                zgui.separator();

                // Orientation
                const obw = (panel_w - 24) / 3.0;
                if (zgui.button("Axial##sv", .{ .w = obw })) {
                    self.slice_orientation = 0;
                    self.updateSliceOrientation(vol);
                }
                zgui.sameLine(.{});
                if (zgui.button("Coronal##sv", .{ .w = obw })) {
                    self.slice_orientation = 1;
                    self.updateSliceOrientation(vol);
                }
                zgui.sameLine(.{});
                if (zgui.button("Sagittal##sv", .{ .w = obw })) {
                    self.slice_orientation = 2;
                    self.updateSliceOrientation(vol);
                }

                // Slice slider
                const max_slice: i32 = @intCast(self.slice_view.max_slices -| 1);
                zgui.pushItemWidth(-40);
                _ = zgui.sliderInt("Slice", .{ .v = &self.slice_index, .min = 0, .max = max_slice });
                _ = zgui.sliderFloat("W/L", .{ .v = &self.window_center, .min = 0.0, .max = 65535.0 });
                _ = zgui.sliderFloat("W/W", .{ .v = &self.window_width, .min = 1.0, .max = 65536.0 });
                zgui.popItemWidth();
            }
        }
        zgui.end();
    }

    // -------------------------------------------------------------------------
    // Custom band range slider — colored bar with draggable threshold handles
    // -------------------------------------------------------------------------
    fn drawBandRangeSlider(self: *App) void {
        const max_density: f32 = 35000.0;
        const avail_w = zgui.getContentRegionAvail()[0];
        const widget_w = @max(avail_w, 180.0);
        const widget_h: f32 = 78.0;
        const pad: f32 = 8.0;

        const cursor = zgui.getCursorScreenPos();

        // Use an invisible button as the interaction area for the whole widget
        _ = zgui.invisibleButton("##band_slider", .{ .w = widget_w, .h = widget_h });
        const is_hovered = zgui.isItemHovered(.{});
        const is_active = zgui.isItemActive();

        const draw_list = zgui.getWindowDrawList();
        const track_top = cursor[1] + widget_h - 28.0;
        const track_bot = cursor[1] + widget_h - 16.0;
        const track_left = cursor[0] + pad;
        const track_right = cursor[0] + widget_w - pad;
        const track_w = track_right - track_left;

        // Handle drag interaction
        const mouse = zgui.getMousePos();
        if (is_active) {
            // Find or continue dragging nearest handle
            if (self.active_band_handle < 0) {
                // Find nearest handle on click
                var nearest: i32 = -1;
                var nearest_dist: f32 = 20.0; // max grab distance
                for (0..4) |i| {
                    const hx = track_left + (@as(f32, @floatFromInt(self.band_thresholds[i])) / max_density) * track_w;
                    const dist = @abs(mouse[0] - hx);
                    if (dist < nearest_dist) {
                        nearest_dist = dist;
                        nearest = @intCast(i);
                    }
                }
                self.active_band_handle = nearest;
            }

            if (self.active_band_handle >= 0) {
                const idx: usize = @intCast(self.active_band_handle);
                const t = std.math.clamp((mouse[0] - track_left) / track_w, 0.0, 1.0);
                var new_val: i32 = @intFromFloat(t * max_density);

                const lower: i32 = if (idx == 0) 0 else self.band_thresholds[idx - 1];
                const upper: i32 = if (idx + 1 < 4) self.band_thresholds[idx + 1] else @intFromFloat(max_density);
                new_val = std.math.clamp(new_val, lower, upper);

                self.band_thresholds[idx] = new_val;
                self.bands[idx].threshold = @intCast(@as(u32, @intCast(new_val)));
            }
        } else {
            self.active_band_handle = -1;
        }
        _ = is_hovered;

        // Draw track background
        draw_list.addRectFilled(.{
            .pmin = .{ track_left, track_top },
            .pmax = .{ track_right, track_bot },
            .col = zgui.colorConvertFloat4ToU32(.{ 0.2, 0.2, 0.2, 1.0 }),
            .rounding = 3.0,
        });

        // Draw colored band segments
        for (0..5) |i| {
            const start: f32 = if (i == 0) 0.0 else @floatFromInt(self.band_thresholds[i - 1]);
            const end: f32 = @floatFromInt(self.band_thresholds[i]);
            const sx = track_left + (start / max_density) * track_w;
            const ex = track_left + (end / max_density) * track_w;
            if (ex <= sx) continue;

            var r = @as(f32, @floatFromInt(self.bands[i].color[0])) / 255.0;
            var g = @as(f32, @floatFromInt(self.bands[i].color[1])) / 255.0;
            var b = @as(f32, @floatFromInt(self.bands[i].color[2])) / 255.0;
            if (self.bands[i].is_transparent) {
                r *= 0.25;
                g *= 0.25;
                b *= 0.25;
            }

            draw_list.addRectFilled(.{
                .pmin = .{ sx, track_top },
                .pmax = .{ ex, track_bot },
                .col = zgui.colorConvertFloat4ToU32(.{ r, g, b, 1.0 }),
                .rounding = 2.0,
            });

            // Band name below track
            if (ex - sx > 28.0) {
                const name = self.bands[i].name;
                draw_list.addText(.{ (sx + ex) * 0.5 - 12.0, track_bot + 2.0 }, zgui.colorConvertFloat4ToU32(.{ 0.7, 0.7, 0.7, 1.0 }), "{s}", .{name});
            }
        }

        // Draw threshold handles and values
        for (0..4) |i| {
            const hx = track_left + (@as(f32, @floatFromInt(self.band_thresholds[i])) / max_density) * track_w;
            const cy = (track_top + track_bot) * 0.5;
            const is_dragging = self.active_band_handle == @as(i32, @intCast(i));

            const handle_col = if (is_dragging)
                zgui.colorConvertFloat4ToU32(.{ 0.3, 0.7, 1.0, 1.0 })
            else
                zgui.colorConvertFloat4ToU32(.{ 0.9, 0.9, 0.9, 1.0 });

            draw_list.addCircleFilled(.{ .p = .{ hx, cy }, .r = 6.0, .col = handle_col });
            draw_list.addCircle(.{ .p = .{ hx, cy }, .r = 6.0, .col = zgui.colorConvertFloat4ToU32(.{ 0.4, 0.4, 0.4, 1.0 }) });

            // Threshold value above
            draw_list.addText(.{ hx - 14.0, track_top - 14.0 }, zgui.colorConvertFloat4ToU32(.{ 0.8, 0.8, 0.8, 1.0 }), "{d}", .{self.band_thresholds[i]});
        }
    }

    fn updateSliceOrientation(self: *App, vol: *const volume_mod.Volume) void {
        self.slice_view.orientation = switch (self.slice_orientation) {
            1 => .coronal,
            2 => .sagittal,
            else => .axial,
        };
        self.slice_view.updateForVolume(vol);
        self.slice_index = @intCast(self.slice_view.max_slices / 2);
        self.slice_dirty = true;
    }

    fn updateSliceTexture(self: *App) void {
        if (self.volumes.items.len == 0) return;
        const vol = &self.volumes.items[self.active_volume];

        self.slice_view.slice_index = @intCast(@as(u32, @intCast(@max(self.slice_index, 0))));
        self.slice_view.window_center = self.window_center;
        self.slice_view.window_width = self.window_width;

        const pixels = self.slice_view.renderSlice(self.allocator, vol) catch return;
        defer self.allocator.free(pixels);

        const dims = self.slice_view.orientation.sliceDims(vol);
        if (dims.w == 0 or dims.h == 0) return;

        if (self.slice_texv) |h| self.renderer.gctx.releaseResource(h);
        if (self.slice_tex) |h| self.renderer.gctx.releaseResource(h);

        const w: u32 = @intCast(dims.w);
        const h: u32 = @intCast(dims.h);

        const tex = self.renderer.gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{ .width = w, .height = h },
            .format = .rgba8_unorm,
        });
        self.slice_tex = tex;
        self.slice_texv = self.renderer.gctx.createTextureView(tex, .{});
        self.slice_w = w;
        self.slice_h = h;

        self.renderer.gctx.queue.writeTexture(
            .{ .texture = self.renderer.gctx.lookupResource(tex).? },
            .{ .bytes_per_row = w * 4, .rows_per_image = h },
            .{ .width = w, .height = h },
            u8,
            pixels,
        );
    }

    fn setPreset(self: *App, preset: transfer_fn.TransferPreset) void {
        self.transfer_preset = preset;
        if (preset == .default) {
            self.bands = transfer_fn.defaultBands();
            for (self.bands, 0..) |band, i| {
                self.band_thresholds[i] = @intCast(band.threshold);
            }
        }
        const tf = transfer_fn.TransferFunction.fromPreset(preset);
        self.renderer.uploadTransferFunction(&tf);
    }
};
