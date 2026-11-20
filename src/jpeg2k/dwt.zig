//! 5/3 reversible discrete wavelet transform (lifting scheme).
//!
//! Implements the forward and inverse DWT of ITU-T T.800 Annex F using the
//! lifting factorisation of the Le Gall 5/3 filter.
//!
//! Two families live here:
//! * the **conformant** multi-level transforms (`*Conformant`, floor lifting,
//!   columns-then-rows forward), used by the T.800 pipeline; and
//! * the **frozen legacy** transforms (truncating division, early stop on
//!   degenerate regions), used only to decode v1.0.0 / Go raw-DWT files.
//!
//! 1-D transforms take a caller-supplied `scratch` slice (`len >= n`) so the
//! multi-level drivers allocate once per call rather than once per row.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// 1-D transforms (conformant, floor lifting)
// ---------------------------------------------------------------------------

/// Forward 1-D 5/3 wavelet transform (in-place, lifting scheme).
///
/// Afterwards `signal[0..(n+1)/2]` holds the low-pass and the remainder the
/// high-pass coefficients. `scratch.len` must be `>= signal.len`.
pub fn forward1d(signal: []i32, scratch: []i32) void {
    lift(signal, scratch, .forward, .floor);
}

/// Inverse 1-D 5/3 wavelet transform (in-place, lifting scheme).
pub fn inverse1d(signal: []i32, scratch: []i32) void {
    lift(signal, scratch, .inverse, .floor);
}

/// Legacy forward 1-D transform (truncating division). Frozen for byte
/// compatibility with 1.0.0 codestreams.
fn legacyForward1d(signal: []i32, scratch: []i32) void {
    lift(signal, scratch, .forward, .truncate);
}

/// Legacy inverse 1-D transform (truncating division). Frozen.
fn legacyInverse1d(signal: []i32, scratch: []i32) void {
    lift(signal, scratch, .inverse, .truncate);
}

const Direction = enum { forward, inverse };
const Rounding = enum { floor, truncate };

inline fn div(comptime r: Rounding, a: i32, comptime d: i32) i32 {
    return switch (r) {
        // Arithmetic shift = floor for negatives (T.800 F.4.8.2).
        .floor => a >> comptime std.math.log2_int(u32, d),
        .truncate => @divTrunc(a, d),
    };
}

fn lift(signal: []i32, scratch: []i32, comptime dir: Direction, comptime r: Rounding) void {
    // Wrapping arithmetic: hostile (legacy or crafted) coefficients may sum
    // past i32; Rust release builds wrap there too, so results stay identical.
    const n = signal.len;
    if (n < 2) return;
    std.debug.assert(scratch.len >= n);

    const half = (n + 1) / 2;
    const num_high = n - half;
    const low = scratch[0..half];
    const high = scratch[half..n];

    switch (dir) {
        .forward => {
            for (0..half) |i| low[i] = signal[2 * i];
            for (0..num_high) |i| high[i] = signal[2 * i + 1];
            // Predict: d[i] = x[2i+1] - floor((x[2i] + x[2i+2]) / 2)
            for (0..num_high) |i| {
                const left = low[i];
                const right = if (i + 1 < half) low[i + 1] else left; // symmetric ext.
                high[i] -%= div(r, left +% right, 2);
            }
            // Update: s[i] = x[2i] + floor((d[i-1] + d[i] + 2) / 4)
            for (0..half) |i| {
                const left = updLeft(high, i);
                const right = if (i < num_high) high[i] else left;
                low[i] +%= div(r, left +% right +% 2, 4);
            }
            @memcpy(signal[0..half], low);
            @memcpy(signal[half..n], high);
        },
        .inverse => {
            @memcpy(low, signal[0..half]);
            @memcpy(high, signal[half..n]);
            for (0..half) |i| {
                const left = updLeft(high, i);
                const right = if (i < num_high) high[i] else left;
                low[i] -%= div(r, left +% right +% 2, 4);
            }
            for (0..num_high) |i| {
                const left = low[i];
                const right = if (i + 1 < half) low[i + 1] else left;
                high[i] +%= div(r, left +% right, 2);
            }
            for (0..half) |i| signal[2 * i] = low[i];
            for (0..num_high) |i| signal[2 * i + 1] = high[i];
        },
    }
}

inline fn updLeft(high: []const i32, i: usize) i32 {
    if (i > 0) return high[i - 1];
    if (high.len != 0) return high[0]; // symmetric extension
    return 0;
}

// ---------------------------------------------------------------------------
// 2-D transforms (single level, full buffer; retained for tests/API parity)
// ---------------------------------------------------------------------------

/// Forward 2-D 5/3 DWT -- rows then columns (single level, in place).
pub fn forward2d(gpa: Allocator, data: []i32, width: usize, height: usize) Allocator.Error!void {
    if (width < 2 or height < 2) return;
    const buf = try gpa.alloc(i32, 2 * (width + height));
    defer gpa.free(buf);
    const line = buf[0 .. width + height];
    const scratch = buf[width + height ..];
    rowsPass(data, width, width, height, line, scratch, forward1d);
    colsPass(data, width, width, height, line, scratch, forward1d);
}

/// Inverse 2-D 5/3 DWT -- columns then rows (single level, in place).
pub fn inverse2d(gpa: Allocator, data: []i32, width: usize, height: usize) Allocator.Error!void {
    if (width < 2 or height < 2) return;
    const buf = try gpa.alloc(i32, 2 * (width + height));
    defer gpa.free(buf);
    const line = buf[0 .. width + height];
    const scratch = buf[width + height ..];
    colsPass(data, width, width, height, line, scratch, inverse1d);
    rowsPass(data, width, width, height, line, scratch, inverse1d);
}

const Fn1d = fn ([]i32, []i32) void;

fn rowsPass(data: []i32, stride: usize, width: usize, height: usize, line: []i32, scratch: []i32, comptime f: Fn1d) void {
    const row = line[0..width];
    for (0..height) |y| {
        const off = y * stride;
        @memcpy(row, data[off .. off + width]);
        f(row, scratch);
        @memcpy(data[off .. off + width], row);
    }
}

fn colsPass(data: []i32, stride: usize, width: usize, height: usize, line: []i32, scratch: []i32, comptime f: Fn1d) void {
    const col = line[0..height];
    for (0..width) |x| {
        for (col, 0..) |*slot, y| slot.* = data[y * stride + x];
        f(col, scratch);
        for (col, 0..) |v, y| data[y * stride + x] = v;
    }
}

// ---------------------------------------------------------------------------
// Legacy multi-level transforms (FROZEN: truncating, early stop)
// ---------------------------------------------------------------------------

pub const Dims = struct { usize, usize };

/// Forward multi-level 2-D DWT (LEGACY truncating pipeline). Rows then
/// columns; stops at the first degenerate (< 2) region. Returns the final LL
/// dimensions. Do not change -- legacy fixtures pin this behaviour.
pub fn forwardMultiLevel(gpa: Allocator, data: []i32, width: usize, height: usize, levels: usize) Allocator.Error!Dims {
    const buf = try gpa.alloc(i32, 2 * (width + height));
    defer gpa.free(buf);
    const line = buf[0 .. width + height];
    const scratch = buf[width + height ..];

    var ll_w = width;
    var ll_h = height;
    for (0..levels) |_| {
        if (ll_w < 2 or ll_h < 2) break;
        rowsPass(data, width, ll_w, ll_h, line, scratch, legacyForward1d);
        colsPass(data, width, ll_w, ll_h, line, scratch, legacyForward1d);
        ll_w = (ll_w + 1) / 2;
        ll_h = (ll_h + 1) / 2;
    }
    return .{ ll_w, ll_h };
}

/// Inverse multi-level 2-D DWT (LEGACY truncating pipeline).
pub fn inverseMultiLevel(gpa: Allocator, data: []i32, width: usize, height: usize, levels: usize) Allocator.Error!void {
    const buf = try gpa.alloc(i32, 2 * (width + height));
    defer gpa.free(buf);
    const line = buf[0 .. width + height];
    const scratch = buf[width + height ..];

    var level = levels;
    while (level > 0) {
        level -= 1;
        const ll_w = llDim(width, level);
        const ll_h = llDim(height, level);
        if (ll_w < 2 or ll_h < 2) continue;
        colsPass(data, width, ll_w, ll_h, line, scratch, legacyInverse1d);
        rowsPass(data, width, ll_w, ll_h, line, scratch, legacyInverse1d);
    }
}

/// `ceil(v / 2^k)`, saturating to 1 for large `k` (matches repeated
/// `div_ceil(2)` for `v >= 1`).
fn llDim(v: usize, k: usize) usize {
    if (k >= @bitSizeOf(usize)) return if (v == 0) 0 else 1;
    const sh: std.math.Log2Int(usize) = @intCast(k);
    const d = @as(usize, 1) << sh;
    return (v >> sh) + @intFromBool(v & (d - 1) != 0);
}

// ---------------------------------------------------------------------------
// Conformant multi-level transforms (T.800 F.4.8 -- floor lifting)
// ---------------------------------------------------------------------------
//
// Differences from the legacy path: floor lifting; degenerate 1xN / Nx1
// regions are transformed along the dimension of length >= 2 (1x1 is a
// no-op) instead of stopping early; exactly `levels` levels; forward is
// columns-then-rows (as OpenJPEG / T.800), inverse rows-then-columns.

/// Forward multi-level 2-D 5/3 DWT (conformant). Returns final LL dims.
pub fn forwardMultiLevelConformant(gpa: Allocator, data: []i32, width: usize, height: usize, levels: usize) Allocator.Error!Dims {
    const buf = try gpa.alloc(i32, 2 * (width + height));
    defer gpa.free(buf);
    const line = buf[0 .. width + height];
    const scratch = buf[width + height ..];

    var ll_w = width;
    var ll_h = height;
    for (0..levels) |_| {
        colsPass(data, width, ll_w, ll_h, line, scratch, forward1d);
        rowsPass(data, width, ll_w, ll_h, line, scratch, forward1d);
        ll_w = (ll_w + 1) / 2;
        ll_h = (ll_h + 1) / 2;
    }
    return .{ ll_w, ll_h };
}

/// Inverse multi-level 2-D 5/3 DWT (conformant).
pub fn inverseMultiLevelConformant(gpa: Allocator, data: []i32, width: usize, height: usize, levels: usize) Allocator.Error!void {
    const buf = try gpa.alloc(i32, 2 * (width + height));
    defer gpa.free(buf);
    const line = buf[0 .. width + height];
    const scratch = buf[width + height ..];

    var level = levels;
    while (level > 0) {
        level -= 1;
        const ll_w = llDim(width, level);
        const ll_h = llDim(height, level);
        rowsPass(data, width, ll_w, ll_h, line, scratch, inverse1d);
        colsPass(data, width, ll_w, ll_h, line, scratch, inverse1d);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn rt1d(original: []const i32) !void {
    var data: [32]i32 = undefined;
    var scratch: [32]i32 = undefined;
    const d = data[0..original.len];
    @memcpy(d, original);
    forward1d(d, &scratch);
    inverse1d(d, &scratch);
    try testing.expectEqualSlices(i32, original, d);
}

test "forward inverse 1d roundtrip" {
    try rt1d(&.{ 10, 20, 30, 40, 50, 60, 70, 80 });
}

test "forward inverse 1d odd length" {
    try rt1d(&.{ 5, 15, 25, 35, 45 });
}

test "forward inverse 1d length 2" {
    try rt1d(&.{ 100, 200 });
}

test "forward inverse 1d length 3" {
    try rt1d(&.{ 7, 13, 42 });
}

test "forward inverse 1d length 1 noop" {
    var d = [_]i32{42};
    var s: [1]i32 = undefined;
    forward1d(&d, &s);
    try testing.expectEqual(@as(i32, 42), d[0]);
    inverse1d(&d, &s);
    try testing.expectEqual(@as(i32, 42), d[0]);
}

test "forward inverse 2d roundtrip" {
    var data: [64]i32 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(i);
    const orig = data;
    try forward2d(testing.allocator, &data, 8, 8);
    try inverse2d(testing.allocator, &data, 8, 8);
    try testing.expectEqualSlices(i32, &orig, &data);
}

test "forward inverse 2d non square" {
    var data: [24]i32 = undefined;
    for (&data, 0..) |*v, i| v.* = @intCast(i);
    const orig = data;
    try forward2d(testing.allocator, &data, 6, 4);
    try inverse2d(testing.allocator, &data, 6, 4);
    try testing.expectEqualSlices(i32, &orig, &data);
}

fn legacyRt(w: usize, h: usize, levels: usize, f: *const fn (i32) i32) !void {
    const a = testing.allocator;
    const orig = try a.alloc(i32, w * h);
    defer a.free(orig);
    for (orig, 0..) |*v, i| v.* = f(@intCast(i));
    const data = try a.dupe(i32, orig);
    defer a.free(data);
    const ll = try forwardMultiLevel(a, data, w, h, levels);
    try testing.expect(ll[0] > 0 and ll[1] > 0);
    try inverseMultiLevel(a, data, w, h, levels);
    try testing.expectEqualSlices(i32, orig, data);
}

fn ident(x: i32) i32 {
    return x;
}
fn mod256(x: i32) i32 {
    return @mod(x, 256);
}
fn big(x: i32) i32 {
    return x * 100 + 5000;
}

test "forward inverse multi level roundtrip" {
    try legacyRt(16, 16, 3, &ident);
}

test "forward inverse multi level 5 levels" {
    try legacyRt(64, 64, 5, &mod256);
}

test "forward inverse multi level odd dims" {
    try legacyRt(13, 11, 3, &ident);
}

test "forward inverse multi level large values" {
    try legacyRt(32, 32, 4, &big);
}

test "forward 1d all zeros" {
    var d: [8]i32 = @splat(0);
    var s: [8]i32 = undefined;
    forward1d(&d, &s);
    for (d) |v| try testing.expectEqual(@as(i32, 0), v);
}

test "forward 1d constant" {
    try rt1d(&(@as([8]i32, @splat(42))));
}

// -- Brute-force T.800 F.4.8.2.1 reference ---------------------------------

fn mirror(n: isize, i: isize) usize {
    if (n == 1) return 0;
    const period = 2 * (n - 1);
    var k = @mod(i, period);
    if (k >= n) k = period - k;
    return @intCast(k);
}

fn refForward1d(x: []const i32, out: []i32) void {
    const n = x.len;
    if (n < 2) {
        @memcpy(out[0..n], x);
        return;
    }
    const half = (n + 1) / 2;
    const num_high = n - half;
    const ni: isize = @intCast(n);
    var y: [32]i32 = undefined;
    for (0..num_high) |i| {
        const idx = 2 * i + 1;
        const ii: isize = @intCast(idx);
        const a = x[mirror(ni, ii - 1)];
        const b = x[mirror(ni, ii + 1)];
        y[idx] = x[idx] - @divFloor(a + b, 2);
    }
    for (0..half) |i| {
        const idx = 2 * i;
        const ii: isize = @intCast(idx);
        const a = y[mirror(ni, ii - 1)];
        const b = y[mirror(ni, ii + 1)];
        y[idx] = x[idx] + @divFloor(a + b + 2, 4);
    }
    for (0..half) |i| out[i] = y[2 * i];
    for (0..num_high) |i| out[half + i] = y[2 * i + 1];
}

fn signedRamp(n: usize, out: []i32) void {
    const ni: i32 = @intCast(n);
    for (0..n) |iu| {
        const i: i32 = @intCast(iu);
        out[iu] = (i * 7 - 3 * ni) * (@rem(i, 3) - 1);
    }
}

test "forward 1d matches reference with negatives" {
    var s: [32]i32 = undefined;
    for (1..18) |n| {
        var x: [32]i32 = undefined;
        signedRamp(n, &x);
        var got: [32]i32 = undefined;
        @memcpy(got[0..n], x[0..n]);
        forward1d(got[0..n], &s);
        var want: [32]i32 = undefined;
        refForward1d(x[0..n], &want);
        try testing.expectEqualSlices(i32, want[0..n], got[0..n]);
    }
}

test "inverse 1d inverts reference with negatives" {
    var s: [32]i32 = undefined;
    for (1..18) |n| {
        var x: [32]i32 = undefined;
        signedRamp(n, &x);
        var a: [32]i32 = undefined;
        @memcpy(a[0..n], x[0..n]);
        forward1d(a[0..n], &s);
        inverse1d(a[0..n], &s);
        try testing.expectEqualSlices(i32, x[0..n], a[0..n]);

        var b: [32]i32 = undefined;
        refForward1d(x[0..n], &b);
        inverse1d(b[0..n], &s);
        try testing.expectEqualSlices(i32, x[0..n], b[0..n]);
    }
}

test "forward 1d uses floor not truncation" {
    const x = [_]i32{ -1, 5, -2 };
    var s: [3]i32 = undefined;
    var floored = x;
    forward1d(&floored, &s);
    var want: [3]i32 = undefined;
    refForward1d(&x, &want);
    try testing.expectEqualSlices(i32, &want, &floored);
    var trunc = x;
    legacyForward1d(&trunc, &s);
    try testing.expect(!std.mem.eql(i32, &floored, &trunc));
}

fn conformantRt(w: usize, h: usize, levels: usize, seed: i32) !void {
    const a = testing.allocator;
    const orig = try a.alloc(i32, w * h);
    defer a.free(orig);
    for (orig, 0..) |*v, i| v.* = @rem(@as(i32, @intCast(i)) *% seed, 4096) - 2048;
    const data = try a.dupe(i32, orig);
    defer a.free(data);
    _ = try forwardMultiLevelConformant(a, data, w, h, levels);
    try inverseMultiLevelConformant(a, data, w, h, levels);
    try testing.expectEqualSlices(i32, orig, data);
}

test "conformant roundtrip degenerate 13x7 5 levels" {
    try conformantRt(13, 7, 5, 31);
}

test "conformant roundtrip 1x16" {
    try conformantRt(1, 16, 4, 17);
}

test "conformant roundtrip 16x1" {
    try conformantRt(16, 1, 4, 23);
}

test "conformant roundtrip 1x1 noop" {
    var d = [_]i32{42};
    _ = try forwardMultiLevelConformant(testing.allocator, &d, 1, 1, 3);
    try testing.expectEqual(@as(i32, 42), d[0]);
    try inverseMultiLevelConformant(testing.allocator, &d, 1, 1, 3);
    try testing.expectEqual(@as(i32, 42), d[0]);
}

test "conformant roundtrip square and odd" {
    try conformantRt(64, 64, 5, 3);
    try conformantRt(17, 13, 3, 5);
    try conformantRt(2, 2, 1, 9);
}

test "conformant transforms degenerate region" {
    const orig = [_]i32{ 10, 20, 30, 40 };
    var d = orig;
    _ = try forwardMultiLevelConformant(testing.allocator, &d, 1, 4, 1);
    try testing.expect(!std.mem.eql(i32, &orig, &d));
    try inverseMultiLevelConformant(testing.allocator, &d, 1, 4, 1);
    try testing.expectEqualSlices(i32, &orig, &d);
}
