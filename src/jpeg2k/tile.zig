//! Conformant T.800 tile-component pipeline.
//!
//! Encodes/decodes one tile-component through the full lossless pipeline:
//! reversible 5/3 DWT <-> resolution/band/code-block geometry <-> EBCOT
//! tier-1 <-> LRCP tier-2 packets. For this profile (1 tile, 1 component,
//! 1 layer, 1 precinct per band, LRCP) the packet order is resolution `r`
//! ascending, one packet per resolution covering its bands.
//!
//! `Mb` (max magnitude bit-planes for a band, `Mb = eps_b + G - 1`) is
//! supplied per band by `mb_for.mb(kind, level)`, where `level` is the band's
//! *decomposition level* (`NL` for LL, `NL..=1` for detail bands) -- the same
//! key the QCD marker orders its exponents by.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CodecError = @import("error.zig").CodecError;
const dwt = @import("dwt.zig");
const ebcot = @import("ebcot.zig");
const geometry = @import("geometry.zig");
const packet = @import("packet.zig");

const CodedBlock = ebcot.CodedBlock;
const Band = geometry.Band;
const BandKind = geometry.BandKind;
const CodeBlockGeom = geometry.CodeBlockGeom;
const TileGeometry = geometry.TileGeometry;
const PrecinctState = packet.PrecinctState;

/// Maximum tile area (samples) we allocate for, guarding hostile dimensions.
pub const MAX_TILE_AREA: usize = 1 << 28;

/// Constant-`Mb` provider (tests and simple callers).
pub const ConstMb = struct {
    value: u32,
    pub fn mb(self: ConstMb, _: BandKind, _: u8) u32 {
        return self.value;
    }
};

/// Decomposition level of a resolution's bands: `NL` at `r = 0` (LL) and
/// `r = 1`, decreasing to `1` at the finest resolution.
fn decompositionLevel(r: u8, num_levels: u8) u8 {
    return if (r == 0) num_levels else num_levels - r + 1;
}

/// Validate dimensions and return `w * h`.
fn checkedArea(w: u32, h: u32) CodecError!usize {
    // "tile has a zero dimension"
    if (w == 0 or h == 0) return error.InvalidData;
    const n = std.math.mul(usize, w, h) catch return error.InvalidData;
    // "tile area exceeds the sample cap"
    if (n > MAX_TILE_AREA) return error.InvalidData;
    return n;
}

/// The tier-2 pipeline emits one packet per resolution with one precinct
/// state per band, so reject geometries spanning more than one precinct
/// (e.g. a resolution wider than 2^15) rather than silently mispacking.
fn ensureSinglePrecinct(geom: *const TileGeometry) CodecError!void {
    for (geom.resolutions) |res| {
        if (@as(u64, res.num_precincts_w) * res.num_precincts_h > 1) return error.Unsupported;
    }
}

/// Copy a code-block's coefficients out of the packed Mallat buffer.
fn gather(dst: []i32, buf: []const i32, stride: usize, band: Band, cb: CodeBlockGeom) void {
    const bw: usize = cb.rect.width();
    const bh: usize = cb.rect.height();
    const x_off = @as(usize, band.placement.x_off) + cb.rect.x0;
    const y_off = @as(usize, band.placement.y_off) + cb.rect.y0;
    for (0..bh) |yy| {
        const src = (y_off + yy) * stride + x_off;
        @memcpy(dst[yy * bw .. yy * bw + bw], buf[src .. src + bw]);
    }
}

/// Scatter a code-block's decoded coefficients back into the Mallat buffer.
fn scatter(buf: []i32, stride: usize, band: Band, cb: CodeBlockGeom, coeffs: []const i32) void {
    const bw: usize = cb.rect.width();
    const bh: usize = cb.rect.height();
    const x_off = @as(usize, band.placement.x_off) + cb.rect.x0;
    const y_off = @as(usize, band.placement.y_off) + cb.rect.y0;
    for (0..bh) |yy| {
        const d = (y_off + yy) * stride + x_off;
        @memcpy(buf[d .. d + bw], coeffs[yy * bw .. yy * bw + bw]);
    }
}

fn initStates(gpa: Allocator, bands: []const Band) Allocator.Error![]PrecinctState {
    const states = try gpa.alloc(PrecinctState, bands.len);
    var made: usize = 0;
    errdefer {
        for (states[0..made]) |*s| s.deinit(gpa);
        gpa.free(states);
    }
    for (bands, 0..) |b, i| {
        states[i] = try PrecinctState.init(gpa, b.cb_grid_w, b.cb_grid_h);
        made += 1;
    }
    return states;
}

/// Encode one tile-component (`w x h`, row-major) to a concatenation of LRCP
/// packets. Returns `error.InvalidData` if a code-block needs more bit-planes
/// than its band's `Mb`. Caller owns the result.
pub fn encodeTile(
    gpa: Allocator,
    component: []const i32,
    w: u32,
    h: u32,
    num_levels: u8,
    xcb: u8,
    ycb: u8,
    mb_for: anytype,
) CodecError![]u8 {
    const n = try checkedArea(w, h);
    if (component.len != n) return error.DimensionMismatch;
    const stride: usize = w;

    var geom = try geometry.buildGeometry(gpa, w, h, num_levels, xcb, ycb);
    defer geom.deinit(gpa);
    try ensureSinglePrecinct(&geom);

    // Forward DWT into a packed Mallat buffer.
    const buf = try gpa.dupe(i32, component);
    defer gpa.free(buf);
    _ = try dwt.forwardMultiLevelConformant(gpa, buf, stride, h, num_levels);

    // One code-block's worth of scratch (largest block in the tile).
    var max_cb: usize = 0;
    for (geom.resolutions) |res| for (res.bands) |b| for (b.cbs) |cb| {
        max_cb = @max(max_cb, @as(usize, cb.rect.width()) * cb.rect.height());
    };
    const scratch = try gpa.alloc(i32, max_cb);
    defer gpa.free(scratch);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (geom.resolutions) |res| {
        const level = decompositionLevel(res.r, num_levels);
        const bands = res.bands;

        const states = try initStates(gpa, bands);
        defer packet.freeStates(gpa, states);

        var mbs: [3]u32 = undefined;
        var all_blocks: [3][]?CodedBlock = undefined;
        var nb_built: usize = 0;
        defer for (all_blocks[0..nb_built]) |blocks| {
            for (blocks) |*b| if (b.*) |*c| c.deinit(gpa);
            gpa.free(blocks);
        };

        for (bands, 0..) |band, bi| {
            const mb: u32 = mb_for.mb(band.kind, level);
            mbs[bi] = mb;
            const blocks = try gpa.alloc(?CodedBlock, band.cbs.len);
            @memset(blocks, null);
            all_blocks[bi] = blocks;
            nb_built += 1;
            for (band.cbs, 0..) |cb, k| {
                const bw: usize = cb.rect.width();
                const bh: usize = cb.rect.height();
                const coeffs = scratch[0 .. bw * bh];
                gather(coeffs, buf, stride, band, cb);
                var coded = try ebcot.encodeCodeBlock(gpa, coeffs, bw, bh, band.kind);
                // "code-block needs more bit-planes than Mb"
                if (coded.num_bitplanes > mb) {
                    coded.deinit(gpa);
                    return error.InvalidData;
                }
                if (coded.num_bitplanes == 0) {
                    coded.deinit(gpa);
                } else {
                    blocks[k] = coded;
                }
            }
        }

        var refs: [3][]const ?CodedBlock = undefined;
        for (all_blocks[0..bands.len], 0..) |b, i| refs[i] = b;
        try packet.writePacket(gpa, states, bands, refs[0..bands.len], mbs[0..bands.len], &out);
    }

    return out.toOwnedSlice(gpa);
}

/// Decode a tile-component from a concatenation of LRCP packets. Caller owns
/// the returned `w * h` coefficients.
pub fn decodeTile(
    gpa: Allocator,
    bitstream: []const u8,
    w: u32,
    h: u32,
    num_levels: u8,
    xcb: u8,
    ycb: u8,
    mb_for: anytype,
) CodecError![]i32 {
    const n = try checkedArea(w, h);
    const stride: usize = w;

    var geom = try geometry.buildGeometry(gpa, w, h, num_levels, xcb, ycb);
    defer geom.deinit(gpa);
    try ensureSinglePrecinct(&geom);

    const buf = try gpa.alloc(i32, n);
    errdefer gpa.free(buf);
    @memset(buf, 0);
    var pos: usize = 0;

    for (geom.resolutions) |res| {
        const level = decompositionLevel(res.r, num_levels);
        const bands = res.bands;
        const states = try initStates(gpa, bands);
        defer packet.freeStates(gpa, states);
        var mbs: [3]u32 = undefined;
        for (bands, 0..) |b, i| mbs[i] = mb_for.mb(b.kind, level);

        // "tile bitstream truncated"
        if (pos > bitstream.len) return error.InvalidData;
        var rr = try packet.readPacket(gpa, states, bands, mbs[0..bands.len], bitstream[pos..]);
        defer rr.deinit(gpa);
        var body_pos = std.math.add(usize, pos, rr.header_len) catch return error.InvalidData;

        for (bands, 0..) |band, bi| {
            const mb = mbs[bi];
            for (band.cbs, 0..) |cb, k| {
                const bw: usize = cb.rect.width();
                const bh: usize = cb.rect.height();
                const c = rr.contributions[bi][k] orelse continue; // stays zero
                // "zero-bit-planes exceed Mb"
                if (c.zero_bitplanes > mb) return error.InvalidData;
                const num_bitplanes = mb - c.zero_bitplanes;
                // "included block with zero magnitude bit-planes"
                if (num_bitplanes == 0) return error.InvalidData;
                // "num_passes exceeds 3*nb-2"
                if (c.num_passes > 3 * num_bitplanes - 2) return error.InvalidData;
                const end = std.math.add(usize, body_pos, c.len) catch return error.InvalidData;
                // "code-block body truncated"
                if (end > bitstream.len) return error.InvalidData;
                const data = bitstream[body_pos..end];
                body_pos = end;
                const coeffs = try ebcot.decodeCodeBlock(gpa, data, bw, bh, band.kind, num_bitplanes, c.num_passes);
                defer gpa.free(coeffs);
                scatter(buf, stride, band, cb, coeffs);
            }
        }
        pos = body_pos;
    }

    try dwt.inverseMultiLevelConformant(gpa, buf, stride, h, num_levels);
    return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

/// Comfortable constant Mb: never overflowed by 12-bit input.
const mb40: ConstMb = .{ .value = 40 };

fn roundtrip(component: []const i32, w: u32, h: u32, nl: u8, xcb: u8, ycb: u8) !void {
    const enc = try encodeTile(ta, component, w, h, nl, xcb, ycb, mb40);
    defer ta.free(enc);
    const dec = try decodeTile(ta, enc, w, h, nl, xcb, ycb, mb40);
    defer ta.free(dec);
    try testing.expectEqualSlices(i32, component, dec);
}

/// Deterministic patterns, values < 4096.
fn pattern(kind: usize, w: u32, h: u32) ![]i32 {
    const n: usize = @as(usize, w) * h;
    const v = try ta.alloc(i32, n);
    switch (kind) {
        0 => @memset(v, 1234),
        1 => for (v, 0..) |*x, i| {
            const iu: u32 = @intCast(i);
            x.* = @rem(@as(i32, @intCast(iu % w)) * 3 + @as(i32, @intCast(iu / w)) * 5, 4096);
        },
        2 => {
            var s: u64 = 0x9E37_79B9_7F4A_7C15 ^ (@as(u64, w) << 20) ^ @as(u64, h);
            for (v) |*x| {
                s = s *% 6364136223846793005 +% 1;
                x.* = @as(i32, @intCast(s >> 40)) & 0xFFF;
            }
        },
        else => {
            @memset(v, 0);
            v[0] = 2000;
            v[n / 2] = -1500;
            v[n - 1] = 999;
        },
    }
    return v;
}

test "roundtrip matrix" {
    const dims = [_]u32{ 1, 2, 3, 5, 8, 13, 16, 31, 64, 65, 130 };
    const levels = [_]u8{ 0, 1, 2, 5 };
    const cbs = [_][2]u8{ .{ 2, 2 }, .{ 6, 6 }, .{ 10, 2 } };
    for (dims) |w| for (dims) |h| for (levels) |nl| for (cbs) |cb| for (0..4) |kind| {
        const comp = try pattern(kind, w, h);
        defer ta.free(comp);
        try roundtrip(comp, w, h, nl, cb[0], cb[1]);
    };
}

test "all zero image empty packets to zeros" {
    const w = 64;
    const h = 48;
    const comp: [w * h]i32 = @splat(0);
    const enc = try encodeTile(ta, &comp, w, h, 5, 6, 6, mb40);
    defer ta.free(enc);
    try testing.expectEqualSlices(u8, &(@as([6]u8, @splat(0))), enc);
    const dec = try decodeTile(ta, enc, w, h, 5, 6, 6, mb40);
    defer ta.free(dec);
    try testing.expectEqualSlices(i32, &comp, dec);
}

test "tight mb equal to actual bitplanes" {
    const w = 31;
    const h = 17;
    const comp = try pattern(2, w, h);
    defer ta.free(comp);
    const nl: u8 = 3;

    var tight: u32 = 0;
    while (tight <= 48) : (tight += 1) {
        if (encodeTile(ta, comp, w, h, nl, 4, 4, ConstMb{ .value = tight })) |enc| {
            ta.free(enc);
            break;
        } else |_| {}
    }
    try testing.expect(tight > 0 and tight <= 48);

    const enc = try encodeTile(ta, comp, w, h, nl, 4, 4, ConstMb{ .value = tight });
    defer ta.free(enc);
    const dec = try decodeTile(ta, enc, w, h, nl, 4, 4, ConstMb{ .value = tight });
    defer ta.free(dec);
    try testing.expectEqualSlices(i32, comp, dec);

    try testing.expectError(error.InvalidData, encodeTile(ta, comp, w, h, nl, 4, 4, ConstMb{ .value = tight - 1 }));
}

test "mismatched mb decode errors cleanly" {
    const comp = try pattern(1, 32, 32);
    defer ta.free(comp);
    const enc = try encodeTile(ta, comp, 32, 32, 2, 6, 6, mb40);
    defer ta.free(enc);
    try testing.expectError(error.InvalidData, decodeTile(ta, enc, 32, 32, 2, 6, 6, ConstMb{ .value = 5 }));
}

test "truncated bitstream never panics" {
    const comp = try pattern(2, 16, 13);
    defer ta.free(comp);
    const enc = try encodeTile(ta, comp, 16, 13, 2, 4, 4, mb40);
    defer ta.free(enc);
    for (0..enc.len) |cut| {
        if (decodeTile(ta, enc[0..cut], 16, 13, 2, 4, 4, mb40)) |d| ta.free(d) else |_| {}
    }
    const dec = try decodeTile(ta, enc, 16, 13, 2, 4, 4, mb40);
    defer ta.free(dec);
    try testing.expectEqualSlices(i32, comp, dec);
}

test "zero dimension rejected" {
    try testing.expectError(error.InvalidData, encodeTile(ta, &.{}, 0, 4, 0, 6, 6, mb40));
    try testing.expectError(error.InvalidData, decodeTile(ta, &.{0}, 4, 0, 0, 6, 6, mb40));
}

test "dimension mismatch rejected" {
    const comp: [10]i32 = @splat(0);
    try testing.expectError(error.DimensionMismatch, encodeTile(ta, &comp, 4, 4, 0, 6, 6, mb40));
}

test "single pixel" {
    for ([_]i32{ 0, 1, 2047, -2047 }) |v| {
        try roundtrip(&.{v}, 1, 1, 0, 2, 2);
        try roundtrip(&.{v}, 1, 1, 3, 6, 6);
    }
}
