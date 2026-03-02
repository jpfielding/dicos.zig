const std = @import("std");

pub const TRANSFER_SIZE: usize = 1024;

pub const ColorBand = struct {
    name: []const u8,
    color: [3]u8,
    threshold: u16,
    is_transparent: bool,
    alpha: f32,
};

pub const TransferPreset = enum {
    default,
    threat,
    monochrome,
};

pub fn defaultBands() [5]ColorBand {
    return .{
        .{ .name = "Air", .color = .{ 250, 200, 110 }, .threshold = 8000, .is_transparent = true, .alpha = 1.0 },
        .{ .name = "Organic", .color = .{ 230, 150, 50 }, .threshold = 15000, .is_transparent = false, .alpha = 1.0 },
        .{ .name = "Inorganic", .color = .{ 80, 200, 40 }, .threshold = 20000, .is_transparent = false, .alpha = 1.0 },
        .{ .name = "Metal", .color = .{ 15, 165, 200 }, .threshold = 25000, .is_transparent = false, .alpha = 1.0 },
        .{ .name = "Dense", .color = .{ 40, 48, 180 }, .threshold = 30000, .is_transparent = false, .alpha = 1.0 },
    };
}

const OpacityEntry = struct { density: f32, alpha: f32 };
const OPACITY_MAP = [_]OpacityEntry{
    .{ .density = 0.0, .alpha = 0.0 },
    .{ .density = 499.0, .alpha = 0.0 },
    .{ .density = 500.0, .alpha = 0.005 },
    .{ .density = 800.0, .alpha = 0.008 },
    .{ .density = 1449.0, .alpha = 0.008 },
    .{ .density = 1450.0, .alpha = 0.01 },
    .{ .density = 3000.0, .alpha = 0.01 },
    .{ .density = 4500.0, .alpha = 0.01 },
    .{ .density = 6500.0, .alpha = 0.02 },
    .{ .density = 6600.0, .alpha = 0.03 },
    .{ .density = 7000.0, .alpha = 0.05 },
    .{ .density = 9000.0, .alpha = 0.05 },
    .{ .density = 9500.0, .alpha = 0.05 },
    .{ .density = 10100.0, .alpha = 0.08 },
    .{ .density = 15000.0, .alpha = 0.08 },
    .{ .density = 30000.0, .alpha = 0.3 },
    .{ .density = 35000.0, .alpha = 0.4 },
};

fn interpolateOpacity(density: f32) f32 {
    if (density <= OPACITY_MAP[0].density) return OPACITY_MAP[0].alpha;
    if (density >= OPACITY_MAP[OPACITY_MAP.len - 1].density) return OPACITY_MAP[OPACITY_MAP.len - 1].alpha;
    for (0..OPACITY_MAP.len - 1) |i| {
        const d0 = OPACITY_MAP[i].density;
        const a0 = OPACITY_MAP[i].alpha;
        const d1 = OPACITY_MAP[i + 1].density;
        const a1 = OPACITY_MAP[i + 1].alpha;
        if (density >= d0 and density < d1) {
            const t = (density - d0) / (d1 - d0);
            return a0 + t * (a1 - a0);
        }
    }
    return 0.0;
}

/// RGBA transfer function table.
pub const TransferFunction = struct {
    data: [TRANSFER_SIZE][4]f32,

    pub fn fromBands(bands: []const ColorBand) TransferFunction {
        var result: TransferFunction = undefined;
        if (bands.len == 0) {
            @memset(&result.data, .{ 0.0, 0.0, 0.0, 0.0 });
            return result;
        }

        const max_density: f32 = @floatFromInt(bands[bands.len - 1].threshold);

        for (0..TRANSFER_SIZE) |i| {
            const density = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(TRANSFER_SIZE - 1))) * max_density;

            var band_idx: usize = 0;
            var prev_threshold: f32 = 0.0;
            for (bands, 0..) |band, bi| {
                if (density <= @as(f32, @floatFromInt(band.threshold))) {
                    band_idx = bi;
                    break;
                }
                prev_threshold = @floatFromInt(band.threshold);
                if (bi == bands.len - 1) band_idx = bi;
            }

            const band = &bands[band_idx];

            if (band.is_transparent) {
                result.data[i] = .{ 0.0, 0.0, 0.0, 0.0 };
                continue;
            }

            const band_range = @as(f32, @floatFromInt(band.threshold)) - prev_threshold;
            const progress = if (band_range > 0.0)
                std.math.clamp((density - prev_threshold) / band_range, 0.0, 1.0)
            else
                0.0;

            const brightness = 0.85 + 0.3 * progress;
            const r = @min(@as(f32, @floatFromInt(band.color[0])) / 255.0 * brightness, 1.0);
            const g = @min(@as(f32, @floatFromInt(band.color[1])) / 255.0 * brightness, 1.0);
            const b = @min(@as(f32, @floatFromInt(band.color[2])) / 255.0 * brightness, 1.0);
            const base_alpha = interpolateOpacity(density);
            const alpha = base_alpha * band.alpha;

            result.data[i] = .{ r, g, b, alpha };
        }

        return result;
    }

    pub fn threat() TransferFunction {
        var result: TransferFunction = undefined;
        const threshold_idx: usize = @intFromFloat(700.0 / 30000.0 * @as(f32, @floatFromInt(TRANSFER_SIZE - 1)));

        for (0..TRANSFER_SIZE) |i| {
            if (i < threshold_idx) {
                result.data[i] = .{ 0.0, 0.0, 0.0, 0.0 };
            } else {
                const progress = @as(f32, @floatFromInt(i - threshold_idx)) / @as(f32, @floatFromInt(TRANSFER_SIZE - 1 - threshold_idx));
                const alpha = 0.03 + 0.17 * progress;
                result.data[i] = .{ 188.0 / 255.0, 25.0 / 255.0, 30.0 / 255.0, alpha };
            }
        }
        return result;
    }

    pub fn monochrome() TransferFunction {
        var result: TransferFunction = undefined;
        for (0..TRANSFER_SIZE) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(TRANSFER_SIZE - 1));
            const gray = 0.67 * t;
            const alpha = 0.5 * t;
            result.data[i] = .{ gray, gray, gray, alpha };
        }
        return result;
    }

    pub fn fromPreset(preset: TransferPreset) TransferFunction {
        return switch (preset) {
            .default => fromBands(&defaultBands()),
            .threat => threat(),
            .monochrome => monochrome(),
        };
    }

    pub fn asRgbaU8(self: *const TransferFunction) [TRANSFER_SIZE * 4]u8 {
        var result: [TRANSFER_SIZE * 4]u8 = undefined;
        for (0..TRANSFER_SIZE) |i| {
            result[i * 4 + 0] = @intFromFloat(std.math.clamp(self.data[i][0] * 255.0, 0.0, 255.0));
            result[i * 4 + 1] = @intFromFloat(std.math.clamp(self.data[i][1] * 255.0, 0.0, 255.0));
            result[i * 4 + 2] = @intFromFloat(std.math.clamp(self.data[i][2] * 255.0, 0.0, 255.0));
            result[i * 4 + 3] = @intFromFloat(std.math.clamp(self.data[i][3] * 255.0, 0.0, 255.0));
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "default bands count" {
    const bands = defaultBands();
    try std.testing.expectEqual(@as(usize, 5), bands.len);
    try std.testing.expect(bands[0].is_transparent);
    try std.testing.expect(!bands[1].is_transparent);
}

test "transfer function size" {
    const bands = defaultBands();
    const tf = TransferFunction.fromBands(&bands);
    try std.testing.expectEqual(@as(usize, TRANSFER_SIZE), tf.data.len);
}

test "air band is transparent" {
    const bands = defaultBands();
    const tf = TransferFunction.fromBands(&bands);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), tf.data[0][3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), tf.data[1][3], 1e-6);
}

test "dense band has opacity" {
    const bands = defaultBands();
    const tf = TransferFunction.fromBands(&bands);
    try std.testing.expect(tf.data[TRANSFER_SIZE - 1][3] > 0.0);
}

test "threat below threshold is transparent" {
    const tf = TransferFunction.threat();
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), tf.data[0][3], 1e-6);
}

test "monochrome gradient" {
    const tf = TransferFunction.monochrome();
    try std.testing.expect(tf.data[0][0] < 0.01);
    try std.testing.expect(tf.data[TRANSFER_SIZE - 1][0] > 0.5);
}

test "preset roundtrip" {
    const presets = [_]TransferPreset{ .default, .threat, .monochrome };
    for (presets) |preset| {
        const tf = TransferFunction.fromPreset(preset);
        try std.testing.expectEqual(@as(usize, TRANSFER_SIZE), tf.data.len);
    }
}
