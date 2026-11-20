//! JPEG-LS encoder.
//!
//! Writes a compliant JPEG-LS bitstream (SOI, SOF55, SOS, entropy-coded
//! scan data, EOI). The default `Profile.t87` path is ITU-T T.87 conformant
//! (single-bit stuffing, limited Golomb, run mode); `Profile.legacy_go`
//! reproduces the frozen 1.0.0 / Go-compatible bytes.

const std = @import("std");
const bitstream = @import("bitstream.zig");
const context = @import("context.zig");
const errors = @import("error.zig");
const legacy = @import("legacy.zig");
const options = @import("options.zig");
const predictor = @import("predictor.zig");
const run_mode = @import("run_mode.zig");

const BitWriter = bitstream.BitWriter;
const CodecError = errors.CodecError;
const ContextModel = context.ContextModel;
const Diagnostic = errors.Diagnostic;
const EncodeOptions = options.EncodeOptions;
const clamp = predictor.clamp;
const iabs = predictor.iabs;
const predictMed = predictor.predictMed;

// ---------------------------------------------------------------------------
// JPEG-LS markers
// ---------------------------------------------------------------------------

const MARKER_SOI: u16 = 0xFFD8;
const MARKER_EOI: u16 = 0xFFD9;
const MARKER_SOS: u16 = 0xFFDA;
const MARKER_SOF55: u16 = 0xFFF7;

/// Default statistics reset threshold (T.87 A.2.1 RESET).
pub const DEFAULT_RESET: i32 = 64;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a 16-bit grayscale image into JPEG-LS lossless format.
///
/// `pixels` is a row-major pixel buffer of length `width * height`; the
/// stream is written to `out` (which is flushed). Uses the default
/// `EncodeOptions` (`Profile.t87`, lossless). `allocator` is used only for
/// line buffers.
pub fn encode(
    allocator: std.mem.Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
    out: *std.Io.Writer,
) CodecError!void {
    return encodeWithOptions(allocator, pixels, width, height, .{}, out);
}

/// Validated parameters shared by both encode entry points.
const Params = struct { precision: u8, max_val: i32, near: i32 };

fn checkDims(diag: ?*Diagnostic, width: u32, height: u32) CodecError!void {
    // Dimensions: JPEG-LS SOF55 stores X/Y as 16-bit, and 0 is illegal.
    if (width == 0 or width > 65535) return errors.invalidParameter(diag, "width", width, "1..=65535");
    if (height == 0 or height > 65535) return errors.invalidParameter(diag, "height", height, "1..=65535");
}

fn checkParams(diag: ?*Diagnostic, samples: []const u16, opts: EncodeOptions) CodecError!Params {
    // Precision: explicit override (validated 2..=16) or derived from data.
    const max_pixel: u16 = if (samples.len == 0) 0 else std.mem.max(u16, samples);
    const precision: u8 = if (opts.precision) |p| blk: {
        if (p < 2 or p > 16) return errors.invalidParameter(diag, "precision", p, "2..=16");
        break :blk p;
    } else effectivePrecision(max_pixel);
    const max_val: i32 = (@as(i32, 1) << @intCast(precision)) - 1;

    if (@as(i32, max_pixel) > max_val) {
        return errors.invalidParameter(diag, "precision", precision, "large enough to hold every sample");
    }

    // NEAR: bounded by min(255, MAXVAL/2) (T.87 C.2.4.1.1).
    const near: i32 = opts.near;
    if (near > @min(@divTrunc(max_val, 2), 255)) {
        return errors.invalidParameter(diag, "near", opts.near, "0..=min(255, MAXVAL/2)");
    }
    return .{ .precision = precision, .max_val = max_val, .near = near };
}

/// Encode a 16-bit grayscale image with explicit `EncodeOptions`.
pub fn encodeWithOptions(
    allocator: std.mem.Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
    opts: EncodeOptions,
    out: *std.Io.Writer,
) CodecError!void {
    const diag = opts.diagnostic;
    try checkDims(diag, width, height);

    const w: usize = width;
    const h: usize = height;
    const expected = w * h;
    if (pixels.len != expected) return errors.dimensionMismatch(diag, expected, pixels.len);

    const p = try checkParams(diag, pixels, opts);

    switch (opts.profile) {
        .legacy_go => {
            if (p.near != 0) {
                return errors.invalidParameter(diag, "near", opts.near, "0 (LegacyGo profile is lossless only)");
            }
            try writeHeaders(diag, out, p.precision, @intCast(height), @intCast(width), 0);
            legacy.encodeScan(allocator, out, pixels, w, h, p.max_val, 0) catch |e| switch (e) {
                error.Io => return errors.io(diag),
                error.OutOfMemory => return error.OutOfMemory,
            };
            try writeMarker(diag, out, MARKER_EOI);
        },
        .t87 => {
            try writeHeaders(diag, out, p.precision, @intCast(height), @intCast(width), opts.near);
            const ctx = ContextModel.init(p.max_val, p.near, DEFAULT_RESET);
            try encodeScanT87(allocator, diag, out, pixels, w, h, ctx);
            try writeMarker(diag, out, MARKER_EOI);
        },
    }
    out.flush() catch return errors.io(diag);
}

/// Encode a multi-component image as a **planar** (ILV 0) JPEG-LS stream: a
/// shared SOF55 with `components` components, then one SOS + entropy scan per
/// component. `samples` is component-planar -- all of component 0, then
/// component 1, ... -- of length `width * height * components`.
/// `components == 1` is the grayscale case and produces the same stream as
/// `encodeWithOptions`. T.87 profile only. Only 1 (grayscale) or 3 (planar
/// RGB) components are supported.
pub fn encodeImage(
    allocator: std.mem.Allocator,
    samples: []const u16,
    width: u32,
    height: u32,
    components: u8,
    opts: EncodeOptions,
    out: *std.Io.Writer,
) CodecError!void {
    const diag = opts.diagnostic;
    if (components != 1 and components != 3) {
        return errors.invalidParameter(diag, "components", components, "1 or 3");
    }
    if (opts.profile != .t87) {
        return errors.unsupported(diag, "encode_image supports only the T87 profile", .{});
    }
    try checkDims(diag, width, height);

    const w: usize = width;
    const h: usize = height;
    const plane = w * h;
    const expected = plane * components;
    if (samples.len != expected) return errors.dimensionMismatch(diag, expected, samples.len);

    const p = try checkParams(diag, samples, opts);

    try writeMarker(diag, out, MARKER_SOI);
    try writeSof(diag, out, p.precision, @intCast(height), @intCast(width), components);
    // One SOS + entropy scan per component (ILV 0). Each scan gets a fresh
    // context, as the decoder expects.
    for (0..components) |c| {
        try writeSos(diag, out, @intCast(c + 1), opts.near);
        const ctx = ContextModel.init(p.max_val, p.near, DEFAULT_RESET);
        try encodeScanT87(allocator, diag, out, samples[c * plane .. (c + 1) * plane], w, h, ctx);
    }
    try writeMarker(diag, out, MARKER_EOI);
    out.flush() catch return errors.io(diag);
}

/// Write SOI, SOF55, and SOS headers for a single-component image.
fn writeHeaders(diag: ?*Diagnostic, out: *std.Io.Writer, precision: u8, height: u16, width: u16, near: u8) CodecError!void {
    try writeMarker(diag, out, MARKER_SOI);
    try writeSof(diag, out, precision, height, width, 1);
    try writeSos(diag, out, 1, near);
}

// ---------------------------------------------------------------------------
// T.87 conformant scan (regular + run mode)
// ---------------------------------------------------------------------------

/// Encode the entropy-coded scan for a single-component image (T.87 A.4-A.7).
///
/// Takes a pre-built `ContextModel` so callers (and tests) can inject LSE
/// preset thresholds; the public path builds a default model.
pub fn encodeScanT87(
    allocator: std.mem.Allocator,
    diag: ?*Diagnostic,
    out: *std.Io.Writer,
    pixels: []const u16,
    width: usize,
    height: usize,
    ctx_in: ContextModel,
) CodecError!void {
    var ctx = ctx_in;
    var bw = BitWriter.init(out);
    const near = ctx.near;
    const max_val = ctx.max_val;
    const range = ctx.range;

    const lines = try allocator.alloc(i32, 3 * width + 4);
    defer allocator.free(lines);
    @memset(lines, 0);
    var prev = lines[0 .. width + 2];
    var cur = lines[width + 2 .. 2 * width + 4];
    const src_row = lines[2 * width + 4 ..];

    for (0..height) |y| {
        // T.87 A.2.1 edge seeds: Ra(0,y) = Rb, Rd(width-1,y) = Rb.
        cur[0] = prev[1];
        prev[width + 1] = prev[width];

        for (src_row, pixels[y * width .. (y + 1) * width]) |*dst, px| dst.* = px;

        var x: usize = 0;
        while (x < width) {
            const ra = cur[x];
            const rb = prev[x + 1];
            const rc = prev[x];
            const rd = prev[x + 2];

            const d1 = rd - rb;
            const d2 = rb - rc;
            const d3 = rc - ra;

            if (iabs(d1) <= near and iabs(d2) <= near and iabs(d3) <= near) {
                x = run_mode.encodeRun(&bw, &ctx, src_row, cur, prev, x, width) catch return errors.io(diag);
                continue;
            }

            const ci = ctx.getContextIndex(d1, d2, d3);
            const q = ci.q;
            const sign = ci.sign;
            const k = ctx.computeK(q);
            var px = predictMed(ra, rb, rc);
            px += sign * ctx.c[q];
            px = clamp(px, 0, max_val);

            const ix = src_row[x];
            const err_q = run_mode.moduloRange(run_mode.quantize((ix - px) * sign, near), range);

            const correction: i32 = if (k == 0 and near == 0 and 2 * ctx.b[q] <= -ctx.n[q]) -1 else 0;
            const mapped = run_mode.mapError(err_q, correction);
            bw.writeLimitedGolomb(k, mapped, ctx.limit, ctx.qbpp) catch return errors.io(diag);
            ctx.updateStats(q, err_q);

            cur[x + 1] = run_mode.fixReconstructed(px + sign * err_q * (2 * near + 1), near, range, max_val);
            x += 1;
        }

        std.mem.swap([]i32, &prev, &cur);
    }

    bw.flush() catch return errors.io(diag);
}

// ---------------------------------------------------------------------------
// Marker writers
// ---------------------------------------------------------------------------

fn put(diag: ?*Diagnostic, out: *std.Io.Writer, bytes: []const u8) CodecError!void {
    out.writeAll(bytes) catch return errors.io(diag);
}

fn writeMarker(diag: ?*Diagnostic, out: *std.Io.Writer, marker: u16) CodecError!void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, marker, .big);
    try put(diag, out, &b);
}

fn writeSof(diag: ?*Diagnostic, out: *std.Io.Writer, precision: u8, height: u16, width: u16, components: u8) CodecError!void {
    // Length: 2 + 1(P) + 2(Y) + 2(X) + 1(Nf) + Nf*3
    var hdr: [10]u8 = undefined;
    std.mem.writeInt(u16, hdr[0..2], MARKER_SOF55, .big);
    std.mem.writeInt(u16, hdr[2..4], 8 + @as(u16, components) * 3, .big);
    hdr[4] = precision;
    std.mem.writeInt(u16, hdr[5..7], height, .big);
    std.mem.writeInt(u16, hdr[7..9], width, .big);
    hdr[9] = components;
    try put(diag, out, &hdr);
    for (0..components) |i| {
        // Component ID, H=1/V=1, Tq=0.
        try put(diag, out, &.{ @intCast(i + 1), 0x11, 0x00 });
    }
}

fn writeSos(diag: ?*Diagnostic, out: *std.Io.Writer, component_id: u8, near: u8) CodecError!void {
    try put(diag, out, &.{ 0xFF, 0xDA, 0x00, 0x08, 1, component_id, 0, near, 0, 0 });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Determine the effective bit depth needed for the maximum pixel value.
///
/// JPEG-LS supports 2..=16 bits per sample. We always use at least 8.
pub fn effectivePrecision(max_pixel: u16) u8 {
    if (max_pixel == 0) return 8;
    const bits_needed: u8 = 16 - @as(u8, @clz(max_pixel));
    return std.math.clamp(bits_needed, 8, 16);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "effective precision 8bit" {
    try testing.expectEqual(@as(u8, 8), effectivePrecision(0));
    try testing.expectEqual(@as(u8, 8), effectivePrecision(1));
    try testing.expectEqual(@as(u8, 8), effectivePrecision(255));
}

test "effective precision more than 8" {
    try testing.expectEqual(@as(u8, 9), effectivePrecision(256));
    try testing.expectEqual(@as(u8, 10), effectivePrecision(1023));
    try testing.expectEqual(@as(u8, 12), effectivePrecision(4095));
    try testing.expectEqual(@as(u8, 16), effectivePrecision(65535));
}

test "encode rejects empty image" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try testing.expect(std.meta.isError(encode(testing.allocator, &.{}, 0, 0, &aw.writer)));
}

test "encode produces soi and eoi" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try encode(testing.allocator, &[_]u16{42} ** 4, 2, 2, &aw.writer);
    const buf = aw.written();
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, buf[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, buf[buf.len - 2 ..]);
}

test "encode uniform image" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try encode(testing.allocator, &[_]u16{0} ** 16, 4, 4, &aw.writer);
    try testing.expect(aw.written().len > 0);
}

test "encode rejects oversize dimension" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidParameter, encodeWithOptions(testing.allocator, &[_]u16{0} ** 4, 65536, 1, .{ .diagnostic = &diag }, &aw.writer));
    try testing.expectEqualStrings("width", diag.name);
}

test "encode legacy rejects near" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidParameter, encodeWithOptions(testing.allocator, &[_]u16{0} ** 4, 2, 2, .{ .near = 1, .profile = .legacy_go, .diagnostic = &diag }, &aw.writer));
    try testing.expectEqualStrings("near", diag.name);
}
