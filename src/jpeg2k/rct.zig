//! Reversible Color Transform (ITU-T T.800 Annex G).
//!
//! For single-component (grayscale) images this is the identity transform.
//! Provided for completeness; the DICOS codec uses single-component images.

const std = @import("std");

/// Forward RCT: RGB -> YCbCr (reversible).
///
/// `r`, `g`, `b` are modified in place to become Y, Cb, Cr respectively.
pub fn forwardRctInPlace(r: []i32, g: []i32, b: []i32) void {
    const n = r.len;
    for (0..n) |i| {
        const ri = r[i];
        const gi = g[i];
        const bi = b[i];
        r[i] = @divFloor(ri + 2 * gi + bi, 4); // Y
        g[i] = bi - gi; // Cb
        b[i] = ri - gi; // Cr
    }
}

/// Inverse RCT: YCbCr -> RGB (reversible).
///
/// `y`, `cb`, `cr` are modified in place to become R, G, B respectively.
pub fn inverseRctInPlace(y: []i32, cb: []i32, cr: []i32) void {
    const n = y.len;
    for (0..n) |i| {
        const yi = y[i];
        const cbi = cb[i];
        const cri = cr[i];
        const g_val = yi - @divFloor(cbi + cri, 4);
        y[i] = cri + g_val; // R
        cb[i] = g_val; // G
        cr[i] = cbi + g_val; // B
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "rct roundtrip" {
    var r = [_]i32{ 100, 200, 50, 0, 255 };
    var g = [_]i32{ 150, 100, 200, 128, 64 };
    var b = [_]i32{ 200, 50, 100, 255, 0 };

    const orig_r = r;
    const orig_g = g;
    const orig_b = b;

    forwardRctInPlace(&r, &g, &b);
    inverseRctInPlace(&r, &g, &b);

    try std.testing.expectEqualSlices(i32, &orig_r, &r);
    try std.testing.expectEqualSlices(i32, &orig_g, &g);
    try std.testing.expectEqualSlices(i32, &orig_b, &b);
}

test "rct identity grayscale" {
    // For a single-component image the RCT is not applied.
    // This test verifies the logic that the transform is reversible
    // even when all components are equal (grayscale-like).
    var r = [_]i32{128} ** 10;
    var g = [_]i32{128} ** 10;
    var b = [_]i32{128} ** 10;

    forwardRctInPlace(&r, &g, &b);
    // Y = (128 + 256 + 128)/4 = 128, Cb = 0, Cr = 0
    for (r) |v| try std.testing.expectEqual(@as(i32, 128), v);
    for (g) |v| try std.testing.expectEqual(@as(i32, 0), v);
    for (b) |v| try std.testing.expectEqual(@as(i32, 0), v);

    inverseRctInPlace(&r, &g, &b);
    for (r) |v| try std.testing.expectEqual(@as(i32, 128), v);
    for (g) |v| try std.testing.expectEqual(@as(i32, 128), v);
    for (b) |v| try std.testing.expectEqual(@as(i32, 128), v);
}
