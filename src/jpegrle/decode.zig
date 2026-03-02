//! DICOM RLE decoding for 16-bit grayscale images.
//!
//! Parses the 64-byte RLE header, decodes each PackBits-compressed
//! byte-plane segment, and reconstructs the 16-bit pixel buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const packbits = @import("packbits.zig");
const encode_mod = @import("encode.zig");

const ByteList = std.array_list.AlignedManaged(u8, null);

/// DICOM RLE header size in bytes.
const header_size: usize = 64;

/// Errors from RLE decoding.
pub const DecodeError = error{
    /// The compressed data is malformed or truncated.
    InvalidData,
    /// The decoded pixel count does not match the expected dimensions.
    DimensionMismatch,
    /// The segment count or format is not supported.
    Unsupported,
    /// Out of memory.
    OutOfMemory,
};

/// Decode DICOM RLE compressed data into a 16-bit grayscale pixel buffer.
///
/// The input `data` contains the 64-byte RLE header followed by
/// PackBits-compressed byte-plane segments. For 16-bit images,
/// segment 0 is the high-byte plane and segment 1 is the low-byte plane.
///
/// `width` and `height` must be provided since RLE streams do not
/// encode image dimensions.
///
/// Returns a struct with the decoded pixels, width, and height. The caller
/// must free `result.pixels` with the provided allocator.
pub const DecodeResult = struct {
    pixels: []u16,
    width: u32,
    height: u32,

    pub fn deinit(self: DecodeResult, allocator: Allocator) void {
        allocator.free(self.pixels);
    }
};

pub fn decode(allocator: Allocator, data: []const u8, width: u32, height: u32) DecodeError!DecodeResult {
    if (data.len < header_size) {
        return DecodeError.InvalidData;
    }

    // Parse header
    const num_segments = std.mem.readInt(u32, data[0..4], .little);
    if (num_segments == 0) {
        return DecodeError.InvalidData;
    }
    if (num_segments > 15) {
        return DecodeError.InvalidData;
    }

    var offsets: [15]u32 = undefined;
    for (0..15) |i| {
        const start = 4 + i * 4;
        offsets[i] = std.mem.readInt(u32, data[start..][0..4], .little);
    }

    const num_pixels: usize = @as(usize, width) * @as(usize, height);

    // Decode each segment
    const seg_count: usize = @intCast(num_segments);
    var segments: [15][]u8 = undefined;
    var segments_allocated: usize = 0;
    errdefer {
        for (0..segments_allocated) |i| {
            allocator.free(segments[i]);
        }
    }

    for (0..seg_count) |i| {
        const start: usize = @intCast(offsets[i]);
        const end: usize = if (i < seg_count - 1)
            @intCast(offsets[i + 1])
        else
            data.len;

        if (start > data.len or end > data.len or start > end) {
            return DecodeError.InvalidData;
        }

        const seg_data = data[start..end];
        const decoded_seg = packbits.decodePackbits(allocator, seg_data, num_pixels) catch |err| switch (err) {
            error.OutOfMemory => return DecodeError.OutOfMemory,
            else => return DecodeError.InvalidData,
        };

        if (decoded_seg.len != num_pixels) {
            allocator.free(decoded_seg);
            return DecodeError.DimensionMismatch;
        }

        segments[i] = decoded_seg;
        segments_allocated += 1;
    }

    // Reconstruct the 16-bit image from byte planes
    switch (num_segments) {
        1 => {
            // 8-bit data stored as 16-bit
            const pixels = allocator.alloc(u16, num_pixels) catch return DecodeError.OutOfMemory;
            for (segments[0], 0..) |b, i| {
                pixels[i] = @as(u16, b);
            }
            // Free decoded segments
            for (0..segments_allocated) |i| {
                allocator.free(segments[i]);
            }
            return DecodeResult{
                .pixels = pixels,
                .width = width,
                .height = height,
            };
        },
        2 => {
            // 16-bit: segment 0 = high bytes, segment 1 = low bytes
            const high = segments[0];
            const low = segments[1];
            const pixels = allocator.alloc(u16, num_pixels) catch return DecodeError.OutOfMemory;
            for (0..num_pixels) |i| {
                pixels[i] = (@as(u16, high[i]) << 8) | @as(u16, low[i]);
            }
            // Free decoded segments
            for (0..segments_allocated) |i| {
                allocator.free(segments[i]);
            }
            return DecodeResult{
                .pixels = pixels,
                .width = width,
                .height = height,
            };
        },
        else => {
            return DecodeError.Unsupported;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "decode too short" {
    const short_data = [_]u8{0} ** 10;
    const result = decode(testing.allocator, &short_data, 1, 1);
    try testing.expectError(DecodeError.InvalidData, result);
}

test "decode zero segments" {
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u32, data[0..4], 0, .little);
    const result = decode(testing.allocator, &data, 1, 1);
    try testing.expectError(DecodeError.InvalidData, result);
}

test "decode too many segments" {
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u32, data[0..4], 16, .little);
    const result = decode(testing.allocator, &data, 1, 1);
    try testing.expectError(DecodeError.InvalidData, result);
}

test "roundtrip small" {
    const original = [_]u16{ 100, 200, 300, 400, 500, 600 };
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, &original, 3, 2, &buf);

    const result = try decode(testing.allocator, buf.items, 3, 2);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), result.width);
    try testing.expectEqual(@as(u32, 2), result.height);
    try testing.expectEqualSlices(u16, &original, result.pixels);
}

test "roundtrip uniform" {
    const original = [_]u16{0x1234} ** (50 * 50);
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, &original, 50, 50, &buf);

    const result = try decode(testing.allocator, buf.items, 50, 50);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &original, result.pixels);
}

test "roundtrip gradient" {
    var pixels: [256]u16 = undefined;
    for (0..256) |i| {
        pixels[i] = @intCast(i);
    }
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, &pixels, 16, 16, &buf);

    const result = try decode(testing.allocator, buf.items, 16, 16);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip max values" {
    const original = [_]u16{std.math.maxInt(u16)} ** (10 * 10);
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, &original, 10, 10, &buf);

    const result = try decode(testing.allocator, buf.items, 10, 10);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &original, result.pixels);
}

test "roundtrip alternating" {
    var pixels: [100]u16 = undefined;
    for (0..100) |i| {
        pixels[i] = if (i % 2 == 0) 0x0000 else 0xFFFF;
    }
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, &pixels, 10, 10, &buf);

    const result = try decode(testing.allocator, buf.items, 10, 10);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip large image" {
    // 512x512 gradient -- realistic CT slice size
    const size = 512 * 512;
    const pixels = try testing.allocator.alloc(u16, size);
    defer testing.allocator.free(pixels);
    for (0..size) |i| {
        pixels[i] = @truncate(i);
    }

    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, pixels, 512, 512, &buf);

    const result = try decode(testing.allocator, buf.items, 512, 512);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, pixels, result.pixels);
}

test "roundtrip odd dimensions" {
    const size = 7 * 13;
    var pixels: [size]u16 = undefined;
    for (0..size) |i| {
        pixels[i] = @truncate(i *% 137);
    }
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, &pixels, 7, 13, &buf);

    const result = try decode(testing.allocator, buf.items, 7, 13);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip single pixel" {
    const original = [_]u16{0xABCD};
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode_mod.encode(testing.allocator, &original, 1, 1, &buf);

    const result = try decode(testing.allocator, buf.items, 1, 1);
    defer result.deinit(testing.allocator);
    try testing.expectEqualSlices(u16, &original, result.pixels);
}
