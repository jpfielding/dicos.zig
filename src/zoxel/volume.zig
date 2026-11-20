//! Volume data model.
//!
//! A loaded 3D volume (stored samples plus the metadata needed to display
//! them), its threat boxes, and the CPU work that prepares it for the GPU:
//! window estimation, centre of mass and the packed density + gradient
//! texture. Nothing here touches the DICOS parser; see `dicos_adapter.zig`.

const std = @import("std");

/// Threat ROI bounding box (voxel indices, inclusive).
pub const ThreatBox = struct {
    /// Human-readable name for UI labels (owned).
    name: []u8,
    /// Optional confidence score (0..1).
    confidence: ?f64 = null,
    /// Minimum voxel corner (inclusive): `[x, y, z]`.
    min: [3]usize,
    /// Maximum voxel corner (inclusive): `[x, y, z]`.
    max: [3]usize,
    /// RGB colour for this threat.
    color: [3]u8 = .{ 0, 0, 0 },
    /// Whether this threat is currently enabled for display.
    enabled: bool = true,

    pub fn deinit(self: *ThreatBox, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.* = undefined;
    }

    pub fn clone(self: ThreatBox, gpa: std.mem.Allocator) !ThreatBox {
        var out = self;
        out.name = try gpa.dupe(u8, self.name);
        return out;
    }
};

pub const ThreatList = std.ArrayList(ThreatBox);

pub fn freeThreats(gpa: std.mem.Allocator, list: *ThreatList) void {
    for (list.items) |*t| t.deinit(gpa);
    list.deinit(gpa);
    list.* = .empty;
}

/// A loaded 3D volume ready for rendering.
pub const Volume = struct {
    /// Raw stored samples (bit patterns; signed when `signed_pixels`).
    data: []u16,
    dim_x: usize,
    dim_y: usize,
    dim_z: usize,
    /// Window/level in the modality (rescaled) domain.
    window_center: f64 = 32768.0,
    window_width: f64 = 65536.0,
    rescale_intercept: f64 = 0.0,
    /// Defaults to 1.0 when the tag is absent.
    rescale_slope: f64 = 1.0,
    /// True when PixelRepresentation is 1 (two's-complement samples).
    signed_pixels: bool = false,
    /// Modality string (owned), e.g. "CT".
    modality: []u8,
    /// Voxel spacing in mm (X, Y, Z).
    voxel_spacing: [3]f64 = .{ 1.0, 1.0, 1.0 },
    threats: ThreatList = .empty,

    pub fn deinit(self: *Volume, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.free(self.modality);
        freeThreats(gpa, &self.threats);
        self.* = undefined;
    }

    pub fn voxelCount(self: *const Volume) usize {
        return self.dim_x * self.dim_y * self.dim_z;
    }

    /// Interpret a stored sample as a signed or unsigned integer.
    pub fn storedSample(self: *const Volume, raw: u16) f64 {
        if (self.signed_pixels) return @floatFromInt(@as(i16, @bitCast(raw)));
        return @floatFromInt(raw);
    }

    /// `stored * RescaleSlope + RescaleIntercept`.
    pub fn modalityValue(self: *const Volume, raw: u16) f64 {
        return self.storedSample(raw) * self.rescale_slope + self.rescale_intercept;
    }

    /// Density-weighted centre of mass in normalised [0,1] coordinates.
    pub fn centerOfMass(self: *const Volume) [3]f32 {
        if (self.data.len == 0) return .{ 0.5, 0.5, 0.5 };
        var min_val = std.math.inf(f64);
        var max_val = -std.math.inf(f64);
        for (self.data) |v| {
            const val = self.storedSample(v);
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
        const threshold = min_val + (max_val - min_val) * 0.1;
        const dx = self.dim_x;
        const dxy = self.dim_x * self.dim_y;
        var sx: f64 = 0;
        var sy: f64 = 0;
        var sz: f64 = 0;
        var total: f64 = 0;
        for (self.data, 0..) |v, i| {
            const val = self.storedSample(v);
            if (val > threshold) {
                // Shift by a negative minimum so weights are never negative.
                const w = val - @min(min_val, 0.0);
                const z = i / dxy;
                const rem = i % dxy;
                const y = rem / dx;
                const x = rem % dx;
                sx += @as(f64, @floatFromInt(x)) * w;
                sy += @as(f64, @floatFromInt(y)) * w;
                sz += @as(f64, @floatFromInt(z)) * w;
                total += w;
            }
        }
        if (total == 0) return .{ 0.5, 0.5, 0.5 };
        return .{
            @floatCast(sx / total / @as(f64, @floatFromInt(self.dim_x))),
            @floatCast(sy / total / @as(f64, @floatFromInt(self.dim_y))),
            @floatCast(sz / total / @as(f64, @floatFromInt(self.dim_z))),
        };
    }

    /// Window centre/width from the 1st and 99th percentiles of up to ~100k
    /// samples, in the modality domain (matches slices and 3D).
    pub fn computeWindowFromData(self: *Volume, gpa: std.mem.Allocator) !void {
        if (self.data.len == 0) return;
        const step = @max(self.data.len / 100_000, 1);
        const count = (self.data.len + step - 1) / step;
        const samples = try gpa.alloc(f64, count);
        defer gpa.free(samples);
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.data.len) : (i += step) {
            samples[n] = self.modalityValue(self.data[i]);
            n += 1;
        }
        std.mem.sort(f64, samples[0..n], {}, std.sort.asc(f64));
        const p01 = samples[n / 100];
        const p99 = samples[n * 99 / 100];
        if (p99 <= p01) return;
        const width = @max(p99 - p01, 1.0);
        self.window_center = p01 + width * 0.5;
        self.window_width = width;
    }

    /// Pack for GPU upload as RGBA16: `[density, gx+0.5, gy+0.5, gz+0.5]`.
    /// Density is the stored bits for unsigned data and offset-binary
    /// (`raw ^ 0x8000`) for signed data so linear filtering stays monotonic;
    /// gradients use central differences of the signed stored value.
    pub fn packForGpu(self: *const Volume, gpa: std.mem.Allocator) ![]u16 {
        const dx = self.dim_x;
        const dy = self.dim_y;
        const dz = self.dim_z;
        const total = dx * dy * dz;
        std.debug.assert(self.data.len == total);
        const packed_buf = try gpa.alloc(u16, total * 4);
        const inv_range: f32 = 1.0 / 65535.0;
        const stride_y = dx;
        const stride_z = dx * dy;
        const data = self.data;
        const signed = self.signed_pixels;
        for (0..dz) |z| {
            const z_base = z * stride_z;
            for (0..dy) |y| {
                const yz_base = z_base + y * stride_y;
                for (0..dx) |x| {
                    const idx = yz_base + x;
                    const c = storedF32(data[idx], signed);
                    const left = if (x > 0) storedF32(data[idx - 1], signed) else c;
                    const right = if (x + 1 < dx) storedF32(data[idx + 1], signed) else c;
                    const below = if (y > 0) storedF32(data[idx - stride_y], signed) else c;
                    const above = if (y + 1 < dy) storedF32(data[idx + stride_y], signed) else c;
                    const back = if (z > 0) storedF32(data[idx - stride_z], signed) else c;
                    const front = if (z + 1 < dz) storedF32(data[idx + stride_z], signed) else c;
                    const gx = (right - left) * 0.5;
                    const gy = (above - below) * 0.5;
                    const gz = (front - back) * 0.5;
                    const pi = idx * 4;
                    packed_buf[pi] = if (signed) data[idx] ^ 0x8000 else data[idx];
                    packed_buf[pi + 1] = toUnorm16(gx * inv_range + 0.5);
                    packed_buf[pi + 2] = toUnorm16(gy * inv_range + 0.5);
                    packed_buf[pi + 3] = toUnorm16(gz * inv_range + 0.5);
                }
            }
        }
        return packed_buf;
    }
};

inline fn storedF32(raw: u16, signed: bool) f32 {
    if (signed) return @floatFromInt(@as(i16, @bitCast(raw)));
    return @floatFromInt(raw);
}

fn toUnorm16(v: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 65535.0));
}

// ---------------------------------------------------------------------------
// Threat colours and merging
// ---------------------------------------------------------------------------

fn hsvToRgb(h_in: f32, s: f32, v: f32) [3]u8 {
    const h = @mod(h_in, 360.0);
    const c = v * s;
    const x = c * (1.0 - @abs(@mod(h / 60.0, 2.0) - 1.0));
    const m = v - c;
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (h < 60.0) {
        r = c;
        g = x;
    } else if (h < 120.0) {
        r = x;
        g = c;
    } else if (h < 180.0) {
        g = c;
        b = x;
    } else if (h < 240.0) {
        g = x;
        b = c;
    } else if (h < 300.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    return .{
        @intFromFloat(@round((r + m) * 255.0)),
        @intFromFloat(@round((g + m) * 255.0)),
        @intFromFloat(@round((b + m) * 255.0)),
    };
}

/// Golden-ratio hue stepping: stable, well-separated colours.
pub fn threatColorForIndex(index: usize) [3]u8 {
    const f = @as(f32, @floatFromInt(index)) * 0.618034;
    const hue = (f - @floor(f)) * 360.0;
    return hsvToRgb(hue, 0.82, 0.98);
}

pub fn recolorThreats(threats: []ThreatBox) void {
    for (threats, 0..) |*t, i| t.color = threatColorForIndex(i);
}

fn sameThreat(a: ThreatBox, b: ThreatBox) bool {
    return std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(usize, &a.min, &b.min) and
        std.mem.eql(usize, &a.max, &b.max) and
        std.meta.eql(a.confidence, b.confidence);
}

/// Append the threats of `src` not already in `dst` (by name, box and
/// confidence), taking ownership of `src`'s entries, then recolour `dst`.
/// Returns how many were added. `src` is left empty.
pub fn mergeUniqueThreats(gpa: std.mem.Allocator, dst: *ThreatList, src: *ThreatList) !usize {
    var added: usize = 0;
    defer {
        for (src.items) |*t| t.deinit(gpa);
        src.clearRetainingCapacity();
    }
    var i: usize = 0;
    while (i < src.items.len) {
        const threat = src.items[i];
        var dup = false;
        for (dst.items) |existing| {
            if (sameThreat(existing, threat)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            i += 1;
            continue;
        }
        try dst.append(gpa, threat);
        _ = src.orderedRemove(i);
        added += 1;
    }
    recolorThreats(dst.items);
    return added;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a test volume filled with `fill`. Caller owns it.
pub fn testVolume(gpa: std.mem.Allocator, dx: usize, dy: usize, dz: usize, fill: u16) !Volume {
    const data = try gpa.alloc(u16, dx * dy * dz);
    @memset(data, fill);
    return .{
        .data = data,
        .dim_x = dx,
        .dim_y = dy,
        .dim_z = dz,
        .modality = try gpa.dupe(u8, "CT"),
    };
}

fn setData(gpa: std.mem.Allocator, vol: *Volume, values: []const u16, dx: usize, dy: usize, dz: usize) !void {
    gpa.free(vol.data);
    vol.data = try gpa.dupe(u16, values);
    vol.dim_x = dx;
    vol.dim_y = dy;
    vol.dim_z = dz;
}

test "automatic window uses the same rescaled domain as rendering" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 10, 10, 10, 0);
    defer vol.deinit(gpa);
    for (vol.data, 0..) |*v, i| v.* = @intCast(i);
    vol.rescale_intercept = -1024.0;
    try vol.computeWindowFromData(gpa);
    try testing.expectEqual(@as(f64, -524.0), vol.window_center);
    try testing.expectEqual(@as(f64, 980.0), vol.window_width);
}

test "automatic window applies slope" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 10, 10, 10, 0);
    defer vol.deinit(gpa);
    for (vol.data, 0..) |*v, i| v.* = @intCast(i);
    vol.rescale_slope = 2.0;
    vol.rescale_intercept = -1024.0;
    try vol.computeWindowFromData(gpa);
    try testing.expectEqual(@as(f64, -24.0), vol.window_center);
    try testing.expectEqual(@as(f64, 1960.0), vol.window_width);
}

test "center of mass uniform and empty" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 4, 4, 4, 100);
    defer vol.deinit(gpa);
    const com = vol.centerOfMass();
    for (com) |c| try testing.expect(@abs(c - 0.5) < 0.1);

    var empty = Volume{ .data = &.{}, .dim_x = 0, .dim_y = 0, .dim_z = 0, .modality = &.{} };
    try testing.expectEqual([3]f32{ 0.5, 0.5, 0.5 }, empty.centerOfMass());
}

test "pack for gpu length, density and zero gradient" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 4, 4, 4, 100);
    defer vol.deinit(gpa);
    const p = try vol.packForGpu(gpa);
    defer gpa.free(p);
    try testing.expectEqual(@as(usize, 4 * 4 * 4 * 4), p.len);
    var i: usize = 0;
    while (i < p.len) : (i += 4) try testing.expectEqual(@as(u16, 100), p[i]);
    const idx = (2 * 16 + 2 * 4 + 2) * 4;
    for (1..4) |c| try testing.expect(@abs(@as(i32, p[idx + c]) - 32768) <= 1);
}

test "modality value interprets signed bits" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 1, 1, 1, 0);
    defer vol.deinit(gpa);
    vol.signed_pixels = true;
    try testing.expectEqual(@as(f64, -1.0), vol.modalityValue(0xFFFF));
    vol.signed_pixels = false;
    try testing.expectEqual(@as(f64, 65535.0), vol.modalityValue(0xFFFF));
}

test "packed gradient uses signed samples" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 1, 1, 1, 0);
    defer vol.deinit(gpa);
    try setData(gpa, &vol, &.{ @bitCast(@as(i16, -2)), 0, 2 }, 3, 1, 1);
    vol.signed_pixels = true;
    const p = try vol.packForGpu(gpa);
    defer gpa.free(p);
    const expected: u16 = @intFromFloat(@round((2.0 / 65535.0 + 0.5) * 65535.0));
    try testing.expectEqual(expected, p[5]);
}

test "signed density is offset binary and filters linearly" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 1, 1, 1, 0);
    defer vol.deinit(gpa);
    try setData(gpa, &vol, &.{ @bitCast(@as(i16, -1000)), 40 }, 2, 1, 1);
    vol.signed_pixels = true;
    const p = try vol.packForGpu(gpa);
    defer gpa.free(p);
    const a: f32 = @floatFromInt(p[0]);
    const b: f32 = @floatFromInt(p[4]);
    try testing.expectEqual(@as(f32, -1000.0), a - 32768.0);
    try testing.expectEqual(@as(f32, 40.0), b - 32768.0);
    try testing.expectEqual(@as(f32, -480.0), (a + b) * 0.5 - 32768.0);
}

test "unsigned density is unchanged" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 1, 1, 1, 40000);
    defer vol.deinit(gpa);
    const p = try vol.packForGpu(gpa);
    defer gpa.free(p);
    try testing.expectEqual(@as(u16, 40000), p[0]);
}

test "center of mass with negative samples stays inside" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 1, 1, 1, 0);
    defer vol.deinit(gpa);
    try setData(gpa, &vol, &.{ @bitCast(@as(i16, -100)), @bitCast(@as(i16, -2)), 3 }, 3, 1, 1);
    vol.signed_pixels = true;
    const c = vol.centerOfMass();
    try testing.expect(c[0] >= 0 and c[0] <= 1);
}

test "center of mass unsigned weights unchanged" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa, 1, 1, 1, 0);
    defer vol.deinit(gpa);
    try setData(gpa, &vol, &.{ 1000, 1200, 2000 }, 3, 1, 1);
    const expected: f32 = @floatCast((1.0 * 1200.0 + 2.0 * 2000.0) / 3200.0 / 3.0);
    try testing.expectEqual(expected, vol.centerOfMass()[0]);
}

fn makeThreat(gpa: std.mem.Allocator, name: []const u8, min: [3]usize, max: [3]usize) !ThreatBox {
    return .{ .name = try gpa.dupe(u8, name), .min = min, .max = max, .color = .{ 255, 0, 0 } };
}

test "merge unique threats" {
    const gpa = testing.allocator;
    var dst: ThreatList = .empty;
    defer freeThreats(gpa, &dst);
    try dst.append(gpa, try makeThreat(gpa, "A", .{ 0, 0, 0 }, .{ 1, 1, 1 }));

    var empty: ThreatList = .empty;
    try testing.expectEqual(@as(usize, 0), try mergeUniqueThreats(gpa, &dst, &empty));

    var src: ThreatList = .empty;
    defer freeThreats(gpa, &src);
    try src.append(gpa, try makeThreat(gpa, "B", .{ 2, 2, 2 }, .{ 3, 3, 3 }));
    try src.append(gpa, try makeThreat(gpa, "A", .{ 0, 0, 0 }, .{ 1, 1, 1 }));
    try src.append(gpa, try makeThreat(gpa, "C", .{ 0, 0, 0 }, .{ 1, 1, 1 }));
    try testing.expectEqual(@as(usize, 2), try mergeUniqueThreats(gpa, &dst, &src));
    try testing.expectEqual(@as(usize, 3), dst.items.len);
    try testing.expectEqualStrings("B", dst.items[1].name);
    try testing.expectEqualStrings("C", dst.items[2].name);
    try testing.expectEqual(threatColorForIndex(0), dst.items[0].color);
    try testing.expectEqual(threatColorForIndex(1), dst.items[1].color);
    try testing.expectEqual(@as(usize, 0), src.items.len);
}
