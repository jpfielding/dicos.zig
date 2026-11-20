//! DICOM RLE encoding for 16-bit grayscale images.

const std = @import("std");
const Allocator = std.mem.Allocator;
const packbits = @import("packbits.zig");
const errors = @import("error.zig");

const CodecError = errors.CodecError;
const Diagnostics = errors.Diagnostics;

/// DICOM RLE header size in bytes.
/// 4 bytes for segment count + 15 * 4 bytes for offsets = 64 bytes.
const HEADER_SIZE: u32 = 64;

/// Encode a 16-bit grayscale image into DICOM RLE format.
///
/// `pixels` is a row-major pixel buffer of length `width * height`. 16-bit images
/// are split into high-byte and low-byte segments which are independently
/// PackBits-compressed. Returns the encoded stream; the caller owns the memory.
///
/// The output format is:
/// - 64-byte header: segment count (u32 LE) + 15 offset slots (u32 LE)
/// - Segment data: PackBits-compressed byte planes, each padded to even length
pub fn encode(allocator: Allocator, pixels: []const u16, width: u32, height: u32) CodecError![]u8 {
    return encodeDiag(allocator, pixels, width, height, null);
}

/// Like `encode`, additionally filling `diag` (when non-null) on error.
pub fn encodeDiag(
    allocator: Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
    diag: ?*Diagnostics,
) CodecError![]u8 {
    const expected = @as(usize, width) * @as(usize, height);
    if (pixels.len != expected) return errors.dimensionMismatch(diag, expected, pixels.len);

    // Split 16-bit pixels into high-byte and low-byte planes
    const planes = try allocator.alloc(u8, 2 * pixels.len);
    defer allocator.free(planes);
    const high_bytes = planes[0..pixels.len];
    const low_bytes = planes[pixels.len..];
    for (pixels, 0..) |pixel, i| {
        high_bytes[i] = @intCast(pixel >> 8);
        low_bytes[i] = @intCast(pixel & 0xFF);
    }

    // PackBits-compress each byte plane
    var segments: [2][]u8 = undefined;
    var made: usize = 0;
    defer for (segments[0..made]) |s| allocator.free(s);
    segments[0] = try packbits.encodePackbits(allocator, high_bytes);
    made = 1;
    segments[1] = try packbits.encodePackbits(allocator, low_bytes);
    made = 2;

    // Header offsets are 32-bit; reject output that cannot be addressed.
    var total: u64 = HEADER_SIZE;
    for (segments) |s| total += s.len + (s.len & 1);
    if (total > std.math.maxInt(u32)) return errors.invalidData(diag, "RLE segment offsets exceed 32 bits");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @intCast(total));

    // Header: segment count, then 15 offset slots (unused slots are zero).
    var header = [_]u8{0} ** HEADER_SIZE;
    std.mem.writeInt(u32, header[0..4], segments.len, .little);
    var current_offset: u32 = HEADER_SIZE;
    for (segments, 0..) |s, i| {
        std.mem.writeInt(u32, header[4 + i * 4 ..][0..4], current_offset, .little);
        // Each segment is padded to even length (DICOM RLE requirement).
        current_offset += @intCast(s.len + (s.len & 1));
    }
    out.appendSliceAssumeCapacity(&header);

    for (segments) |s| {
        out.appendSliceAssumeCapacity(s);
        if (s.len & 1 != 0) out.appendAssumeCapacity(0x00);
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encode small image" {
    const pixels = [_]u16{ 0x0102, 0x0304, 0x0506, 0x0708 };
    const buf = try encode(testing.allocator, &pixels, 2, 2);
    defer testing.allocator.free(buf);

    try testing.expect(buf.len >= 64);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[0..4], .little));
    const off1 = std.mem.readInt(u32, buf[4..8], .little);
    const off2 = std.mem.readInt(u32, buf[8..12], .little);
    try testing.expectEqual(@as(u32, 64), off1);
    try testing.expect(off2 > off1);
}

test "encode uniform image" {
    const pixels = [_]u16{0x1234} ** (100 * 100);
    const buf = try encode(testing.allocator, &pixels, 100, 100);
    defer testing.allocator.free(buf);
    // 64-byte header + 2 compressed segments (~80 bytes each for 10k identical
    // bytes) plus even-padding: well under 1000 bytes for 20000 raw bytes.
    try testing.expect(buf.len < 1000);
}

test "encode zero image" {
    const buf = try encode(testing.allocator, &.{}, 0, 0);
    defer testing.allocator.free(buf);
    try testing.expect(buf.len >= 64);
}

test "encode single pixel" {
    const buf = try encode(testing.allocator, &[_]u16{0xABCD}, 1, 1);
    defer testing.allocator.free(buf);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[0..4], .little));
}

test "encode dimension mismatch" {
    const pixels = [_]u16{0} ** 10;
    var diag: Diagnostics = .{};
    try testing.expectError(error.DimensionMismatch, encodeDiag(testing.allocator, &pixels, 2, 2, &diag));
    try testing.expectEqual(@as(usize, 4), diag.expected);
    try testing.expectEqual(@as(usize, 10), diag.actual);
}

test "encode pads odd segments to even length" {
    // 3 distinct bytes per plane -> literal (1 + 3) = 4 bytes... use 1 pixel: each
    // plane is one literal byte (2 bytes), so make an odd one with 2 distinct.
    const pixels = [_]u16{ 0x0102, 0x0304 }; // planes: [01 03] and [02 04] -> 3 bytes each
    const buf = try encode(testing.allocator, &pixels, 2, 1);
    defer testing.allocator.free(buf);
    const off1 = std.mem.readInt(u32, buf[4..8], .little);
    const off2 = std.mem.readInt(u32, buf[8..12], .little);
    try testing.expectEqual(@as(u32, 64), off1);
    try testing.expectEqual(@as(u32, 68), off2); // 3 bytes padded to 4
    try testing.expectEqual(@as(usize, 72), buf.len);
    try testing.expectEqual(@as(u8, 0), buf[67]);
}
