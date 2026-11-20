//! T.87 run mode and shared regular-mode sample arithmetic.
//!
//! Run mode is entered from the regular scan loop whenever all three local
//! gradients are within `NEAR` (T.87 A.7). This module holds:
//! - the run-length coding (A.7.1) and run-interruption coding (A.7.2), wired
//!   into both scan loops via `encodeRun` / `decodeRun`;
//! - the shared error mapping (A.5.2), near-lossless quantization/modulo
//!   (A.4.4/A.4.5), and reconstruction (A.4.6) helpers used by regular mode
//!   too, so the encoder and decoder cannot drift.
//!
//! # Line buffers
//!
//! `cur` and `prev` are `width + 2` element `i32` buffers holding reconstructed
//! samples with a one-slot offset: logical sample `x` lives at index `x + 1`.
//! Logical index `-1` is slot `0` (the left border) and logical index `width`
//! is slot `width + 1` (the right border). This realizes the T.87 A.2.1 edge
//! rules: `Ra(0,y) = Rb`, `Rc(0,y)` retains the prior line's seed, and
//! `Rd(width-1,y) = Rb`.

const std = @import("std");
const bitstream = @import("bitstream.zig");
const context = @import("context.zig");
const predictor = @import("predictor.zig");

const BitReader = bitstream.BitReader;
const BitWriter = bitstream.BitWriter;
const ContextModel = context.ContextModel;
const clamp = predictor.clamp;
const iabs = predictor.iabs;

/// Run-interruption context base index (T.87: contexts 365/366).
const RUN_CTX_BASE = context.RUN_CTX_BASE;

// ---------------------------------------------------------------------------
// Shared sample arithmetic (regular + run mode)
// ---------------------------------------------------------------------------

/// Map a signed error to a non-negative code (T.87 A.5.2).
///
/// `correction` is `0` normally or `-1` (all-ones) when the `k == 0 && NEAR == 0`
/// bias-flip case applies; the XOR realizes both the flip and its inverse.
pub inline fn mapError(err_val: i32, correction: i32) u32 {
    const v = correction ^ err_val;
    return if (v >= 0) @intCast(2 * v) else @intCast(-2 * v - 1);
}

/// Inverse of `mapError` (T.87 A.5.2).
pub inline fn unmapError(mapped: u32, correction: i32) i32 {
    const m: i32 = @bitCast(mapped);
    const v = (m >> 1) ^ -(m & 1);
    return correction ^ v;
}

/// Near-lossless error quantization (T.87 A.4.4). Identity when `near == 0`.
pub inline fn quantize(e: i32, near: i32) i32 {
    if (near == 0) return e;
    if (e >= 0) return @divTrunc(e + near, 2 * near + 1);
    return -@divTrunc(near - e, 2 * near + 1);
}

/// Modulo reduction of the (quantized) error into the coding range (A.4.5).
pub inline fn moduloRange(e_in: i32, range: i32) i32 {
    var e = e_in;
    if (e < 0) e += range;
    if (e >= @divTrunc(range + 1, 2)) e -= range;
    return e;
}

/// Reject a decoded error value no conformant encoder can produce.
///
/// The encoder reduces every error modulo RANGE (A.4.5), so `|Errval| <=
/// RANGE/2`. A larger value can only come from a corrupt Golomb code; left
/// unchecked it inflates the context's A accumulator, which raises k, which
/// lets the next code decode larger still, until A overflows `i32`. Within
/// the bound A stays below `RESET * RANGE/2 <= 65535 * 32768 < i32::MAX`.
pub inline fn checkErrval(err: i32, range: i32) error{InvalidData}!void {
    if (@abs(err) > @as(u32, @intCast(@divTrunc(range, 2)))) return error.InvalidData;
}

/// Reconstruct a sample value, folding it back into `[0, max_val]` (A.4.6).
pub inline fn fixReconstructed(value: i32, near: i32, range: i32, max_val: i32) i32 {
    var v = value;
    if (v < -near) {
        v += range * (2 * near + 1);
    } else if (v > max_val + near) {
        v -= range * (2 * near + 1);
    }
    return clamp(v, 0, max_val);
}

// ---------------------------------------------------------------------------
// Run-length coding (T.87 A.7.1)
// ---------------------------------------------------------------------------

inline fn runBlock(ctx: *const ContextModel) usize {
    return @as(usize, 1) << @intCast(ctx.j[ctx.run_index]);
}

/// Emit the run-length code for a run of `run_length` samples (A.7.1.2).
fn encodeRunPixels(bw: *BitWriter, ctx: *ContextModel, run_length_in: usize, end_of_line: bool) bitstream.WriteError!void {
    var run_length = run_length_in;
    while (run_length >= runBlock(ctx)) {
        try bw.writeBit(1);
        run_length -= runBlock(ctx);
        ctx.incrementRunIndex();
    }
    if (end_of_line) {
        // A.15 end-of-line rule: a residual run emits a single 1-bit and does
        // NOT advance RUNindex.
        if (run_length != 0) try bw.writeBit(1);
    } else {
        try bw.writeBit(0);
        const jbits = ctx.j[ctx.run_index];
        if (jbits > 0) try bw.writeBits(@intCast(run_length), jbits);
    }
}

/// Decode a run-length code, returning the number of run samples (A.7.1.2).
fn decodeRunPixels(br: *BitReader, ctx: *ContextModel, pixel_count: usize) bitstream.ReadError!usize {
    var index: usize = 0;
    while ((try br.readBit()) == 1) {
        const block = runBlock(ctx);
        const count = @min(block, pixel_count - index);
        index += count;
        if (count == block) ctx.incrementRunIndex();
        if (index == pixel_count) return index;
    }
    const jbits = ctx.j[ctx.run_index];
    if (jbits > 0) index += try br.readBits(jbits);
    // "run length exceeds line width"
    if (index > pixel_count) return error.InvalidData;
    return index;
}

// ---------------------------------------------------------------------------
// Run-interruption coding (T.87 A.7.2, code segments A.19-A.23)
// ---------------------------------------------------------------------------

const InterruptionParams = struct { ri_type: usize, px: i32, sign: i32 };

/// Select the run-interruption parameters (T.87 A.7.2): `(RItype, Px, sign)`.
inline fn interruptionParams(ra: i32, rb: i32, near: i32) InterruptionParams {
    if (iabs(ra - rb) <= near) return .{ .ri_type = 1, .px = ra, .sign = 1 };
    return .{ .ri_type = 0, .px = rb, .sign = if (rb > ra) 1 else -1 };
}

/// Run-interruption error-mapping predicate `map` (T.87 code segment A.21).
inline fn runMap(err: i32, k: i32, nn: i32, n: i32) bool {
    return (k == 0 and err > 0 and 2 * nn < n) or (err < 0 and 2 * nn >= n) or (err < 0 and k != 0);
}

/// Encode one run-interruption sample (A.7.2); returns the reconstructed value.
fn encodeRunInterruption(bw: *BitWriter, ctx: *ContextModel, ix: i32, ra: i32, rb: i32) bitstream.WriteError!i32 {
    const near = ctx.near;
    const p = interruptionParams(ra, rb, near);
    const ctx_idx = RUN_CTX_BASE + p.ri_type;

    const err_q = moduloRange(quantize((ix - p.px) * p.sign, near), ctx.range);

    const k = ctx.computeKRun(p.ri_type);
    const map = runMap(err_q, k, ctx.nn[p.ri_type], ctx.n[ctx_idx]);
    const e_mapped: u32 = @intCast(2 * iabs(err_q) - @as(i32, @intCast(p.ri_type)) - @intFromBool(map));

    const glimit = ctx.limit - ctx.j[ctx.run_index] - 1;
    try bw.writeLimitedGolomb(k, e_mapped, glimit, ctx.qbpp);
    ctx.updateRunStats(p.ri_type, e_mapped, err_q < 0);

    return fixReconstructed(p.px + p.sign * err_q * (2 * near + 1), near, ctx.range, ctx.max_val);
}

/// Decode one run-interruption sample (A.7.2); returns the reconstructed value.
fn decodeRunInterruption(br: *BitReader, ctx: *ContextModel, ra: i32, rb: i32) bitstream.ReadError!i32 {
    const near = ctx.near;
    const p = interruptionParams(ra, rb, near);
    const ctx_idx = RUN_CTX_BASE + p.ri_type;

    const k = ctx.computeKRun(p.ri_type);
    const glimit = ctx.limit - ctx.j[ctx.run_index] - 1;
    const e_mapped = try br.readLimitedGolomb(k, glimit, ctx.qbpp);

    // temp = e_mapped + RItype = 2*|err| - map, so its parity is `map` and
    // ceil(temp/2) is |err| (A.22). The sign is recovered from the same
    // predicate the encoder used: for +|err| the encoder's `map` is
    // `k==0 && 2*Nn < N`; the negative branch is its exact complement.
    // Computed in i64 so a corrupt (huge) code cannot overflow before the
    // range check rejects it.
    const temp: i64 = @as(i64, e_mapped) + @as(i64, @intCast(p.ri_type));
    const abs_e: i64 = (temp + (temp & 1)) >> 1;
    const map_positive = k == 0 and 2 * ctx.nn[p.ri_type] < ctx.n[ctx_idx];
    const err_wide: i64 = if ((temp & 1) == @intFromBool(map_positive)) abs_e else -abs_e;

    // Also bounds e_mapped (<= 2*|err|) before it reaches the run-context A.
    if (err_wide > @divTrunc(ctx.range, 2) or err_wide < -@divTrunc(ctx.range, 2)) return error.InvalidData;
    const err_q: i32 = @intCast(err_wide);
    ctx.updateRunStats(p.ri_type, e_mapped, err_q < 0);

    return fixReconstructed(p.px + p.sign * err_q * (2 * near + 1), near, ctx.range, ctx.max_val);
}

// ---------------------------------------------------------------------------
// Run mode entry points (called from the scan loops)
// ---------------------------------------------------------------------------

/// Encode a run starting at logical sample `start`; returns the next sample.
///
/// `src` is the source row (length `width`); `cur`/`prev` are the offset-1
/// reconstructed line buffers described in the module docs.
pub fn encodeRun(
    bw: *BitWriter,
    ctx: *ContextModel,
    src: []const i32,
    cur: []i32,
    prev: []const i32,
    start: usize,
    width: usize,
) bitstream.WriteError!usize {
    const near = ctx.near;
    const ra = cur[start]; // logical sample start-1 (border at start==0)

    var run_length: usize = 0;
    while (start + run_length < width and iabs(src[start + run_length] - ra) <= near) {
        cur[start + run_length + 1] = ra;
        run_length += 1;
    }
    const end = start + run_length;
    const end_of_line = end == width;
    try encodeRunPixels(bw, ctx, run_length, end_of_line);
    if (end_of_line) return end;

    const rb = prev[end + 1];
    cur[end + 1] = try encodeRunInterruption(bw, ctx, src[end], ra, rb);
    ctx.decrementRunIndex();
    return end + 1;
}

/// Decode a run starting at logical sample `start`; returns the next sample.
pub fn decodeRun(
    br: *BitReader,
    ctx: *ContextModel,
    cur: []i32,
    prev: []const i32,
    start: usize,
    width: usize,
) bitstream.ReadError!usize {
    const ra = cur[start];

    const run_length = try decodeRunPixels(br, ctx, width - start);
    @memset(cur[start + 1 .. start + run_length + 1], ra);
    const end = start + run_length;
    if (end == width) return end;

    const rb = prev[end + 1];
    cur[end + 1] = try decodeRunInterruption(br, ctx, ra, rb);
    ctx.decrementRunIndex();
    return end + 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "map unmap roundtrip all corrections" {
    for ([_]i32{ 0, -1 }) |correction| {
        var err: i32 = -300;
        while (err <= 300) : (err += 1) {
            try testing.expectEqual(err, unmapError(mapError(err, correction), correction));
        }
    }
}

test "quantize near0 identity" {
    var e: i32 = -50;
    while (e <= 50) : (e += 1) try testing.expectEqual(e, quantize(e, 0));
}

test "quantize near symmetric" {
    try testing.expectEqual(@as(i32, 0), quantize(0, 2));
    try testing.expectEqual(@as(i32, 0), quantize(2, 2));
    try testing.expectEqual(@as(i32, 0), quantize(-2, 2));
    try testing.expectEqual(@as(i32, 1), quantize(3, 2));
    try testing.expectEqual(@as(i32, -1), quantize(-3, 2));
    try testing.expectEqual(@as(i32, 1), quantize(7, 2));
    try testing.expectEqual(@as(i32, 2), quantize(8, 2));
}

test "fix reconstructed lossless wraps" {
    try testing.expectEqual(@as(i32, 255), fixReconstructed(-1, 0, 256, 255));
    try testing.expectEqual(@as(i32, 0), fixReconstructed(256, 0, 256, 255));
    try testing.expectEqual(@as(i32, 128), fixReconstructed(128, 0, 256, 255));
}
