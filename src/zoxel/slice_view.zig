//! CPU-based 2D slice renderer for volume data.

const std = @import("std");
const volume_mod = @import("volume.zig");

const Volume = volume_mod.Volume;

/// Slice orientation through the volume.
pub const Orientation = enum {
    axial,
    coronal,
    sagittal,

    pub fn label(self: Orientation) []const u8 {
        return switch (self) {
            .axial => "Axial",
            .coronal => "Coronal",
            .sagittal => "Sagittal",
        };
    }

    pub fn depthForVolume(self: Orientation, vol: *const Volume) usize {
        return switch (self) {
            .axial => vol.dim_z,
            .coronal => vol.dim_y,
            .sagittal => vol.dim_x,
        };
    }

    pub fn sliceDims(self: Orientation, vol: *const Volume) struct { w: usize, h: usize } {
        return switch (self) {
            .axial => .{ .w = vol.dim_x, .h = vol.dim_y },
            .coronal => .{ .w = vol.dim_x, .h = vol.dim_z },
            .sagittal => .{ .w = vol.dim_y, .h = vol.dim_z },
        };
    }

    pub fn sampleVoxel(self: Orientation, vol: *const Volume, u: usize, v: usize, s: usize) u16 {
        const coords = switch (self) {
            .axial => .{ u, v, s },
            .coronal => .{ u, s, v },
            .sagittal => .{ s, u, v },
        };
        return vol.data[coords[2] * vol.dim_y * vol.dim_x + coords[1] * vol.dim_x + coords[0]];
    }
};

/// State for the 2D slice/projection panel.
pub const SliceView = struct {
    orientation: Orientation = .axial,
    slice_index: usize = 0,
    max_slices: usize = 1,
    window_center: f32 = 32768.0,
    window_width: f32 = 65536.0,
    composite: bool = true,
    volume_index: usize = 0,
    alpha_scale: f32 = 0.5,
    zoom: f32 = 100.0,

    pub fn updateForVolume(self: *SliceView, vol: *const Volume) void {
        self.max_slices = self.orientation.depthForVolume(vol);
        if (self.slice_index >= self.max_slices) {
            self.slice_index = if (self.max_slices > 0) self.max_slices - 1 else 0;
        }
    }

    /// Render a single slice as grayscale RGBA pixels.
    pub fn renderSlice(self: *const SliceView, allocator: std.mem.Allocator, vol: *const Volume) ![]u8 {
        const dims = self.orientation.sliceDims(vol);
        if (dims.w == 0 or dims.h == 0) {
            return allocator.alloc(u8, 4); // 1x1 black pixel
        }

        const half_width = self.window_width * 0.5;
        const low = self.window_center - half_width;
        const inv_width: f32 = if (self.window_width > 0.0) 255.0 / self.window_width else 0.0;

        const pixels = try allocator.alloc(u8, dims.w * dims.h * 4);
        for (0..dims.h) |v| {
            for (0..dims.w) |u| {
                const raw: f32 = @floatFromInt(self.orientation.sampleVoxel(vol, u, v, self.slice_index));
                const gray: u8 = @intFromFloat(std.math.clamp((raw - low) * inv_width, 0.0, 255.0));
                const idx = (v * dims.w + u) * 4;
                pixels[idx + 0] = gray;
                pixels[idx + 1] = gray;
                pixels[idx + 2] = gray;
                pixels[idx + 3] = 255;
            }
        }

        return pixels;
    }
};
