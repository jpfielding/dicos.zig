//! Tile encoder / decoder for JPEG 2000.
//!
//! Handles encoding and decoding of a single tile component: applies the
//! multi-level DWT, then serialises (or deserialises) the wavelet
//! coefficients as signed 32-bit big-endian integers -- a simple format
//! that guarantees lossless round-trip for all bit depths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dwt = @import("dwt.zig");

pub const CodecError = error{
    InvalidData,
    DimensionMismatch,
    OutOfMemory,
    EndOfStream,
};

// ---------------------------------------------------------------------------
// Tile encoder
// ---------------------------------------------------------------------------

/// Encodes a single-component tile.
pub const TileEncoder = struct {
    width: usize,
    height: usize,
    decomp_levels: usize,

    pub fn init(width: usize, height: usize, decomp_levels: usize) TileEncoder {
        return .{
            .width = width,
            .height = height,
            .decomp_levels = decomp_levels,
        };
    }

    /// Encode a tile (single component) and return the serialised byte stream.
    ///
    /// Format:
    /// - `width`  (2 bytes, big-endian u16)
    /// - `height` (2 bytes, big-endian u16)
    /// - `coeffs` (width * height * 4 bytes, each i32 big-endian)
    pub fn encodeTile(self: *const TileEncoder, allocator: Allocator, data: []const i32) CodecError![]u8 {
        const expected = self.width * self.height;
        if (data.len != expected) {
            return error.DimensionMismatch;
        }

        // Copy and apply forward DWT.
        const coeffs = try allocator.alloc(i32, expected);
        defer allocator.free(coeffs);
        @memcpy(coeffs, data);
        _ = try dwt.forwardMultiLevel(allocator, coeffs, self.width, self.height, self.decomp_levels);

        // Serialise.
        const result_len = 4 + expected * 4;
        const result = try allocator.alloc(u8, result_len);
        errdefer allocator.free(result);

        result[0] = @intCast((self.width >> 8) & 0xFF);
        result[1] = @intCast(self.width & 0xFF);
        result[2] = @intCast((self.height >> 8) & 0xFF);
        result[3] = @intCast(self.height & 0xFF);

        var pos: usize = 4;
        for (coeffs) |c| {
            const cu: u32 = @bitCast(c);
            result[pos] = @intCast((cu >> 24) & 0xFF);
            result[pos + 1] = @intCast((cu >> 16) & 0xFF);
            result[pos + 2] = @intCast((cu >> 8) & 0xFF);
            result[pos + 3] = @intCast(cu & 0xFF);
            pos += 4;
        }

        return result;
    }
};

// ---------------------------------------------------------------------------
// Tile decoder
// ---------------------------------------------------------------------------

/// Decodes a single-component tile.
pub const TileDecoder = struct {
    decomp_levels: usize,

    pub fn init(decomp_levels: usize) TileDecoder {
        return .{ .decomp_levels = decomp_levels };
    }

    /// Decode a serialised tile and return the reconstructed pixel data.
    ///
    /// Returns `(width, height, pixels)`.
    pub fn decodeTile(self: *const TileDecoder, allocator: Allocator, data: []const u8) CodecError!struct { usize, usize, []i32 } {
        if (data.len < 4) {
            return error.InvalidData;
        }

        const width = (@as(usize, data[0]) << 8) | @as(usize, data[1]);
        const height = (@as(usize, data[2]) << 8) | @as(usize, data[3]);

        const expected_len = 4 + width * height * 4;
        if (data.len < expected_len) {
            return error.InvalidData;
        }

        const coeffs = try allocator.alloc(i32, width * height);
        errdefer allocator.free(coeffs);

        var pos: usize = 4;
        for (0..width * height) |i| {
            const v: i32 = @bitCast(
                (@as(u32, data[pos]) << 24) |
                    (@as(u32, data[pos + 1]) << 16) |
                    (@as(u32, data[pos + 2]) << 8) |
                    @as(u32, data[pos + 3]),
            );
            coeffs[i] = v;
            pos += 4;
        }

        try dwt.inverseMultiLevel(allocator, coeffs, width, height, self.decomp_levels);

        return .{ width, height, coeffs };
    }

    /// Return the byte length consumed by a tile component's data block,
    /// given the tile data starting at the header.
    pub fn tileDataLen(data: []const u8) CodecError!usize {
        if (data.len < 4) {
            return error.InvalidData;
        }
        const width = (@as(usize, data[0]) << 8) | @as(usize, data[1]);
        const height = (@as(usize, data[2]) << 8) | @as(usize, data[3]);
        return 4 + width * height * 4;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tile roundtrip basic" {
    const allocator = std.testing.allocator;
    const w = 8;
    const h = 8;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @intCast(i);

    const enc = TileEncoder.init(w, h, 3);
    const encoded = try enc.encodeTile(allocator, &data);
    defer allocator.free(encoded);

    const dec = TileDecoder.init(3);
    const result = try dec.decodeTile(allocator, encoded);
    defer allocator.free(result[2]);

    try std.testing.expectEqual(@as(usize, w), result[0]);
    try std.testing.expectEqual(@as(usize, h), result[1]);
    try std.testing.expectEqualSlices(i32, &data, result[2]);
}

test "tile roundtrip 16bit values" {
    const allocator = std.testing.allocator;
    const w = 16;
    const h = 16;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @as(i32, @intCast(i)) * 100 + 1000;

    const enc = TileEncoder.init(w, h, 4);
    const encoded = try enc.encodeTile(allocator, &data);
    defer allocator.free(encoded);

    const dec = TileDecoder.init(4);
    const result = try dec.decodeTile(allocator, encoded);
    defer allocator.free(result[2]);
    try std.testing.expectEqualSlices(i32, &data, result[2]);
}

test "tile roundtrip odd dims" {
    const allocator = std.testing.allocator;
    const w = 13;
    const h = 7;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @intCast(i);

    const enc = TileEncoder.init(w, h, 2);
    const encoded = try enc.encodeTile(allocator, &data);
    defer allocator.free(encoded);

    const dec = TileDecoder.init(2);
    const result = try dec.decodeTile(allocator, encoded);
    defer allocator.free(result[2]);

    try std.testing.expectEqual(@as(usize, w), result[0]);
    try std.testing.expectEqual(@as(usize, h), result[1]);
    try std.testing.expectEqualSlices(i32, &data, result[2]);
}

test "tile roundtrip all zeros" {
    const allocator = std.testing.allocator;
    const w = 32;
    const h = 32;
    const data = [_]i32{0} ** (w * h);

    const enc = TileEncoder.init(w, h, 5);
    const encoded = try enc.encodeTile(allocator, &data);
    defer allocator.free(encoded);

    const dec = TileDecoder.init(5);
    const result = try dec.decodeTile(allocator, encoded);
    defer allocator.free(result[2]);
    try std.testing.expectEqualSlices(i32, &data, result[2]);
}

test "tile roundtrip constant" {
    const allocator = std.testing.allocator;
    const w = 16;
    const h = 16;
    const data = [_]i32{12345} ** (w * h);

    const enc = TileEncoder.init(w, h, 3);
    const encoded = try enc.encodeTile(allocator, &data);
    defer allocator.free(encoded);

    const dec = TileDecoder.init(3);
    const result = try dec.decodeTile(allocator, encoded);
    defer allocator.free(result[2]);
    try std.testing.expectEqualSlices(i32, &data, result[2]);
}

test "tile data len calculation" {
    const allocator = std.testing.allocator;
    const w = 10;
    const h = 20;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @intCast(i);

    const enc = TileEncoder.init(w, h, 2);
    const encoded = try enc.encodeTile(allocator, &data);
    defer allocator.free(encoded);

    const tile_len = try TileDecoder.tileDataLen(encoded);
    try std.testing.expectEqual(encoded.len, tile_len);
}

test "tile decode too short" {
    const dec = TileDecoder.init(3);
    const short_data = [_]u8{ 0, 0 };
    const result = dec.decodeTile(std.testing.allocator, &short_data);
    try std.testing.expectError(error.InvalidData, result);
}

test "tile encode dimension mismatch" {
    const allocator = std.testing.allocator;
    const enc = TileEncoder.init(4, 4, 2);
    const data = [_]i32{0} ** 10; // wrong size
    const result = enc.encodeTile(allocator, &data);
    try std.testing.expectError(error.DimensionMismatch, result);
}
