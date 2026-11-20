//! WebGPU ray-casting volume renderer (port of roxel `renderer.rs`).
//!
//! Owns the ray-cast and overlay-line pipelines, the RGBA16 density +
//! gradient 3D texture, the RGBA32F transfer table and the per-frame
//! uniforms. The fragment shader (`raycast.wgsl`) marches rays through the
//! physical volume box with transfer lookup, Phong lighting, a depth cue, a
//! cutaway plane and Beer-Lambert opacity correction.
//!
//! The volume format is chosen at run time: `Rgba16Unorm` where the device
//! has 16-bit normalized textures, otherwise `Rgba16Float` (always the case
//! through WebGPU, and through this Dawn build, whose binding exposes no
//! 16-bit unorm format). The shader decodes `texel.r * scale + offset`.

const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const camera_mod = @import("camera.zig");
const transfer = @import("transfer.zig");
const volume_mod = @import("volume.zig");
const state_mod = @import("state.zig");

const Vec3 = camera_mod.Vec3;
const Camera = camera_mod.Camera;

/// Matches the WGSL `Uniforms` struct (16-byte aligned, 144 bytes).
pub const Uniforms = extern struct {
    cam_pos: [3]f32,
    fov: f32,
    cam_forward: [3]f32,
    aspect_ratio: f32,
    cam_right: [3]f32,
    step_size: f32,
    cam_up: [3]f32,
    _camera_padding: f32 = 0,
    window_min: f32,
    window_range: f32,
    alpha_scale: f32,
    rescale_intercept: f32,
    density_threshold: f32,
    ambient_intensity: f32,
    diffuse_intensity: f32,
    specular_intensity: f32,
    clip_plane: [4]f32,
    depth_cue: f32,
    rescale_slope: f32,
    density_scale: f32,
    density_offset: f32,
    volume_extent: [3]f32,
    _extent_padding: f32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Uniforms) == 144);
    std.debug.assert(@offsetOf(Uniforms, "volume_extent") == 128);
    std.debug.assert(@offsetOf(Uniforms, "_extent_padding") == 140);
}

const LineVertex = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

pub const VolumeFormat = enum { rgba16_unorm, rgba16_float };

/// Convert packed u16 texels to texture bytes for `format` (caller frees).
/// `Rgba16Unorm` takes the packed values as-is. `Rgba16Float` gets
/// `v / 65535` as f16, except the density of signed volumes, uploaded as the
/// stored value itself (exact to +/-2048, far finer near 0).
pub fn volumeTexels(gpa: std.mem.Allocator, format: VolumeFormat, signed: bool, packed_buf: []const u16) ![]u16 {
    const out = try gpa.alloc(u16, packed_buf.len);
    switch (format) {
        .rgba16_unorm => @memcpy(out, packed_buf),
        .rgba16_float => for (packed_buf, 0..) |v, i| {
            const f: f32 = if (signed and i % 4 == 0)
                @as(f32, @floatFromInt(v)) - 32768.0
            else
                @as(f32, @floatFromInt(v)) / 65535.0;
            out[i] = @bitCast(@as(f16, @floatCast(f)));
        },
    }
    return out;
}

/// Shader decode `(scale, offset)`: `texel.r * scale + offset` is the stored
/// sample, matching `volumeTexels` and `Volume.packForGpu`.
pub fn densityDecode(format: VolumeFormat, signed: bool) [2]f32 {
    if (!signed) return .{ 65535.0, 0.0 };
    return switch (format) {
        .rgba16_unorm => .{ 65535.0, -32768.0 },
        .rgba16_float => .{ 1.0, 0.0 },
    };
}

pub const RenderParams = struct {
    camera: *const Camera,
    /// Viewport size in points (for the aspect ratio).
    viewport: [2]f32,
    /// Viewport rect in physical pixels: x, y, w, h.
    viewport_rect: [4]f32,
    clip_plane: ?[4]f32,
    threats: []const volume_mod.ThreatBox,
    show_threats: bool,
    settings: *const state_mod.RenderSettings,
};

const BG = wgpu.Color{ .r = 0.063, .g = 0.086, .b = 0.114, .a = 1.0 };
const LINE_CAPACITY: usize = (2 * 1024 * 1024) / @sizeOf(LineVertex);

pub const VolumeRenderer = struct {
    gctx: *zgpu.GraphicsContext,
    gpa: std.mem.Allocator,
    pipeline: zgpu.RenderPipelineHandle,
    line_pipeline: zgpu.RenderPipelineHandle,
    bind_group_layout: zgpu.BindGroupLayoutHandle,
    bind_group: ?zgpu.BindGroupHandle = null,
    uniform_buf: zgpu.BufferHandle,
    line_buf: zgpu.BufferHandle,
    volume_tex: ?zgpu.TextureHandle = null,
    volume_view: ?zgpu.TextureViewHandle = null,
    volume_format: VolumeFormat,
    transfer_tex: ?zgpu.TextureHandle = null,
    transfer_view: ?zgpu.TextureViewHandle = null,
    volume_sampler: zgpu.SamplerHandle,
    transfer_sampler: zgpu.SamplerHandle,
    rescale_intercept: f32 = 0,
    rescale_slope: f32 = 1,
    signed_pixels: bool = false,
    dims: [3]u32 = .{ 1, 1, 1 },
    volume_extent: Vec3 = Vec3.one,

    pub fn init(gpa: std.mem.Allocator, gctx: *zgpu.GraphicsContext, target_format: wgpu.TextureFormat) VolumeRenderer {
        // No 16-bit unorm format in this binding: always the float path.
        const volume_format: VolumeFormat = .rgba16_float;

        const bgl = gctx.createBindGroupLayout(&.{
            .{ .binding = 0, .visibility = .{ .fragment = true }, .buffer = .{ .binding_type = .uniform } },
            .{ .binding = 1, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .tvdim_3d } },
            .{ .binding = 2, .visibility = .{ .fragment = true }, .sampler = .{ .binding_type = .filtering } },
            .{ .binding = 3, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .tvdim_2d } },
            .{ .binding = 4, .visibility = .{ .fragment = true }, .sampler = .{ .binding_type = .filtering } },
        });
        const pl = gctx.createPipelineLayout(&.{bgl});
        defer gctx.releaseResource(pl);

        const sm = zgpu.createWgslShaderModule(gctx.device, @embedFile("raycast.wgsl"), "raycast");
        defer sm.release();
        const targets = [_]wgpu.ColorTargetState{.{ .format = target_format }};
        const pipeline = gctx.createRenderPipeline(pl, .{
            .vertex = .{ .module = sm, .entry_point = "vs_main" },
            .primitive = .{ .topology = .triangle_list },
            .fragment = &.{ .module = sm, .entry_point = "fs_main", .target_count = targets.len, .targets = &targets },
        });

        const lsm = zgpu.createWgslShaderModule(gctx.device, @embedFile("overlay_lines.wgsl"), "overlay_lines");
        defer lsm.release();
        const attrs = [_]wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = @offsetOf(LineVertex, "color"), .shader_location = 1 },
        };
        const vbufs = [_]wgpu.VertexBufferLayout{.{ .array_stride = @sizeOf(LineVertex), .attribute_count = attrs.len, .attributes = &attrs }};
        const blend = wgpu.BlendState{
            .color = .{ .operation = .add, .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .operation = .add, .src_factor = .one, .dst_factor = .one_minus_src_alpha },
        };
        const ltargets = [_]wgpu.ColorTargetState{.{ .format = target_format, .blend = &blend }};
        const lpl = gctx.createPipelineLayout(&.{});
        defer gctx.releaseResource(lpl);
        const line_pipeline = gctx.createRenderPipeline(lpl, .{
            .vertex = .{ .module = lsm, .entry_point = "vs_main", .buffer_count = vbufs.len, .buffers = &vbufs },
            .primitive = .{ .topology = .line_list },
            .fragment = &.{ .module = lsm, .entry_point = "fs_main", .target_count = ltargets.len, .targets = &ltargets },
        });

        return .{
            .gctx = gctx,
            .gpa = gpa,
            .pipeline = pipeline,
            .line_pipeline = line_pipeline,
            .bind_group_layout = bgl,
            .uniform_buf = gctx.createBuffer(.{ .usage = .{ .copy_dst = true, .uniform = true }, .size = @sizeOf(Uniforms) }),
            .line_buf = gctx.createBuffer(.{ .usage = .{ .copy_dst = true, .vertex = true }, .size = LINE_CAPACITY * @sizeOf(LineVertex) }),
            .volume_format = volume_format,
            .volume_sampler = gctx.createSampler(.{ .address_mode_u = .clamp_to_edge, .address_mode_v = .clamp_to_edge, .address_mode_w = .clamp_to_edge, .mag_filter = .linear, .min_filter = .linear }),
            .transfer_sampler = gctx.createSampler(.{ .address_mode_u = .clamp_to_edge, .address_mode_v = .clamp_to_edge, .mag_filter = .linear, .min_filter = .linear }),
        };
    }

    pub fn deinit(self: *VolumeRenderer) void {
        const g = self.gctx;
        if (self.bind_group) |h| g.releaseResource(h);
        if (self.volume_view) |h| g.releaseResource(h);
        if (self.volume_tex) |h| g.releaseResource(h);
        if (self.transfer_view) |h| g.releaseResource(h);
        if (self.transfer_tex) |h| g.releaseResource(h);
        g.releaseResource(self.uniform_buf);
        g.releaseResource(self.line_buf);
        g.releaseResource(self.volume_sampler);
        g.releaseResource(self.transfer_sampler);
        g.releaseResource(self.pipeline);
        g.releaseResource(self.line_pipeline);
        g.releaseResource(self.bind_group_layout);
    }

    pub fn isReady(self: *const VolumeRenderer) bool {
        return self.bind_group != null;
    }

    /// Upload a volume from a buffer packed by `Volume.packForGpu`.
    pub fn uploadVolumePacked(self: *VolumeRenderer, vol: *const volume_mod.Volume, packed_buf: []const u16) !void {
        const g = self.gctx;
        const dims = [3]u32{ @intCast(vol.dim_x), @intCast(vol.dim_y), @intCast(vol.dim_z) };
        const reuse = std.mem.eql(u32, &dims, &self.dims) and self.volume_tex != null;
        self.dims = dims;
        self.rescale_intercept = @floatCast(vol.rescale_intercept);
        self.rescale_slope = @floatCast(vol.rescale_slope);
        self.signed_pixels = vol.signed_pixels;
        self.volume_extent = camera_mod.physicalExtent(.{ vol.dim_x, vol.dim_y, vol.dim_z }, vol.voxel_spacing);

        const texels = try volumeTexels(self.gpa, self.volume_format, self.signed_pixels, packed_buf);
        defer self.gpa.free(texels);
        const size = wgpu.Extent3D{ .width = dims[0], .height = dims[1], .depth_or_array_layers = dims[2] };
        if (!reuse) {
            if (self.bind_group) |h| g.releaseResource(h);
            self.bind_group = null;
            if (self.volume_view) |h| g.releaseResource(h);
            if (self.volume_tex) |h| g.releaseResource(h);
            const tex = g.createTexture(.{
                .usage = .{ .texture_binding = true, .copy_dst = true },
                .dimension = .tdim_3d,
                .size = size,
                .format = switch (self.volume_format) {
                    .rgba16_float => .rgba16_float,
                    // Not reachable with this binding; kept for parity.
                    .rgba16_unorm => .rgba16_float,
                },
            });
            self.volume_tex = tex;
            self.volume_view = g.createTextureView(tex, .{});
        }
        g.queue.writeTexture(
            .{ .texture = g.lookupResource(self.volume_tex.?).? },
            .{ .bytes_per_row = dims[0] * 8, .rows_per_image = dims[1] },
            size,
            u16,
            texels,
        );
        self.rebuildBindGroup();
    }

    pub fn uploadVolume(self: *VolumeRenderer, vol: *const volume_mod.Volume) !void {
        const p = try vol.packForGpu(self.gpa);
        defer self.gpa.free(p);
        try self.uploadVolumePacked(vol, p);
    }

    /// Upload the transfer table. roxel uses RGBA32F with the
    /// float32-filterable feature; this Dawn build cannot request that, so
    /// the table is RGBA16F (filterable everywhere; values lie in 0..1 where
    /// f16 keeps about three significant digits).
    pub fn uploadTransferFunction(self: *VolumeRenderer, tf: *const transfer.TransferFunction) void {
        const g = self.gctx;
        const size = wgpu.Extent3D{ .width = transfer.TRANSFER_SIZE, .height = 1, .depth_or_array_layers = 1 };
        const fresh = self.transfer_tex == null;
        if (fresh) {
            const tex = g.createTexture(.{ .usage = .{ .texture_binding = true, .copy_dst = true }, .size = size, .format = .rgba16_float });
            self.transfer_tex = tex;
            self.transfer_view = g.createTextureView(tex, .{});
        }
        var halves: [transfer.TRANSFER_SIZE][4]f16 = undefined;
        for (tf.data, 0..) |e, i| {
            for (0..4) |c| halves[i][c] = @floatCast(e[c]);
        }
        g.queue.writeTexture(
            .{ .texture = g.lookupResource(self.transfer_tex.?).? },
            .{ .bytes_per_row = transfer.TRANSFER_SIZE * 8, .rows_per_image = 1 },
            size,
            [4]f16,
            &halves,
        );
        if (fresh) self.rebuildBindGroup();
    }

    fn rebuildBindGroup(self: *VolumeRenderer) void {
        const vv = self.volume_view orelse return;
        const tv = self.transfer_view orelse return;
        if (self.bind_group) |h| self.gctx.releaseResource(h);
        self.bind_group = self.gctx.createBindGroup(self.bind_group_layout, &.{
            .{ .binding = 0, .buffer_handle = self.uniform_buf, .offset = 0, .size = @sizeOf(Uniforms) },
            .{ .binding = 1, .texture_view_handle = vv },
            .{ .binding = 2, .sampler_handle = self.volume_sampler },
            .{ .binding = 3, .texture_view_handle = tv },
            .{ .binding = 4, .sampler_handle = self.transfer_sampler },
        });
    }

    /// Match the ray shader's camera model: shader `uv.y` grows downwards,
    /// so clip-space y is its negation.
    fn projectPoint(cam: *const Camera, point: Vec3, aspect: f32, extent: Vec3) ?[2]f32 {
        const world = point.mul(extent);
        const to = world.sub(cam.position());
        const depth = to.dot(cam.forward());
        if (depth <= 1e-5) return null;
        const dx = depth * cam.fov * @max(aspect, 0.01);
        const dy = depth * cam.fov;
        if (@abs(dx) <= 1e-8 or @abs(dy) <= 1e-8) return null;
        const ux = to.dot(cam.right()) / dx;
        const uy = to.dot(cam.up()) / dy;
        if (!std.math.isFinite(ux) or !std.math.isFinite(uy)) return null;
        return .{ ux, -uy };
    }

    fn buildThreatLines(self: *const VolumeRenderer, out: []LineVertex, threats: []const volume_mod.ThreatBox, cam: *const Camera, aspect: f32) usize {
        if (threats.len == 0) return 0;
        const dx: f32 = @floatFromInt(@max(self.dims[0] -| 1, 1));
        const dy: f32 = @floatFromInt(@max(self.dims[1] -| 1, 1));
        const dz: f32 = @floatFromInt(@max(self.dims[2] -| 1, 1));
        const edges = [12][2]u8{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 } };
        var n: usize = 0;
        for (threats) |t| {
            if (!t.enabled) continue;
            const x0 = std.math.clamp(@as(f32, @floatFromInt(t.min[0])) / dx, 0, 1);
            const y0 = std.math.clamp(@as(f32, @floatFromInt(t.min[1])) / dy, 0, 1);
            const z0 = std.math.clamp(@as(f32, @floatFromInt(t.min[2])) / dz, 0, 1);
            const x1 = std.math.clamp(@as(f32, @floatFromInt(t.max[0])) / dx, 0, 1);
            const y1 = std.math.clamp(@as(f32, @floatFromInt(t.max[1])) / dy, 0, 1);
            const z1 = std.math.clamp(@as(f32, @floatFromInt(t.max[2])) / dz, 0, 1);
            const corners = [8]Vec3{
                Vec3.init(x0, y0, z0), Vec3.init(x1, y0, z0), Vec3.init(x1, y1, z0), Vec3.init(x0, y1, z0),
                Vec3.init(x0, y0, z1), Vec3.init(x1, y0, z1), Vec3.init(x1, y1, z1), Vec3.init(x0, y1, z1),
            };
            const color = [4]f32{ @as(f32, @floatFromInt(t.color[0])) / 255.0, @as(f32, @floatFromInt(t.color[1])) / 255.0, @as(f32, @floatFromInt(t.color[2])) / 255.0, 1.0 };
            for (edges) |e| {
                if (n + 2 > out.len) return n;
                const pa = projectPoint(cam, corners[e[0]], aspect, self.volume_extent) orelse continue;
                const pb = projectPoint(cam, corners[e[1]], aspect, self.volume_extent) orelse continue;
                out[n] = .{ .pos = pa, .color = color };
                out[n + 1] = .{ .pos = pb, .color = color };
                n += 2;
            }
        }
        return n;
    }

    /// Clear `target` and ray-cast into the viewport rect.
    pub fn render(self: *VolumeRenderer, encoder: wgpu.CommandEncoder, target: wgpu.TextureView, params: ?RenderParams) void {
        const g = self.gctx;
        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{ .view = target, .load_op = .clear, .store_op = .store, .clear_value = BG }};
        const pass = encoder.beginRenderPass(.{ .color_attachment_count = color_attachments.len, .color_attachments = &color_attachments });
        defer {
            pass.end();
            pass.release();
        }
        const p = params orelse return;
        const bg = self.bind_group orelse return;
        const cam = p.camera;
        const s = p.settings;
        const voxel = self.volume_extent.div(Vec3.init(@floatFromInt(@max(self.dims[0], 1)), @floatFromInt(@max(self.dims[1], 1)), @floatFromInt(@max(self.dims[2], 1))));
        const zoom_factor = 1.0 / std.math.clamp(cam.distance, Camera.MIN_DISTANCE, Camera.MAX_DISTANCE);
        const mult: f32 = switch (s.quality) {
            .fast => 1.5,
            .medium => 1.0,
            .high => 0.5,
        };
        const step = std.math.clamp(voxel.minElement() * zoom_factor * mult, 0.0005, 0.02);
        const aspect = if (p.viewport[1] > 0) p.viewport[0] / p.viewport[1] else 1.0;
        const dec = densityDecode(self.volume_format, self.signed_pixels);
        const u = Uniforms{
            .cam_pos = cam.position().toArray(),
            .fov = cam.fov,
            .cam_forward = cam.forward().toArray(),
            .aspect_ratio = aspect,
            .cam_right = cam.right().toArray(),
            .step_size = step,
            .cam_up = cam.up().toArray(),
            .window_min = s.window_center - s.window_width * 0.5,
            .window_range = s.window_width,
            .alpha_scale = s.global_opacity,
            .rescale_intercept = self.rescale_intercept,
            .density_threshold = s.density_threshold,
            .ambient_intensity = s.ambient,
            .diffuse_intensity = s.diffuse,
            .specular_intensity = s.specular,
            .clip_plane = p.clip_plane orelse .{ 0, 0, 0, -1 },
            .depth_cue = s.depth_cue,
            .rescale_slope = self.rescale_slope,
            .density_scale = dec[0],
            .density_offset = dec[1],
            .volume_extent = self.volume_extent.toArray(),
        };
        g.queue.writeBuffer(g.lookupResource(self.uniform_buf).?, 0, Uniforms, &.{u});

        var lines: [4096]LineVertex = undefined;
        const nlines = if (p.show_threats) self.buildThreatLines(&lines, p.threats, cam, aspect) else 0;
        if (nlines > 0) g.queue.writeBuffer(g.lookupResource(self.line_buf).?, 0, LineVertex, lines[0..nlines]);

        const r = p.viewport_rect;
        if (r[2] < 1 or r[3] < 1) return;
        pass.setViewport(r[0], r[1], r[2], r[3], 0, 1);
        const pipe = g.lookupResource(self.pipeline) orelse return;
        pass.setPipeline(pipe);
        pass.setBindGroup(0, g.lookupResource(bg).?, null);
        pass.draw(3, 1, 0, 0);
        if (nlines > 1) {
            if (g.lookupResource(self.line_pipeline)) |lp| {
                pass.setPipeline(lp);
                pass.setVertexBuffer(0, g.lookupResource(self.line_buf).?, 0, nlines * @sizeOf(LineVertex));
                pass.draw(@intCast(nlines), 1, 0, 0);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (CPU only: texel conversion and decode)
// ---------------------------------------------------------------------------

fn decodeDensity(format: VolumeFormat, signed: bool, packed_buf: []const u16) !f32 {
    const t = try volumeTexels(std.testing.allocator, format, signed, packed_buf);
    defer std.testing.allocator.free(t);
    const dec = densityDecode(format, signed);
    const texel: f32 = switch (format) {
        .rgba16_unorm => @as(f32, @floatFromInt(t[0])) / 65535.0,
        .rgba16_float => @floatCast(@as(f16, @bitCast(t[0]))),
    };
    return texel * dec[0] + dec[1];
}

test "density upload and decode round trip" {
    for ([_]i16{ -32768, -1000, -17, -1, 0, 1, 40, 2047 }) |stored| {
        const p = [4]u16{ @as(u16, @bitCast(stored)) ^ 0x8000, 0, 0, 0 };
        try std.testing.expect(@abs(try decodeDensity(.rgba16_unorm, true, &p) - @as(f32, @floatFromInt(stored))) < 0.01);
        try std.testing.expectEqual(@as(f32, @floatFromInt(stored)), try decodeDensity(.rgba16_float, true, &p));
    }
    for ([_]u16{ 0, 1, 40000, 65535 }) |stored| {
        const p = [4]u16{ stored, 0, 0, 0 };
        try std.testing.expect(@abs(try decodeDensity(.rgba16_unorm, false, &p) - @as(f32, @floatFromInt(stored))) < 0.01);
    }
}
