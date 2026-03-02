//! GPU volume rendering pipeline using zgpu (WebGPU via Dawn).

const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const camera_mod = @import("camera.zig");
const volume_mod = @import("volume.zig");
const transfer_fn = @import("transfer_fn.zig");

/// Quality presets for ray-casting step size.
pub const Quality = enum {
    low,
    medium,
    high,
    ultra,

    pub fn stepSize(self: Quality) f32 {
        return switch (self) {
            .low => 0.004,
            .medium => 0.002,
            .high => 0.001,
            .ultra => 0.0005,
        };
    }
};

/// Per-frame uniform data sent to the ray-casting shader.
pub const Uniforms = extern struct {
    cam_pos: [3]f32 = .{ 0, 0, 0 },
    fov: f32 = 0.8,
    cam_forward: [3]f32 = .{ 0, 0, -1 },
    aspect_ratio: f32 = 1.0,
    cam_right: [3]f32 = .{ 1, 0, 0 },
    step_size: f32 = 0.002,
    cam_up: [3]f32 = .{ 0, 1, 0 },
    scale_z: f32 = 1.0,
    window_min: f32 = 0.0,
    window_range: f32 = 65535.0,
    alpha_scale: f32 = 1.0,
    rescale_intercept: f32 = 0.0,
    density_threshold: f32 = 0.0,
    ambient_intensity: f32 = 0.4,
    diffuse_intensity: f32 = 0.6,
    specular_intensity: f32 = 0.2,
};

/// Overlay line vertex: 2D NDC position + RGBA color.
const LineVertex = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

/// GPU volume renderer.
pub const VolumeRenderer = struct {
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    quality: Quality,
    uniforms: Uniforms,

    // Ray-cast pipeline resources
    raycast_pipeline: zgpu.RenderPipelineHandle,
    bind_group_layout: zgpu.BindGroupLayoutHandle,
    bind_group: ?zgpu.BindGroupHandle,
    uniform_buf: zgpu.BufferHandle,
    volume_tex: ?zgpu.TextureHandle,
    volume_texv: ?zgpu.TextureViewHandle,
    volume_sampler: zgpu.SamplerHandle,
    transfer_tex: ?zgpu.TextureHandle,
    transfer_texv: ?zgpu.TextureViewHandle,
    transfer_sampler: zgpu.SamplerHandle,

    // Overlay line pipeline resources
    line_pipeline: zgpu.RenderPipelineHandle,
    line_buf: zgpu.BufferHandle,
    line_vertex_count: u32,

    pub fn init(allocator: std.mem.Allocator, gctx: *zgpu.GraphicsContext) VolumeRenderer {
        // --- Bind group layout (matches raycast.wgsl @group(0)) ---
        const bgl = gctx.createBindGroupLayout(&[_]wgpu.BindGroupLayoutEntry{
            .{
                .binding = 0,
                .visibility = .{ .vertex = true, .fragment = true },
                .buffer = .{ .binding_type = .uniform },
            },
            .{
                .binding = 1,
                .visibility = .{ .fragment = true },
                .texture = .{
                    .sample_type = .float,
                    .view_dimension = .tvdim_3d,
                },
            },
            .{
                .binding = 2,
                .visibility = .{ .fragment = true },
                .sampler = .{ .binding_type = .filtering },
            },
            .{
                .binding = 3,
                .visibility = .{ .fragment = true },
                .texture = .{
                    .sample_type = .unfilterable_float,
                    .view_dimension = .tvdim_2d,
                },
            },
            .{
                .binding = 4,
                .visibility = .{ .fragment = true },
                .sampler = .{ .binding_type = .non_filtering },
            },
        });

        const pl = gctx.createPipelineLayout(&[_]zgpu.BindGroupLayoutHandle{bgl});

        // --- Raycast pipeline ---
        const raycast_wgsl = @embedFile("raycast.wgsl");
        const raycast_sm = zgpu.createWgslShaderModule(gctx.device, raycast_wgsl, "raycast");
        defer raycast_sm.release();

        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
        }};

        const raycast_pipeline = gctx.createRenderPipeline(pl, .{
            .vertex = .{ .module = raycast_sm, .entry_point = "vs_main" },
            .fragment = &.{
                .module = raycast_sm,
                .entry_point = "fs_main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        });

        // --- Line overlay pipeline ---
        const line_wgsl = @embedFile("overlay_lines.wgsl");
        const line_sm = zgpu.createWgslShaderModule(gctx.device, line_wgsl, "overlay_lines");
        defer line_sm.release();

        const line_attrs = [_]wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = @offsetOf(LineVertex, "color"), .shader_location = 1 },
        };
        const line_bufs = [_]wgpu.VertexBufferLayout{.{
            .array_stride = @sizeOf(LineVertex),
            .attribute_count = line_attrs.len,
            .attributes = &line_attrs,
        }};

        const blend_state = wgpu.BlendState{
            .color = .{
                .operation = .add,
                .src_factor = .src_alpha,
                .dst_factor = .one_minus_src_alpha,
            },
            .alpha = .{
                .operation = .add,
                .src_factor = .one,
                .dst_factor = .one_minus_src_alpha,
            },
        };

        const line_color_targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &blend_state,
        }};

        const line_pl = gctx.createPipelineLayout(&[_]zgpu.BindGroupLayoutHandle{});
        const line_pipeline = gctx.createRenderPipeline(line_pl, .{
            .vertex = .{
                .module = line_sm,
                .entry_point = "vs_main",
                .buffer_count = line_bufs.len,
                .buffers = &line_bufs,
            },
            .primitive = .{ .topology = .line_list },
            .fragment = &.{
                .module = line_sm,
                .entry_point = "fs_main",
                .target_count = line_color_targets.len,
                .targets = &line_color_targets,
            },
        });

        // --- GPU buffers ---
        const uniform_buf = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .uniform = true },
            .size = @sizeOf(Uniforms),
        });

        const line_buf = gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = 2 * 1024 * 1024, // 2 MiB
        });

        // --- Samplers ---
        const volume_sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        const transfer_sampler = gctx.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });

        return .{
            .gctx = gctx,
            .allocator = allocator,
            .quality = .medium,
            .uniforms = .{},
            .raycast_pipeline = raycast_pipeline,
            .bind_group_layout = bgl,
            .bind_group = null,
            .uniform_buf = uniform_buf,
            .volume_tex = null,
            .volume_texv = null,
            .volume_sampler = volume_sampler,
            .transfer_tex = null,
            .transfer_texv = null,
            .transfer_sampler = transfer_sampler,
            .line_pipeline = line_pipeline,
            .line_buf = line_buf,
            .line_vertex_count = 0,
        };
    }

    pub fn deinit(self: *VolumeRenderer) void {
        if (self.bind_group) |h| self.gctx.releaseResource(h);
        if (self.volume_texv) |h| self.gctx.releaseResource(h);
        if (self.volume_tex) |h| self.gctx.releaseResource(h);
        if (self.transfer_texv) |h| self.gctx.releaseResource(h);
        if (self.transfer_tex) |h| self.gctx.releaseResource(h);
        self.gctx.releaseResource(self.uniform_buf);
        self.gctx.releaseResource(self.volume_sampler);
        self.gctx.releaseResource(self.transfer_sampler);
        self.gctx.releaseResource(self.line_buf);
        self.gctx.releaseResource(self.raycast_pipeline);
        self.gctx.releaseResource(self.line_pipeline);
        self.gctx.releaseResource(self.bind_group_layout);
    }

    /// Upload a volume's GPU-packed data as a 3D texture.
    pub fn uploadVolume(self: *VolumeRenderer, vol: *const volume_mod.Volume) !void {
        const gpu_data = try vol.packForGpu(self.allocator);
        defer self.allocator.free(gpu_data);

        // Release old resources
        if (self.volume_texv) |h| self.gctx.releaseResource(h);
        if (self.volume_tex) |h| self.gctx.releaseResource(h);
        if (self.bind_group) |h| self.gctx.releaseResource(h);

        const tex = self.gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .dimension = .tdim_3d,
            .size = .{
                .width = @intCast(vol.dim_x),
                .height = @intCast(vol.dim_y),
                .depth_or_array_layers = @intCast(vol.dim_z),
            },
            .format = .rgba16_float,
        });
        self.volume_tex = tex;

        const texv = self.gctx.createTextureView(tex, .{});
        self.volume_texv = texv;

        // Write data to texture via queue
        self.gctx.queue.writeTexture(
            .{ .texture = self.gctx.lookupResource(tex).? },
            .{
                .bytes_per_row = @intCast(vol.dim_x * 8), // 4 × f16 = 8 bytes
                .rows_per_image = @intCast(vol.dim_y),
            },
            .{
                .width = @intCast(vol.dim_x),
                .height = @intCast(vol.dim_y),
                .depth_or_array_layers = @intCast(vol.dim_z),
            },
            u8,
            gpu_data,
        );

        self.rebuildBindGroup();
    }

    /// Upload a transfer function as a 1024×1 texture.
    pub fn uploadTransferFunction(self: *VolumeRenderer, tf: *const transfer_fn.TransferFunction) void {
        // Release old resources
        if (self.transfer_texv) |h| self.gctx.releaseResource(h);
        if (self.transfer_tex) |h| self.gctx.releaseResource(h);
        if (self.bind_group) |h| {
            self.gctx.releaseResource(h);
            self.bind_group = null;
        }

        const tex = self.gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{ .width = transfer_fn.TRANSFER_SIZE, .height = 1 },
            .format = .rgba32_float,
        });
        self.transfer_tex = tex;

        const texv = self.gctx.createTextureView(tex, .{});
        self.transfer_texv = texv;

        self.gctx.queue.writeTexture(
            .{ .texture = self.gctx.lookupResource(tex).? },
            .{
                .bytes_per_row = transfer_fn.TRANSFER_SIZE * 16, // 4 × f32 = 16 bytes
                .rows_per_image = 1,
            },
            .{ .width = transfer_fn.TRANSFER_SIZE, .height = 1 },
            [4]f32,
            &tf.data,
        );

        self.rebuildBindGroup();
    }

    fn rebuildBindGroup(self: *VolumeRenderer) void {
        const vtv = self.volume_texv orelse return;
        const ttv = self.transfer_texv orelse return;

        if (self.bind_group) |h| self.gctx.releaseResource(h);

        self.bind_group = self.gctx.createBindGroup(
            self.bind_group_layout,
            &[_]zgpu.BindGroupEntryInfo{
                .{ .binding = 0, .buffer_handle = self.uniform_buf, .offset = 0, .size = @sizeOf(Uniforms) },
                .{ .binding = 1, .texture_view_handle = vtv },
                .{ .binding = 2, .sampler_handle = self.volume_sampler },
                .{ .binding = 3, .texture_view_handle = ttv },
                .{ .binding = 4, .sampler_handle = self.transfer_sampler },
            },
        );
    }

    pub fn updateCamera(self: *VolumeRenderer, cam: *const camera_mod.Camera, width: u32, height: u32) void {
        const pos = cam.position();
        const fwd = cam.forward();
        const rgt = cam.right();
        const upv = cam.up();
        self.uniforms.cam_pos = .{ pos.x, pos.y, pos.z };
        self.uniforms.cam_forward = .{ fwd.x, fwd.y, fwd.z };
        self.uniforms.cam_right = .{ rgt.x, rgt.y, rgt.z };
        self.uniforms.cam_up = .{ upv.x, upv.y, upv.z };
        self.uniforms.fov = cam.fov;
        self.uniforms.aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(@max(height, 1)));
        self.uniforms.step_size = self.quality.stepSize();
    }

    /// Upload threat overlay lines for the current camera view.
    pub fn updateThreatLines(self: *VolumeRenderer, cam: *const camera_mod.Camera, threats: []const volume_mod.ThreatBox, vol: *const volume_mod.Volume) void {
        var vertices: [4096]LineVertex = undefined;
        var count: u32 = 0;

        for (threats) |threat| {
            if (!threat.enabled) continue;
            const color = [4]f32{
                @as(f32, @floatFromInt(threat.color[0])) / 255.0,
                @as(f32, @floatFromInt(threat.color[1])) / 255.0,
                @as(f32, @floatFromInt(threat.color[2])) / 255.0,
                0.8,
            };

            // Normalize corners to [0,1] volume space
            const min_n = [3]f32{
                @as(f32, @floatFromInt(threat.min[0])) / @as(f32, @floatFromInt(@max(vol.dim_x, 1))),
                @as(f32, @floatFromInt(threat.min[1])) / @as(f32, @floatFromInt(@max(vol.dim_y, 1))),
                @as(f32, @floatFromInt(threat.min[2])) / @as(f32, @floatFromInt(@max(vol.dim_z, 1))) * self.uniforms.scale_z,
            };
            const max_n = [3]f32{
                @as(f32, @floatFromInt(threat.max[0])) / @as(f32, @floatFromInt(@max(vol.dim_x, 1))),
                @as(f32, @floatFromInt(threat.max[1])) / @as(f32, @floatFromInt(@max(vol.dim_y, 1))),
                @as(f32, @floatFromInt(threat.max[2])) / @as(f32, @floatFromInt(@max(vol.dim_z, 1))) * self.uniforms.scale_z,
            };

            // 8 corners of the box
            const corners = [8][3]f32{
                .{ min_n[0], min_n[1], min_n[2] },
                .{ max_n[0], min_n[1], min_n[2] },
                .{ min_n[0], max_n[1], min_n[2] },
                .{ max_n[0], max_n[1], min_n[2] },
                .{ min_n[0], min_n[1], max_n[2] },
                .{ max_n[0], min_n[1], max_n[2] },
                .{ min_n[0], max_n[1], max_n[2] },
                .{ max_n[0], max_n[1], max_n[2] },
            };

            // 12 edges
            const edges = [12][2]u8{
                .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 },
                .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 },
                .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
            };

            for (edges) |edge| {
                if (count + 2 > vertices.len) break;
                const p0 = projectToNdc(cam, corners[edge[0]]);
                const p1 = projectToNdc(cam, corners[edge[1]]);
                if (p0[2] < 0 or p1[2] < 0) continue; // behind camera
                vertices[count] = .{ .pos = .{ p0[0], p0[1] }, .color = color };
                count += 1;
                vertices[count] = .{ .pos = .{ p1[0], p1[1] }, .color = color };
                count += 1;
            }
        }

        self.line_vertex_count = count;
        if (count > 0) {
            self.gctx.queue.writeBuffer(
                self.gctx.lookupResource(self.line_buf).?,
                0,
                LineVertex,
                vertices[0..count],
            );
        }
    }

    fn projectToNdc(cam: *const camera_mod.Camera, point: [3]f32) [3]f32 {
        const cp = cam.position();
        const fwd = cam.forward();
        const rgt = cam.right();
        const upv = cam.up();

        const dx = point[0] - cp.x;
        const dy = point[1] - cp.y;
        const dz = point[2] - cp.z;

        const depth = dx * fwd.x + dy * fwd.y + dz * fwd.z;
        if (depth <= 0.0) return .{ 0, 0, -1 };

        const rx = dx * rgt.x + dy * rgt.y + dz * rgt.z;
        const ry = dx * upv.x + dy * upv.y + dz * upv.z;

        const ndc_x = rx / (depth * cam.fov);
        const ndc_y = ry / (depth * cam.fov);

        return .{ ndc_x, -ndc_y, depth };
    }

    /// Render the volume and overlays. Returns the render pass for zgui to draw into.
    pub fn render(self: *VolumeRenderer, encoder: wgpu.CommandEncoder, back_buffer_view: wgpu.TextureView) wgpu.RenderPassEncoder {
        // Upload uniforms
        self.gctx.queue.writeBuffer(
            self.gctx.lookupResource(self.uniform_buf).?,
            0,
            Uniforms,
            &[_]Uniforms{self.uniforms},
        );

        const pass = zgpu.beginRenderPassSimple(encoder, .clear, back_buffer_view, .{ .r = 0.84, .g = 0.84, .b = 0.84, .a = 1.0 }, null, null);

        // Draw volume ray-cast (full-screen triangle)
        if (self.bind_group) |bg| {
            if (self.gctx.lookupResource(self.raycast_pipeline)) |pipeline| {
                pass.setPipeline(pipeline);
                pass.setBindGroup(0, self.gctx.lookupResource(bg).?, null);
                pass.draw(3, 1, 0, 0);
            }
        }

        // Draw threat overlay lines
        if (self.line_vertex_count > 0) {
            if (self.gctx.lookupResource(self.line_pipeline)) |pipeline| {
                pass.setPipeline(pipeline);
                pass.setVertexBuffer(0, self.gctx.lookupResource(self.line_buf).?, 0, self.line_vertex_count * @sizeOf(LineVertex));
                pass.draw(self.line_vertex_count, 1, 0, 0);
            }
        }

        return pass;
    }
};
