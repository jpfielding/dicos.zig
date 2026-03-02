//! JPEG-LS context model.
//!
//! Maintains the A/B/C/N statistic arrays, gradient quantization tables,
//! and the Golomb parameter `k` computation used by both encoder and decoder.
//!
//! Reference: ISO/IEC 14495-1, Sections A.2 -- A.6.

const std = @import("std");
const predictor = @import("predictor.zig");
const clampVal = predictor.clampVal;

/// Number of regular contexts (5 * 9 * 9 = 405 possible, but after sign
/// normalisation the first non-zero quantized gradient is always >= 0,
/// giving a maximum index of 4*81 + 4*9 + 4 = 364, i.e. 365 contexts).
const NUM_REGULAR_CONTEXTS: usize = 365;

/// Two additional contexts for run interruption samples (A.4.2).
const NUM_RUN_CONTEXTS: usize = 2;

/// Total context array size.
pub const NUM_CONTEXTS: usize = NUM_REGULAR_CONTEXTS + NUM_RUN_CONTEXTS;

/// J-table values for run-length coding (ISO 14495-1, Table A.3).
const J_TABLE = [32]i32{
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

/// The context model state used during encoding and decoding.
pub const ContextModel = struct {
    // --- Quantization thresholds (ISO A.3) ---
    t1: i32,
    t2: i32,
    t3: i32,

    /// Maximum sample value (`(1 << precision) - 1`).
    max_val: i32,

    // --- Per-context statistics ---
    /// A[Q]: sum of absolute prediction errors.
    a: []i32,
    /// B[Q]: sum of prediction errors (bias accumulator).
    b: []i32,
    /// C[Q]: bias correction value.
    c: []i32,
    /// N[Q]: occurrence count.
    n: []i32,

    /// Reset threshold -- halve statistics when `N[Q]` reaches this.
    reset: i32,

    // --- Run mode ---
    /// J-table for run-length coding.
    j: [32]i32,
    /// Current run index (reset to 0 at the start of each line).
    run_index: usize,

    /// Allocator used for dynamic arrays.
    allocator: std.mem.Allocator,

    /// Create a new context model for the given `max_val`, `near`, and `reset_val`.
    ///
    /// `near` is the near-lossless tolerance (0 for lossless).
    pub fn init(allocator: std.mem.Allocator, max_val: i32, near: i32, reset_val: i32) !ContextModel {
        // Compute quantization thresholds (ISO A.3).
        const factor = @divTrunc(@min(max_val, 4095) + 128, 256);

        const t1 = clampVal(factor * (3 - 2) + 2 + 3 * near, near + 1, max_val);
        const t2 = clampVal(factor * (7 - 3) + 3 + 5 * near, t1, max_val);
        const t3 = clampVal(factor * (21 - 4) + 4 + 7 * near, t2, max_val);

        const a = try allocator.alloc(i32, NUM_CONTEXTS);
        const b_arr = try allocator.alloc(i32, NUM_CONTEXTS);
        const c_arr = try allocator.alloc(i32, NUM_CONTEXTS);
        const n_arr = try allocator.alloc(i32, NUM_CONTEXTS);

        // Initialise statistics (ISO A.2): A[Q] = 4, N[Q] = 1.
        for (0..NUM_CONTEXTS) |i| {
            a[i] = 4;
            b_arr[i] = 0;
            c_arr[i] = 0;
            n_arr[i] = 1;
        }

        return .{
            .t1 = t1,
            .t2 = t2,
            .t3 = t3,
            .max_val = max_val,
            .a = a,
            .b = b_arr,
            .c = c_arr,
            .n = n_arr,
            .reset = reset_val,
            .j = J_TABLE,
            .run_index = 0,
            .allocator = allocator,
        };
    }

    /// Free dynamic arrays.
    pub fn deinit(self: *ContextModel) void {
        self.allocator.free(self.a);
        self.allocator.free(self.b);
        self.allocator.free(self.c);
        self.allocator.free(self.n);
    }

    /// Quantize a single gradient value `d` into one of 9 buckets (-4..=4).
    pub inline fn quantizeGradient(self: *const ContextModel, d: i32) i32 {
        if (d <= -self.t3) {
            return -4;
        } else if (d <= -self.t2) {
            return -3;
        } else if (d <= -self.t1) {
            return -2;
        } else if (d < 0) {
            return -1;
        } else if (d == 0) {
            return 0;
        } else if (d < self.t1) {
            return 1;
        } else if (d < self.t2) {
            return 2;
        } else if (d < self.t3) {
            return 3;
        } else {
            return 4;
        }
    }

    /// Compute the context index `Q` and the `sign` from the three gradients.
    ///
    /// The sign normalisation ensures that the first non-zero quantized
    /// gradient is always non-negative. When the sign is flipped, the
    /// prediction error must also be negated.
    ///
    /// Returns `{ Q, sign }` where `sign` is `1` or `-1`.
    pub fn getContextIndex(self: *const ContextModel, d1: i32, d2: i32, d3: i32) struct { usize, i32 } {
        var q1 = self.quantizeGradient(d1);
        var q2 = self.quantizeGradient(d2);
        var q3 = self.quantizeGradient(d3);

        var sign: i32 = 1;
        if (q1 < 0 or (q1 == 0 and q2 < 0) or (q1 == 0 and q2 == 0 and q3 < 0)) {
            q1 = -q1;
            q2 = -q2;
            q3 = -q3;
            sign = -1;
        }

        // Index in [0, 364].
        const index: usize = @intCast(q1 * 81 + q2 * 9 + q3);
        return .{ index, sign };
    }

    /// Compute the Golomb-Rice parameter `k` for context `q`.
    ///
    /// `k` is the smallest integer such that `N[Q] << k >= A[Q]`.
    /// Capped at 31 to prevent shift overflow.
    pub fn computeK(self: *const ContextModel, q: usize) i32 {
        const n_val = self.n[q];
        if (n_val == 0) {
            return 0;
        }
        const a_val = self.a[q];
        // Use i64 to avoid overflow during the shift comparison.
        var k: i32 = 0;
        while (k < 31 and (@as(i64, n_val) << @as(u6, @intCast(k))) < @as(i64, a_val)) {
            k += 1;
        }
        return k;
    }

    /// Update the A/B/C/N statistics for context `q` after observing `err_val`.
    ///
    /// `err_val` is the prediction error *before* sign adjustment (i.e. the
    /// value used for the mapped-error computation, not the raw pixel diff).
    ///
    /// Uses saturating arithmetic to prevent overflow with 16-bit image data
    /// where prediction errors can be large.
    pub fn updateStats(self: *ContextModel, q: usize, err_val: i32) void {
        self.b[q] = self.b[q] +| err_val;
        // Compute |err_val| safely -- if err_val is minInt, saturate to maxInt.
        const abs_err: i32 = if (err_val == std.math.minInt(i32))
            std.math.maxInt(i32)
        else if (err_val < 0)
            -err_val
        else
            err_val;
        self.a[q] = self.a[q] +| abs_err;

        // Halve when N reaches reset threshold.
        if (self.n[q] >= self.reset) {
            self.a[q] = @divTrunc(self.a[q], 2);
            self.b[q] = @divTrunc(self.b[q], 2);
            self.n[q] = @divTrunc(self.n[q], 2);
        }
        self.n[q] = self.n[q] +| 1;

        // Bias correction update.
        self.updateBias(q);
    }

    /// Adjust the bias correction variable C[Q] and keep B[Q] in range.
    fn updateBias(self: *ContextModel, q: usize) void {
        if (self.b[q] <= -self.n[q]) {
            self.b[q] += self.n[q];
            self.c[q] -= 1;
            if (self.b[q] <= -self.n[q]) {
                self.b[q] += self.n[q];
                self.c[q] -= 1;
            }
        } else if (self.b[q] > 0) {
            self.b[q] -= self.n[q];
            self.c[q] += 1;
            if (self.b[q] > 0) {
                self.b[q] -= self.n[q];
                self.c[q] += 1;
            }
        }

        // Clamp C[Q] to [-128, 127].
        self.c[q] = std.math.clamp(self.c[q], -128, 127);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Helper: create a default 8-bit lossless context model.
fn model8bit() !ContextModel {
    return ContextModel.init(testing.allocator, 255, 0, 64);
}

/// Helper: create a default 16-bit lossless context model.
fn model16bit() !ContextModel {
    return ContextModel.init(testing.allocator, 65535, 0, 64);
}

// -- Threshold tests --

test "thresholds 8bit" {
    var m = try model8bit();
    defer m.deinit();
    try testing.expectEqual(@as(i32, 3), m.t1);
    try testing.expectEqual(@as(i32, 7), m.t2);
    try testing.expectEqual(@as(i32, 21), m.t3);
}

test "thresholds 16bit" {
    var m = try model16bit();
    defer m.deinit();
    // factor = (4095+128)/256 = 16
    // T1 = 16*1 + 2 = 18
    // T2 = 16*4 + 3 = 67
    // T3 = 16*17 + 4 = 276
    try testing.expectEqual(@as(i32, 18), m.t1);
    try testing.expectEqual(@as(i32, 67), m.t2);
    try testing.expectEqual(@as(i32, 276), m.t3);
}

// -- Gradient quantization --

test "quantize zero" {
    var m = try model8bit();
    defer m.deinit();
    try testing.expectEqual(@as(i32, 0), m.quantizeGradient(0));
}

test "quantize positive buckets" {
    var m = try model8bit();
    defer m.deinit();
    // T1=3, T2=7, T3=21
    try testing.expectEqual(@as(i32, 1), m.quantizeGradient(1)); // 0 < d < T1
    try testing.expectEqual(@as(i32, 1), m.quantizeGradient(2));
    try testing.expectEqual(@as(i32, 2), m.quantizeGradient(3)); // T1 <= d < T2
    try testing.expectEqual(@as(i32, 2), m.quantizeGradient(6));
    try testing.expectEqual(@as(i32, 3), m.quantizeGradient(7)); // T2 <= d < T3
    try testing.expectEqual(@as(i32, 3), m.quantizeGradient(20));
    try testing.expectEqual(@as(i32, 4), m.quantizeGradient(21)); // d >= T3
    try testing.expectEqual(@as(i32, 4), m.quantizeGradient(100));
}

test "quantize negative buckets" {
    var m = try model8bit();
    defer m.deinit();
    try testing.expectEqual(@as(i32, -1), m.quantizeGradient(-1));
    try testing.expectEqual(@as(i32, -1), m.quantizeGradient(-2));
    try testing.expectEqual(@as(i32, -2), m.quantizeGradient(-3));
    try testing.expectEqual(@as(i32, -3), m.quantizeGradient(-7));
    try testing.expectEqual(@as(i32, -4), m.quantizeGradient(-21));
    try testing.expectEqual(@as(i32, -4), m.quantizeGradient(-100));
}

// -- Context index --

test "context index all zero" {
    var m = try model8bit();
    defer m.deinit();
    const result = m.getContextIndex(0, 0, 0);
    try testing.expectEqual(@as(usize, 0), result[0]);
    try testing.expectEqual(@as(i32, 1), result[1]);
}

test "context index sign flip" {
    var m = try model8bit();
    defer m.deinit();
    // D1=-1 (Q1=-1) -> first nonzero is negative -> flip
    const result1 = m.getContextIndex(-1, 0, 0);
    const result2 = m.getContextIndex(1, 0, 0);
    try testing.expectEqual(result1[0], result2[0]);
    try testing.expectEqual(@as(i32, -1), result1[1]);
    try testing.expectEqual(@as(i32, 1), result2[1]);
}

// -- Golomb k --

test "compute k initial" {
    var m = try model8bit();
    defer m.deinit();
    // A=4, N=1 -> k: 1<<k >= 4 -> k=2
    try testing.expectEqual(@as(i32, 2), m.computeK(0));
}

test "compute k zero n" {
    var m = try model8bit();
    defer m.deinit();
    m.n[0] = 0;
    try testing.expectEqual(@as(i32, 0), m.computeK(0));
}

// -- Stats update --

test "update stats basic" {
    var m = try model8bit();
    defer m.deinit();
    // Initial: A=4, B=0, N=1
    m.updateStats(0, 5);
    try testing.expectEqual(@as(i32, 9), m.a[0]); // 4 + |5| = 9
    // B starts at 0 + 5 = 5, then bias correction:
    //   B=5 > 0: B -= N(2) => 3, C++; still > 0: B -= 2 => 1, C++
    try testing.expectEqual(@as(i32, 1), m.b[0]);
    try testing.expectEqual(@as(i32, 2), m.c[0]);
    try testing.expectEqual(@as(i32, 2), m.n[0]);
}

test "update stats reset" {
    var m = try ContextModel.init(testing.allocator, 255, 0, 4);
    defer m.deinit();
    // Initial: A=4, N=1.
    m.updateStats(0, 0); // N: 1 (not >= 4) -> N = 2
    m.updateStats(0, 0); // N: 2 (not >= 4) -> N = 3
    m.updateStats(0, 0); // N: 3 (not >= 4) -> N = 4
    try testing.expectEqual(@as(i32, 4), m.n[0]);
    m.updateStats(0, 0); // N: 4 (>= 4) -> halve N to 2, then N++ = 3
    try testing.expectEqual(@as(i32, 3), m.n[0]);
}

test "bias correction clamp" {
    {
        var m = try model8bit();
        defer m.deinit();
        // Drive C[0] below -128
        var i: usize = 0;
        while (i < 300) : (i += 1) {
            m.updateStats(0, -100);
        }
        try testing.expect(m.c[0] >= -128);
    }

    {
        var m2 = try model8bit();
        defer m2.deinit();
        // Drive C[1] above 127
        var i: usize = 0;
        while (i < 300) : (i += 1) {
            m2.updateStats(1, 100);
        }
        try testing.expect(m2.c[1] <= 127);
    }
}

// -- Initialisation --

test "initial stats" {
    var m = try model8bit();
    defer m.deinit();
    for (0..NUM_CONTEXTS) |i| {
        try testing.expectEqual(@as(i32, 4), m.a[i]);
        try testing.expectEqual(@as(i32, 0), m.b[i]);
        try testing.expectEqual(@as(i32, 0), m.c[i]);
        try testing.expectEqual(@as(i32, 1), m.n[i]);
    }
}

test "j table length" {
    var m = try model8bit();
    defer m.deinit();
    try testing.expectEqual(@as(usize, 32), m.j.len);
    try testing.expectEqual(@as(i32, 0), m.j[0]);
    try testing.expectEqual(@as(i32, 15), m.j[31]);
}
