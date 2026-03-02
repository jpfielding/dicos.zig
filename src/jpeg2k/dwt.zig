//! 5/3 reversible discrete wavelet transform (lifting scheme).
//!
//! Implements the forward and inverse DWT as specified in ITU-T T.800
//! Annex F, using the lifting-based factorisation of the Le Gall 5/3 filter.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// 1-D transforms
// ---------------------------------------------------------------------------

/// Forward 1-D 5/3 wavelet transform (in-place, lifting scheme).
///
/// After the transform the first `(n+1)/2` samples contain the low-pass
/// coefficients and the remaining `n/2` samples contain the high-pass
/// coefficients.
pub fn forward1d(allocator: Allocator, signal: []i32) Allocator.Error!void {
    const n = signal.len;
    if (n < 2) return;

    const half = (n + 1) / 2;
    const num_high = n - half;

    // Split into even (low) and odd (high) samples.
    const low = try allocator.alloc(i32, half);
    defer allocator.free(low);
    const high = try allocator.alloc(i32, num_high);
    defer allocator.free(high);

    for (0..half) |i| {
        low[i] = signal[2 * i];
    }
    for (0..num_high) |i| {
        high[i] = signal[2 * i + 1];
    }

    // Predict step (high-pass):
    //   d[i] = x[2i+1] - floor((x[2i] + x[2i+2]) / 2)
    for (0..num_high) |i| {
        const left = low[i];
        const right = if (i + 1 < half) low[i + 1] else left; // symmetric extension
        high[i] -= @divTrunc(left + right, 2);
    }

    // Update step (low-pass):
    //   s[i] = x[2i] + floor((d[i-1] + d[i] + 2) / 4)
    for (0..half) |i| {
        const left = if (i > 0)
            high[i - 1]
        else if (num_high > 0)
            high[0] // symmetric extension
        else
            @as(i32, 0);
        const right = if (i < num_high) high[i] else left;
        low[i] += @divTrunc(left + right + 2, 4);
    }

    // Pack: low first, then high.
    @memcpy(signal[0..half], low);
    @memcpy(signal[half..][0..num_high], high);
}

/// Inverse 1-D 5/3 wavelet transform (in-place, lifting scheme).
///
/// Expects low-pass coefficients in `signal[..half]` and high-pass in
/// `signal[half..]` where `half = (n+1)/2`.
pub fn inverse1d(allocator: Allocator, signal: []i32) Allocator.Error!void {
    const n = signal.len;
    if (n < 2) return;

    const half = (n + 1) / 2;
    const num_high = n - half;

    const low = try allocator.alloc(i32, half);
    defer allocator.free(low);
    const high = try allocator.alloc(i32, num_high);
    defer allocator.free(high);

    @memcpy(low, signal[0..half]);
    @memcpy(high, signal[half..][0..num_high]);

    // Inverse update step.
    for (0..half) |i| {
        const left = if (i > 0)
            high[i - 1]
        else if (num_high > 0)
            high[0]
        else
            @as(i32, 0);
        const right = if (i < num_high) high[i] else left;
        low[i] -= @divTrunc(left + right + 2, 4);
    }

    // Inverse predict step.
    for (0..num_high) |i| {
        const left = low[i];
        const right = if (i + 1 < half) low[i + 1] else left;
        high[i] += @divTrunc(left + right, 2);
    }

    // Interleave.
    for (0..half) |i| {
        signal[2 * i] = low[i];
    }
    for (0..num_high) |i| {
        signal[2 * i + 1] = high[i];
    }
}

// ---------------------------------------------------------------------------
// 2-D transforms (single level)
// ---------------------------------------------------------------------------

/// Forward 2-D 5/3 DWT -- produces LL, HL, LH, HH subbands (in-place).
pub fn forward2d(allocator: Allocator, data: []i32, width: usize, height: usize) Allocator.Error!void {
    if (width < 2 or height < 2) return;

    // Transform rows.
    const row = try allocator.alloc(i32, width);
    defer allocator.free(row);
    for (0..height) |y| {
        const off = y * width;
        @memcpy(row, data[off..][0..width]);
        try forward1d(allocator, row);
        @memcpy(data[off..][0..width], row);
    }

    // Transform columns.
    const col = try allocator.alloc(i32, height);
    defer allocator.free(col);
    for (0..width) |x| {
        for (0..height) |y| {
            col[y] = data[y * width + x];
        }
        try forward1d(allocator, col);
        for (0..height) |y| {
            data[y * width + x] = col[y];
        }
    }
}

/// Inverse 2-D 5/3 DWT -- reconstructs from LL, HL, LH, HH subbands (in-place).
pub fn inverse2d(allocator: Allocator, data: []i32, width: usize, height: usize) Allocator.Error!void {
    if (width < 2 or height < 2) return;

    // Inverse columns first.
    const col = try allocator.alloc(i32, height);
    defer allocator.free(col);
    for (0..width) |x| {
        for (0..height) |y| {
            col[y] = data[y * width + x];
        }
        try inverse1d(allocator, col);
        for (0..height) |y| {
            data[y * width + x] = col[y];
        }
    }

    // Inverse rows.
    const row = try allocator.alloc(i32, width);
    defer allocator.free(row);
    for (0..height) |y| {
        const off = y * width;
        @memcpy(row, data[off..][0..width]);
        try inverse1d(allocator, row);
        @memcpy(data[off..][0..width], row);
    }
}

// ---------------------------------------------------------------------------
// Multi-level transforms (operates on LL region of previous level)
// ---------------------------------------------------------------------------

/// Forward multi-level 2-D DWT.
///
/// Each level transforms the LL subband from the previous level.
/// Returns the (width, height) of the final LL subband.
pub fn forwardMultiLevel(
    allocator: Allocator,
    data: []i32,
    width: usize,
    height: usize,
    levels: usize,
) Allocator.Error!struct { usize, usize } {
    var ll_w = width;
    var ll_h = height;

    for (0..levels) |_| {
        if (ll_w < 2 or ll_h < 2) break;
        try forwardLlRegion(allocator, data, width, ll_w, ll_h);
        ll_w = (ll_w + 1) / 2;
        ll_h = (ll_h + 1) / 2;
    }
    return .{ ll_w, ll_h };
}

/// Inverse multi-level 2-D DWT.
///
/// Levels are processed in reverse order, from smallest to largest.
pub fn inverseMultiLevel(
    allocator: Allocator,
    data: []i32,
    width: usize,
    height: usize,
    levels: usize,
) Allocator.Error!void {
    // Pre-calculate LL dimensions at each level.
    const dims = try allocator.alloc(struct { usize, usize }, levels + 1);
    defer allocator.free(dims);
    dims[0] = .{ width, height };
    for (1..levels + 1) |i| {
        dims[i] = .{ (dims[i - 1][0] + 1) / 2, (dims[i - 1][1] + 1) / 2 };
    }

    // Reconstruct from smallest to largest.
    var level_idx: usize = levels;
    while (level_idx > 0) {
        level_idx -= 1;
        const ll_w = dims[level_idx][0];
        const ll_h = dims[level_idx][1];
        if (ll_w < 2 or ll_h < 2) continue;
        try inverseLlRegion(allocator, data, width, ll_w, ll_h);
    }
}

// ---------------------------------------------------------------------------
// Helpers -- forward/inverse on the LL sub-region
// ---------------------------------------------------------------------------

fn forwardLlRegion(allocator: Allocator, data: []i32, stride: usize, width: usize, height: usize) Allocator.Error!void {
    if (width < 2 or height < 2) return;

    // Transform rows in the region.
    const row = try allocator.alloc(i32, width);
    defer allocator.free(row);
    for (0..height) |y| {
        const off = y * stride;
        @memcpy(row, data[off..][0..width]);
        try forward1d(allocator, row);
        @memcpy(data[off..][0..width], row);
    }

    // Transform columns in the region.
    const col = try allocator.alloc(i32, height);
    defer allocator.free(col);
    for (0..width) |x| {
        for (0..height) |y| {
            col[y] = data[y * stride + x];
        }
        try forward1d(allocator, col);
        for (0..height) |y| {
            data[y * stride + x] = col[y];
        }
    }
}

fn inverseLlRegion(allocator: Allocator, data: []i32, stride: usize, width: usize, height: usize) Allocator.Error!void {
    if (width < 2 or height < 2) return;

    // Inverse columns first.
    const col = try allocator.alloc(i32, height);
    defer allocator.free(col);
    for (0..width) |x| {
        for (0..height) |y| {
            col[y] = data[y * stride + x];
        }
        try inverse1d(allocator, col);
        for (0..height) |y| {
            data[y * stride + x] = col[y];
        }
    }

    // Inverse rows.
    const row = try allocator.alloc(i32, width);
    defer allocator.free(row);
    for (0..height) |y| {
        const off = y * stride;
        @memcpy(row, data[off..][0..width]);
        try inverse1d(allocator, row);
        @memcpy(data[off..][0..width], row);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "forward inverse 1d roundtrip" {
    const allocator = std.testing.allocator;
    var data = [_]i32{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const original = data;
    try forward1d(allocator, &data);
    try inverse1d(allocator, &data);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse 1d odd length" {
    const allocator = std.testing.allocator;
    var data = [_]i32{ 5, 15, 25, 35, 45 };
    const original = data;
    try forward1d(allocator, &data);
    try inverse1d(allocator, &data);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse 1d length 2" {
    const allocator = std.testing.allocator;
    var data = [_]i32{ 100, 200 };
    const original = data;
    try forward1d(allocator, &data);
    try inverse1d(allocator, &data);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse 1d length 3" {
    const allocator = std.testing.allocator;
    var data = [_]i32{ 7, 13, 42 };
    const original = data;
    try forward1d(allocator, &data);
    try inverse1d(allocator, &data);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse 1d length 1 noop" {
    const allocator = std.testing.allocator;
    var data = [_]i32{42};
    const original = data;
    try forward1d(allocator, &data);
    try std.testing.expectEqualSlices(i32, &original, &data);
    try inverse1d(allocator, &data);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse 2d roundtrip" {
    const allocator = std.testing.allocator;
    var data: [64]i32 = undefined;
    for (0..64) |i| data[i] = @intCast(i);
    const original = data;
    try forward2d(allocator, &data, 8, 8);
    try inverse2d(allocator, &data, 8, 8);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse 2d non square" {
    const allocator = std.testing.allocator;
    const w = 6;
    const h = 4;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @intCast(i);
    const original = data;
    try forward2d(allocator, &data, w, h);
    try inverse2d(allocator, &data, w, h);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse multi level roundtrip" {
    const allocator = std.testing.allocator;
    const w = 16;
    const h = 16;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @intCast(i);
    const original = data;
    const result = try forwardMultiLevel(allocator, &data, w, h, 3);
    try std.testing.expect(result[0] > 0 and result[1] > 0);
    try inverseMultiLevel(allocator, &data, w, h, 3);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse multi level 5 levels" {
    const allocator = std.testing.allocator;
    const w = 64;
    const h = 64;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @rem(@as(i32, @intCast(i)), 256);
    const original = data;
    _ = try forwardMultiLevel(allocator, &data, w, h, 5);
    try inverseMultiLevel(allocator, &data, w, h, 5);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse multi level odd dims" {
    const allocator = std.testing.allocator;
    const w = 13;
    const h = 11;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @intCast(i);
    const original = data;
    _ = try forwardMultiLevel(allocator, &data, w, h, 3);
    try inverseMultiLevel(allocator, &data, w, h, 3);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward inverse multi level large values" {
    const allocator = std.testing.allocator;
    const w = 32;
    const h = 32;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @as(i32, @intCast(i)) * 100 + 5000;
    const original = data;
    _ = try forwardMultiLevel(allocator, &data, w, h, 4);
    try inverseMultiLevel(allocator, &data, w, h, 4);
    try std.testing.expectEqualSlices(i32, &original, &data);
}

test "forward 1d all zeros" {
    const allocator = std.testing.allocator;
    var data = [_]i32{0} ** 8;
    try forward1d(allocator, &data);
    for (data) |x| try std.testing.expectEqual(@as(i32, 0), x);
}

test "forward 1d constant" {
    const allocator = std.testing.allocator;
    var data = [_]i32{42} ** 8;
    const original = data;
    try forward1d(allocator, &data);
    try inverse1d(allocator, &data);
    try std.testing.expectEqualSlices(i32, &original, &data);
}
