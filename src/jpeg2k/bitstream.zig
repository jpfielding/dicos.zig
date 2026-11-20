//! Bit-level I/O helpers for JPEG 2000 codestream reading and writing.
//!
//! Provides `BitReader` and `BitWriter` for bit-granularity access to byte
//! streams, plus `ByteReader` and `ByteWriter` for big-endian multi-byte
//! primitives.
//!
//! Only `ByteReader`/`ByteWriter` are live in the conformant pipeline (packet
//! I/O has its own stuffing-bit codec in `packet.zig`); the bit helpers are
//! kept for API parity with the Rust crate.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// BitReader
// ---------------------------------------------------------------------------

/// Reads bits from a byte slice (MSB first).
pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    buf: u32 = 0,
    bits: u32 = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// Read a single bit (0 or 1).
    pub fn readBit(self: *BitReader) error{EndOfStream}!u32 {
        if (self.bits == 0) try self.fill();
        self.bits -= 1;
        return (self.buf >> @intCast(self.bits)) & 1;
    }

    /// Read `n` bits (`n <= 25`) and return them right-justified.
    pub fn readBits(self: *BitReader, n: u5) error{EndOfStream}!u32 {
        while (self.bits < n) try self.fill();
        self.bits -= n;
        return (self.buf >> @intCast(self.bits)) & ((@as(u32, 1) << n) - 1);
    }

    /// Discard buffered bits, aligning to a byte boundary.
    pub fn alignToByte(self: *BitReader) void {
        self.bits = 0;
        self.buf = 0;
    }

    fn fill(self: *BitReader) error{EndOfStream}!void {
        if (self.pos >= self.data.len) return error.EndOfStream;
        self.buf = (self.buf << 8) | self.data[self.pos];
        self.pos += 1;
        self.bits += 8;
    }
};

// ---------------------------------------------------------------------------
// BitWriter
// ---------------------------------------------------------------------------

/// Writes bits to a `std.Io.Writer` (MSB first).
pub const BitWriter = struct {
    inner: *std.Io.Writer,
    buf: u32 = 0,
    bits: u32 = 0,

    pub fn init(inner: *std.Io.Writer) BitWriter {
        return .{ .inner = inner };
    }

    /// Write a single bit (only bit 0 of `bit` is used).
    pub fn writeBit(self: *BitWriter, bit: u32) std.Io.Writer.Error!void {
        self.buf = (self.buf << 1) | (bit & 1);
        self.bits += 1;
        if (self.bits >= 8) try self.flushByte();
    }

    /// Write the lowest `n` bits of `val` (`n <= 25`).
    pub fn writeBits(self: *BitWriter, val: u32, n: u5) std.Io.Writer.Error!void {
        self.buf = (self.buf << n) | (val & ((@as(u32, 1) << n) - 1));
        self.bits += n;
        while (self.bits >= 8) try self.flushByte();
    }

    /// Pad remaining bits with zeros and flush the underlying writer.
    pub fn flush(self: *BitWriter) std.Io.Writer.Error!void {
        if (self.bits > 0) {
            const padding: u5 = @intCast(8 - self.bits);
            self.buf <<= padding;
            self.bits = 8;
            try self.flushByte();
        }
        try self.inner.flush();
    }

    /// Pad remaining bits with ones (JPEG 2000 convention) and flush.
    pub fn flushWithStuffing(self: *BitWriter) std.Io.Writer.Error!void {
        if (self.bits > 0) {
            const padding: u5 = @intCast(8 - self.bits);
            self.buf = (self.buf << padding) | ((@as(u32, 1) << padding) - 1);
            self.bits = 8;
            try self.flushByte();
        }
        try self.inner.flush();
    }

    fn flushByte(self: *BitWriter) std.Io.Writer.Error!void {
        const shift: u5 = @intCast(self.bits - 8);
        const c: u8 = @truncate(self.buf >> shift);
        self.bits = shift;
        self.buf &= (@as(u32, 1) << shift) - 1;
        try self.inner.writeByte(c);
    }
};

// ---------------------------------------------------------------------------
// ByteReader -- big-endian multi-byte reads from a slice
// ---------------------------------------------------------------------------

/// Reads big-endian primitives from a byte slice with a cursor.
pub const ByteReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub const Error = error{EndOfStream};

    pub fn init(data: []const u8) ByteReader {
        return .{ .data = data };
    }

    /// Current read position.
    pub fn position(self: *const ByteReader) usize {
        return self.pos;
    }

    /// Remaining unread bytes.
    pub fn remaining(self: *const ByteReader) usize {
        return self.data.len -| self.pos;
    }

    pub fn readU8(self: *ByteReader) Error!u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU16(self: *ByteReader) Error!u16 {
        const hi: u16 = try self.readU8();
        const lo: u16 = try self.readU8();
        return (hi << 8) | lo;
    }

    pub fn readU32(self: *ByteReader) Error!u32 {
        var val: u32 = 0;
        for (0..4) |_| val = (val << 8) | try self.readU8();
        return val;
    }

    pub fn readBytes(self: *ByteReader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return error.EndOfStream;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    pub fn skip(self: *ByteReader, n: usize) Error!void {
        if (n > self.remaining()) return error.EndOfStream;
        self.pos += n;
    }
};

// ---------------------------------------------------------------------------
// ByteWriter -- big-endian multi-byte writes to a growable buffer
// ---------------------------------------------------------------------------

/// Writes big-endian primitives into a growable byte buffer.
pub const ByteWriter = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) ByteWriter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ByteWriter) void {
        self.buf.deinit(self.gpa);
    }

    pub fn writeU8(self: *ByteWriter, v: u8) Allocator.Error!void {
        try self.buf.append(self.gpa, v);
    }

    pub fn writeU16(self: *ByteWriter, v: u16) Allocator.Error!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .big);
        try self.buf.appendSlice(self.gpa, &b);
    }

    pub fn writeU32(self: *ByteWriter, v: u32) Allocator.Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try self.buf.appendSlice(self.gpa, &b);
    }

    pub fn writeBytes(self: *ByteWriter, data: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(self.gpa, data);
    }

    /// The accumulated bytes (borrowed; valid until the next write/deinit).
    pub fn bytes(self: *const ByteWriter) []const u8 {
        return self.buf.items;
    }

    /// Transfer ownership of the accumulated bytes to the caller.
    pub fn toOwnedSlice(self: *ByteWriter) Allocator.Error![]u8 {
        return self.buf.toOwnedSlice(self.gpa);
    }

    pub fn len(self: *const ByteWriter) usize {
        return self.buf.items.len;
    }

    pub fn isEmpty(self: *const ByteWriter) bool {
        return self.buf.items.len == 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "bit writer reader roundtrip" {
    var out: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var bw = BitWriter.init(&w);
    try bw.writeBit(1);
    try bw.writeBit(0);
    try bw.writeBit(1);
    try bw.writeBits(0b11010, 5);
    try bw.flush();
    // 1_0_1_11010 = 0b10111010 = 0xBA
    try testing.expectEqualSlices(u8, &.{0xBA}, w.buffered());

    var br = BitReader.init(w.buffered());
    try testing.expectEqual(@as(u32, 1), try br.readBit());
    try testing.expectEqual(@as(u32, 0), try br.readBit());
    try testing.expectEqual(@as(u32, 1), try br.readBit());
    try testing.expectEqual(@as(u32, 0b11010), try br.readBits(5));
}

test "bit writer multi byte" {
    var out: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var bw = BitWriter.init(&w);
    try bw.writeBits(0xABCD, 16);
    try bw.flush();
    try testing.expectEqualSlices(u8, &.{ 0xAB, 0xCD }, w.buffered());
}

test "byte reader primitives" {
    const data = [_]u8{ 0x00, 0x0A, 0x01, 0x02, 0x03, 0x04 };
    var r = ByteReader.init(&data);
    try testing.expectEqual(@as(u16, 0x000A), try r.readU16());
    try testing.expectEqual(@as(u32, 0x01020304), try r.readU32());
}

test "byte writer primitives" {
    var w = ByteWriter.init(testing.allocator);
    defer w.deinit();
    try w.writeU16(0xFF51);
    try w.writeU32(0x00000100);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x51, 0x00, 0x00, 0x01, 0x00 }, w.bytes());
}

test "bit writer flush with stuffing" {
    var out: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var bw = BitWriter.init(&w);
    try bw.writeBits(0b101, 3);
    try bw.flushWithStuffing();
    // 101_11111 = 0xBF
    try testing.expectEqualSlices(u8, &.{0xBF}, w.buffered());
}

test "byte reader remaining" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var r = ByteReader.init(&data);
    try testing.expectEqual(@as(usize, 5), r.remaining());
    _ = try r.readU8();
    try testing.expectEqual(@as(usize, 4), r.remaining());
    try r.skip(2);
    try testing.expectEqual(@as(usize, 2), r.remaining());
}
