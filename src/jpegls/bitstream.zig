//! Bit-level reader and writer for T.87 (ITU-T T.87 / ISO 14495-1) JPEG-LS
//! entropy-coded segments.
//!
//! # Single-bit stuffing (T.87 A.1)
//!
//! Whenever an output byte equals `0xFF`, the *next* byte carries only 7 data
//! bits and its most-significant bit is forced to `0` (the "stuffed" bit).
//! On read, a byte `< 0x80` following a `0xFF` contributes 7 data bits (its
//! MSB is the stuffed zero); a byte `>= 0x80` following `0xFF` is a **marker**
//! and is surfaced as `error.Marker` with the code in `BitReader.pending_marker`.
//!
//! # Limited-length Golomb (T.87 A.5.3)
//!
//! `BitWriter.writeLimitedGolomb` / `BitReader.readLimitedGolomb` implement
//! the length-limited mapped-error code, replacing the pre-spec uncapped
//! unary coder (which lives on, frozen, in `legacy.zig`).

const std = @import("std");

/// Errors the bit reader can raise. `Marker` means a `0xFFxx` (xx >= 0x80)
/// marker terminated the segment; `InvalidData` means end of data or an
/// over-long unary prefix.
pub const ReadError = error{ Marker, InvalidData };

/// Errors the bit writer can raise (the sink failed).
pub const WriteError = error{Io};

// ---------------------------------------------------------------------------
// BitReader
// ---------------------------------------------------------------------------

/// Reads bits from a byte slice, handling T.87 single-bit stuffing.
pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    /// Bit accumulator (MSB-first, valid bits are the low `n_bits`).
    bits: u64 = 0,
    /// Number of valid bits in `bits`.
    n_bits: i32 = 0,
    /// Whether the most recently consumed byte was `0xFF` (so the next byte is
    /// a stuffed 7-bit byte or a marker).
    last_ff: bool = false,
    /// Set when a marker (0xFFxx, xx >= 0x80) was encountered mid-scan; the
    /// value is the full 16-bit marker code (e.g. `0xFFD9` for EOI).
    pending_marker: ?u16 = null,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// Byte offset of the marker terminating the scan.
    ///
    /// If the final consumed data byte was `0xFF`, its mandatory stuff byte
    /// (T.87 A.1) may not have been pulled into the accumulator yet; it sits at
    /// `pos` and the marker begins immediately after it.
    pub fn markerPos(self: *const BitReader) usize {
        return if (self.last_ff) self.pos + 1 else self.pos;
    }

    /// Fill the accumulator so it contains at least `n` bits.
    fn fill(self: *BitReader, n: i32) ReadError!void {
        while (self.n_bits < n) {
            if (self.pending_marker != null) return error.Marker;
            if (self.pos >= self.data.len) return error.InvalidData;
            const b = self.data[self.pos];

            if (self.last_ff) {
                // The previous byte was a `0xFF` data byte, so this byte is a
                // stuffed 7-bit byte: its MSB is the stuffed 0.
                self.pos += 1;
                self.bits = (self.bits << 7) | (@as(u64, b) & 0x7F);
                self.n_bits += 7;
                self.last_ff = false;
            } else if (b == 0xFF) {
                // A following byte >= 0x80 makes `0xFF` the first half of a
                // marker; a following byte < 0x80 (or end of data) makes it an
                // 8-bit data byte with a stuffed byte after it.
                if (self.pos + 1 < self.data.len and self.data[self.pos + 1] >= 0x80) {
                    self.pending_marker = 0xFF00 | @as(u16, self.data[self.pos + 1]);
                    return error.Marker;
                }
                self.pos += 1;
                self.bits = (self.bits << 8) | 0xFF;
                self.n_bits += 8;
                self.last_ff = true;
            } else {
                self.pos += 1;
                self.bits = (self.bits << 8) | b;
                self.n_bits += 8;
                self.last_ff = false;
            }
        }
    }

    /// Read `n` bits (0..=32) and return them right-justified.
    pub fn readBits(self: *BitReader, n: i32) ReadError!u32 {
        if (n == 0) return 0;
        try self.fill(n);
        const shift: u6 = @intCast(self.n_bits - n);
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        const val = (self.bits >> shift) & mask;
        self.n_bits -= n;
        return @intCast(val);
    }

    /// Read a single bit.
    pub inline fn readBit(self: *BitReader) ReadError!u32 {
        return self.readBits(1);
    }

    /// Count the `0` bits before the terminating `1` (the unary prefix of a
    /// limited-length Golomb code), capped at `escape`. An over-long run is
    /// rejected with `InvalidData`.
    fn readUnaryCapped(self: *BitReader, escape: i32) ReadError!i32 {
        var count: i32 = 0;
        while (true) {
            if (self.n_bits == 0) try self.fill(1);
            // Left-justify the n_bits-wide window so the next bit sits at bit 63.
            const nb: u6 = @intCast(self.n_bits);
            const window = (self.bits & ((@as(u64, 1) << nb) - 1)) << @intCast(64 - @as(u7, nb));
            const zeros: i32 = @min(@as(i32, @clz(window)), self.n_bits);
            if (zeros < self.n_bits) {
                // Terminating 1 sits `zeros` bits in; consume the zeros and it.
                self.n_bits -= zeros + 1;
                const total = count + zeros;
                if (total > escape) return error.InvalidData;
                return total;
            }
            // The whole buffered window was zero: consume it and refill.
            count += self.n_bits;
            self.n_bits = 0;
            if (count > escape) return error.InvalidData;
        }
    }

    /// Read a length-limited Golomb code (T.87 A.5.3).
    ///
    /// Counts the zeros preceding the terminating `1`:
    /// - `count < glimit - qbpp - 1` -> `(count << k) | readBits(k)`;
    /// - `count == glimit - qbpp - 1` (escape) -> `readBits(qbpp) + 1`;
    /// - anything longer -> `InvalidData`.
    pub fn readLimitedGolomb(self: *BitReader, k: i32, glimit: i32, qbpp: i32) ReadError!u32 {
        const escape = glimit - qbpp - 1;
        const count = try self.readUnaryCapped(escape);
        if (count < escape) {
            const r: u32 = if (k > 0) try self.readBits(k) else 0;
            return (@as(u32, @intCast(count)) << @intCast(k)) | r;
        }
        // count == escape: the escape carries (val - 1) in qbpp bits.
        return (try self.readBits(qbpp)) +% 1;
    }
};

// ---------------------------------------------------------------------------
// BitWriter
// ---------------------------------------------------------------------------

/// Writes bits to a `std.Io.Writer`, applying T.87 single-bit stuffing.
pub const BitWriter = struct {
    out: *std.Io.Writer,
    /// Bit accumulator (MSB-first, valid bits are the low `n_bits`).
    bits: u64 = 0,
    /// Number of valid bits in `bits`.
    n_bits: i32 = 0,
    /// Whether the most recently emitted byte was `0xFF` (so the next byte
    /// must carry only 7 data bits with its MSB forced to 0).
    last_ff: bool = false,

    pub fn init(out: *std.Io.Writer) BitWriter {
        return .{ .out = out };
    }

    fn emit(self: *BitWriter, b: u8) WriteError!void {
        self.out.writeByte(b) catch return error.Io;
    }

    /// Emit whole output bytes while enough bits are buffered. After a `0xFF`
    /// byte the next byte carries only 7 bits (MSB forced 0) per T.87 A.1.
    fn drain(self: *BitWriter) WriteError!void {
        while (true) {
            const width: i32 = if (self.last_ff) 7 else 8;
            if (self.n_bits < width) break;
            const shift: u6 = @intCast(self.n_bits - width);
            const mask = (@as(u64, 1) << @intCast(width)) - 1;
            const b: u8 = @intCast((self.bits >> shift) & mask);
            try self.emit(b);
            self.n_bits -= width;
            self.last_ff = b == 0xFF;
        }
    }

    /// Write `n` bits (0..=32) from `val` (MSB-first).
    pub fn writeBits(self: *BitWriter, val: u32, n: i32) WriteError!void {
        if (n == 0) return;
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        self.bits = (self.bits << @intCast(n)) | (@as(u64, val) & mask);
        self.n_bits += n;
        try self.drain();
    }

    /// Write a single bit.
    pub inline fn writeBit(self: *BitWriter, bit: u32) WriteError!void {
        return self.writeBits(bit, 1);
    }

    /// Write a length-limited Golomb code (T.87 A.5.3).
    ///
    /// With `q = val >> k` and `escape = glimit - qbpp - 1`:
    /// - `q < escape` -> `q` zeros, a `1`, then the low `k` bits of `val`;
    /// - otherwise -> `escape` zeros, a `1`, then `val - 1` in `qbpp` bits.
    pub fn writeLimitedGolomb(self: *BitWriter, k: i32, val: u32, glimit: i32, qbpp: i32) WriteError!void {
        const kk: u5 = @intCast(k);
        const q: i32 = @bitCast(val >> kk);
        const escape = glimit - qbpp - 1;

        if (q < escape) {
            var i: i32 = 0;
            while (i < q) : (i += 1) try self.writeBit(0);
            try self.writeBit(1);
            if (k > 0) try self.writeBits(val & ((@as(u32, 1) << kk) - 1), k);
        } else {
            var i: i32 = 0;
            while (i < escape) : (i += 1) try self.writeBit(0);
            try self.writeBit(1);
            try self.writeBits(val -% 1, qbpp);
        }
    }

    /// Flush remaining bits, zero-padded to a byte boundary.
    ///
    /// Padding respects the stuffing state: if the previous emitted byte was
    /// `0xFF`, the final byte carries 7 bits (MSB forced 0); otherwise 8. A
    /// `0xFF` emitted as the final data byte still gets its mandatory stuff
    /// byte (T.87 A.1) so a following marker is not misread.
    pub fn flush(self: *BitWriter) WriteError!void {
        if (self.n_bits > 0) {
            const width: i32 = if (self.last_ff) 7 else 8;
            std.debug.assert(self.n_bits < width);
            const pad = width - self.n_bits;
            self.bits <<= @intCast(pad);
            self.n_bits += pad;
            const mask = (@as(u64, 1) << @intCast(width)) - 1;
            const b: u8 = @intCast(self.bits & mask);
            try self.emit(b);
            self.bits = 0;
            self.n_bits = 0;
            self.last_ff = b == 0xFF;
        }
        if (self.last_ff) {
            try self.emit(0x00);
            self.last_ff = false;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn writeBytesViaBits(aw: *std.Io.Writer.Allocating, values: []const u8) ![]const u8 {
    var bw = BitWriter.init(&aw.writer);
    for (values) |v| try bw.writeBits(v, 8);
    try bw.flush();
    return aw.written();
}

test "plain bits roundtrip" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var bw = BitWriter.init(&aw.writer);
    try bw.writeBits(0b101, 3);
    try bw.writeBits(0b1100, 4);
    try bw.writeBits(0b1, 1);
    try bw.flush();
    try testing.expectEqualSlices(u8, &.{0xB9}, aw.written());

    var br = BitReader.init(aw.written());
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try testing.expectEqual(@as(u32, 0b1100), try br.readBits(4));
    try testing.expectEqual(@as(u32, 0b1), try br.readBits(1));
}

test "single bit stuffing after ff" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var bw = BitWriter.init(&aw.writer);
    try bw.writeBits(0xFF, 8);
    try bw.writeBits(0b1, 1);
    try bw.flush();
    // 0xFF, then a stuffed byte: MSB 0, next bit 1, padded => 0b0100_0000.
    const buf = aw.written();
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x40 }, buf);
    for (0..buf.len - 1) |i| {
        if (buf[i] == 0xFF) try testing.expect(buf[i + 1] < 0x80);
    }
}

test "stuffing roundtrip many ff boundaries" {
    const patterns = [_][]const u8{
        &.{0xFF},
        &.{ 0xFF, 0xFF, 0xFF, 0xFF },
        &.{ 0xFF, 0x00, 0xFF, 0x00 },
        &.{ 0x00, 0xFF, 0xFF, 0x01, 0xFF, 0xFF, 0xFF, 0x80, 0x7F },
        &([_]u8{0xFF} ** 16),
        &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x12, 0x34 },
    };
    for (patterns) |pat| {
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        const encoded = try writeBytesViaBits(&aw, pat);
        for (0..encoded.len -| 1) |i| {
            if (encoded[i] == 0xFF) try testing.expect(encoded[i + 1] < 0x80);
        }
        var br = BitReader.init(encoded);
        for (pat) |v| try testing.expectEqual(@as(u32, v), try br.readBits(8));
    }
}

test "limited golomb roundtrip all k non escape" {
    const glimit = 32;
    const qbpp = 16;
    const escape: u32 = glimit - qbpp - 1;
    var k: i32 = 0;
    while (k <= 15) : (k += 1) {
        const kk: u5 = @intCast(k);
        const kbits = @as(u32, 1) << kk;
        var values: [12]u32 = undefined;
        var n: usize = 0;
        for ([_]u32{ 0, 1, 7, escape - 1 }) |q| {
            for ([_]u32{ 0, kbits / 2, kbits - 1 }) |r| {
                values[n] = (q << kk) | (r & (kbits - 1));
                n += 1;
            }
        }
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        var bw = BitWriter.init(&aw.writer);
        for (values) |v| {
            try testing.expect((v >> kk) < escape);
            try bw.writeLimitedGolomb(k, v, glimit, qbpp);
        }
        try bw.flush();
        var br = BitReader.init(aw.written());
        for (values) |v| try testing.expectEqual(v, try br.readLimitedGolomb(k, glimit, qbpp));
    }
}

test "limited golomb escape path" {
    const glimit = 32;
    const qbpp = 16;
    const values = [_]u32{ 15, 16, 100, 1000, 65535, 1 << qbpp };
    var k: i32 = 0;
    while (k <= 15) : (k += 1) {
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        var bw = BitWriter.init(&aw.writer);
        for (values) |v| try bw.writeLimitedGolomb(k, v, glimit, qbpp);
        try bw.flush();
        var br = BitReader.init(aw.written());
        for (values) |v| try testing.expectEqual(v, try br.readLimitedGolomb(k, glimit, qbpp));
    }
}

test "marker detection mid stream" {
    const data = [_]u8{ 0xFF, 0xD9 };
    var br = BitReader.init(&data);
    try testing.expectError(error.Marker, br.readBit());
    try testing.expectEqual(@as(?u16, 0xFFD9), br.pending_marker);
    // Subsequent reads keep reporting the marker, not garbage.
    try testing.expectError(error.Marker, br.readBit());
}

test "marker after valid data" {
    const data = [_]u8{ 0b1010_0000, 0xFF, 0xD9 };
    var br = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    var hit_marker = false;
    for (0..16) |_| {
        _ = br.readBit() catch |e| {
            try testing.expectEqual(error.Marker, e);
            try testing.expectEqual(@as(?u16, 0xFFD9), br.pending_marker);
            hit_marker = true;
            break;
        };
    }
    try testing.expect(hit_marker);
}

test "truncation is error not panic" {
    const data = [_]u8{0b1010_1010};
    var br = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0b1010_1010), try br.readBits(8));
    try testing.expectError(error.InvalidData, br.readBit());
}

test "read zero bits returns zero" {
    const data = [_]u8{0xAB};
    var br = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0), try br.readBits(0));
}

test "write zero bits is noop" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var bw = BitWriter.init(&aw.writer);
    try bw.writeBits(0, 0);
    try bw.flush();
    try testing.expectEqual(@as(usize, 0), aw.written().len);
}

test "limited golomb rejects overlong unary" {
    const data = [_]u8{0x00} ** 8;
    var br = BitReader.init(&data);
    try testing.expectError(error.InvalidData, br.readLimitedGolomb(0, 32, 16));
}
