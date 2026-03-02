//! Volume data management for 3D rendering.
//!
//! Loads DICOS files into a 3D voxel grid and extracts metadata
//! for display and rendering.

const std = @import("std");
const dicos = @import("dicos");

/// A bounding box for a detected threat object.
pub const ThreatBox = struct {
    name: []const u8,
    confidence: f32,
    color: [3]u8,
    min: [3]usize,
    max: [3]usize,
    enabled: bool,
};

/// A 3D volume of voxel data loaded from DICOS file(s).
pub const Volume = struct {
    dim_x: usize,
    dim_y: usize,
    dim_z: usize,
    data: []u16,
    threats: []ThreatBox,
    modality: []const u8,
    window_center: f32,
    window_width: f32,
    rescale_intercept: f32,
    rescale_slope: f32,
    pixel_spacing_x: f32,
    pixel_spacing_y: f32,
    slice_thickness: f32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Volume) void {
        self.allocator.free(self.data);
        for (self.threats) |t| {
            self.allocator.free(t.name);
        }
        self.allocator.free(self.threats);
        self.allocator.free(self.modality);
    }

    /// Sample a voxel at (x, y, z).
    pub fn sample(self: *const Volume, x: usize, y: usize, z: usize) u16 {
        return self.data[z * self.dim_y * self.dim_x + y * self.dim_x + x];
    }

    /// Load a volume from a single DICOS file path using the provided Io.
    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !Volume {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(data);
        var ds = try dicos.reader.parseBytes(allocator, data);
        defer ds.deinit();

        return loadFromDataset(allocator, &ds);
    }

    /// Load a volume from a byte slice containing a DICOS file.
    pub fn loadBytes(allocator: std.mem.Allocator, file_data: []const u8) !Volume {
        var ds = try dicos.reader.parseBytes(allocator, file_data);
        defer ds.deinit();
        return loadFromDataset(allocator, &ds);
    }

    /// Pack volume data for GPU upload as Rgba16Float.
    /// Channel layout: R=density(u16→f16), G=grad_x, B=grad_y, A=grad_z.
    /// Gradients are computed via central differences, scaled to [0,1] centered at 0.5.
    pub fn packForGpu(self: *const Volume, allocator: std.mem.Allocator) ![]u8 {
        const dx = self.dim_x;
        const dy = self.dim_y;
        const dz = self.dim_z;
        const total = dx * dy * dz;

        // 4 channels × 2 bytes (f16) = 8 bytes per voxel
        const out = try allocator.alloc(u8, total * 8);

        const f16_slice = @as([*]f16, @alignCast(@ptrCast(out.ptr)))[0 .. total * 4];

        for (0..dz) |z| {
            for (0..dy) |y| {
                for (0..dx) |x| {
                    const idx = z * dy * dx + y * dx + x;
                    const density = self.data[idx];

                    // Central differences for gradient (clamped at boundaries)
                    const xm: f32 = @floatFromInt(self.data[idx -% @as(usize, if (x > 0) 1 else 0)]);
                    const xp: f32 = @floatFromInt(self.data[idx +% @as(usize, if (x + 1 < dx) 1 else 0)]);
                    const ym: f32 = @floatFromInt(self.data[z * dy * dx + (if (y > 0) y - 1 else y) * dx + x]);
                    const yp: f32 = @floatFromInt(self.data[z * dy * dx + (if (y + 1 < dy) y + 1 else y) * dx + x]);
                    const zm: f32 = @floatFromInt(self.data[(if (z > 0) z - 1 else z) * dy * dx + y * dx + x]);
                    const zp: f32 = @floatFromInt(self.data[(if (z + 1 < dz) z + 1 else z) * dy * dx + y * dx + x]);

                    // Gradient scaled to [0,1] centered at 0.5
                    const scale: f32 = 0.5 / 65535.0;
                    const gx = (xp - xm) * scale + 0.5;
                    const gy = (yp - ym) * scale + 0.5;
                    const gz = (zp - zm) * scale + 0.5;

                    const out_idx = idx * 4;
                    f16_slice[out_idx + 0] = @floatCast(@as(f32, @floatFromInt(density)) / 65535.0);
                    f16_slice[out_idx + 1] = @floatCast(std.math.clamp(gx, 0.0, 1.0));
                    f16_slice[out_idx + 2] = @floatCast(std.math.clamp(gy, 0.0, 1.0));
                    f16_slice[out_idx + 3] = @floatCast(std.math.clamp(gz, 0.0, 1.0));
                }
            }
        }

        return out;
    }

    fn loadFromDataset(allocator: std.mem.Allocator, ds: *const dicos.Dataset) !Volume {
        const rows: usize = ds.rows();
        const cols: usize = ds.columns();
        const frames = ds.numberOfFrames();

        const modality_str = ds.modality();
        const modality = try allocator.dupe(u8, modality_str);

        // Window/level
        var wc: f32 = 32768.0;
        var ww: f32 = 65536.0;
        if (ds.getF64(dicos.tag.WINDOW_CENTER)) |v| wc = @floatCast(v);
        if (ds.getF64(dicos.tag.WINDOW_WIDTH)) |v| ww = @floatCast(v);

        var ri: f32 = 0.0;
        var rs: f32 = 1.0;
        if (ds.getF64(dicos.tag.RESCALE_INTERCEPT)) |v| ri = @floatCast(v);
        if (ds.getF64(dicos.tag.RESCALE_SLOPE)) |v| rs = @floatCast(v);

        // Pixel data -- create empty volume of correct dimensions
        const total_pixels = cols * rows * frames;
        const data = try allocator.alloc(u16, total_pixels);
        @memset(data, 0);

        // Try to fill from pixel data
        if (ds.pixelData()) |pd| {
            if (!pd.is_encapsulated) {
                var offset: usize = 0;
                for (pd.frames) |frame| {
                    const copy_len = @min(frame.data.len, total_pixels - offset);
                    @memcpy(data[offset .. offset + copy_len], frame.data[0..copy_len]);
                    offset += copy_len;
                }
            }
        } else if (ds.get(dicos.tag.PIXEL_DATA)) |elem| {
            // Non-encapsulated pixel data stored as raw bytes
            switch (elem.value) {
                .bytes => |raw_bytes| {
                    const u16_data = std.mem.bytesAsSlice(u16, raw_bytes);
                    const copy_len = @min(u16_data.len, total_pixels);
                    @memcpy(data[0..copy_len], u16_data[0..copy_len]);
                },
                else => {},
            }
        }

        return Volume{
            .dim_x = cols,
            .dim_y = rows,
            .dim_z = frames,
            .data = data,
            .threats = try allocator.alloc(ThreatBox, 0),
            .modality = modality,
            .window_center = wc,
            .window_width = ww,
            .rescale_intercept = ri,
            .rescale_slope = rs,
            .pixel_spacing_x = 1.0,
            .pixel_spacing_y = 1.0,
            .slice_thickness = 1.0,
            .allocator = allocator,
        };
    }
};
