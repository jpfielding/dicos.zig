//! T.87 (ITU-T T.87 / ISO 14495-1) JPEG-LS context model.
//!
//! Maintains the A/B/C/N statistics, the near-aware gradient quantizer, the
//! Golomb parameter derivation, and the run-mode statistics used by both the
//! encoder and the decoder.
//!
//! References: T.87 A.2 (initialization), A.3 (context quantization), A.5
//! (Golomb parameter / limited coding), A.6 (variable update), A.7 (run mode).

const std = @import("std");

/// Number of regular contexts (indices `0..=364`).
pub const NUM_REGULAR_CONTEXTS: usize = 365;
/// Two additional contexts for run-interruption samples (indices `365`, `366`).
pub const NUM_RUN_CONTEXTS: usize = 2;
/// Total context array size (`367`).
pub const NUM_CONTEXTS: usize = NUM_REGULAR_CONTEXTS + NUM_RUN_CONTEXTS;

/// Index of the run-interruption context with RItype = 0 (Ra == Rb).
pub const RUN_CTX_BASE: usize = 365;

/// Bias-correction bounds (T.87 A.6.2, MIN_C / MAX_C).
pub const MIN_C: i32 = -128;
pub const MAX_C: i32 = 127;

/// Default basic thresholds (T.87 A.2.1: BASIC_T1/T2/T3).
const BASIC_T1: i32 = 3;
const BASIC_T2: i32 = 7;
const BASIC_T3: i32 = 21;

/// J-table for run-length coding (T.87 A.7.1.1, Table A.16 -- 32 entries).
pub const J_TABLE = [32]i32{
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,  2,  3,  3,  3,  3,
    4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

/// Smallest `k` such that `2^k >= x` (ceil of log2), for `x >= 1`.
fn ceilLog2(x: i32) i32 {
    var k: i32 = 0;
    while ((@as(i64, 1) << @intCast(k)) < @as(i64, x)) k += 1;
    return k;
}

/// T.87 threshold clamp (A.2.1): returns `lo` when `i` falls outside
/// `[lo, hi]` (note: an over-`hi` value collapses to `lo`, not `hi`).
fn clampThreshold(i: i32, lo: i32, hi: i32) i32 {
    return if (i > hi or i < lo) lo else i;
}

/// T1/T2/T3 quantization thresholds.
pub const Thresholds = struct { t1: i32, t2: i32, t3: i32 };

/// The T.87 context model state used during encoding and decoding.
pub const ContextModel = struct {
    // --- Quantization thresholds (T.87 A.2.1 / A.3) ---
    t1: i32,
    t2: i32,
    t3: i32,

    /// Maximum sample value (`MAXVAL`).
    max_val: i32,
    /// Near-lossless error tolerance (`NEAR`; 0 for lossless).
    near: i32,
    /// Reconstruction range (`RANGE`, T.87 A.3.1).
    range: i32,
    /// Bits needed to represent a mapped/limited value (`qbpp`, T.87 A.5.3).
    qbpp: i32,
    /// Unary escape limit (`LIMIT`, T.87 A.5.3 / A.2).
    limit: i32,

    // --- Per-context statistics ---
    /// A[Q]: sum of absolute prediction errors.
    a: [NUM_CONTEXTS]i32,
    /// B[Q]: bias accumulator.
    b: [NUM_CONTEXTS]i32,
    /// C[Q]: bias correction value.
    c: [NUM_CONTEXTS]i32,
    /// N[Q]: occurrence count.
    n: [NUM_CONTEXTS]i32,
    /// Nn[RItype]: negative-error counters for the two run contexts (A.7.2).
    nn: [2]i32,

    /// Reset threshold -- halve statistics when `N[Q]` reaches this (`RESET`).
    reset: i32,

    // --- Run mode ---
    /// J-table for run-length coding.
    j: [32]i32,
    /// Current run index (`RUNindex`).
    run_index: usize,

    /// Create a new context model for the given `max_val`, `near`, and `reset`.
    pub fn init(max_val: i32, near: i32, reset: i32) ContextModel {
        return withPresets(max_val, near, reset, null, null, null);
    }

    /// Create a context model, optionally overriding the T1/T2/T3 quantization
    /// thresholds (as carried by an LSE ID=1 preset segment, T.87 C.2.4.1.1).
    ///
    /// A `null` override selects the default threshold computed from
    /// `max_val`/`near` per T.87 A.2.1.
    pub fn withPresets(
        max_val: i32,
        near: i32,
        reset: i32,
        t1_override: ?i32,
        t2_override: ?i32,
        t3_override: ?i32,
    ) ContextModel {
        // Derived parameters (T.87 A.2 / A.3.1 / A.5.3).
        const bpp = @max(ceilLog2(max_val + 1), 2);
        const limit = 2 * (bpp + @max(bpp, 8));
        const range = if (near == 0)
            max_val + 1
        else
            @divTrunc(max_val + 2 * near, 2 * near + 1) + 1;
        const qbpp = ceilLog2(range);

        const dt = defaultThresholds(max_val, near);

        // A[Q] initialization (T.87 A.2.1 / A.8): max(2, floor((RANGE+32)/64))
        // for ALL contexts (regular AND run).
        const a_init = @max(@divTrunc(range + 32, 64), 2);

        return .{
            .t1 = t1_override orelse dt.t1,
            .t2 = t2_override orelse dt.t2,
            .t3 = t3_override orelse dt.t3,
            .max_val = max_val,
            .near = near,
            .range = range,
            .qbpp = qbpp,
            .limit = limit,
            .a = @splat(a_init),
            .b = @splat(0),
            .c = @splat(0),
            .n = @splat(1),
            .nn = .{ 0, 0 },
            .reset = reset,
            .j = J_TABLE,
            .run_index = 0,
        };
    }

    /// Compute the default T1/T2/T3 thresholds (T.87 A.2.1).
    pub fn defaultThresholds(max_val: i32, near: i32) Thresholds {
        if (max_val >= 128) {
            const factor = @divTrunc(@min(max_val, 4095) + 128, 256);
            const t1 = clampThreshold(factor * (BASIC_T1 - 2) + 2 + 3 * near, near + 1, max_val);
            const t2 = clampThreshold(factor * (BASIC_T2 - 3) + 3 + 5 * near, t1, max_val);
            const t3 = clampThreshold(factor * (BASIC_T3 - 4) + 4 + 7 * near, t2, max_val);
            return .{ .t1 = t1, .t2 = t2, .t3 = t3 };
        }
        const factor = @divTrunc(256, max_val + 1);
        const t1 = clampThreshold(@max(@divTrunc(BASIC_T1, factor) + 3 * near, 2), near + 1, max_val);
        const t2 = clampThreshold(@max(@divTrunc(BASIC_T2, factor) + 5 * near, 3), t1, max_val);
        const t3 = clampThreshold(@max(@divTrunc(BASIC_T3, factor) + 7 * near, 4), t2, max_val);
        return .{ .t1 = t1, .t2 = t2, .t3 = t3 };
    }

    /// Near-aware gradient quantization into one of 9 buckets (-4..=4), T.87
    /// A.3.3.
    pub inline fn quantizeGradient(self: *const ContextModel, d: i32) i32 {
        if (d <= -self.t3) return -4;
        if (d <= -self.t2) return -3;
        if (d <= -self.t1) return -2;
        if (d < -self.near) return -1;
        if (d <= self.near) return 0;
        if (d < self.t1) return 1;
        if (d < self.t2) return 2;
        if (d < self.t3) return 3;
        return 4;
    }

    pub const ContextIndex = struct { q: usize, sign: i32 };

    /// Compute the context index `Q` and the `sign` (`1` or `-1`) from the
    /// three gradients.
    pub fn getContextIndex(self: *const ContextModel, d1: i32, d2: i32, d3: i32) ContextIndex {
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
        return .{ .q = @intCast(q1 * 81 + q2 * 9 + q3), .sign = sign };
    }

    /// Compute the Golomb-Rice parameter `k` for a regular context `q`
    /// (T.87 A.5.1): smallest `k` with `N[Q] << k >= A[Q]`.
    pub fn computeK(self: *const ContextModel, q: usize) i32 {
        const n = self.n[q];
        if (n == 0) return 0;
        const a = self.a[q];
        var k: i32 = 0;
        while (k < 31 and (n << @intCast(k)) < a) k += 1;
        return k;
    }

    /// Update A/B/N (T.87 A.6.1, code segment A.12) then the bias C (A.6.2,
    /// A.13) for regular context `q` after observing corrected error `err_val`.
    pub fn updateStats(self: *ContextModel, q: usize, err_val: i32) void {
        self.b[q] += err_val * (2 * self.near + 1);
        self.a[q] += if (err_val < 0) -err_val else err_val;
        if (self.n[q] == self.reset) {
            self.a[q] >>= 1;
            self.b[q] = if (self.b[q] >= 0) self.b[q] >> 1 else -((1 - self.b[q]) >> 1);
            self.n[q] >>= 1;
        }
        self.n[q] += 1;
        self.updateBias(q);
    }

    /// Single-step bias update with clamping (T.87 A.6.2, code segment A.13).
    ///
    /// Uses `N[Q]` *after* the increment performed in `updateStats`.
    fn updateBias(self: *ContextModel, q: usize) void {
        if (self.b[q] <= -self.n[q]) {
            if (self.c[q] > MIN_C) self.c[q] -= 1;
            self.b[q] += self.n[q];
            if (self.b[q] <= -self.n[q]) self.b[q] = -self.n[q] + 1;
        } else if (self.b[q] > 0) {
            if (self.c[q] < MAX_C) self.c[q] += 1;
            self.b[q] -= self.n[q];
            if (self.b[q] > 0) self.b[q] = 0;
        }
    }

    /// Advance `RUNindex` after coding a full run segment (T.87 A.7.1.2),
    /// saturating at 31.
    pub fn incrementRunIndex(self: *ContextModel) void {
        if (self.run_index < 31) self.run_index += 1;
    }

    /// Decrement `RUNindex` after coding a run-interruption sample (T.87
    /// A.7.2), saturating at 0.
    pub fn decrementRunIndex(self: *ContextModel) void {
        if (self.run_index > 0) self.run_index -= 1;
    }

    /// Golomb parameter `k` for a run-interruption sample (T.87 A.7.2.2).
    ///
    /// `ri_type` is 0 (Ra == Rb) or 1 (Ra != Rb), selecting run context
    /// `365 + ri_type`.
    pub fn computeKRun(self: *const ContextModel, ri_type: usize) i32 {
        const ctx = RUN_CTX_BASE + ri_type;
        const temp = if (ri_type == 1)
            self.a[RUN_CTX_BASE + 1] + (self.n[RUN_CTX_BASE + 1] >> 1)
        else
            self.a[RUN_CTX_BASE];
        const n = self.n[ctx];
        var k: i32 = 0;
        while (k < 31 and (n << @intCast(k)) < temp) k += 1;
        return k;
    }

    /// Update run-interruption statistics (T.87 A.7.2, code segment A.23).
    ///
    /// `e_mapped` is `EMErrval`; `err_negative` indicates the (corrected)
    /// error was negative.
    pub fn updateRunStats(self: *ContextModel, ri_type: usize, e_mapped: u32, err_negative: bool) void {
        const ctx = RUN_CTX_BASE + ri_type;
        if (err_negative) self.nn[ri_type] += 1;
        self.a[ctx] += @intCast((@as(u64, e_mapped) + 1 - ri_type) >> 1);
        if (self.n[ctx] == self.reset) {
            self.a[ctx] >>= 1;
            self.n[ctx] >>= 1;
            self.nn[ri_type] >>= 1;
        }
        self.n[ctx] += 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const expectEqual = testing.expectEqual;

fn model8bit() ContextModel {
    return ContextModel.init(255, 0, 64);
}

fn model16bit() ContextModel {
    return ContextModel.init(65535, 0, 64);
}

fn expectThresholds(m: ContextModel, t1: i32, t2: i32, t3: i32) !void {
    try expectEqual(t1, m.t1);
    try expectEqual(t2, m.t2);
    try expectEqual(t3, m.t3);
}

test "derived params 8bit" {
    const m = model8bit();
    try expectEqual(@as(i32, 256), m.range);
    try expectEqual(@as(i32, 8), m.qbpp);
    try expectEqual(@as(i32, 32), m.limit);
}

test "derived params 16bit" {
    const m = model16bit();
    try expectEqual(@as(i32, 65536), m.range);
    try expectEqual(@as(i32, 16), m.qbpp);
    try expectEqual(@as(i32, 64), m.limit);
}

test "a init 8bit is 4" {
    const m = model8bit();
    for (0..NUM_CONTEXTS) |i| {
        try expectEqual(@as(i32, 4), m.a[i]);
        try expectEqual(@as(i32, 1), m.n[i]);
        try expectEqual(@as(i32, 0), m.b[i]);
        try expectEqual(@as(i32, 0), m.c[i]);
    }
    try expectEqual([2]i32{ 0, 0 }, m.nn);
}

test "a init 16bit is 1024" {
    const m = model16bit();
    for (0..NUM_CONTEXTS) |i| try expectEqual(@as(i32, 1024), m.a[i]);
}

test "thresholds 8bit" {
    try expectThresholds(model8bit(), 3, 7, 21);
}

test "thresholds 16bit" {
    try expectThresholds(model16bit(), 18, 67, 276);
}

test "thresholds near2 8bit" {
    try expectThresholds(ContextModel.init(255, 2, 64), 9, 17, 35);
}

test "thresholds small maxval" {
    try expectThresholds(ContextModel.init(100, 0, 64), 2, 3, 10);
}

test "quantize near0" {
    const m = model8bit();
    const cases = [_][2]i32{
        .{ 0, 0 },  .{ 1, 1 },  .{ 2, 1 },   .{ 3, 2 },   .{ 6, 2 },   .{ 7, 3 },
        .{ 20, 3 }, .{ 21, 4 }, .{ -1, -1 }, .{ -3, -2 }, .{ -7, -3 }, .{ -21, -4 },
    };
    for (cases) |c| try expectEqual(c[1], m.quantizeGradient(c[0]));
}

test "quantize near2" {
    const m = ContextModel.init(255, 2, 64);
    const cases = [_][2]i32{
        .{ 0, 0 }, .{ 2, 0 },   .{ -2, 0 }, .{ 3, 1 },  .{ -3, -1 },
        .{ 9, 2 }, .{ -9, -2 }, .{ 17, 3 }, .{ 35, 4 }, .{ -35, -4 },
    };
    for (cases) |c| try expectEqual(c[1], m.quantizeGradient(c[0]));
}

test "context index all zero" {
    const ci = model8bit().getContextIndex(0, 0, 0);
    try expectEqual(@as(usize, 0), ci.q);
    try expectEqual(@as(i32, 1), ci.sign);
}

test "context index sign flip" {
    const m = model8bit();
    const c1 = m.getContextIndex(-1, 0, 0);
    const c2 = m.getContextIndex(1, 0, 0);
    try expectEqual(c1.q, c2.q);
    try expectEqual(@as(i32, -1), c1.sign);
    try expectEqual(@as(i32, 1), c2.sign);
}

test "compute k initial 8bit" {
    try expectEqual(@as(i32, 2), model8bit().computeK(0));
}

test "update stats single step bias" {
    var m = model8bit();
    m.updateStats(0, 5);
    try expectEqual(@as(i32, 9), m.a[0]);
    try expectEqual(@as(i32, 0), m.b[0]);
    try expectEqual(@as(i32, 1), m.c[0]);
    try expectEqual(@as(i32, 2), m.n[0]);
}

test "update stats reset halving" {
    var m = ContextModel.init(255, 0, 4);
    m.updateStats(0, 0);
    m.updateStats(0, 0);
    m.updateStats(0, 0);
    try expectEqual(@as(i32, 4), m.n[0]);
    try expectEqual(@as(i32, 4), m.a[0]);
    m.updateStats(0, 0);
    try expectEqual(@as(i32, 3), m.n[0]);
    try expectEqual(@as(i32, 2), m.a[0]);
}

test "bias correction clamps" {
    var m = model8bit();
    for (0..1000) |_| m.updateStats(0, -100);
    try testing.expect(m.c[0] >= MIN_C);

    var m2 = model8bit();
    for (0..1000) |_| m2.updateStats(1, 100);
    try testing.expect(m2.c[1] <= MAX_C);
}

test "compute k run initial 8bit" {
    const m = model8bit();
    try expectEqual(@as(i32, 2), m.computeKRun(0));
    try expectEqual(@as(i32, 2), m.computeKRun(1));
}

test "update run stats counts and reset" {
    var m = ContextModel.init(255, 0, 4);
    const ctx = RUN_CTX_BASE;
    m.updateRunStats(0, 3, true);
    try expectEqual(@as(i32, 6), m.a[ctx]);
    try expectEqual(@as(i32, 1), m.nn[0]);
    try expectEqual(@as(i32, 2), m.n[ctx]);

    m.updateRunStats(0, 1, false);
    m.updateRunStats(0, 1, false);
    try expectEqual(@as(i32, 4), m.n[ctx]);
    m.updateRunStats(0, 1, true);
    try expectEqual(@as(i32, 3), m.n[ctx]);
    try expectEqual(@as(i32, 4), m.a[ctx]);
    try expectEqual(@as(i32, 1), m.nn[0]);
}

test "j table matches spec" {
    try expectEqual([32]i32{
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,  2,  3,  3,  3,  3,
        4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    }, model8bit().j);
}
