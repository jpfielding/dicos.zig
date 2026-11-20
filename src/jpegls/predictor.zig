//! LOCO-I Median Edge Detection (MED) predictor.
//!
//! The predictor selects between three candidates based on the local
//! gradient pattern, effectively detecting vertical and horizontal edges
//! and choosing the prediction that follows the dominant edge direction.

const std = @import("std");

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
    }
    // No strong edge -- use the plane predictor.
    return ra + rb - rc;
}

/// Clamp `val` to the inclusive range `[lo, hi]` (`lo` wins if `lo > hi`).
pub inline fn clamp(val: i32, lo: i32, hi: i32) i32 {
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

/// `|x|` as `i32` for values well inside the `i32` range.
pub inline fn iabs(x: i32) i32 {
    return if (x < 0) -x else x;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expectEqual = std.testing.expectEqual;

test "med no edge" {
    try expectEqual(@as(i32, 15), predictMed(10, 20, 15));
}

test "med vertical edge" {
    try expectEqual(@as(i32, 3), predictMed(5, 3, 10));
}

test "med horizontal edge" {
    try expectEqual(@as(i32, 5), predictMed(5, 3, 1));
}

test "med all equal" {
    try expectEqual(@as(i32, 100), predictMed(100, 100, 100));
}

test "med zero" {
    try expectEqual(@as(i32, 0), predictMed(0, 0, 0));
}

test "med large values" {
    try expectEqual(@as(i32, 55000), predictMed(60000, 50000, 55000));
}

test "clamp within range" {
    try expectEqual(@as(i32, 50), clamp(50, 0, 255));
}

test "clamp below range" {
    try expectEqual(@as(i32, 0), clamp(-10, 0, 255));
}

test "clamp above range" {
    try expectEqual(@as(i32, 255), clamp(300, 0, 255));
}

test "clamp at boundaries" {
    try expectEqual(@as(i32, 0), clamp(0, 0, 255));
    try expectEqual(@as(i32, 255), clamp(255, 0, 255));
}
