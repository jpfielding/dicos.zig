//! LOCO-I Median Edge Detection (MED) predictor.
//!
//! The predictor selects between three candidates based on the local
//! gradient pattern, effectively detecting vertical and horizontal edges
//! and choosing the prediction that follows the dominant edge direction.

/// Predict the current sample using the MED (Median Edge Detection) rule.
///
/// - `ra`: left neighbour (a)
/// - `rb`: above neighbour (b)
/// - `rc`: above-left neighbour (c)
///
/// Returns the predicted value before bias correction and clamping.
pub inline fn predictMed(ra: i32, rb: i32, rc: i32) i32 {
    if (rc >= @max(ra, rb)) {
        // Vertical edge detected -- predict the smaller of a, b.
        return @min(ra, rb);
    } else if (rc <= @min(ra, rb)) {
        // Horizontal edge detected -- predict the larger of a, b.
        return @max(ra, rb);
    } else {
        // No strong edge -- use the plane predictor.
        return ra + rb - rc;
    }
}

/// Clamp `val` to the inclusive range `[lo, hi]`.
pub inline fn clampVal(val: i32, lo: i32, hi: i32) i32 {
    if (val < lo) {
        return lo;
    } else if (val > hi) {
        return hi;
    } else {
        return val;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "med no edge" {
    // rc not extreme -- plane predictor: a + b - c = 10 + 20 - 15 = 15
    try testing.expectEqual(@as(i32, 15), predictMed(10, 20, 15));
}

test "med vertical edge" {
    // rc >= max(a, b) => min(a, b)
    // a=5, b=3, c=10 => c >= 5 => min(5,3) = 3
    try testing.expectEqual(@as(i32, 3), predictMed(5, 3, 10));
}

test "med horizontal edge" {
    // rc <= min(a, b) => max(a, b)
    // a=5, b=3, c=1 => c <= 3 => max(5,3) = 5
    try testing.expectEqual(@as(i32, 5), predictMed(5, 3, 1));
}

test "med all equal" {
    try testing.expectEqual(@as(i32, 100), predictMed(100, 100, 100));
}

test "med zero" {
    try testing.expectEqual(@as(i32, 0), predictMed(0, 0, 0));
}

test "med large values" {
    // 16-bit range
    const a: i32 = 60000;
    const b: i32 = 50000;
    const c: i32 = 55000;
    // plane: 60000 + 50000 - 55000 = 55000
    try testing.expectEqual(@as(i32, 55000), predictMed(a, b, c));
}

test "clamp within range" {
    try testing.expectEqual(@as(i32, 50), clampVal(50, 0, 255));
}

test "clamp below range" {
    try testing.expectEqual(@as(i32, 0), clampVal(-10, 0, 255));
}

test "clamp above range" {
    try testing.expectEqual(@as(i32, 255), clampVal(300, 0, 255));
}

test "clamp at boundaries" {
    try testing.expectEqual(@as(i32, 0), clampVal(0, 0, 255));
    try testing.expectEqual(@as(i32, 255), clampVal(255, 0, 255));
}
