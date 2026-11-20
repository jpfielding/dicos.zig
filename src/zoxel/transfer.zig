//! Transfer functions for volume rendering.
//!
//! Five material bands (Air transparent, Organic orange, Inorganic green,
//! Metal blue, Dense dark blue) with editable thresholds and per-band
//! opacity, plus the Threat (red) and Grayscale presets.
//!
//! Opacity model: `alpha = curve(density) * band.alpha * global_opacity *
//! gradient_boost`. The curve (OPACITY_MAP) and per-band alpha live here; the
//! global opacity is `RenderSettings.global_opacity` (GPU) / `SliceView
//! .alpha_scale` (CPU composite); the gradient edge boost is GPU-only
//! (`raycast.wgsl`). GPU alpha is defined over one smallest physical voxel
//! spacing and corrected for the actual ray segment length (Beer-Lambert).

const std = @import("std");

/// Number of entries in the 1D transfer function texture.
pub const TRANSFER_SIZE: usize = 1024;

pub const ColorBand = struct {
    name: []const u8,
    color: [3]u8,
    /// Upper density threshold (0-65535).
    threshold: u16,
    is_transparent: bool,
    /// Per-band opacity multiplier (0-2).
    alpha: f32,
};

pub const TransferPreset = enum {
    /// Materials: orange/green/blue bands.
    default,
    /// Red highlight of dense material.
    threat,
    /// Grayscale with lifted midtones.
    monochrome,
};

pub const BAND_COUNT = 5;
pub const Bands = [BAND_COUNT]ColorBand;

pub fn defaultBands() Bands {
    return .{
        .{ .name = "Air", .color = .{ 250, 200, 110 }, .threshold = 8000, .is_transparent = true, .alpha = 1.0 },
        .{ .name = "Organic", .color = .{ 230, 150, 50 }, .threshold = 15000, .is_transparent = false, .alpha = 1.0 },
        .{ .name = "Inorganic", .color = .{ 80, 200, 40 }, .threshold = 20000, .is_transparent = false, .alpha = 1.0 },
        .{ .name = "Metal", .color = .{ 15, 165, 200 }, .threshold = 25000, .is_transparent = false, .alpha = 1.0 },
        .{ .name = "Dense", .color = .{ 40, 48, 180 }, .threshold = 30000, .is_transparent = false, .alpha = 1.0 },
    };
}

const OpacityPoint = struct { d: f32, a: f32 };
const OPACITY_MAP = [_]OpacityPoint{
    .{ .d = 0.0, .a = 0.0 },       .{ .d = 499.0, .a = 0.0 },     .{ .d = 500.0, .a = 0.005 },
    .{ .d = 800.0, .a = 0.008 },   .{ .d = 1449.0, .a = 0.008 },  .{ .d = 1450.0, .a = 0.01 },
    .{ .d = 3000.0, .a = 0.01 },   .{ .d = 4500.0, .a = 0.01 },   .{ .d = 6500.0, .a = 0.02 },
    .{ .d = 6600.0, .a = 0.03 },   .{ .d = 7000.0, .a = 0.05 },   .{ .d = 9000.0, .a = 0.05 },
    .{ .d = 9500.0, .a = 0.05 },   .{ .d = 10100.0, .a = 0.08 },  .{ .d = 15000.0, .a = 0.08 },
    .{ .d = 30000.0, .a = 0.3 },   .{ .d = 35000.0, .a = 0.4 },
};

fn interpolateOpacity(map: []const OpacityPoint, density: f32) f32 {
    if (map.len == 0) return 0;
    if (density <= map[0].d) return map[0].a;
    if (density >= map[map.len - 1].d) return map[map.len - 1].a;
    for (0..map.len - 1) |i| {
        const p0 = map[i];
        const p1 = map[i + 1];
        if (density >= p0.d and density < p1.d) {
            const t = (density - p0.d) / (p1.d - p0.d);
            return p0.a + t * (p1.a - p0.a);
        }
    }
    return 0;
}

/// An RGBA transfer table of TRANSFER_SIZE entries.
pub const TransferFunction = struct {
    data: [TRANSFER_SIZE][4]f32,

    pub fn fromBands(bands: []const ColorBand) TransferFunction {
        var tf = TransferFunction{ .data = [_][4]f32{.{ 0, 0, 0, 0 }} ** TRANSFER_SIZE };
        if (bands.len == 0) return tf;
        const max_density: f32 = @floatFromInt(bands[bands.len - 1].threshold);
        for (&tf.data, 0..) |*entry, i| {
            const density = (@as(f32, @floatFromInt(i)) / @as(f32, TRANSFER_SIZE - 1)) * max_density;
            var band_idx: usize = 0;
            var prev: f32 = 0;
            for (bands, 0..) |band, bi| {
                if (density <= @as(f32, @floatFromInt(band.threshold))) {
                    band_idx = bi;
                    break;
                }
                prev = @floatFromInt(band.threshold);
                if (bi == bands.len - 1) band_idx = bi;
            }
            const band = bands[band_idx];
            if (band.is_transparent) {
                entry.* = .{ 0, 0, 0, 0 };
                continue;
            }
            const range = @as(f32, @floatFromInt(band.threshold)) - prev;
            const progress = if (range > 0) std.math.clamp((density - prev) / range, 0.0, 1.0) else 0.0;
            const brightness = 0.85 + 0.3 * progress;
            const r = @as(f32, @floatFromInt(band.color[0])) / 255.0 * brightness;
            const g = @as(f32, @floatFromInt(band.color[1])) / 255.0 * brightness;
            const b = @as(f32, @floatFromInt(band.color[2])) / 255.0 * brightness;
            const alpha = interpolateOpacity(&OPACITY_MAP, density) * band.alpha;
            entry.* = .{ @min(r, 1.0), @min(g, 1.0), @min(b, 1.0), alpha };
        }
        return tf;
    }

    /// Red monochrome for highlighting dense material.
    pub fn threat() TransferFunction {
        var tf = TransferFunction{ .data = [_][4]f32{.{ 0, 0, 0, 0 }} ** TRANSFER_SIZE };
        const threshold_idx: usize = @intFromFloat(700.0 / 30000.0 * @as(f32, TRANSFER_SIZE - 1));
        for (&tf.data, 0..) |*entry, i| {
            if (i < threshold_idx) continue;
            const progress = @as(f32, @floatFromInt(i - threshold_idx)) / @as(f32, @floatFromInt(TRANSFER_SIZE - 1 - threshold_idx));
            entry.* = .{ 188.0 / 255.0, 25.0 / 255.0, 30.0 / 255.0, 0.03 + 0.17 * progress };
        }
        return tf;
    }

    /// Grayscale: midtones lifted with `0.9 * t^0.65`; alpha linear.
    pub fn monochrome() TransferFunction {
        var tf: TransferFunction = undefined;
        for (&tf.data, 0..) |*entry, i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, TRANSFER_SIZE - 1);
            const gray = 0.9 * std.math.pow(f32, t, 0.65);
            entry.* = .{ gray, gray, gray, 0.5 * t };
        }
        return tf;
    }

    pub fn fromPreset(preset: TransferPreset) TransferFunction {
        return switch (preset) {
            .default => blk: {
                const bands = defaultBands();
                break :blk fromBands(&bands);
            },
            .threat => threat(),
            .monochrome => monochrome(),
        };
    }

    /// The grayscale ramp value the legend draws (same curve as the table).
    pub fn grayscaleLevel(t: f32) f32 {
        return 0.9 * std.math.pow(f32, t, 0.65);
    }
};

/// Keep thresholds non-decreasing; the last stays non-zero.
pub fn clampBandThresholds(bands: []ColorBand) void {
    if (bands.len == 0) return;
    var prev: u16 = 0;
    for (bands) |*b| {
        if (b.threshold < prev) b.threshold = prev;
        prev = b.threshold;
    }
    if (bands[bands.len - 1].threshold == 0) bands[bands.len - 1].threshold = 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "homogeneous slab opacity is independent of sampling partition" {
    const reference: f64 = 1.0 / 256.0;
    const len: f64 = 0.073;
    for ([_]f64{ 0.0, 0.003, 0.0495, 0.0743, 1.0 }) |alpha| {
        const expected = 1.0 - std.math.pow(f64, 1.0 - alpha, len / reference);
        for ([_]f64{ 0.25, 0.5, 1.0, 1.5, 2.75 }) |factor| {
            const step = reference * factor;
            var t: f64 = 0;
            var acc: f64 = 0;
            while (t < len) {
                const d = @min(step, len - t);
                const a = 1.0 - std.math.pow(f64, 1.0 - alpha, d / reference);
                acc += (1.0 - acc) * a;
                t += d;
            }
            try testing.expect(@abs(acc - expected) < 1e-12);
        }
    }
}

test "default bands and table shape" {
    const bands = defaultBands();
    try testing.expectEqual(@as(usize, 5), bands.len);
    try testing.expect(bands[0].is_transparent);
    try testing.expect(!bands[1].is_transparent);
    const tf = TransferFunction.fromBands(&bands);
    try testing.expectEqual(@as(f32, 0), tf.data[0][3]);
    try testing.expectEqual(@as(f32, 0), tf.data[1][3]);
    try testing.expect(tf.data[TRANSFER_SIZE - 1][3] > 0);
}

test "threat and monochrome presets" {
    const t = TransferFunction.threat();
    try testing.expectEqual(@as(f32, 0), t.data[0][3]);
    const m = TransferFunction.monochrome();
    try testing.expect(m.data[0][0] < 0.01);
    try testing.expect(m.data[TRANSFER_SIZE - 1][0] > 0.5);
    try testing.expect(@abs(m.data[TRANSFER_SIZE - 1][0] - 0.9) < 1e-6);
    try testing.expect(@abs(m.data[TRANSFER_SIZE - 1][3] - 0.5) < 1e-6);
    for ([_]TransferPreset{ .default, .threat, .monochrome }) |p| {
        _ = TransferFunction.fromPreset(p);
    }
}

test "clamp band thresholds keeps order" {
    var bands = defaultBands();
    bands[2].threshold = 100;
    clampBandThresholds(&bands);
    try testing.expectEqual(@as(u16, 15000), bands[2].threshold);
}
