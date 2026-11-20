//! EBCOT (Embedded Block Coding with Optimal Truncation) -- ITU-T T.800
//! Annex D.
//!
//! Conformant tier-1 coder for lossless code-blocks. A single shared `Tier1`
//! state machine drives BOTH encoding and decoding: scan order, flag grid and
//! all context formation (zero-coding, sign-coding, magnitude-refinement) are
//! written once and dispatch to the MQ coder through one `code()` primitive.
//!
//! Coding uses 4-row stripes (Figure D.2): columns left-to-right, rows
//! top-to-bottom within a column. Each bit-plane gets up to three passes:
//! significance propagation (D.3.1), magnitude refinement (D.3.3) and cleanup
//! (D.4, with run-length mode). The most-significant plane is cleanup-only,
//! so `num_passes = 3*nb - 2`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CodecError = @import("error.zig").CodecError;
const BandKind = @import("geometry.zig").BandKind;
const mq = @import("mq.zig");

const MqEncoder = mq.MqEncoder;
const MqDecoder = mq.MqDecoder;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// A tier-1 coded code-block: the MQ codeword segment plus the metadata a
/// tier-2 packet header must signal.
pub const CodedBlock = struct {
    /// The single MQ codeword segment (empty for an all-zero block).
    data: []u8,
    /// Total coding passes emitted (`3*num_bitplanes - 2`, or 0).
    num_passes: u32,
    /// Number of magnitude bit-planes (0 for an all-zero block).
    num_bitplanes: u32,

    pub fn deinit(self: *CodedBlock, gpa: Allocator) void {
        gpa.free(self.data);
        self.* = undefined;
    }
};

/// Encode one code-block of signed subband samples (`w*h`, row-major).
/// An all-zero block yields `{ data = empty, num_passes = 0, num_bitplanes = 0 }`.
/// Caller owns `data`.
pub fn encodeCodeBlock(gpa: Allocator, coeffs: []const i32, w: usize, h: usize, band: BandKind) Allocator.Error!CodedBlock {
    std.debug.assert(coeffs.len == w * h);

    var max_mag: u32 = 0;
    for (coeffs) |v| max_mag = @max(max_mag, @abs(v));
    if (max_mag == 0) return .{ .data = try gpa.alloc(u8, 0), .num_passes = 0, .num_bitplanes = 0 };
    const nb: u32 = 32 - @as(u32, @clz(max_mag));

    var t = try Tier1.initEncoder(gpa, w, h, band);
    defer t.deinit();
    // Pre-seed magnitudes and SIGN flags. Sign context only consults the
    // sign of *significant* neighbours, and a sign is coded the instant its
    // sample becomes significant, so pre-seeding is safe and matches decode.
    for (0..h) |y| for (0..w) |x| {
        const v = coeffs[y * w + x];
        t.mag[y * w + x] = @abs(v);
        if (v < 0) t.flags.set(t.flags.idx(x, y), SIGN);
    };

    var passes: u32 = 0;
    try t.cleanupPass(nb - 1);
    passes += 1;
    var p = nb - 1;
    while (p > 0) {
        p -= 1;
        try t.sigPropPass(p);
        try t.magRefPass(p);
        try t.cleanupPass(p);
        passes += 3;
    }

    return .{ .data = try t.finishEncoder(), .num_passes = passes, .num_bitplanes = nb };
}

/// Decode one code-block back into signed subband samples. Honours any pass
/// prefix `1..=3*nb-2` and never panics on malformed data (the MQ decoder
/// feeds synthetic 1-bits past end-of-data). Caller owns the result.
pub fn decodeCodeBlock(
    gpa: Allocator,
    data: []const u8,
    w: usize,
    h: usize,
    band: BandKind,
    num_bitplanes: u32,
    num_passes: u32,
) CodecError![]i32 {
    if (num_bitplanes == 0) {
        // "num_bitplanes == 0 but num_passes != 0"
        if (num_passes != 0) return error.InvalidData;
        const out = try gpa.alloc(i32, w * h);
        @memset(out, 0);
        return out;
    }
    const nb = num_bitplanes;
    // Shift guard: planes shift `1 << (nb-1)`; nb >= 32 would overflow i32.
    if (nb >= 32) return error.InvalidData;
    const max_passes = 3 * nb - 2;
    if (num_passes == 0 or num_passes > max_passes) return error.InvalidData;

    var t = try Tier1.initDecoder(gpa, data, w, h, band);
    defer t.deinit();

    var done: u32 = 0;
    try t.cleanupPass(nb - 1);
    done += 1;
    var p = nb - 1;
    while (p > 0 and done < num_passes) {
        p -= 1;
        try t.sigPropPass(p);
        done += 1;
        if (done >= num_passes) break;
        try t.magRefPass(p);
        done += 1;
        if (done >= num_passes) break;
        try t.cleanupPass(p);
        done += 1;
    }

    const out = try gpa.alloc(i32, w * h);
    for (0..h) |y| for (0..w) |x| {
        const ci = y * w + x;
        const m: i32 = @intCast(t.mag[ci]);
        out[ci] = if (t.flags.get(t.flags.idx(x, y), SIGN)) -m else m;
    };
    return out;
}

// ---------------------------------------------------------------------------
// Shared flag grid
// ---------------------------------------------------------------------------

/// Significant: the sample has a coded 1 magnitude bit.
const SIG: u16 = 1 << 0;
/// Visited: coded in this plane's significance-propagation pass.
const VISITED: u16 = 1 << 1;
/// Refined: has had at least one magnitude-refinement bit coded.
const REFINED: u16 = 1 << 2;
/// Sign: set when the sample is negative.
const SIGN: u16 = 1 << 3;

/// Per-sample state with a one-cell insignificant border all round.
const BlockFlags = struct {
    flags: []u16,
    stride: usize,

    fn init(gpa: Allocator, w: usize, h: usize) Allocator.Error!BlockFlags {
        const stride = w + 2;
        const f = try gpa.alloc(u16, stride * (h + 2));
        @memset(f, 0);
        return .{ .flags = f, .stride = stride };
    }

    inline fn idx(self: *const BlockFlags, x: usize, y: usize) usize {
        return (y + 1) * self.stride + (x + 1);
    }

    inline fn get(self: *const BlockFlags, i: usize, bit: u16) bool {
        return self.flags[i] & bit != 0;
    }

    inline fn set(self: *BlockFlags, i: usize, bit: u16) void {
        self.flags[i] |= bit;
    }

    fn clearVisited(self: *BlockFlags) void {
        for (self.flags) |*f| f.* &= ~VISITED;
    }
};

// ---------------------------------------------------------------------------
// Context formation (T.800 Tables D.1-D.4)
// ---------------------------------------------------------------------------

/// Zero-coding context, LL/LH ("H-major") table. Returns `0..=8`.
fn zcLl(h: u32, v: u32, d: u32) u8 {
    if (h == 2) return 8;
    if (h == 1) {
        if (v >= 1) return 7;
        if (d >= 1) return 6;
        return 5;
    }
    if (v == 2) return 4;
    if (v == 1) return 3;
    if (d >= 2) return 2;
    if (d == 1) return 1;
    return 0;
}

/// Zero-coding context, HH ("D-major") table. Returns `0..=8`.
fn zcHh(h: u32, v: u32, d: u32) u8 {
    const hv = h + v;
    if (d >= 3) return 8;
    if (d == 2) return if (hv >= 1) 7 else 6;
    if (d == 1) {
        if (hv >= 2) return 5;
        if (hv == 1) return 4;
        return 3;
    }
    if (hv >= 2) return 2;
    if (hv == 1) return 1;
    return 0;
}

/// Orientation-aware zero-coding context. HL swaps the H/V roles.
fn zcContext(h: u32, v: u32, d: u32, band: BandKind) u8 {
    return switch (band) {
        .LL, .LH => zcLl(h, v, d),
        .HL => zcLl(v, h, d),
        .HH => zcHh(h, v, d),
    };
}

const Counts = struct { h: u32, v: u32, d: u32 };

// ---------------------------------------------------------------------------
// Tier-1 state machine (drives both directions)
// ---------------------------------------------------------------------------

const Tier1 = struct {
    gpa: Allocator,
    coder: union(enum) { enc: MqEncoder, dec: MqDecoder },
    contexts: mq.Contexts,
    flags: BlockFlags,
    /// Magnitudes: source data on encode, reconstruction on decode.
    mag: []u32,
    w: usize,
    h: usize,
    band: BandKind,

    fn initCommon(gpa: Allocator, w: usize, h: usize, band: BandKind) Allocator.Error!Tier1 {
        const flags = try BlockFlags.init(gpa, w, h);
        errdefer gpa.free(flags.flags);
        const mag = try gpa.alloc(u32, w * h);
        @memset(mag, 0);
        return .{
            .gpa = gpa,
            .coder = undefined,
            .contexts = mq.setupDefaultContexts(),
            .flags = flags,
            .mag = mag,
            .w = w,
            .h = h,
            .band = band,
        };
    }

    fn initEncoder(gpa: Allocator, w: usize, h: usize, band: BandKind) Allocator.Error!Tier1 {
        var t = try initCommon(gpa, w, h, band);
        t.coder = .{ .enc = MqEncoder.init(gpa) };
        return t;
    }

    fn initDecoder(gpa: Allocator, data: []const u8, w: usize, h: usize, band: BandKind) Allocator.Error!Tier1 {
        var t = try initCommon(gpa, w, h, band);
        t.coder = .{ .dec = MqDecoder.init(data) };
        return t;
    }

    fn deinit(self: *Tier1) void {
        switch (self.coder) {
            .enc => |*e| e.deinit(),
            .dec => {},
        }
        self.gpa.free(self.flags.flags);
        self.gpa.free(self.mag);
    }

    inline fn encoding(self: *const Tier1) bool {
        return self.coder == .enc;
    }

    /// The single coding primitive. Encode: code `known` and return it.
    /// Decode: ignore `known` and return the decoded bit.
    inline fn code(self: *Tier1, ctx: usize, known: u8) Allocator.Error!u8 {
        switch (self.coder) {
            .enc => |*e| {
                try e.encode(known, &self.contexts[ctx]);
                return known;
            },
            .dec => |*d| return d.decode(&self.contexts[ctx]),
        }
    }

    fn finishEncoder(self: *Tier1) Allocator.Error![]u8 {
        const e = &self.coder.enc;
        try e.flush();
        return e.toOwnedSlice();
    }

    // -- neighbourhood queries ----------------------------------------------

    inline fn neighborCounts(self: *const Tier1, i: usize) Counts {
        const s = self.flags.stride;
        const f = self.flags.flags;
        const sig = struct {
            inline fn isSig(v: u16) u32 {
                return @intFromBool(v & SIG != 0);
            }
        }.isSig;
        return .{
            .h = sig(f[i - 1]) + sig(f[i + 1]),
            .v = sig(f[i - s]) + sig(f[i + s]),
            .d = sig(f[i - s - 1]) + sig(f[i - s + 1]) + sig(f[i + s - 1]) + sig(f[i + s + 1]),
        };
    }

    inline fn zcAt(self: *const Tier1, i: usize) u8 {
        const c = self.neighborCounts(i);
        return zcContext(c.h, c.v, c.d, self.band);
    }

    inline fn hasSigNeighbor(self: *const Tier1, i: usize) bool {
        const c = self.neighborCounts(i);
        return c.h + c.v + c.d > 0;
    }

    /// 0 if insignificant, +1 significant-positive, -1 significant-negative.
    inline fn signContrib(self: *const Tier1, i: usize) i32 {
        if (!self.flags.get(i, SIG)) return 0;
        return if (self.flags.get(i, SIGN)) -1 else 1;
    }

    /// Sign-coding context and XOR bit (T.800 Tables D.2/D.3).
    fn scContextAndXor(self: *const Tier1, i: usize) struct { u8, u8 } {
        const s = self.flags.stride;
        const hc = std.math.clamp(self.signContrib(i - 1) + self.signContrib(i + 1), -1, 1);
        const vc = std.math.clamp(self.signContrib(i - s) + self.signContrib(i + s), -1, 1);
        // Table indexed by (hc+1)*3 + (vc+1).
        const table = [9]struct { u8, u8 }{
            .{ 4, 1 }, .{ 3, 1 }, .{ 2, 1 }, // hc = -1: vc -1, 0, 1
            .{ 1, 1 }, .{ 0, 0 }, .{ 1, 0 }, // hc =  0
            .{ 2, 0 }, .{ 3, 0 }, .{ 4, 0 }, // hc =  1
        };
        return table[@intCast((hc + 1) * 3 + (vc + 1))];
    }

    /// Magnitude-refinement context (T.800 Table D.4).
    fn mrContext(self: *const Tier1, i: usize) u8 {
        if (self.flags.get(i, REFINED)) return 2;
        if (self.hasSigNeighbor(i)) return 1;
        return 0;
    }

    // -- shared coding primitives -------------------------------------------

    fn codeSign(self: *Tier1, i: usize) Allocator.Error!void {
        const sc_ctx, const xor = self.scContextAndXor(i);
        const known_sym: u8 = if (self.encoding()) @as(u8, @intFromBool(self.flags.get(i, SIGN))) ^ xor else 0;
        const sym = try self.code(mq.CTX_SC_START + sc_ctx, known_sym);
        if (sym ^ xor == 1) self.flags.set(i, SIGN);
    }

    /// Zero-coding of the plane-`p` significance bit, then sign on a 1.
    fn codeSignificance(self: *Tier1, x: usize, y: usize, p: u32, zc_ctx: u8) Allocator.Error!void {
        const i = self.flags.idx(x, y);
        const ci = y * self.w + x;
        const known: u8 = @intCast((self.mag[ci] >> @intCast(p)) & 1);
        const bit = try self.code(mq.CTX_ZC_START + zc_ctx, known);
        if (bit == 1) {
            self.flags.set(i, SIG);
            self.mag[ci] |= @as(u32, 1) << @intCast(p);
            try self.codeSign(i);
        }
    }

    // -- coding passes ------------------------------------------------------

    /// Significance propagation (D.3.1): not-yet-significant samples with a
    /// significant neighbour (live state); every candidate is marked VISITED.
    fn sigPropPass(self: *Tier1, p: u32) Allocator.Error!void {
        var y0: usize = 0;
        while (y0 < self.h) : (y0 += 4) {
            const rows = @min(self.h - y0, 4);
            for (0..self.w) |x| for (0..rows) |r| {
                const y = y0 + r;
                const i = self.flags.idx(x, y);
                if (self.flags.get(i, SIG)) continue;
                const zc = self.zcAt(i);
                if (zc == 0) continue;
                self.flags.set(i, VISITED);
                try self.codeSignificance(x, y, p, zc);
            };
        }
    }

    /// Magnitude refinement (D.3.3): significant samples not coded in SPP.
    fn magRefPass(self: *Tier1, p: u32) Allocator.Error!void {
        var y0: usize = 0;
        while (y0 < self.h) : (y0 += 4) {
            const rows = @min(self.h - y0, 4);
            for (0..self.w) |x| for (0..rows) |r| {
                const y = y0 + r;
                const i = self.flags.idx(x, y);
                if (!self.flags.get(i, SIG) or self.flags.get(i, VISITED)) continue;
                const mrc = self.mrContext(i);
                const ci = y * self.w + x;
                const known: u8 = @intCast((self.mag[ci] >> @intCast(p)) & 1);
                const bit = try self.code(mq.CTX_MR_START + mrc, known);
                self.mag[ci] |= @as(u32, bit) << @intCast(p);
                self.flags.set(i, REFINED);
            };
        }
    }

    /// Cleanup (D.4) with run-length mode; clears all VISITED flags after.
    fn cleanupPass(self: *Tier1, p: u32) Allocator.Error!void {
        var y0: usize = 0;
        while (y0 < self.h) : (y0 += 4) {
            const rows = @min(self.h - y0, 4);
            for (0..self.w) |x| {
                if (rows == 4 and self.rlEligible(x, y0)) {
                    try self.cleanupRl(x, y0, p);
                } else {
                    for (0..rows) |r| {
                        const y = y0 + r;
                        const i = self.flags.idx(x, y);
                        if (self.flags.get(i, SIG) or self.flags.get(i, VISITED)) continue;
                        try self.codeSignificance(x, y, p, self.zcAt(i));
                    }
                }
            }
        }
        self.flags.clearVisited();
    }

    /// All 4 samples of a full stripe column: not significant, not visited,
    /// zero zero-coding context.
    fn rlEligible(self: *const Tier1, x: usize, y0: usize) bool {
        for (0..4) |r| {
            const i = self.flags.idx(x, y0 + r);
            if (self.flags.get(i, SIG) or self.flags.get(i, VISITED)) return false;
            if (self.zcAt(i) != 0) return false;
        }
        return true;
    }

    /// Run-length coding of one eligible stripe column (D.4.2).
    fn cleanupRl(self: *Tier1, x: usize, y0: usize, p: u32) Allocator.Error!void {
        var run_known: u8 = 0;
        var r_known: u8 = 0;
        if (self.encoding()) {
            for (0..4) |r| {
                const ci = (y0 + r) * self.w + x;
                if ((self.mag[ci] >> @intCast(p)) & 1 == 1) {
                    run_known = 1;
                    r_known = @intCast(r);
                    break;
                }
            }
        }

        const run = try self.code(mq.CTX_RUN_LENGTH, run_known);
        if (run == 0) return;

        // Two uniform-context bits, MSB first: the first-significant row.
        const b1 = try self.code(mq.CTX_UNIFORM, (r_known >> 1) & 1);
        const b0 = try self.code(mq.CTX_UNIFORM, r_known & 1);
        const r: usize = (@as(usize, b1) << 1) | b0;

        const i = self.flags.idx(x, y0 + r);
        const ci = (y0 + r) * self.w + x;
        self.flags.set(i, SIG);
        self.mag[ci] |= @as(u32, 1) << @intCast(p);
        try self.codeSign(i);

        // Rows r+1..4 are coded normally.
        for (r + 1..4) |rr| {
            const y = y0 + rr;
            try self.codeSignificance(x, y, p, self.zcAt(self.flags.idx(x, y)));
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

const BANDS = [_]BandKind{ .LL, .HL, .LH, .HH };

const GOLDEN_DATA = [_]u8{
    17,  122, 213, 200, 44,  48,  19,  55,  152, 3,   114, 203, 128, 94, 228, 236, 23, 50,  37, 67,
    151, 36,  157, 218, 120, 179, 42,  102, 230, 143, 83,  188, 48,  23, 249, 14,  55, 180, 3,  181,
    230, 140, 33,  71,  227, 43,  255, 127,
};
const GOLDEN_BITPLANES: u32 = 7;
const GOLDEN_PASSES: u32 = 19;

fn roundtrip(coeffs: []const i32, w: usize, h: usize, band: BandKind) !void {
    var cb = try encodeCodeBlock(ta, coeffs, w, h, band);
    defer cb.deinit(ta);
    const dec = try decodeCodeBlock(ta, cb.data, w, h, band, cb.num_bitplanes, cb.num_passes);
    defer ta.free(dec);
    try testing.expectEqualSlices(i32, coeffs, dec);
}

// Cross-check against OpenJPEG `opj_compress -n 1` on a 4x4 constant-1000
// image: a single LL block of -31768; OpenJPEG 2.5.4 emits these 19 bytes.
test "openjpeg codeblock interop c4" {
    const coeffs: [16]i32 = @splat(-31768);
    var cb = try encodeCodeBlock(ta, &coeffs, 4, 4, .LL);
    defer cb.deinit(ta);
    const OPJ = [_]u8{
        0x11, 0x50, 0x54, 0xa0, 0xe2, 0xa0, 0x00, 0x03, 0x09, 0x09,
        0x48, 0x13, 0x00, 0x61, 0x1e, 0x62, 0x9c, 0x48, 0x3f,
    };
    try testing.expectEqual(@as(u32, 15), cb.num_bitplanes);
    try testing.expectEqual(@as(u32, 43), cb.num_passes);
    try testing.expectEqualSlices(u8, &OPJ, cb.data);
    const dec = try decodeCodeBlock(ta, &OPJ, 4, 4, .LL, 15, 43);
    defer ta.free(dec);
    try testing.expectEqualSlices(i32, &coeffs, dec);
}

test "all zero is empty" {
    for (BANDS) |band| {
        const z: [16]i32 = @splat(0);
        var cb = try encodeCodeBlock(ta, &z, 4, 4, band);
        defer cb.deinit(ta);
        try testing.expectEqual(@as(usize, 0), cb.data.len);
        try testing.expectEqual(@as(u32, 0), cb.num_passes);
        try testing.expectEqual(@as(u32, 0), cb.num_bitplanes);
        const dec = try decodeCodeBlock(ta, &.{}, 4, 4, band, 0, 0);
        defer ta.free(dec);
        try testing.expectEqualSlices(i32, &z, dec);
    }
}

test "pass count relationship" {
    for (BANDS) |band| {
        var coeffs: [64]i32 = undefined;
        for (&coeffs, 0..) |*c, i| c.* = @as(i32, @intCast(i)) - 32;
        var cb = try encodeCodeBlock(ta, &coeffs, 8, 8, band);
        defer cb.deinit(ta);
        try testing.expect(cb.num_bitplanes > 0);
        try testing.expectEqual(3 * cb.num_bitplanes - 2, cb.num_passes);
    }
}

test "exhaustive 1x1" {
    for (BANDS) |band| {
        var v: i32 = -3;
        while (v <= 3) : (v += 1) try roundtrip(&.{v}, 1, 1, band);
    }
}

test "deterministic 2x2 patterns" {
    var rng: u64 = 0x9E37_79B9_7F4A_7C15;
    for (BANDS) |band| {
        for (0..300) |_| {
            var block: [4]i32 = undefined;
            for (&block) |*b| {
                rng = rng *% 6364136223846793005 +% 1;
                b.* = @rem(@as(i32, @intCast(rng >> 33)), 65) - 32;
            }
            try roundtrip(&block, 2, 2, band);
        }
    }
}

test "single nonzero deep" {
    for (BANDS) |band| {
        var block: [64]i32 = @splat(0);
        block[57] = 12345;
        try roundtrip(&block, 8, 8, band);
    }
}

test "first significant at each stripe row" {
    for (BANDS) |band| {
        for (0..4) |row| {
            var block: [32]i32 = @splat(0);
            block[row * 8] = -777;
            try roundtrip(&block, 8, 4, band);
        }
    }
}

test "sparse blocks force run length" {
    const block = try ta.alloc(i32, 64 * 64);
    defer ta.free(block);
    for (BANDS) |band| {
        @memset(block, 0);
        block[0] = 3;
        block[64 * 30 + 31] = -9;
        block[64 * 63 + 63] = 100;
        try roundtrip(block, 64, 64, band);
    }
}

test "stripe and partial boundaries" {
    const dims = [_][2]usize{ .{ 1, 1 }, .{ 3, 5 }, .{ 7, 4 }, .{ 7, 6 }, .{ 13, 13 }, .{ 17, 3 }, .{ 5, 17 } };
    var buf: [17 * 17]i32 = undefined;
    for (BANDS) |band| for (dims) |d| {
        const n = d[0] * d[1];
        for (buf[0..n], 0..) |*c, i| c.* = @rem(@as(i32, @intCast(i)) * 37, 511) - 255;
        try roundtrip(buf[0..n], d[0], d[1], band);
    };
}

test "truncated data never panics" {
    var coeffs: [64 * 8]i32 = undefined;
    for (&coeffs, 0..) |*c, i| c.* = @as(i32, @intCast(i * 101 % 4096)) - 2048;
    var cb = try encodeCodeBlock(ta, &coeffs, 64, 8, .LH);
    defer cb.deinit(ta);
    for (0..cb.data.len + 1) |cut| {
        if (decodeCodeBlock(ta, cb.data[0..cut], 64, 8, .LH, cb.num_bitplanes, cb.num_passes)) |d| {
            ta.free(d);
        } else |_| {}
    }
}

test "invalid metadata is rejected" {
    try testing.expectError(error.InvalidData, decodeCodeBlock(ta, &.{}, 4, 4, .LL, 3, 100));
    try testing.expectError(error.InvalidData, decodeCodeBlock(ta, &.{}, 4, 4, .LL, 0, 1));
}

// Self-golden regression: a fixed 8x8 HL block must encode to these bytes.
test "golden 8x8 bitstream" {
    var coeffs: [64]i32 = undefined;
    const k: usize = @intCast(@as(u64, 2654435761) % 97);
    for (&coeffs, 0..) |*c, i| c.* = @as(i32, @intCast((i * k) % 200)) - 100;
    var cb = try encodeCodeBlock(ta, &coeffs, 8, 8, .HL);
    defer cb.deinit(ta);
    try testing.expectEqualSlices(u8, &GOLDEN_DATA, cb.data);
    try testing.expectEqual(GOLDEN_BITPLANES, cb.num_bitplanes);
    try testing.expectEqual(GOLDEN_PASSES, cb.num_passes);
    try roundtrip(&coeffs, 8, 8, .HL);
}

// Rust proptest (400 cases): random dims 1..=68, any band, 17-bit signed
// magnitudes. Deterministic seeds here.
test "prop roundtrip" {
    var prng = std.Random.DefaultPrng.init(0xEB_C07);
    const r = prng.random();
    const buf = try ta.alloc(i32, 68 * 68);
    defer ta.free(buf);
    for (0..400) |_| {
        const w = r.intRangeAtMost(usize, 1, 68);
        const h = r.intRangeAtMost(usize, 1, 68);
        const band = BANDS[r.uintLessThan(usize, 4)];
        var rng: u64 = r.int(u64) | 1;
        const coeffs = buf[0 .. w * h];
        var all_zero = true;
        for (coeffs) |*c| {
            rng = rng *% 6364136223846793005 +% 1;
            const mag: i32 = @intCast((rng >> 40) & ((1 << 17) - 1));
            c.* = if ((rng >> 39) & 1 == 1) -mag else mag;
            if (c.* != 0) all_zero = false;
        }
        var cb = try encodeCodeBlock(ta, coeffs, w, h, band);
        defer cb.deinit(ta);
        if (all_zero) {
            try testing.expectEqual(@as(usize, 0), cb.data.len);
            try testing.expectEqual(@as(u32, 0), cb.num_passes);
            try testing.expectEqual(@as(u32, 0), cb.num_bitplanes);
        } else {
            try testing.expectEqual(3 * cb.num_bitplanes - 2, cb.num_passes);
        }
        const dec = try decodeCodeBlock(ta, cb.data, w, h, band, cb.num_bitplanes, cb.num_passes);
        defer ta.free(dec);
        try testing.expectEqualSlices(i32, coeffs, dec);
    }
}
