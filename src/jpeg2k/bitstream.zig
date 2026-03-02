//! Bit-level I/O helpers for JPEG 2000 codestream reading and writing.
//!
//! Provides `BitReader` and `BitWriter` for bit-granularity access
//! to byte buffers, plus `ByteReader` and `ByteWriter` for big-endian
//! multi-byte primitives.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// BitReader
// ---------------------------------------------------------------------------

/// Reads bits from a byte slice (MSB first).
pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    buf: u32,
    bits: u32,

    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .buf = 0,
            .bits = 0,
        };
    }

    /// Read a single bit (0 or 1).
    pub fn readBit(self: *BitReader) error{EndOfStream}!u32 {
        if (self.bits == 0) {
            try self.fill();
        }
        self.bits -= 1;
        return (self.buf >> @intCast(self.bits)) & 1;
    }

    /// Read `n` bits (n <= 25) and return them right-justified.
    pub fn readBits(self: *BitReader, n: u5) error{EndOfStream}!u32 {
        while (self.bits < n) {
            try self.fill();
        }
        self.bits -= n;
        return (self.buf >> @intCast(self.bits)) & ((@as(u32, 1) << n) - 1);
    }

    /// Discard buffered bits, aligning to byte boundary.
    pub fn alignToByte(self: *BitReader) void {
        self.bits = 0;
        self.buf = 0;
    }

    fn fill(self: *BitReader) error{EndOfStream}!void {
        if (self.pos >= self.data.len) {
            return error.EndOfStream;
        }
        self.buf = (self.buf << 8) | @as(u32, self.data[self.pos]);
        self.pos += 1;
        self.bits += 8;
    }
};

// ---------------------------------------------------------------------------
// BitWriter
// ---------------------------------------------------------------------------

/// Writes bits to a growable byte buffer (MSB first).
pub const BitWriter = struct {
    output: std.array_list.AlignedManaged(u8, null),
    buf: u32,
    bits: u32,

    pub fn init(allocator: Allocator) BitWriter {
        return .{
            .output = std.array_list.AlignedManaged(u8, null).init(allocator),
            .buf = 0,
            .bits = 0,
        };
    }

    pub fn deinit(self: *BitWriter) void {
        self.output.deinit();
    }

    /// Write a single bit (0 or 1).
    pub fn writeBit(self: *BitWriter, bit: u32) Allocator.Error!void {
        self.buf = (self.buf << 1) | (bit & 1);
        self.bits += 1;
        if (self.bits >= 8) {
            try self.flushByte();
        }
    }

    /// Write the lowest `n` bits of `val` (n <= 25).
    pub fn writeBits(self: *BitWriter, val: u32, n: u5) Allocator.Error!void {
        self.buf = (self.buf << n) | (val & ((@as(u32, 1) << n) - 1));
        self.bits += n;
        while (self.bits >= 8) {
            try self.flushByte();
        }
    }

    /// Pad remaining bits with zeros and flush.
    pub fn flush(self: *BitWriter) Allocator.Error!void {
        if (self.bits > 0) {
            const padding: u5 = @intCast(8 - self.bits);
            self.buf <<= padding;
            self.bits = 8;
            try self.flushByte();
        }
    }

    /// Pad remaining bits with ones (JPEG 2000 convention) and flush.
    pub fn flushWithStuffing(self: *BitWriter) Allocator.Error!void {
        if (self.bits > 0) {
            const padding: u5 = @intCast(8 - self.bits);
            self.buf = (self.buf << padding) | ((@as(u32, 1) << padding) - 1);
            self.bits = 8;
            try self.flushByte();
        }
    }

    fn flushByte(self: *BitWriter) Allocator.Error!void {
        const shift: u5 = @intCast(self.bits - 8);
        const c: u8 = @intCast((self.buf >> shift) & 0xFF);
        self.bits = @as(u32, shift);
        self.buf &= (@as(u32, 1) << shift) -% 1;
        try self.output.append(c);
    }

    /// Return the accumulated bytes as a slice.
    pub fn bytes(self: *const BitWriter) []const u8 {
        return self.output.items;
    }

    /// Return the accumulated bytes and release ownership.
    pub fn toOwnedSlice(self: *BitWriter) Allocator.Error![]u8 {
        return self.output.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// ByteReader -- big-endian multi-byte reads from a slice
// ---------------------------------------------------------------------------

/// Reads big-endian primitives from a byte slice with a cursor.
pub const ByteReader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) ByteReader {
        return .{ .data = data, .pos = 0 };
    }

    /// Current read position.
    pub fn position(self: *const ByteReader) usize {
        return self.pos;
    }

    /// Remaining unread bytes.
    pub fn remaining(self: *const ByteReader) usize {
        if (self.pos >= self.data.len) return 0;
        return self.data.len - self.pos;
    }

    pub fn readU8(self: *ByteReader) error{EndOfStream}!u8 {
        if (self.pos >= self.data.len) {
            return error.EndOfStream;
        }
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU16(self: *ByteReader) error{EndOfStream}!u16 {
        const hi: u16 = try self.readU8();
        const lo: u16 = try self.readU8();
        return (hi << 8) | lo;
    }

    pub fn readU32(self: *ByteReader) error{EndOfStream}!u32 {
        var val: u32 = 0;
        for (0..4) |_| {
            val = (val << 8) | @as(u32, try self.readU8());
        }
        return val;
    }

    pub fn readBytes(self: *ByteReader, n: usize) error{EndOfStream}![]const u8 {
        if (self.pos + n > self.data.len) {
            return error.EndOfStream;
        }
        const slice = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    pub fn skip(self: *ByteReader, n: usize) error{EndOfStream}!void {
        if (self.pos + n > self.data.len) {
            return error.EndOfStream;
        }
        self.pos += n;
    }
};

// ---------------------------------------------------------------------------
// ByteWriter -- big-endian multi-byte writes to an ArrayList
// ---------------------------------------------------------------------------

/// Writes big-endian primitives into a growable byte buffer.
pub const ByteWriter = struct {
    buf: std.array_list.AlignedManaged(u8, null),

    pub fn init(allocator: Allocator) ByteWriter {
        return .{ .buf = std.array_list.AlignedManaged(u8, null).init(allocator) };
    }

    pub fn deinit(self: *ByteWriter) void {
        self.buf.deinit();
    }

    pub fn writeU8(self: *ByteWriter, v: u8) Allocator.Error!void {
        try self.buf.append(v);
    }

    pub fn writeU16(self: *ByteWriter, v: u16) Allocator.Error!void {
        try self.buf.append(@intCast(v >> 8));
        try self.buf.append(@intCast(v & 0xFF));
    }

    pub fn writeU32(self: *ByteWriter, v: u32) Allocator.Error!void {
        try self.buf.append(@intCast((v >> 24) & 0xFF));
        try self.buf.append(@intCast((v >> 16) & 0xFF));
        try self.buf.append(@intCast((v >> 8) & 0xFF));
        try self.buf.append(@intCast(v & 0xFF));
    }

    pub fn writeBytes(self: *ByteWriter, data: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(data);
    }

    /// Return the accumulated bytes and release ownership.
    pub fn toOwnedSlice(self: *ByteWriter) Allocator.Error![]u8 {
        return self.buf.toOwnedSlice();
    }

    /// Return the accumulated bytes as a slice.
    pub fn bytes(self: *const ByteWriter) []const u8 {
        return self.buf.items;
    }

    /// Current length of the buffer.
    pub fn len(self: *const ByteWriter) usize {
        return self.buf.items.len;
    }

    /// Whether the buffer is empty.
    pub fn isEmpty(self: *const ByteWriter) bool {
        return self.buf.items.len == 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "bit writer reader roundtrip" {
    const allocator = std.testing.allocator;

    var bw = BitWriter.init(allocator);
    defer bw.deinit();
    try bw.writeBit(1);
    try bw.writeBit(0);
    try bw.writeBit(1);
    try bw.writeBits(0b11010, 5);
    try bw.flush();
    // Expected byte: 1_0_1_11010 = 0b10111010 = 0xBA
    try std.testing.expectEqualSlices(u8, &.{0xBA}, bw.bytes());

    var br = BitReader.init(bw.bytes());
    try std.testing.expectEqual(@as(u32, 1), try br.readBit());
    try std.testing.expectEqual(@as(u32, 0), try br.readBit());
    try std.testing.expectEqual(@as(u32, 1), try br.readBit());
    try std.testing.expectEqual(@as(u32, 0b11010), try br.readBits(5));
}

test "bit writer multi byte" {
    const allocator = std.testing.allocator;

    var bw = BitWriter.init(allocator);
    defer bw.deinit();
    try bw.writeBits(0xABCD, 16);
    try bw.flush();
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD }, bw.bytes());
}

test "byte reader primitives" {
    const data = [_]u8{ 0x00, 0x0A, 0x01, 0x02, 0x03, 0x04 };
    var r = ByteReader.init(&data);
    try std.testing.expectEqual(@as(u16, 0x000A), try r.readU16());
    try std.testing.expectEqual(@as(u32, 0x01020304), try r.readU32());
}

test "byte writer primitives" {
    const allocator = std.testing.allocator;

    var w = ByteWriter.init(allocator);
    defer w.deinit();
    try w.writeU16(0xFF51);
    try w.writeU32(0x00000100);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x51, 0x00, 0x00, 0x01, 0x00 }, w.bytes());
}

test "bit writer flush with stuffing" {
    const allocator = std.testing.allocator;

    var bw = BitWriter.init(allocator);
    defer bw.deinit();
    try bw.writeBits(0b101, 3);
    try bw.flushWithStuffing();
    // 101_11111 = 0xBF
    try std.testing.expectEqualSlices(u8, &.{0xBF}, bw.bytes());
}

test "byte reader remaining" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var r = ByteReader.init(&data);
    try std.testing.expectEqual(@as(usize, 5), r.remaining());
    _ = try r.readU8();
    try std.testing.expectEqual(@as(usize, 4), r.remaining());
    try r.skip(2);
    try std.testing.expectEqual(@as(usize, 2), r.remaining());
}
