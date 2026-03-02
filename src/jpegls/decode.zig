//! JPEG-LS decoder.
//!
//! Parses SOI, SOF55, SOS markers and then entropy-decodes the scan data
//! to reconstruct a 16-bit grayscale image.

const std = @import("std");
const bitstream_mod = @import("bitstream.zig");
const context_mod = @import("context.zig");
const predictor_mod = @import("predictor.zig");
const run_mode_mod = @import("run_mode.zig");

const BitReader = bitstream_mod.BitReader;
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
const MARKER_LSE: u16 = 0xFFF8;

// ---------------------------------------------------------------------------
// Frame / scan headers
// ---------------------------------------------------------------------------

const FrameHeader = struct {
    precision: u32,
    height: usize,
    width: usize,
    components: u8,
};

const ScanHeader = struct {
    components: u8,
    near: i32,
    ilv: u8,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Decode a JPEG-LS compressed bitstream into a 16-bit grayscale pixel buffer.
///
/// `width` and `height` are the *expected* image dimensions. They are
/// cross-checked against the dimensions stored in the SOF55 marker.
///
/// Returns `{ pixels, width, height }`.
pub fn decode(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
) CodecError!struct { []u16, u32, u32 } {
    var dec = Decoder.init(data);
    return dec.decodeImage(allocator, width, height);
}

// ---------------------------------------------------------------------------
// Decoder state
// ---------------------------------------------------------------------------

const Decoder = struct {
    /// Raw byte slice; `pos` tracks the current read position for
    /// byte-level marker parsing before we hand off to `BitReader`.
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) Decoder {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    // -- byte-level helpers ------------------------------------------------

    fn readByte(self: *Decoder) CodecError!u8 {
        if (self.pos >= self.data.len) {
            return CodecError.EndOfData;
        }
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU16be(self: *Decoder) CodecError!u16 {
        const hi = try self.readByte();
        const lo = try self.readByte();
        return @as(u16, hi) << 8 | @as(u16, lo);
    }

    fn skip(self: *Decoder, n: usize) CodecError!void {
        if (self.pos + n > self.data.len) {
            return CodecError.EndOfData;
        }
        self.pos += n;
    }

    // -- marker parsing ----------------------------------------------------

    fn expectMarker(self: *Decoder, expected: u16) CodecError!void {
        const b1 = try self.readByte();
        const b2 = try self.readByte();
        const marker: u16 = @as(u16, b1) << 8 | @as(u16, b2);
        if (marker != expected) {
            return CodecError.InvalidData;
        }
    }

    fn readMarker(self: *Decoder) CodecError!struct { u16, usize } {
        const b1 = try self.readByte();
        if (b1 != 0xFF) {
            return CodecError.InvalidData;
        }
        const b2 = try self.readByte();
        const marker: u16 = 0xFF00 | @as(u16, b2);

        const length = try self.readU16be();
        // Length field includes its own 2 bytes.
        const payload: usize = if (length >= 2) length - 2 else 0;
        return .{ marker, payload };
    }

    fn readSof(self: *Decoder, payload_len: usize) CodecError!FrameHeader {
        const p = try self.readByte();
        const height = try self.readU16be();
        const width = try self.readU16be();
        const nf = try self.readByte();

        // Skip component specs (Nf * 3 bytes).
        const to_skip = if (payload_len >= 6) payload_len - 6 else 0;
        try self.skip(to_skip);

        return .{
            .precision = @as(u32, p),
            .height = @as(usize, height),
            .width = @as(usize, width),
            .components = nf,
        };
    }

    fn readSos(self: *Decoder, _payload_len: usize) CodecError!ScanHeader {
        _ = _payload_len;
        const ns = try self.readByte();
        // Skip component specs (Ns * 2 bytes).
        try self.skip(@as(usize, ns) * 2);

        const near = try self.readByte();
        const ilv = try self.readByte();
        _ = try self.readByte(); // al_ah

        return .{
            .components = ns,
            .near = @as(i32, near),
            .ilv = ilv,
        };
    }

    // -- main decode flow --------------------------------------------------

    fn decodeImage(
        self: *Decoder,
        allocator: std.mem.Allocator,
        exp_width: u32,
        exp_height: u32,
    ) CodecError!struct { []u16, u32, u32 } {
        // 1. SOI
        try self.expectMarker(MARKER_SOI);

        // 2. Parse markers until SOS.
        var frame: ?FrameHeader = null;
        var scan: ScanHeader = undefined;

        while (true) {
            const marker_result = try self.readMarker();
            const marker = marker_result[0];
            const length = marker_result[1];

            if (marker == MARKER_SOF55) {
                frame = try self.readSof(length);
            } else if (marker == MARKER_LSE) {
                try self.skip(length);
            } else if (marker == MARKER_SOS) {
                scan = try self.readSos(length);
                break;
            } else if (marker == MARKER_EOI) {
                return CodecError.InvalidData;
            } else {
                try self.skip(length);
            }
        }

        const frame_hdr = frame orelse return CodecError.InvalidData;

        // Cross-check dimensions.
        if (frame_hdr.width != @as(usize, exp_width) or frame_hdr.height != @as(usize, exp_height)) {
            return CodecError.DimensionMismatch;
        }

        const max_val: i32 = (@as(i32, 1) << @as(u5, @intCast(frame_hdr.precision))) - 1;
        var ctx = try ContextModel.init(allocator, max_val, scan.near, 64);
        defer ctx.deinit();

        // The rest of the data (from current `pos`) is the entropy-coded scan.
        const scan_data = self.data[self.pos..];
        var br = BitReader.init(scan_data);

        const w: usize = @intCast(exp_width);
        const h: usize = @intCast(exp_height);
        const pixels = allocator.alloc(u16, w * h) catch return CodecError.OutOfMemory;
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        try decodeScan(&br, &ctx, pixels, w, h, max_val);

        return .{ pixels, exp_width, exp_height };
    }
};

// ---------------------------------------------------------------------------
// Scan decoder
// ---------------------------------------------------------------------------

fn decodeScan(
    br: *BitReader,
    ctx: *ContextModel,
    pixels: []u16,
    w: usize,
    h: usize,
    max_val: i32,
) CodecError!void {
    const curr_line = ctx.allocator.alloc(i32, w) catch return CodecError.OutOfMemory;
    defer ctx.allocator.free(curr_line);
    const prev_line = ctx.allocator.alloc(i32, w) catch return CodecError.OutOfMemory;
    defer ctx.allocator.free(prev_line);
    @memset(curr_line, 0);
    @memset(prev_line, 0);

    const max_val_plus1 = max_val + 1;

    for (0..h) |y| {
        ctx.run_index = 0;

        var x: usize = 0;
        while (x < w) {
            // Neighbours.
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

            // Gradients.
            const d1 = rd - rb;
            const d2 = rb - rc;
            const d3 = rc - ra;

            // Run mode disabled: existing DICOS files were encoded by the Go
            // codec which has run mode disabled.
            if (false and d1 == 0 and d2 == 0 and d3 == 0) {
                try run_mode_mod.decodeRun(br, ctx, curr_line, &x, w, ra, rb);
                continue;
            }

            // Regular mode.
            const ctx_result = ctx.getContextIndex(d1, d2, d3);
            const q = ctx_result[0];
            const sign = ctx_result[1];

            var px = predictMed(ra, rb, rc);
            px += sign * ctx.c[q];
            px = clampVal(px, 0, max_val);

            const k = ctx.computeK(q);
            const mapped_err = br.readGolomb(k) catch |e| {
                // A marker-encountered error during the last pixels of
                // the image is normal (EOI marker).
                if (e == CodecError.MarkerEncountered) {
                    return;
                }
                return e;
            };

            // Inverse-map the error.
            const em: i32 = @intCast(mapped_err);
            const stats_err: i32 = if (em & 1 == 0)
                @divTrunc(em, 2)
            else
                -@divTrunc(em + 1, 2);

            var err_val = stats_err;
            if (sign == -1) {
                err_val = -err_val;
            }

            ctx.updateStats(q, stats_err);

            // Use i64 for intermediate computation to avoid overflow.
            var rx: i32 = @intCast(@as(i64, px) + @as(i64, err_val));

            // Modulo reduction to [0, max_val].
            if (rx < 0) {
                rx += max_val_plus1;
            }
            if (rx > max_val) {
                rx -= max_val_plus1;
            }
            rx = std.math.clamp(rx, 0, max_val);

            curr_line[x] = rx;
            pixels[y * w + x] = @intCast(rx);

            x += 1;
        }

        // Copy to pixel buffer (the curr_line was written pixel-by-pixel in
        // run_mode but regular mode only stored into curr_line).
        for (0..w) |xi| {
            pixels[y * w + xi] = @intCast(curr_line[xi]);
        }

        @memcpy(prev_line, curr_line);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const encode_mod = @import("encode.zig");

/// Helper: encode then decode and compare.
fn roundtrip(pixels: []const u16, w: u32, h: u32) ![]u16 {
    const buf = try encode_mod.encode(testing.allocator, pixels, w, h);
    defer testing.allocator.free(buf);
    const result = try decode(testing.allocator, buf, w, h);
    return result[0];
}

test "roundtrip uniform zero" {
    var pixels: [16]u16 = undefined;
    @memset(&pixels, 0);
    const out = try roundtrip(&pixels, 4, 4);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip uniform nonzero" {
    var pixels: [64]u16 = undefined;
    @memset(&pixels, 128);
    const out = try roundtrip(&pixels, 8, 8);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip 1x1" {
    const pixels = [_]u16{42};
    const out = try roundtrip(&pixels, 1, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip 1x1 zero" {
    const pixels = [_]u16{0};
    const out = try roundtrip(&pixels, 1, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip single row" {
    var pixels: [16]u16 = undefined;
    for (0..16) |i| {
        pixels[i] = @intCast(i);
    }
    const out = try roundtrip(&pixels, 16, 1);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip single column" {
    var pixels: [16]u16 = undefined;
    for (0..16) |i| {
        pixels[i] = @intCast(i);
    }
    const out = try roundtrip(&pixels, 1, 16);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip horizontal gradient" {
    const w: u32 = 32;
    const h: u32 = 8;
    var pixels: [w * h]u16 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            pixels[y * w + x] = @intCast(x * 8);
        }
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip vertical gradient" {
    const w: u32 = 8;
    const h: u32 = 32;
    var pixels: [w * h]u16 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            pixels[y * w + x] = @intCast(y * 8);
        }
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip diagonal gradient" {
    const w: u32 = 16;
    const h: u32 = 16;
    var pixels: [w * h]u16 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            pixels[y * w + x] = @intCast((x + y) * 4);
        }
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip checkerboard" {
    const w: u32 = 8;
    const h: u32 = 8;
    var pixels: [w * h]u16 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            pixels[y * w + x] = if ((x + y) % 2 == 0) 200 else 50;
        }
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip max 8bit" {
    var pixels: [16]u16 = undefined;
    @memset(&pixels, 255);
    const out = try roundtrip(&pixels, 4, 4);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip 16bit values" {
    const w: u32 = 8;
    const h: u32 = 4;
    var pixels: [w * h]u16 = undefined;
    for (0..w * h) |i| {
        pixels[i] = @as(u16, @intCast(i)) *% 2048;
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip odd dimensions" {
    const w: u32 = 7;
    const h: u32 = 5;
    var pixels: [w * h]u16 = undefined;
    for (0..w * h) |i| {
        pixels[i] = @intCast(i * 3 % 256);
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip large image" {
    const w: u32 = 64;
    const h: u32 = 64;
    var pixels: [w * h]u16 = undefined;
    for (0..w * h) |i| {
        pixels[i] = @intCast((i * 7 + 13) % 256);
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "roundtrip alternating rows" {
    const w: u32 = 16;
    const h: u32 = 8;
    var pixels: [w * h]u16 = undefined;
    for (0..h) |y| {
        const val: u16 = if (y % 2 == 0) 100 else 200;
        for (0..w) |x| {
            pixels[y * w + x] = val;
        }
    }
    const out = try roundtrip(&pixels, w, h);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u16, &pixels, out);
}

test "decode rejects bad soi" {
    const bad_data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const result = decode(testing.allocator, &bad_data, 1, 1);
    try testing.expectError(CodecError.InvalidData, result);
}

test "decode dimension mismatch" {
    // Encode a 4x4, then try to decode as 8x8.
    var pixels: [16]u16 = undefined;
    @memset(&pixels, 42);
    const buf = try encode_mod.encode(testing.allocator, &pixels, 4, 4);
    defer testing.allocator.free(buf);

    const result = decode(testing.allocator, buf, 8, 8);
    try testing.expectError(CodecError.DimensionMismatch, result);
}
