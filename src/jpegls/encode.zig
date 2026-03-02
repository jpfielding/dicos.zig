//! JPEG-LS encoder.
//!
//! Writes a compliant JPEG-LS bitstream (SOI, SOF55, SOS, entropy-coded
//! scan data, EOI) for a single-component grayscale image.

const std = @import("std");
const bitstream_mod = @import("bitstream.zig");
const context_mod = @import("context.zig");
const predictor_mod = @import("predictor.zig");
const run_mode_mod = @import("run_mode.zig");

const BitWriter = bitstream_mod.BitWriter;
const CodecError = bitstream_mod.CodecError;
const ContextModel = context_mod.ContextModel;
const predictMed = predictor_mod.predictMed;
const clampVal = predictor_mod.clampVal;

// ---------------------------------------------------------------------------
// JPEG-LS markers
// ---------------------------------------------------------------------------

const MARKER_SOI: u16 = 0xFFD8;
const MARKER_EOI: u16 = 0xFFD9;
const MARKER_SOS: u16 = 0xFFDA;
const MARKER_SOF55: u16 = 0xFFF7;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a 16-bit grayscale image into JPEG-LS lossless format.
///
/// `pixels` is a row-major pixel buffer of length `width * height`.
/// Returns the encoded bytes using the provided allocator.
pub fn encode(
    allocator: std.mem.Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
) CodecError![]u8 {
    const width_usize: usize = @intCast(width);
    const height_usize: usize = @intCast(height);
    const expected = width_usize * height_usize;

    if (pixels.len != expected) {
        return CodecError.DimensionMismatch;
    }

    if (width_usize == 0 or height_usize == 0) {
        return CodecError.InvalidData;
    }

    // Determine bit depth from the actual maximum pixel value.
    var max_pixel: u16 = 0;
    for (pixels) |p| {
        if (p > max_pixel) max_pixel = p;
    }
    const precision = effectivePrecision(max_pixel);
    const max_val: i32 = (@as(i32, 1) << @as(u5, @intCast(precision))) - 1;

    var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
    errdefer buf.deinit();

    var bw = BitWriter.init(&buf);

    // SOI
    try writeMarker(&bw, MARKER_SOI);

    // SOF55
    try writeSof(&bw, @intCast(precision), @intCast(height), @intCast(width), 1);

    // SOS (Near=0, ILV=0)
    try writeSos(&bw, 1, 0);

    // Context model
    var ctx = try ContextModel.init(allocator, max_val, 0, 64);
    defer ctx.deinit();

    // Scan encoding
    try encodeScan(&bw, &ctx, pixels, width_usize, height_usize, max_val);

    // Flush remaining bits
    try bw.flush();

    // EOI -- write through since we just flushed.
    try bw.writeByte(@intCast(MARKER_EOI >> 8));
    try bw.writeByte(@intCast(MARKER_EOI & 0xFF));

    return buf.toOwnedSlice() catch return CodecError.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Marker writers
// ---------------------------------------------------------------------------

fn writeMarker(bw: *BitWriter, marker: u16) CodecError!void {
    try bw.writeByte(@intCast(marker >> 8));
    try bw.writeByte(@intCast(marker & 0xFF));
}

fn writeSof(
    bw: *BitWriter,
    precision: u8,
    height: u16,
    width: u16,
    components: u8,
) CodecError!void {
    try writeMarker(bw, MARKER_SOF55);

    // Length: 2 + 1(P) + 2(Y) + 2(X) + 1(Nf) + Nf*3
    const length: u16 = 8 + @as(u16, components) * 3;
    try bw.writeU16be(length);

    try bw.writeByte(precision);
    try bw.writeU16be(height);
    try bw.writeU16be(width);
    try bw.writeByte(components);

    var i: u8 = 0;
    while (i < components) : (i += 1) {
        try bw.writeByte(i + 1); // Component ID
        try bw.writeByte(0x11); // H=1, V=1
        try bw.writeByte(0x00); // Tq=0
    }
}

fn writeSos(bw: *BitWriter, components: u8, near: u8) CodecError!void {
    try writeMarker(bw, MARKER_SOS);

    // Length: 2 + 1(Ns) + Ns*2 + 3
    const length: u16 = 6 + @as(u16, components) * 2;
    try bw.writeU16be(length);

    try bw.writeByte(components);

    var i: u8 = 0;
    while (i < components) : (i += 1) {
        try bw.writeByte(i + 1); // Component ID
        try bw.writeByte(0x00); // Mapping table selector
    }

    try bw.writeByte(near); // Near
    try bw.writeByte(0x00); // ILV = 0
    try bw.writeByte(0x00); // Al=0, Ah=0
}

// ---------------------------------------------------------------------------
// Scan encoder
// ---------------------------------------------------------------------------

fn encodeScan(
    bw: *BitWriter,
    ctx: *ContextModel,
    pixels: []const u16,
    w: usize,
    h: usize,
    max_val: i32,
) CodecError!void {
    const curr_line = ctx.allocator.alloc(i32, w) catch return CodecError.OutOfMemory;
    defer ctx.allocator.free(curr_line);
    const prev_line = ctx.allocator.alloc(i32, w) catch return CodecError.OutOfMemory;
    defer ctx.allocator.free(prev_line);
    @memset(prev_line, 0);

    const range_val = max_val + 1;

    for (0..h) |y| {
        ctx.run_index = 0;

        // Read current line into curr_line.
        for (0..w) |xi| {
            curr_line[xi] = @as(i32, pixels[y * w + xi]);
        }

        var x: usize = 0;
        while (x < w) {
            // Compute neighbours.
            const ra: i32 = if (x > 0)
                curr_line[x - 1]
            else if (y > 0)
                prev_line[0]
            else
                0;

            const rb: i32 = if (y > 0) prev_line[x] else 0;

            const rc: i32 = if (y > 0)
                (if (x > 0) prev_line[x - 1] else prev_line[0])
            else
                0;

            const rd: i32 = if (y > 0)
                (if (x < w - 1) prev_line[x + 1] else rb)
            else
                0;

            // Gradients
            const d1 = rd - rb;
            const d2 = rb - rc;
            const d3 = rc - ra;

            // Run mode disabled: matches Go codec behavior for compatibility
            // with existing DICOS files.
            if (false and d1 == 0 and d2 == 0 and d3 == 0) {
                try run_mode_mod.encodeRun(bw, ctx, curr_line, &x, w, ra, rb);
                continue;
            }

            // Regular mode
            const ctx_result = ctx.getContextIndex(d1, d2, d3);
            const q = ctx_result[0];
            const sign = ctx_result[1];

            var px = predictMed(ra, rb, rc);
            px += sign * ctx.c[q];
            px = clampVal(px, 0, max_val);

            const ix = curr_line[x];
            var err_val = ix - px;
            if (sign == -1) {
                err_val = -err_val;
            }

            // Modulo reduction.
            if (err_val < -@divTrunc(range_val, 2)) {
                err_val += range_val;
            }
            if (err_val > @divTrunc(range_val, 2)) {
                err_val -= range_val;
            }

            // Map error to non-negative.
            const mapped: u32 = if (err_val >= 0)
                @intCast(2 * err_val)
            else
                @intCast(-2 * err_val - 1);

            const k = ctx.computeK(q);
            try bw.writeGolomb(k, mapped);

            ctx.updateStats(q, err_val);
            x += 1;
        }

        @memcpy(prev_line, curr_line);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Determine the effective bit depth needed for the maximum pixel value.
///
/// JPEG-LS supports 2..=16 bits per sample. We always use at least 8.
fn effectivePrecision(max_pixel: u16) u32 {
    if (max_pixel == 0) {
        return 8;
    }
    const bits_needed: u32 = 16 - @as(u32, @clz(max_pixel)); // ceil(log2(max+1))
    return @min(@max(bits_needed, 8), 16);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "effective precision 8bit" {
    try testing.expectEqual(@as(u32, 8), effectivePrecision(0));
    try testing.expectEqual(@as(u32, 8), effectivePrecision(1));
    try testing.expectEqual(@as(u32, 8), effectivePrecision(255));
}

test "effective precision more than 8" {
    try testing.expectEqual(@as(u32, 9), effectivePrecision(256));
    try testing.expectEqual(@as(u32, 10), effectivePrecision(1023));
    try testing.expectEqual(@as(u32, 12), effectivePrecision(4095));
    try testing.expectEqual(@as(u32, 16), effectivePrecision(65535));
}

test "encode rejects empty image" {
    const pixels = [_]u16{};
    const result = encode(testing.allocator, &pixels, 0, 0);
    try testing.expectError(CodecError.InvalidData, result);
}

test "encode produces soi and eoi" {
    const pixels = [_]u16{ 42, 42, 42, 42 };
    const buf = try encode(testing.allocator, &pixels, 2, 2);
    defer testing.allocator.free(buf);

    // SOI at start
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try testing.expectEqual(@as(u8, 0xD8), buf[1]);

    // EOI at end
    const n = buf.len;
    try testing.expectEqual(@as(u8, 0xFF), buf[n - 2]);
    try testing.expectEqual(@as(u8, 0xD9), buf[n - 1]);
}

test "encode uniform image" {
    // All-zero image should produce valid bitstream.
    var pixels: [16]u16 = undefined;
    @memset(&pixels, 0);
    const buf = try encode(testing.allocator, &pixels, 4, 4);
    defer testing.allocator.free(buf);
    try testing.expect(buf.len > 0);
}
