//! DICOM RLE decoding for 8/16-bit grayscale images.
//!
//! Parses the 64-byte RLE header, decodes each PackBits-compressed byte-plane
//! segment, and reconstructs the 16-bit pixel buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const packbits = @import("packbits.zig");
const errors = @import("error.zig");
const encode_mod = @import("encode.zig");

const CodecError = errors.CodecError;
const Diagnostics = errors.Diagnostics;

/// DICOM RLE header size in bytes.
const HEADER_SIZE: usize = 64;

/// Hard cap on the number of pixels a single decode will allocate for. Guards
/// against attacker-controlled width/height forcing an unbounded allocation
/// before any data is read.
const MAX_PIXELS: usize = 1 << 28;

/// Result of a successful decode. Free with `deinit`.
pub const DecodeResult = struct {
    pixels: []u16,
    width: u32,
    height: u32,

    pub fn deinit(self: DecodeResult, allocator: Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Decode DICOM RLE compressed data into a 16-bit grayscale pixel buffer.
///
/// The input `data` contains the 64-byte RLE header followed by PackBits-compressed
/// byte-plane segments. With two segments, segment 0 is the high-byte plane and
/// segment 1 the low-byte plane; one segment is 8-bit data.
///
/// `width` and `height` must be provided since RLE streams do not encode image
/// dimensions. The caller owns the result.
pub fn decode(allocator: Allocator, data: []const u8, width: u32, height: u32) CodecError!DecodeResult {
    return decodeDiag(allocator, data, width, height, null);
}

/// Like `decode`, additionally filling `diag` (when non-null) with the details of
/// any returned error (parameter name, truncation offset, ...).
pub fn decodeDiag(
    allocator: Allocator,
    data: []const u8,
    width: u32,
    height: u32,
    diag: ?*Diagnostics,
) CodecError!DecodeResult {
    if (data.len < HEADER_SIZE) return errors.truncated(diag, data.len, "RLE header");

    // Parse header
    const num_segments: usize = std.mem.readInt(u32, data[0..4], .little);
    if (num_segments == 0) return errors.invalidData(diag, "RLE: zero segments");
    if (num_segments > 15) return errors.invalidData(diag, "RLE: invalid segment count");

    var offsets: [15]u32 = undefined;
    for (&offsets, 0..) |*offset, i| {
        offset.* = std.mem.readInt(u32, data[4 + i * 4 ..][0..4], .little);
    }

    const num_pixels = std.math.mul(usize, width, height) catch MAX_PIXELS + 1;
    if (num_pixels > MAX_PIXELS) {
        const value = std.math.mul(i64, width, height) catch std.math.maxInt(i64);
        return errors.invalidParameter(diag, "width*height", value, "product <= 268435456 pixels (1<<28)");
    }

    // Decode each segment. Only the first two are used; later ones are decoded
    // for validation and released immediately to bound memory.
    var segments: [2][]u8 = undefined;
    var kept: usize = 0;
    defer for (segments[0..kept]) |s| allocator.free(s);

    for (0..num_segments) |i| {
        const start: usize = offsets[i];
        const end: usize = if (i < num_segments - 1) offsets[i + 1] else data.len;

        if (start > data.len or end > data.len or start > end)
            return errors.truncated(diag, @min(start, data.len), "RLE segment offsets");

        var pb_diag: packbits.PackBitsDiagnostics = .{};
        const decoded = packbits.decodePackbits(allocator, data[start..end], num_pixels, &pb_diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TruncatedLiteral, error.TruncatedRun => return errors.truncated(diag, start + pb_diag.offset, "RLE PackBits segment"),
        };

        if (decoded.len != num_pixels) {
            const actual = decoded.len;
            allocator.free(decoded);
            return errors.dimensionMismatch(diag, num_pixels, actual);
        }

        if (i < segments.len) {
            segments[i] = decoded;
            kept += 1;
        } else {
            allocator.free(decoded);
        }
    }

    // Reconstruct the image from byte planes
    switch (num_segments) {
        1 => {
            // 8-bit data stored as 16-bit
            const pixels = try allocator.alloc(u16, num_pixels);
            for (pixels, segments[0]) |*p, b| p.* = b;
            return .{ .pixels = pixels, .width = width, .height = height };
        },
        2 => {
            // 16-bit: segment 0 = high bytes, segment 1 = low bytes
            const pixels = try allocator.alloc(u16, num_pixels);
            for (pixels, segments[0], segments[1]) |*p, hi, lo| p.* = (@as(u16, hi) << 8) | lo;
            return .{ .pixels = pixels, .width = width, .height = height };
        },
        else => return errors.unsupported(diag, "RLE: unsupported segment count (expected 1 or 2)"),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectRoundtrip(pixels: []const u16, w: u32, h: u32) !void {
    const buf = try encode_mod.encode(testing.allocator, pixels, w, h);
    defer testing.allocator.free(buf);
    const res = try decode(testing.allocator, buf, w, h);
    defer res.deinit(testing.allocator);
    try testing.expectEqual(w, res.width);
    try testing.expectEqual(h, res.height);
    try testing.expectEqualSlices(u16, pixels, res.pixels);
}

fn expectDecodeErr(expected: CodecError, data: []const u8, w: u32, h: u32, diag: ?*Diagnostics) !void {
    if (decodeDiag(testing.allocator, data, w, h, diag)) |r| {
        r.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |e| try testing.expectEqual(expected, e);
}

test "decode too short" {
    var diag: Diagnostics = .{};
    try expectDecodeErr(error.Truncated, &[_]u8{0} ** 10, 1, 1, &diag);
    try testing.expectEqual(@as(usize, 10), diag.offset);
    try testing.expectEqualStrings("RLE header", diag.context);
}

test "decode huge dims rejected not abort" {
    // A well-formed 1-segment header, but width*height would otherwise force a
    // multi-exabyte allocation. Must return an error, not abort.
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u32, data[0..4], 1, .little);
    var diag: Diagnostics = .{};
    try expectDecodeErr(error.InvalidParameter, &data, 0xFFFF_FFFF, 0xFFFF_FFFF, &diag);
    try testing.expectEqualStrings("width*height", diag.parameter);
}

test "decode zero segments" {
    var data = [_]u8{0} ** 64;
    try expectDecodeErr(error.InvalidData, &data, 1, 1, null);
}

test "decode too many segments" {
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u32, data[0..4], 16, .little);
    try expectDecodeErr(error.InvalidData, &data, 1, 1, null);
}

test "decode unsupported segment count" {
    // Three well-formed (empty-image) segments: valid framing, unsupported layout.
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u32, data[0..4], 3, .little);
    for (0..3) |i| std.mem.writeInt(u32, data[4 + i * 4 ..][0..4], 64, .little);
    try expectDecodeErr(error.Unsupported, &data, 0, 0, null);
}

test "decode bad segment offsets" {
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u32, data[0..4], 1, .little);
    std.mem.writeInt(u32, data[4..8], 1000, .little);
    var diag: Diagnostics = .{};
    try expectDecodeErr(error.Truncated, &data, 1, 1, &diag);
    try testing.expectEqual(@as(usize, 64), diag.offset);
    try testing.expectEqualStrings("RLE segment offsets", diag.context);
}

test "decode truncated packbits segment" {
    var data = [_]u8{0} ** 66;
    std.mem.writeInt(u32, data[0..4], 1, .little);
    std.mem.writeInt(u32, data[4..8], 64, .little);
    data[64] = 0x05; // literal of 6 bytes, none provided
    var diag: Diagnostics = .{};
    try expectDecodeErr(error.Truncated, &data, 2, 3, &diag);
    try testing.expectEqual(@as(usize, 65), diag.offset);
    try testing.expectEqualStrings("RLE PackBits segment", diag.context);
}

test "roundtrip small" {
    try expectRoundtrip(&.{ 100, 200, 300, 400, 500, 600 }, 3, 2);
}

test "roundtrip uniform" {
    try expectRoundtrip(&([_]u16{0x1234} ** (50 * 50)), 50, 50);
}

test "roundtrip gradient" {
    var pixels: [256]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i);
    try expectRoundtrip(&pixels, 16, 16);
}

test "roundtrip max values" {
    try expectRoundtrip(&([_]u16{std.math.maxInt(u16)} ** 100), 10, 10);
}

test "roundtrip alternating" {
    var pixels: [100]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = if (i % 2 == 0) 0x0000 else 0xFFFF;
    try expectRoundtrip(&pixels, 10, 10);
}

test "roundtrip large image" {
    // 512x512 gradient -- realistic CT slice size
    const pixels = try testing.allocator.alloc(u16, 512 * 512);
    defer testing.allocator.free(pixels);
    for (pixels, 0..) |*p, i| p.* = @truncate(i);
    try expectRoundtrip(pixels, 512, 512);
}

test "roundtrip odd dimensions" {
    var pixels: [7 * 13]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @truncate(i * 137);
    try expectRoundtrip(&pixels, 7, 13);
}

test "roundtrip single pixel" {
    try expectRoundtrip(&.{0xABCD}, 1, 1);
}

test "decode single segment is 8-bit" {
    // One segment: 4 literal bytes -> 4 pixels widened to u16.
    var data = [_]u8{0} ** 70;
    std.mem.writeInt(u32, data[0..4], 1, .little);
    std.mem.writeInt(u32, data[4..8], 64, .little);
    @memcpy(data[64..69], &[_]u8{ 0x03, 1, 2, 3, 250 });
    const res = try decode(testing.allocator, data[0..70], 2, 2);
    defer res.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 250 }, res.pixels);
}
