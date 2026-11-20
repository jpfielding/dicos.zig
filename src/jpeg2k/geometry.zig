//! Resolution / band / precinct / code-block geometry (ITU-T T.800 B.5-B.7).
//!
//! Everything here is in *tile-component* space. All grid origins are pinned
//! at zero (the codestream layer rejects non-zero origins with
//! `Unsupported`), so tile-component coordinates equal image coordinates and
//! every rectangle is anchored at `(0, 0)`. The math is nonetheless written
//! in the general ceil-division form so it reads against T.800 directly.
//!
//! Layout (matches `dwt.zig`): the conformant multi-level DWT transforms, at
//! each level, the LL region left by the previous level, in place at full
//! tile stride. One 2-D transform of a `W x H` region deinterleaves into
//!   * LL at `(0, 0)`             size `ceil(W/2) x ceil(H/2)`
//!   * HL at `(ceil(W/2), 0)`     (horizontal detail)
//!   * LH at `(0, ceil(H/2))`     (vertical detail)
//!   * HH at `(ceil(W/2), ceil(H/2))`
//! `MallatPlacement` records where each band lands in that packed buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const markers = @import("markers.zig");

/// The four DWT sub-bands (re-uses `markers.Subband`).
pub const BandKind = markers.Subband;

/// PPx = PPy default precinct exponent (T.800 A.6.1 default: 2^15).
const PP_DEFAULT: u32 = 15;

// ---------------------------------------------------------------------------
// Rect
// ---------------------------------------------------------------------------

/// Half-open rectangle `[x0, x1) x [y0, y1)`.
pub const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    /// Width (saturating; an inverted rect reads as empty).
    pub fn width(self: Rect) u32 {
        return self.x1 -| self.x0;
    }

    pub fn height(self: Rect) u32 {
        return self.y1 -| self.y0;
    }

    pub fn area(self: Rect) u64 {
        return @as(u64, self.width()) * self.height();
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width() == 0 or self.height() == 0;
    }
};

// ---------------------------------------------------------------------------
// Bands / resolutions / tile
// ---------------------------------------------------------------------------

/// Position of a band inside the level's packed (Mallat) tile buffer.
pub const MallatPlacement = struct {
    x_off: u32,
    y_off: u32,
};

/// A single code-block within a band (band-native coordinates).
pub const CodeBlockGeom = struct {
    /// Clipped code-block rectangle in band-native space.
    rect: Rect,
    /// Index of the owning precinct (0 for the single-precinct default).
    precinct_idx: usize,
};

/// One DWT sub-band of a resolution level.
pub const Band = struct {
    kind: BandKind,
    /// Band-native rectangle, anchored at `(0, 0)`.
    rect: Rect,
    /// Log2 nominal gain: 0 (LL), 1 (HL), 1 (LH), 2 (HH).
    gain_log2: u8,
    /// Where this band sits in the packed Mallat tile buffer.
    placement: MallatPlacement,
    /// Code-blocks partitioning the band (raster order, clipped, non-empty).
    cbs: []CodeBlockGeom,
    /// Number of code-block columns (0 if the band is empty).
    cb_grid_w: u32,
    /// Number of code-block rows (0 if the band is empty).
    cb_grid_h: u32,
};

/// A resolution level `r` (`0..=NL`).
pub const Resolution = struct {
    /// Resolution index (`0` = coarsest LL, `NL` = full tile).
    r: u8,
    /// Resolution rectangle, anchored at `(0, 0)`.
    rect: Rect,
    /// Sub-bands: `[LL_NL]` at `r == 0`, else `[HL, LH, HH]`.
    bands: []Band,
    num_precincts_w: u32,
    num_precincts_h: u32,
};

/// Full geometry of one tile-component: one entry per resolution `0..=NL`.
pub const TileGeometry = struct {
    resolutions: []Resolution,

    pub fn deinit(self: *TileGeometry, gpa: Allocator) void {
        for (self.resolutions) |res| {
            for (res.bands) |b| gpa.free(b.cbs);
            gpa.free(res.bands);
        }
        gpa.free(self.resolutions);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// ceil-division helpers
// ---------------------------------------------------------------------------

/// `ceil(v / 2^k)` for unsigned `v` (widened to avoid `1 << 32` overflow).
pub fn ceilShift(v: u32, k: u32) u32 {
    if (k == 0) return v;
    if (k >= 64) return @intFromBool(v != 0);
    const sh: u6 = @intCast(k);
    const d = @as(u64, 1) << sh;
    return @intCast((@as(u64, v) + d - 1) >> sh);
}

/// `ceil(a / b)` for `b > 0`, valid for negative `a`.
fn ceilDivI64(a: i64, b: i64) i64 {
    std.debug.assert(b > 0);
    const q = @divTrunc(a, b);
    const r = @rem(a, b);
    return if (r > 0) q + 1 else q;
}

/// Sub-band rectangle per T.800 Eq. B-15. `nb` is the sub-band decomposition
/// level; `xob`/`yob` the partition offsets: LL=(0,0) HL=(1,0) LH=(0,1) HH=(1,1).
fn subbandRectB15(tcx0: i64, tcy0: i64, tcx1: i64, tcy1: i64, nb: u32, xob: i64, yob: i64) Rect {
    const sh: u6 = @intCast(nb);
    const d = @as(i64, 1) << sh;
    const half: i64 = if (nb > 0) @as(i64, 1) << @intCast(nb - 1) else 0;
    const off_x = xob * half;
    const off_y = yob * half;
    return .{
        .x0 = @intCast(@max(ceilDivI64(tcx0 - off_x, d), 0)),
        .y0 = @intCast(@max(ceilDivI64(tcy0 - off_y, d), 0)),
        .x1 = @intCast(@max(ceilDivI64(tcx1 - off_x, d), 0)),
        .y1 = @intCast(@max(ceilDivI64(tcy1 - off_y, d), 0)),
    };
}

pub fn gainLog2(kind: BandKind) u8 {
    return switch (kind) {
        .LL => 0,
        .HL, .LH => 1,
        .HH => 2,
    };
}

fn xobYob(kind: BandKind) struct { i64, i64 } {
    return switch (kind) {
        .LL => .{ 0, 0 },
        .HL => .{ 1, 0 },
        .LH => .{ 0, 1 },
        .HH => .{ 1, 1 },
    };
}

// ---------------------------------------------------------------------------
// Code-block partition (T.800 B.7)
// ---------------------------------------------------------------------------

const CbPartition = struct { cbs: []CodeBlockGeom, grid_w: u32, grid_h: u32 };

fn buildCodeBlocks(
    gpa: Allocator,
    band: Rect,
    xcb_eff: u32,
    ycb_eff: u32,
    ppx_band: u32,
    ppy_band: u32,
    num_precincts_w: u32,
) Allocator.Error!CbPartition {
    const w = band.width();
    const h = band.height();
    if (w == 0 or h == 0) return .{ .cbs = try gpa.alloc(CodeBlockGeom, 0), .grid_w = 0, .grid_h = 0 };

    const cbw = @as(u32, 1) << @intCast(xcb_eff);
    const cbh = @as(u32, 1) << @intCast(ycb_eff);
    const grid_w = ceilShift(w, xcb_eff);
    const grid_h = ceilShift(h, ycb_eff);

    const cbs = try gpa.alloc(CodeBlockGeom, @as(usize, grid_w) * grid_h);
    var k: usize = 0;
    for (0..grid_h) |row_u| {
        const row: u32 = @intCast(row_u);
        const by0 = row * cbh;
        const by1 = @min(by0 +| cbh, h);
        const prow = by0 >> @intCast(ppy_band);
        for (0..grid_w) |col_u| {
            const col: u32 = @intCast(col_u);
            const bx0 = col * cbw;
            const bx1 = @min(bx0 +| cbw, w);
            const pcol = bx0 >> @intCast(ppx_band);
            cbs[k] = .{
                .rect = .{ .x0 = bx0, .y0 = by0, .x1 = bx1, .y1 = by1 },
                .precinct_idx = @as(usize, prow) * num_precincts_w + pcol,
            };
            k += 1;
        }
    }
    return .{ .cbs = cbs, .grid_w = grid_w, .grid_h = grid_h };
}

fn buildBand(
    gpa: Allocator,
    kind: BandKind,
    tile_w: u32,
    tile_h: u32,
    nb: u32,
    placement: MallatPlacement,
    xcb_eff: u32,
    ycb_eff: u32,
    ppx_band: u32,
    ppy_band: u32,
    num_precincts_w: u32,
) Allocator.Error!Band {
    const xo, const yo = xobYob(kind);
    const rect = subbandRectB15(0, 0, tile_w, tile_h, nb, xo, yo);
    const part = try buildCodeBlocks(gpa, rect, xcb_eff, ycb_eff, ppx_band, ppy_band, num_precincts_w);
    return .{
        .kind = kind,
        .rect = rect,
        .gain_log2 = gainLog2(kind),
        .placement = placement,
        .cbs = part.cbs,
        .cb_grid_w = part.grid_w,
        .cb_grid_h = part.grid_h,
    };
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Build the full resolution / band / precinct / code-block geometry for one
/// `tile_w x tile_h` tile-component decomposed `num_levels` times, with
/// `2^xcb x 2^ycb` code-blocks. Caller owns the result (`deinit`).
pub fn buildGeometry(gpa: Allocator, tile_w: u32, tile_h: u32, num_levels: u8, xcb: u8, ycb: u8) Allocator.Error!TileGeometry {
    const nl: u32 = num_levels;
    const resolutions = try gpa.alloc(Resolution, @as(usize, num_levels) + 1);
    var built: usize = 0;
    errdefer {
        for (resolutions[0..built]) |res| {
            for (res.bands) |b| gpa.free(b.cbs);
            gpa.free(res.bands);
        }
        gpa.free(resolutions);
    }

    for (0..@as(usize, num_levels) + 1) |r_u| {
        const ru: u32 = @intCast(r_u);
        const shift = nl - ru;
        const res_w = ceilShift(tile_w, shift);
        const res_h = ceilShift(tile_h, shift);
        const rect: Rect = .{ .x0 = 0, .y0 = 0, .x1 = res_w, .y1 = res_h };

        // Precincts over the resolution rect (B.6). Empty resolution -> 0.
        const npw: u32, const nph: u32 = if (res_w == 0 or res_h == 0)
            .{ 0, 0 }
        else
            .{ ceilShift(res_w, PP_DEFAULT), ceilShift(res_h, PP_DEFAULT) };

        // Effective exponents (B.7): capped by the precinct exponent, which
        // is reduced by one at resolutions r >= 1.
        const pp: u32 = if (ru == 0) PP_DEFAULT else PP_DEFAULT - 1;
        const xcb_eff = @min(@as(u32, xcb), pp);
        const ycb_eff = @min(@as(u32, ycb), pp);

        const nbands: usize = if (ru == 0) 1 else 3;
        const bands = try gpa.alloc(Band, nbands);
        var nb_built: usize = 0;
        errdefer {
            for (bands[0..nb_built]) |b| gpa.free(b.cbs);
            gpa.free(bands);
        }

        if (ru == 0) {
            bands[0] = try buildBand(gpa, .LL, tile_w, tile_h, nl, .{ .x_off = 0, .y_off = 0 }, xcb_eff, ycb_eff, pp, pp, npw);
            nb_built = 1;
        } else {
            // Detail bands from decomposition level n = NL - r + 1.
            const n = nl - ru + 1;
            const ll_w = ceilShift(tile_w, n);
            const ll_h = ceilShift(tile_h, n);
            const specs = [3]struct { BandKind, MallatPlacement }{
                .{ .HL, .{ .x_off = ll_w, .y_off = 0 } },
                .{ .LH, .{ .x_off = 0, .y_off = ll_h } },
                .{ .HH, .{ .x_off = ll_w, .y_off = ll_h } },
            };
            for (specs, 0..) |s, i| {
                bands[i] = try buildBand(gpa, s[0], tile_w, tile_h, n, s[1], xcb_eff, ycb_eff, pp, pp, npw);
                nb_built += 1;
            }
        }

        resolutions[r_u] = .{
            .r = @intCast(ru),
            .rect = rect,
            .bands = bands,
            .num_precincts_w = npw,
            .num_precincts_h = nph,
        };
        built += 1;
    }

    return .{ .resolutions = resolutions };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

fn findBand(res: Resolution, kind: BandKind) Band {
    for (res.bands) |b| if (b.kind == kind) return b;
    unreachable;
}

fn expectDims(rect: Rect, w: u32, h: u32) !void {
    try testing.expectEqual(w, rect.width());
    try testing.expectEqual(h, rect.height());
}

test "res rects 64x64 5levels" {
    var g = try buildGeometry(ta, 64, 64, 5, 6, 6);
    defer g.deinit(ta);
    const expected = [_]u32{ 2, 4, 8, 16, 32, 64 };
    try testing.expectEqual(@as(usize, 6), g.resolutions.len);
    for (expected, 0..) |e, r| try expectDims(g.resolutions[r].rect, e, e);
}

test "bands 64x64 5levels" {
    var g = try buildGeometry(ta, 64, 64, 5, 6, 6);
    defer g.deinit(ta);
    try expectDims(findBand(g.resolutions[0], .LL).rect, 2, 2);
    for (1..6) |r| {
        const res = g.resolutions[r];
        const prev = ceilShift(64, @intCast(5 - r + 1));
        const region = ceilShift(64, @intCast(5 - r));
        const detail = region - prev;
        try expectDims(findBand(res, .HL).rect, detail, prev);
        try expectDims(findBand(res, .LH).rect, prev, detail);
        try expectDims(findBand(res, .HH).rect, detail, detail);
    }
}

test "single codeblock until dims exceed block" {
    var g = try buildGeometry(ta, 64, 64, 5, 6, 6);
    defer g.deinit(ta);
    for (g.resolutions) |res| for (res.bands) |b| {
        if (b.rect.isEmpty()) continue;
        try testing.expectEqual(@as(usize, 1), b.cbs.len);
        try testing.expectEqual(@as(u32, 1), b.cb_grid_w);
        try testing.expectEqual(@as(u32, 1), b.cb_grid_h);
        try testing.expectEqual(b.rect, b.cbs[0].rect);
    };

    var g2 = try buildGeometry(ta, 200, 64, 1, 6, 6);
    defer g2.deinit(ta);
    const hl = findBand(g2.resolutions[1], .HL);
    try testing.expectEqual(@as(u32, 100), hl.rect.width());
    try testing.expectEqual(@as(u32, 2), hl.cb_grid_w);
    try testing.expectEqual(@as(u32, 64), hl.cbs[0].rect.width());
    try testing.expectEqual(@as(u32, 36), hl.cbs[1].rect.width());
}

test "bands 13x7 2levels" {
    var g = try buildGeometry(ta, 13, 7, 2, 6, 6);
    defer g.deinit(ta);
    try testing.expectEqual(@as(usize, 3), g.resolutions.len);
    try expectDims(g.resolutions[0].rect, 4, 2);
    try expectDims(g.resolutions[1].rect, 7, 4);
    try expectDims(g.resolutions[2].rect, 13, 7);
    try expectDims(findBand(g.resolutions[0], .LL).rect, 4, 2);

    const r1 = g.resolutions[1];
    try expectDims(findBand(r1, .HL).rect, 3, 2);
    try expectDims(findBand(r1, .LH).rect, 4, 2);
    try expectDims(findBand(r1, .HH).rect, 3, 2);

    const r2 = g.resolutions[2];
    try expectDims(findBand(r2, .HL).rect, 6, 4);
    try expectDims(findBand(r2, .LH).rect, 7, 3);
    try expectDims(findBand(r2, .HH).rect, 6, 3);

    try testing.expectEqual(MallatPlacement{ .x_off = 7, .y_off = 0 }, findBand(r2, .HL).placement);
    try testing.expectEqual(MallatPlacement{ .x_off = 0, .y_off = 4 }, findBand(r2, .LH).placement);
    try testing.expectEqual(MallatPlacement{ .x_off = 7, .y_off = 4 }, findBand(r2, .HH).placement);
}

fn checkInvariants(tile_w: u32, tile_h: u32, nl: u8, xcb: u8, ycb: u8) !void {
    var g = try buildGeometry(ta, tile_w, tile_h, nl, xcb, ycb);
    defer g.deinit(ta);

    for (1..g.resolutions.len) |r| {
        const res = g.resolutions[r];
        var band_area: u64 = 0;
        for (res.bands) |b| band_area += b.rect.area();
        try testing.expectEqual(res.rect.area(), band_area + g.resolutions[r - 1].rect.area());
    }

    for (g.resolutions) |res| for (res.bands) |b| {
        if (b.rect.isEmpty()) {
            try testing.expectEqual(@as(usize, 0), b.cbs.len);
            try testing.expectEqual(@as(u32, 0), b.cb_grid_w);
            try testing.expectEqual(@as(u32, 0), b.cb_grid_h);
            continue;
        }
        try testing.expectEqual(@as(usize, b.cb_grid_w * b.cb_grid_h), b.cbs.len);
        var area: u64 = 0;
        for (b.cbs) |cb| {
            try testing.expect(!cb.rect.isEmpty());
            try testing.expect(cb.rect.x1 <= b.rect.width() and cb.rect.y1 <= b.rect.height());
            area += cb.rect.area();
        }
        try testing.expectEqual(b.rect.area(), area);
    };
}

test "invariants various" {
    const cases = [_]struct { u32, u32, u8 }{
        .{ 64, 64, 5 }, .{ 13, 7, 2 },  .{ 13, 11, 3 }, .{ 200, 137, 4 },
        .{ 1, 1, 0 },   .{ 255, 3, 5 }, .{ 68, 68, 5 },
    };
    for (cases) |c| try checkInvariants(c[0], c[1], c[2], 6, 6);
}

test "degenerate 1 by n" {
    var g = try buildGeometry(ta, 1, 16, 4, 6, 6);
    defer g.deinit(ta);
    const r1 = g.resolutions[1];
    try testing.expect(findBand(r1, .HL).rect.isEmpty());
    try testing.expect(findBand(r1, .HH).rect.isEmpty());
    for (g.resolutions) |res| for (res.bands) |b| {
        if (b.rect.isEmpty()) try testing.expectEqual(@as(usize, 0), b.cbs.len);
    };
    try checkInvariants(1, 16, 4, 6, 6);
}

test "degenerate n by 1" {
    var g = try buildGeometry(ta, 16, 1, 4, 6, 6);
    defer g.deinit(ta);
    const r1 = g.resolutions[1];
    try testing.expect(findBand(r1, .LH).rect.isEmpty());
    try testing.expect(findBand(r1, .HH).rect.isEmpty());
    try checkInvariants(16, 1, 4, 6, 6);
}

test "degenerate 1x1" {
    var g = try buildGeometry(ta, 1, 1, 3, 6, 6);
    defer g.deinit(ta);
    try expectDims(findBand(g.resolutions[0], .LL).rect, 1, 1);
    for (g.resolutions[1..]) |res| for (res.bands) |b| try testing.expect(b.rect.isEmpty());
    try checkInvariants(1, 1, 3, 6, 6);
}

test "zero levels is single ll" {
    var g = try buildGeometry(ta, 37, 29, 0, 6, 6);
    defer g.deinit(ta);
    try testing.expectEqual(@as(usize, 1), g.resolutions.len);
    try expectDims(findBand(g.resolutions[0], .LL).rect, 37, 29);
    try checkInvariants(37, 29, 0, 6, 6);
}

test "cb exponent extremes" {
    try checkInvariants(64, 64, 3, 2, 2);
    var g = try buildGeometry(ta, 64, 64, 1, 2, 2);
    defer g.deinit(ta);
    const hl = findBand(g.resolutions[1], .HL);
    try testing.expectEqual(@as(u32, 8), hl.cb_grid_w);
    try testing.expectEqual(@as(u32, 8), hl.cb_grid_h);
    try testing.expectEqual(@as(usize, 64), hl.cbs.len);

    var g2 = try buildGeometry(ta, 64, 64, 5, 10, 10);
    defer g2.deinit(ta);
    for (g2.resolutions) |res| for (res.bands) |b| {
        if (!b.rect.isEmpty()) try testing.expectEqual(@as(usize, 1), b.cbs.len);
    };
    try checkInvariants(200, 200, 4, 10, 10);
}

test "precincts single for realistic tiles" {
    var g = try buildGeometry(ta, 200, 200, 4, 6, 6);
    defer g.deinit(ta);
    for (g.resolutions) |res| {
        try testing.expectEqual(@as(u32, 1), res.num_precincts_w);
        try testing.expectEqual(@as(u32, 1), res.num_precincts_h);
        for (res.bands) |b| for (b.cbs) |cb| try testing.expectEqual(@as(usize, 0), cb.precinct_idx);
    }
}
