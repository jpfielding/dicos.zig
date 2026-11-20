//! Reversible Color Transform (ITU-T T.800 Annex G).
//!
//! Unused while the supported profile is single-component with MCT = 0;
//! retained for API parity with the Rust crate.

const std = @import("std");

/// Forward RCT: RGB -> YCbCr (reversible). `r`, `g`, `b` become Y, Cb, Cr.
pub fn forwardRctInPlace(r: []i32, g: []i32, b: []i32) void {
    for (r, g, b) |*ri, *gi, *bi| {
        const rv = ri.*;
        const gv = gi.*;
        const bv = bi.*;
        ri.* = (rv + 2 * gv + bv) >> 2; // Y
        gi.* = bv - gv; // Cb
        bi.* = rv - gv; // Cr
    }
}

/// Inverse RCT: YCbCr -> RGB (reversible). `y`, `cb`, `cr` become R, G, B.
pub fn inverseRctInPlace(y: []i32, cb: []i32, cr: []i32) void {
    for (y, cb, cr) |*yi, *cbi, *cri| {
        const yv = yi.*;
        const cbv = cbi.*;
        const crv = cri.*;
        const g = yv - ((cbv + crv) >> 2);
        yi.* = crv + g; // R
        cbi.* = g; // G
        cri.* = cbv + g; // B
    }
}

const testing = std.testing;

test "rct roundtrip" {
    var r = [_]i32{ 100, 200, 50, 0, 255 };
    var g = [_]i32{ 150, 100, 200, 128, 64 };
    var b = [_]i32{ 200, 50, 100, 255, 0 };
    const or_ = r;
    const og = g;
    const ob = b;
    forwardRctInPlace(&r, &g, &b);
    inverseRctInPlace(&r, &g, &b);
    try testing.expectEqualSlices(i32, &or_, &r);
    try testing.expectEqualSlices(i32, &og, &g);
    try testing.expectEqualSlices(i32, &ob, &b);
}

test "rct identity grayscale" {
    var r: [10]i32 = @splat(128);
    var g: [10]i32 = @splat(128);
    var b: [10]i32 = @splat(128);
    forwardRctInPlace(&r, &g, &b);
    for (r, g, b) |y, cb, cr| {
        try testing.expectEqual(@as(i32, 128), y);
        try testing.expectEqual(@as(i32, 0), cb);
        try testing.expectEqual(@as(i32, 0), cr);
    }
    inverseRctInPlace(&r, &g, &b);
    for (r, g, b) |rv, gv, bv| {
        try testing.expectEqual(@as(i32, 128), rv);
        try testing.expectEqual(@as(i32, 128), gv);
        try testing.expectEqual(@as(i32, 128), bv);
    }
}
