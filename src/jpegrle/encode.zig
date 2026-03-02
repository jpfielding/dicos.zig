//! DICOM RLE encoding for 16-bit grayscale images.
//!
//! Splits 16-bit pixels into high-byte and low-byte planes, then
//! PackBits-compresses each plane independently. The byte-plane
//! separation improves compression since adjacent high bytes (or
//! low bytes) are often similar.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const packbits = @import("packbits.zig");

const ByteList = std.array_list.AlignedManaged(u8, null);

/// DICOM RLE header size in bytes.
/// 4 bytes for segment count + 15 * 4 bytes for offsets = 64 bytes.
const header_size: u32 = 64;

/// Maximum number of segments in a DICOM RLE frame.
const max_segments: usize = 15;

/// Errors from RLE encoding.
pub const EncodeError = error{
    /// The pixel buffer length does not match width * height.
    DimensionMismatch,
    /// Too many RLE segments.
    InvalidData,
    /// I/O error writing output.
    IoError,
    /// Out of memory.
    OutOfMemory,
};

/// Helper: append a little-endian integer to a managed byte list.
fn appendInt(buf: *ByteList, comptime T: type, val: T) !void {
    const bytes = std.mem.toBytes(std.mem.nativeToLittle(T, val));
    try buf.appendSlice(&bytes);
}

/// Encode a 16-bit grayscale image into DICOM RLE format.
///
/// `pixels` is a row-major pixel buffer that must have length `width * height`.
/// 16-bit images are split into high-byte and low-byte segments which are
/// independently PackBits-compressed.
///
/// The output format is:
/// - 64-byte header: segment count (u32 LE) + 15 offset slots (u32 LE)
/// - Segment data: PackBits-compressed byte planes, each padded to even length
pub fn encode(
    allocator: Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
    out: *ByteList,
) EncodeError!void {
    const expected: usize = @as(usize, width) * @as(usize, height);
    if (pixels.len != expected) {
        return EncodeError.DimensionMismatch;
    }

    const num_pixels = pixels.len;

    // Split 16-bit pixels into high-byte and low-byte planes
    const high_bytes = allocator.alloc(u8, num_pixels) catch return EncodeError.OutOfMemory;
    defer allocator.free(high_bytes);
    const low_bytes = allocator.alloc(u8, num_pixels) catch return EncodeError.OutOfMemory;
    defer allocator.free(low_bytes);

    for (pixels, 0..) |pixel, idx| {
        high_bytes[idx] = @truncate(pixel >> 8);
        low_bytes[idx] = @truncate(pixel & 0xFF);
    }

    // PackBits-compress each byte plane
    const seg_high = packbits.encodePackbits(allocator, high_bytes) catch return EncodeError.OutOfMemory;
    defer allocator.free(seg_high);
    const seg_low = packbits.encodePackbits(allocator, low_bytes) catch return EncodeError.OutOfMemory;
    defer allocator.free(seg_low);

    const segments = [2][]const u8{ seg_high, seg_low };
    const num_segments: u32 = 2;

    if (segments.len > max_segments) {
        return EncodeError.InvalidData;
    }

    // Compute segment sizes with even-length padding
    var seg_sizes: [2]usize = undefined;
    for (segments, 0..) |seg, idx| {
        seg_sizes[idx] = seg.len;
        if (seg.len % 2 != 0) {
            seg_sizes[idx] += 1;
        }
    }

    // Build the 64-byte header
    var offsets = [_]u32{0} ** 15;
    var current_offset: u32 = header_size;
    for (0..segments.len) |i| {
        offsets[i] = current_offset;
        current_offset += @intCast(seg_sizes[i]);
    }

    // Write header: segment count
    appendInt(out, u32, num_segments) catch return EncodeError.IoError;
    // Write header: 15 offset slots
    for (offsets) |offset| {
        appendInt(out, u32, offset) catch return EncodeError.IoError;
    }

    // Write segment data (padded to even length)
    for (segments) |seg| {
        out.appendSlice(seg) catch return EncodeError.IoError;
        if (seg.len % 2 != 0) {
            out.append(0x00) catch return EncodeError.IoError;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "encode small image" {
    const pixels = [_]u16{ 0x0102, 0x0304, 0x0506, 0x0708 };
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode(testing.allocator, &pixels, 2, 2, &buf);

    // Verify header
    try testing.expect(buf.items.len >= 64);
    const num_segments = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 2), num_segments);

    // Verify segment offsets are valid
    const off1 = std.mem.readInt(u32, buf.items[4..8], .little);
    const off2 = std.mem.readInt(u32, buf.items[8..12], .little);
    try testing.expectEqual(@as(u32, 64), off1);
    try testing.expect(off2 > off1);
}

test "encode uniform image" {
    const pixels = [_]u16{0x1234} ** (100 * 100);
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode(testing.allocator, &pixels, 100, 100, &buf);
    // 64-byte header + 2 compressed segments. Should compress well.
    try testing.expect(buf.items.len < 1000);
}

test "encode zero image" {
    const pixels = [_]u16{};
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode(testing.allocator, &pixels, 0, 0, &buf);
    try testing.expect(buf.items.len >= 64);
}

test "encode single pixel" {
    const pixels = [_]u16{0xABCD};
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    try encode(testing.allocator, &pixels, 1, 1, &buf);
    const num_segments = std.mem.readInt(u32, buf.items[0..4], .little);
    try testing.expectEqual(@as(u32, 2), num_segments);
}

test "encode dimension mismatch" {
    const pixels = [_]u16{0} ** 10;
    var buf = ByteList.init(testing.allocator);
    defer buf.deinit();
    const result = encode(testing.allocator, &pixels, 2, 2, &buf);
    try testing.expectError(EncodeError.DimensionMismatch, result);
}
