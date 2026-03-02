//! Bit-level reader and writer for JPEG-LS Golomb-Rice coded bitstreams.
//!
//! Handles 0xFF byte-stuffing as required by the JPEG-LS standard:
//! - On write: after emitting a 0xFF byte, a 0x00 stuff byte is inserted.
//! - On read: 0xFF followed by 0x00 is consumed as a single 0xFF data byte;
//!   0xFF followed by anything else signals a marker.

const std = @import("std");

pub const CodecError = error{
    /// Unexpected end of JPEG-LS data.
    EndOfData,
    /// A JPEG marker was encountered in the bitstream.
    MarkerEncountered,
    /// Golomb quotient overflow.
    GolombOverflow,
    /// I/O error from the underlying writer.
    IoError,
    /// Out of memory.
    OutOfMemory,
    /// Invalid data.
    InvalidData,
    /// Unsupported feature.
    Unsupported,
    /// Dimension mismatch.
    DimensionMismatch,
};

// ---------------------------------------------------------------------------
// BitReader
// ---------------------------------------------------------------------------

/// Reads bits from a byte slice, handling JPEG byte-stuffing.
pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    /// Bit accumulator (MSB-first).
    bits: u64,
    /// Number of valid bits in `bits`.
    n_bits: i32,

    /// Create a new `BitReader` over the given byte slice.
    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .bits = 0,
            .n_bits = 0,
        };
    }

    /// Fill the accumulator so it contains at least `n` bits.
    fn fill(self: *BitReader, n: i32) CodecError!void {
        while (self.n_bits < n) {
            if (self.pos >= self.data.len) {
                return CodecError.EndOfData;
            }
            const b = self.data[self.pos];
            self.pos += 1;

            if (b == 0xFF) {
                // Peek at the next byte.
                if (self.pos >= self.data.len) {
                    return CodecError.EndOfData;
                }
                const next = self.data[self.pos];
                if (next == 0x00) {
                    // Byte stuffing -- consume the 0x00 and treat as 0xFF data.
                    self.pos += 1;
                } else {
                    // This is a marker (e.g. EOI). Stop reading.
                    // Back up so the marker can be parsed later.
                    self.pos -= 1;
                    return CodecError.MarkerEncountered;
                }
            }

            self.bits = (self.bits << 8) | @as(u64, b);
            self.n_bits += 8;
        }
    }

    /// Read `n` bits (0..=32) and return them right-justified.
    pub fn readBits(self: *BitReader, n: i32) CodecError!u32 {
        if (n == 0) {
            return 0;
        }
        try self.fill(n);
        const shift: u6 = @intCast(self.n_bits - n);
        const mask: u64 = (@as(u64, 1) << @as(u6, @intCast(n))) - 1;
        const val: u32 = @intCast((self.bits >> shift) & mask);
        self.n_bits -= n;
        return val;
    }

    /// Read a single bit.
    pub inline fn readBit(self: *BitReader) CodecError!u32 {
        return self.readBits(1);
    }

    /// Read a Golomb-Rice code with parameter `k`.
    ///
    /// The format is: unary-coded quotient (zeros followed by a 1-bit),
    /// then `k` bits for the remainder.
    pub fn readGolomb(self: *BitReader, k: i32) CodecError!u32 {
        // Count leading zeros (the quotient).
        var q: u32 = 0;
        while (true) {
            const b = try self.readBit();
            if (b == 1) {
                break;
            }
            q += 1;
            if (q > 65536) {
                return CodecError.GolombOverflow;
            }
        }

        if (k == 0) {
            return q;
        }

        const r = try self.readBits(k);
        const k_u5: u5 = @intCast(k);
        return (q << k_u5) | r;
    }
};

// ---------------------------------------------------------------------------
// BitWriter
// ---------------------------------------------------------------------------

/// Writes bits to an ArrayList(u8), handling JPEG byte-stuffing.
pub const BitWriter = struct {
    buf: *std.array_list.AlignedManaged(u8, null),
    /// Bit accumulator (MSB-first).
    bits: u64,
    /// Number of valid bits in `bits`.
    n_bits: i32,

    /// Create a new `BitWriter` wrapping the given ArrayList.
    pub fn init(buf: *std.array_list.AlignedManaged(u8, null)) BitWriter {
        return .{
            .buf = buf,
            .bits = 0,
            .n_bits = 0,
        };
    }

    /// Write `n` bits from `val` (MSB-first).
    pub fn writeBits(self: *BitWriter, val: u32, n: i32) CodecError!void {
        const n_u6: u6 = @intCast(n);
        self.bits = (self.bits << n_u6) | (@as(u64, val) & ((@as(u64, 1) << n_u6) - 1));
        self.n_bits += n;

        while (self.n_bits >= 8) {
            const shift: u6 = @intCast(self.n_bits - 8);
            const b: u8 = @intCast((self.bits >> shift) & 0xFF);
            self.buf.append(b) catch return CodecError.OutOfMemory;

            // Byte stuffing: after 0xFF, insert 0x00.
            if (b == 0xFF) {
                self.buf.append(0x00) catch return CodecError.OutOfMemory;
            }

            self.n_bits -= 8;
        }
    }

    /// Write a single bit.
    pub inline fn writeBit(self: *BitWriter, bit: u32) CodecError!void {
        return self.writeBits(bit, 1);
    }

    /// Flush remaining bits (zero-padded to byte boundary).
    pub fn flush(self: *BitWriter) CodecError!void {
        if (self.n_bits > 0) {
            const shift: u6 = @intCast(8 - self.n_bits);
            const b: u8 = @intCast((self.bits << shift) & 0xFF);
            self.buf.append(b) catch return CodecError.OutOfMemory;
            if (b == 0xFF) {
                self.buf.append(0x00) catch return CodecError.OutOfMemory;
            }
            self.n_bits = 0;
            self.bits = 0;
        }
    }

    /// Write a Golomb-Rice code for the non-negative mapped value `val`.
    ///
    /// Format: unary quotient (q zeros + one 1-bit), then k remainder bits.
    pub fn writeGolomb(self: *BitWriter, k: i32, val: u32) CodecError!void {
        const k_u5: u5 = @intCast(k);
        const q = val >> k_u5;
        const r = val & ((@as(u32, 1) << k_u5) - 1);

        // Unary: q zeros then a 1.
        var i: u32 = 0;
        while (i < q) : (i += 1) {
            try self.writeBit(0);
        }
        try self.writeBit(1);

        // Remainder.
        if (k > 0) {
            try self.writeBits(r, k);
        }
    }

    /// Write a raw byte directly (used for markers, not bit-coded data).
    pub fn writeByte(self: *BitWriter, b: u8) CodecError!void {
        self.buf.append(b) catch return CodecError.OutOfMemory;
    }

    /// Write a big-endian 16-bit word directly.
    pub fn writeU16be(self: *BitWriter, v: u16) CodecError!void {
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, v));
        self.buf.appendSlice(&bytes) catch return CodecError.OutOfMemory;
    }

    /// Write raw bytes. Must only be called when the bit buffer is empty
    /// (byte-aligned).
    pub fn writeBytes(self: *BitWriter, data: []const u8) CodecError!void {
        self.buf.appendSlice(data) catch return CodecError.OutOfMemory;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "roundtrip bits" {
    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();

    {
        var bw = BitWriter.init(&buf);
        try bw.writeBits(0b101, 3);
        try bw.writeBits(0b1100, 4);
        try bw.writeBits(0b1, 1);
        try bw.flush();
    }
    // 10111001 = 0xB9
    try testing.expectEqual(@as(usize, 1), buf.items.len);
    try testing.expectEqual(@as(u8, 0xB9), buf.items[0]);

    var br = BitReader.init(buf.items);
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try testing.expectEqual(@as(u32, 0b1100), try br.readBits(4));
    try testing.expectEqual(@as(u32, 0b1), try br.readBits(1));
}

test "roundtrip golomb k0" {
    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();

    {
        var bw = BitWriter.init(&buf);
        // val=0, k=0 -> just "1"
        try bw.writeGolomb(0, 0);
        // val=3, k=0 -> "0001"
        try bw.writeGolomb(0, 3);
        // val=1, k=0 -> "01"
        try bw.writeGolomb(0, 1);
        try bw.flush();
    }

    var br = BitReader.init(buf.items);
    try testing.expectEqual(@as(u32, 0), try br.readGolomb(0));
    try testing.expectEqual(@as(u32, 3), try br.readGolomb(0));
    try testing.expectEqual(@as(u32, 1), try br.readGolomb(0));
}

test "roundtrip golomb k2" {
    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();

    {
        var bw = BitWriter.init(&buf);
        // val=5, k=2 -> q=1, r=1 -> "01" + "01" = "0101"
        try bw.writeGolomb(2, 5);
        // val=0, k=2 -> q=0, r=0 -> "1" + "00" = "100"
        try bw.writeGolomb(2, 0);
        try bw.flush();
    }

    var br = BitReader.init(buf.items);
    try testing.expectEqual(@as(u32, 5), try br.readGolomb(2));
    try testing.expectEqual(@as(u32, 0), try br.readGolomb(2));
}

test "roundtrip golomb many values" {
    var k: i32 = 0;
    while (k < 8) : (k += 1) {
        var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
        defer buf.deinit();

        {
            var bw = BitWriter.init(&buf);
            var v: u32 = 0;
            while (v < 50) : (v += 1) {
                try bw.writeGolomb(k, v);
            }
            try bw.flush();
        }

        var br = BitReader.init(buf.items);
        var v: u32 = 0;
        while (v < 50) : (v += 1) {
            const decoded = try br.readGolomb(k);
            try testing.expectEqual(v, decoded);
        }
    }
}

test "byte stuffing 0xff on write" {
    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();

    {
        var bw = BitWriter.init(&buf);
        try bw.writeBits(0xFF, 8);
        try bw.flush();
    }
    // 0xFF should be followed by 0x00 stuff byte
    try testing.expectEqual(@as(usize, 2), buf.items.len);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[1]);
}

test "byte stuffing roundtrip" {
    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();

    {
        var bw = BitWriter.init(&buf);
        // Write value 0xFF (8 bits) then value 0x01 (8 bits)
        try bw.writeBits(0xFF, 8);
        try bw.writeBits(0x01, 8);
        try bw.flush();
    }
    // Should be: FF 00 01
    try testing.expectEqual(@as(usize, 3), buf.items.len);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[1]);
    try testing.expectEqual(@as(u8, 0x01), buf.items[2]);

    var br = BitReader.init(buf.items);
    try testing.expectEqual(@as(u32, 0xFF), try br.readBits(8));
    try testing.expectEqual(@as(u32, 0x01), try br.readBits(8));
}

test "read bits empty returns error" {
    const buf = [_]u8{};
    var br = BitReader.init(&buf);
    try testing.expectError(CodecError.EndOfData, br.readBit());
}

test "write zero bits is noop" {
    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();

    {
        var bw = BitWriter.init(&buf);
        try bw.writeBits(0, 0);
        try bw.flush();
    }
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "read zero bits returns zero" {
    const buf = [_]u8{0xAB};
    var br = BitReader.init(&buf);
    try testing.expectEqual(@as(u32, 0), try br.readBits(0));
}
