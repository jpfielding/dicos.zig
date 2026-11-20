//! FROZEN legacy (v1.0.0) tile pipeline -- DO NOT MODIFY.
//!
//! The 1.0.0 `encode` serialised raw DWT coefficients as signed 32-bit
//! big-endian integers: `[width u16be, height u16be, width*height i32be]`.
//! Non-conformant, but produced by the shipped 1.0.0 crate and by the Go
//! dicos codec. Only `TileDecoder` is live (via `LegacyPolicy`); the encoder
//! is kept to pin the format in tests. It deliberately uses the legacy
//! *truncating-division* DWT (`dwt.forwardMultiLevel`/`inverseMultiLevel`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const CodecError = @import("error.zig").CodecError;
const dwt = @import("dwt.zig");

/// Encodes a single-component tile in the legacy raw-DWT format.
pub const TileEncoder = struct {
    width: usize,
    height: usize,
    decomp_levels: usize,

    pub fn init(width: usize, height: usize, decomp_levels: usize) TileEncoder {
        return .{ .width = width, .height = height, .decomp_levels = decomp_levels };
    }

    /// Encode a tile and return the serialised bytes (caller owns).
    pub fn encodeTile(self: TileEncoder, gpa: Allocator, data: []const i32) CodecError![]u8 {
        const expected = self.width * self.height;
        if (data.len != expected) return error.DimensionMismatch;

        const coeffs = try gpa.dupe(i32, data);
        defer gpa.free(coeffs);
        _ = try dwt.forwardMultiLevel(gpa, coeffs, self.width, self.height, self.decomp_levels);

        const out = try gpa.alloc(u8, 4 + expected * 4);
        out[0] = @truncate(self.width >> 8);
        out[1] = @truncate(self.width);
        out[2] = @truncate(self.height >> 8);
        out[3] = @truncate(self.height);
        for (coeffs, 0..) |c, i| std.mem.writeInt(i32, out[4 + i * 4 ..][0..4], c, .big);
        return out;
    }
};

/// Decoded legacy tile.
pub const DecodedTile = struct {
    width: usize,
    height: usize,
    /// Reconstructed samples (caller owns).
    pixels: []i32,
};

/// Decodes a single-component legacy tile.
pub const TileDecoder = struct {
    decomp_levels: usize,

    pub fn init(decomp_levels: usize) TileDecoder {
        return .{ .decomp_levels = decomp_levels };
    }

    /// Decode a serialised tile. Allocation is bounded by `data.len`.
    pub fn decodeTile(self: TileDecoder, gpa: Allocator, data: []const u8) CodecError!DecodedTile {
        // "tile data too short for header"
        if (data.len < 4) return error.InvalidData;
        const width = (@as(usize, data[0]) << 8) | data[1];
        const height = (@as(usize, data[2]) << 8) | data[3];
        const count = width * height; // <= 2^32, no overflow on 64-bit usize
        // "tile data too short"
        if (data.len - 4 < count * 4) return error.InvalidData;

        const coeffs = try gpa.alloc(i32, count);
        errdefer gpa.free(coeffs);
        for (coeffs, 0..) |*c, i| c.* = std.mem.readInt(i32, data[4 + i * 4 ..][0..4], .big);

        try dwt.inverseMultiLevel(gpa, coeffs, width, height, self.decomp_levels);
        return .{ .width = width, .height = height, .pixels = coeffs };
    }

    /// Byte length of a tile component's data block (header + coefficients).
    pub fn tileDataLen(data: []const u8) CodecError!usize {
        if (data.len < 4) return error.InvalidData;
        const width = (@as(usize, data[0]) << 8) | data[1];
        const height = (@as(usize, data[2]) << 8) | data[3];
        return 4 + width * height * 4;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

fn rt(w: usize, h: usize, levels: usize, data: []const i32) !void {
    const enc = try TileEncoder.init(w, h, levels).encodeTile(ta, data);
    defer ta.free(enc);
    const dec = try TileDecoder.init(levels).decodeTile(ta, enc);
    defer ta.free(dec.pixels);
    try testing.expectEqual(w, dec.width);
    try testing.expectEqual(h, dec.height);
    try testing.expectEqualSlices(i32, data, dec.pixels);
}

test "tile roundtrip basic" {
    var d: [64]i32 = undefined;
    for (&d, 0..) |*v, i| v.* = @intCast(i);
    try rt(8, 8, 3, &d);
}

test "tile roundtrip 16bit values" {
    var d: [256]i32 = undefined;
    for (&d, 0..) |*v, i| v.* = @as(i32, @intCast(i)) * 100 + 1000;
    try rt(16, 16, 4, &d);
}

test "tile roundtrip odd dims" {
    var d: [91]i32 = undefined;
    for (&d, 0..) |*v, i| v.* = @intCast(i);
    try rt(13, 7, 2, &d);
}

test "tile roundtrip all zeros" {
    const d: [1024]i32 = @splat(0);
    try rt(32, 32, 5, &d);
}

test "tile roundtrip constant" {
    const d: [256]i32 = @splat(12345);
    try rt(16, 16, 3, &d);
}

test "tile data len calculation" {
    var d: [200]i32 = undefined;
    for (&d, 0..) |*v, i| v.* = @intCast(i);
    const enc = try TileEncoder.init(10, 20, 2).encodeTile(ta, &d);
    defer ta.free(enc);
    try testing.expectEqual(enc.len, try TileDecoder.tileDataLen(enc));
}

test "tile decode too short" {
    try testing.expectError(error.InvalidData, TileDecoder.init(3).decodeTile(ta, &.{ 0, 0 }));
}

test "tile encode dimension mismatch" {
    const d: [10]i32 = @splat(0);
    try testing.expectError(error.DimensionMismatch, TileEncoder.init(4, 4, 2).encodeTile(ta, &d));
}
