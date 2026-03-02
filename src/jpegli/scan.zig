//! Scan data parsing and writing for JPEG Lossless.
//!
//! Handles bit-level I/O with JPEG byte stuffing (0xFF -> 0xFF 0x00),
//! Huffman symbol decoding, DPCM predictor selection (1-7), and the
//! overall scan encode/decode loops.

const std = @import("std");
const huffman = @import("huffman.zig");

const HuffmanTable = huffman.HuffmanTable;
const categorize = huffman.categorize;
const extend = huffman.extend;

// ---------------------------------------------------------------------------
// Bit reader (decoding)
// ---------------------------------------------------------------------------

/// Reads bits from a JPEG entropy-coded segment, handling byte stuffing.
pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    buf: u32,
    bits: u8,
    eof: bool,

    pub fn init(data: []const u8) BitReader {
        return .{
            .data = data,
            .pos = 0,
            .buf = 0,
            .bits = 0,
            .eof = false,
        };
    }

    /// Read one byte from the underlying data, returning null on EOF.
    fn readByte(self: *BitReader) ?u8 {
        if (self.pos >= self.data.len) return null;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// Fill the internal buffer up to at least 24 bits (or until EOF / marker).
    fn fill(self: *BitReader) void {
        while (self.bits < 24 and !self.eof) {
            const c = self.readByte() orelse {
                self.eof = true;
                return;
            };
            if (c == 0xFF) {
                // Read the next byte to check for stuffing vs marker
                const next = self.readByte() orelse {
                    // 0xFF at end of data
                    self.eof = true;
                    return;
                };
                if (next == 0x00) {
                    // Stuffed byte: emit 0xFF
                    self.buf = (self.buf << 8) | 0xFF;
                    self.bits += 8;
                } else if (next >= 0xD0 and next <= 0xD7) {
                    // Restart marker: skip it
                    continue;
                } else {
                    // Another marker (e.g. EOI): stop reading
                    self.eof = true;
                    return;
                }
            } else {
                self.buf = (self.buf << 8) | @as(u32, c);
                self.bits += 8;
            }
        }
    }

    /// Read exactly `n` bits (n <= 24).
    pub fn readBits(self: *BitReader, n: u8) !u32 {
        std.debug.assert(n <= 24);
        if (n == 0) return 0;
        while (self.bits < n) {
            self.fill();
            if (self.eof and self.bits < n) {
                // Pad with zeros on EOF (match Go behavior)
                const have = self.buf & ((@as(u32, 1) << @intCast(self.bits)) - 1);
                const missing = n - self.bits;
                const result = have << @intCast(missing);
                self.bits = 0;
                return result;
            }
        }
        self.bits -= n;
        const mask: u32 = (@as(u32, 1) << @intCast(n)) - 1;
        return (self.buf >> @intCast(self.bits)) & mask;
    }

    /// Peek at the top `n` bits without consuming them.
    pub fn peekBits(self: *BitReader, n: u8) !u32 {
        std.debug.assert(n <= 24);
        while (self.bits < n) {
            self.fill();
            if (self.eof and self.bits < n) {
                const have = self.buf & ((@as(u32, 1) << @intCast(self.bits)) - 1);
                const missing = n - self.bits;
                return have << @intCast(missing);
            }
        }
        const mask: u32 = (@as(u32, 1) << @intCast(n)) - 1;
        return (self.buf >> @intCast(self.bits - n)) & mask;
    }

    /// Consume `n` bits that were previously peeked.
    pub fn consumeBits(self: *BitReader, n: u8) void {
        if (self.bits >= n) {
            self.bits -= n;
        } else {
            self.bits = 0;
        }
    }
};

// ---------------------------------------------------------------------------
// Bit writer (encoding)
// ---------------------------------------------------------------------------

/// Writes bits to a JPEG entropy-coded segment with byte stuffing.
pub const BitWriter = struct {
    output: std.array_list.AlignedManaged(u8, null),
    buf: u32,
    bits: u8,

    pub fn init(allocator: std.mem.Allocator) BitWriter {
        return .{
            .output = std.array_list.AlignedManaged(u8, null).init(allocator),
            .buf = 0,
            .bits = 0,
        };
    }

    pub fn deinit(self: *BitWriter) void {
        self.output.deinit();
    }

    /// Write `n` bits (MSB-first) from the low `n` bits of `val`.
    pub fn writeBits(self: *BitWriter, val: u32, n: u8) !void {
        const mask: u32 = if (n >= 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(n)) - 1;
        self.buf = (self.buf << @intCast(n)) | (val & mask);
        self.bits += n;

        while (self.bits >= 8) {
            self.bits -= 8;
            const byte_val: u8 = @intCast((self.buf >> @intCast(self.bits)) & 0xFF);
            try self.output.append(byte_val);
            if (byte_val == 0xFF) {
                try self.output.append(0x00); // byte stuffing
            }
        }
    }

    /// Flush any remaining bits, padding with 1-bits to a byte boundary.
    /// Returns the owned output slice. Caller owns the returned memory.
    pub fn flush(self: *BitWriter) ![]u8 {
        if (self.bits > 0) {
            const pad: u5 = @intCast(8 - self.bits);
            const padded = (self.buf << pad) | ((@as(u32, 1) << pad) - 1);
            const byte_val: u8 = @intCast(padded & 0xFF);
            try self.output.append(byte_val);
            if (byte_val == 0xFF) {
                try self.output.append(0x00);
            }
        }
        self.bits = 0;
        self.buf = 0;
        return try self.output.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// Huffman decode helper
// ---------------------------------------------------------------------------

/// Decode one Huffman symbol from the bit reader using `ht`.
pub fn decodeHuffman(br: *BitReader, ht: *const HuffmanTable) !u8 {
    // Fast path: 8-bit lookup
    const peek: u8 = @intCast(try br.peekBits(8));
    if (ht.fastLookup(peek)) |result| {
        br.consumeBits(result.size);
        return result.value;
    }

    // At EOF with only padding bits remaining: treat as SSSS=0 (no difference).
    // JPEG encoders pad the final byte with 1-bits, which may not form a valid
    // Huffman code. When the stream is exhausted, remaining bits are padding.
    if (br.eof) {
        br.consumeBits(br.bits);
        return 0;
    }

    // Slow path: decode bit by bit
    var code: u16 = 0;
    for (1..17) |size_usize| {
        const size: u8 = @intCast(size_usize);
        const bit = try br.readBits(1);
        code = (code << 1) | @as(u16, @intCast(bit));
        if (ht.decodeSlow(code, size)) |value| {
            return value;
        }
    }
    return error.InvalidData;
}

// ---------------------------------------------------------------------------
// Predictor
// ---------------------------------------------------------------------------

/// Compute the predicted pixel value using one of the 7 DPCM predictors.
///
/// Arguments:
/// - `curr_row`: current row decoded so far (index < x are valid)
/// - `prev_row`: previous row (fully decoded)
/// - `x`, `y`: pixel coordinates
/// - `predictor`: predictor selection (1-7)
/// - `precision`: bits per sample
///
/// Special cases:
/// - (0,0): predicts 2^(precision-1)
/// - first row (y==0): always uses Ra (left neighbor)
/// - first column (x==0): always uses Rb (above neighbor)
pub fn predict(
    curr_row: []const i32,
    prev_row: []const i32,
    x: usize,
    y: usize,
    predictor: u8,
    precision: u8,
) i32 {
    const ra: i32 = if (x > 0) curr_row[x - 1] else 0;
    const rb: i32 = if (y > 0) prev_row[x] else 0;
    const rc: i32 = if (x > 0 and y > 0) prev_row[x - 1] else 0;

    if (y == 0 and x == 0) {
        return @as(i32, 1) << @intCast(precision - 1);
    }
    if (y == 0) {
        return ra;
    }
    if (x == 0) {
        return rb;
    }

    return switch (predictor) {
        0 => 0,
        1 => ra,
        2 => rb,
        3 => rc,
        4 => ra + rb - rc,
        5 => ra + @divTrunc(rb - rc, 2),
        6 => rb + @divTrunc(ra - rc, 2),
        7 => @divTrunc(ra + rb, 2),
        else => ra,
    };
}

// ---------------------------------------------------------------------------
// Scan decode
// ---------------------------------------------------------------------------

/// Decode a full scan of JPEG Lossless data into a flat pixel buffer.
///
/// Returns a slice of u16 of length `width * height`. Caller owns the memory.
pub fn decodeScan(
    allocator: std.mem.Allocator,
    data: []const u8,
    ht: *const HuffmanTable,
    width: usize,
    height: usize,
    precision: u8,
    predictor_sel: u8,
    point_transform: u8,
) ![]u16 {
    const max_val: i32 = (@as(i32, 1) << @intCast(precision)) - 1;
    var br = BitReader.init(data);

    const pixels = try allocator.alloc(u16, width * height);
    errdefer allocator.free(pixels);

    const prev_row = try allocator.alloc(i32, width);
    defer allocator.free(prev_row);
    const curr_row = try allocator.alloc(i32, width);
    defer allocator.free(curr_row);
    @memset(prev_row, 0);
    @memset(curr_row, 0);

    for (0..height) |y| {
        for (0..width) |x| {
            // Decode Huffman symbol (SSSS = number of additional bits)
            const ssss = try decodeHuffman(&br, ht);

            // Read additional bits and sign-extend
            var diff: i32 = if (ssss > 0) blk: {
                const bits = try br.readBits(ssss);
                break :blk extend(bits, ssss);
            } else 0;

            // Apply point transform
            if (point_transform > 0) {
                diff = diff << @intCast(point_transform);
            }

            // Predict and reconstruct
            const pred = predict(curr_row, prev_row, x, y, predictor_sel, precision);
            const val = (pred + diff) & max_val;

            curr_row[x] = val;
            pixels[y * width + x] = @intCast(val);
        }
        @memcpy(prev_row, curr_row);
        @memset(curr_row, 0);
    }

    return pixels;
}

// ---------------------------------------------------------------------------
// Scan encode
// ---------------------------------------------------------------------------

/// Encode a full scan of pixel data into JPEG Lossless format.
///
/// Returns the entropy-coded segment data. Caller owns the returned memory.
pub fn encodeScan(
    allocator: std.mem.Allocator,
    ht: *const HuffmanTable,
    pixels: []const u16,
    width: usize,
    height: usize,
    precision: u8,
    predictor_sel: u8,
) ![]u8 {
    const max_val: i32 = (@as(i32, 1) << @intCast(precision)) - 1;
    var bw = BitWriter.init(allocator);
    defer bw.deinit();

    const prev_row = try allocator.alloc(i32, width);
    defer allocator.free(prev_row);
    const curr_row = try allocator.alloc(i32, width);
    defer allocator.free(curr_row);
    @memset(prev_row, 0);
    @memset(curr_row, 0);

    for (0..height) |y| {
        for (0..width) |x| {
            const val: i32 = @intCast(pixels[y * width + x]);
            curr_row[x] = val;

            const pred = predict(curr_row, prev_row, x, y, predictor_sel, precision);

            // Compute modular difference
            var diff = (val - pred) & max_val;
            if (diff > @divTrunc(max_val, 2)) {
                diff -= max_val + 1;
            }

            const ssss = categorize(diff);

            // Write Huffman code for SSSS
            if (ht.encodeSymbol(ssss)) |enc| {
                try bw.writeBits(@as(u32, enc.code), enc.size);
            }

            // Write additional bits
            if (ssss > 0) {
                const additional: u32 = if (diff < 0)
                    @intCast(diff + (@as(i32, 1) << @intCast(ssss)) - 1)
                else
                    @intCast(diff);
                try bw.writeBits(additional, ssss);
            }
        }
        @memcpy(prev_row, curr_row);
        @memset(curr_row, 0);
    }

    return bw.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "predict first pixel" {
    const curr = [_]i32{ 0, 0, 0, 0 };
    const prev = [_]i32{ 0, 0, 0, 0 };
    // First pixel predicts 2^(p-1)
    try std.testing.expectEqual(@as(i32, 128), predict(&curr, &prev, 0, 0, 1, 8));
    try std.testing.expectEqual(@as(i32, 32768), predict(&curr, &prev, 0, 0, 1, 16));
}

test "predict first row uses left" {
    const curr = [_]i32{ 100, 0, 0, 0 };
    const prev = [_]i32{ 0, 0, 0, 0 };
    // Regardless of predictor, first row uses Ra (left)
    for (1..8) |predictor| {
        try std.testing.expectEqual(@as(i32, 100), predict(&curr, &prev, 1, 0, @intCast(predictor), 8));
    }
}

test "predict first col uses above" {
    const curr = [_]i32{ 0, 0, 0, 0 };
    const prev = [_]i32{ 200, 0, 0, 0 };
    // Regardless of predictor, first column uses Rb (above)
    for (1..8) |predictor| {
        try std.testing.expectEqual(@as(i32, 200), predict(&curr, &prev, 0, 1, @intCast(predictor), 8));
    }
}

test "predict all seven" {
    // Interior pixel: Ra=10, Rb=20, Rc=5
    const curr = [_]i32{ 10, 0 };
    const prev = [_]i32{ 5, 20 };
    const x: usize = 1;
    const y: usize = 1;

    try std.testing.expectEqual(@as(i32, 10), predict(&curr, &prev, x, y, 1, 8)); // Ra
    try std.testing.expectEqual(@as(i32, 20), predict(&curr, &prev, x, y, 2, 8)); // Rb
    try std.testing.expectEqual(@as(i32, 5), predict(&curr, &prev, x, y, 3, 8)); // Rc
    try std.testing.expectEqual(@as(i32, 25), predict(&curr, &prev, x, y, 4, 8)); // Ra+Rb-Rc
    try std.testing.expectEqual(@as(i32, 17), predict(&curr, &prev, x, y, 5, 8)); // Ra+(Rb-Rc)/2
    try std.testing.expectEqual(@as(i32, 22), predict(&curr, &prev, x, y, 6, 8)); // Rb+(Ra-Rc)/2
    try std.testing.expectEqual(@as(i32, 15), predict(&curr, &prev, x, y, 7, 8)); // (Ra+Rb)/2
}

test "bit writer reader roundtrip" {
    const allocator = std.testing.allocator;

    var bw = BitWriter.init(allocator);
    defer bw.deinit();
    try bw.writeBits(0b101, 3);
    try bw.writeBits(0b1100, 4);
    try bw.writeBits(0b1, 1); // byte boundary: 0b10111001 = 0xB9
    try bw.writeBits(0xFF, 8); // should be byte-stuffed
    const buf = try bw.flush();
    defer allocator.free(buf);

    var br = BitReader.init(buf);
    try std.testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try std.testing.expectEqual(@as(u32, 0b1100), try br.readBits(4));
    try std.testing.expectEqual(@as(u32, 0b1), try br.readBits(1));
    try std.testing.expectEqual(@as(u32, 0xFF), try br.readBits(8));
}

test "bit writer byte stuffing" {
    const allocator = std.testing.allocator;

    var bw = BitWriter.init(allocator);
    defer bw.deinit();
    try bw.writeBits(0xFF, 8);
    const buf = try bw.flush();
    defer allocator.free(buf);

    // Should contain 0xFF 0x00 (stuffed) then padding byte
    try std.testing.expect(buf.len >= 2);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
}

test "scan roundtrip small 8bit" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    const pixels = [_]u16{ 100, 102, 104, 103, 101, 105, 108, 107, 106 };
    const w: usize = 3;
    const h: usize = 3;

    const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 8, 1);
    defer allocator.free(encoded);

    const decoded = try decodeScan(allocator, encoded, &ht, w, h, 8, 1, 0);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u16, &pixels, decoded);
}

test "scan roundtrip 16bit" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    const pixels = [_]u16{ 1000, 1002, 1005, 1003, 1001, 1006, 1010, 1008, 1007 };
    const w: usize = 3;
    const h: usize = 3;

    const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 16, 1);
    defer allocator.free(encoded);

    const decoded = try decodeScan(allocator, encoded, &ht, w, h, 16, 1, 0);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u16, &pixels, decoded);
}

test "scan roundtrip all predictors" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    // A 4x4 image with varying values to exercise all neighbors
    const pixels = [_]u16{
        100, 105, 110, 108,
        102, 107, 112, 109,
        104, 108, 115, 111,
        103, 106, 113, 110,
    };
    const w: usize = 4;
    const h: usize = 4;

    for (1..8) |predictor_sel| {
        const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 16, @intCast(predictor_sel));
        defer allocator.free(encoded);

        const decoded = try decodeScan(allocator, encoded, &ht, w, h, 16, @intCast(predictor_sel), 0);
        defer allocator.free(decoded);

        try std.testing.expectEqualSlices(u16, &pixels, decoded);
    }
}

test "scan roundtrip constant image" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    const pixels = [_]u16{42} ** 16;
    const w: usize = 4;
    const h: usize = 4;

    const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 16, 1);
    defer allocator.free(encoded);

    const decoded = try decodeScan(allocator, encoded, &ht, w, h, 16, 1, 0);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u16, &pixels, decoded);
}

test "scan roundtrip max values" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    // 16-bit max values
    const pixels = [_]u16{ 65535, 0, 65535, 0 };
    const w: usize = 2;
    const h: usize = 2;

    const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 16, 1);
    defer allocator.free(encoded);

    const decoded = try decodeScan(allocator, encoded, &ht, w, h, 16, 1, 0);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u16, &pixels, decoded);
}

test "scan roundtrip single pixel" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    const pixels = [_]u16{12345};
    const w: usize = 1;
    const h: usize = 1;

    const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 16, 1);
    defer allocator.free(encoded);

    const decoded = try decodeScan(allocator, encoded, &ht, w, h, 16, 1, 0);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u16, &pixels, decoded);
}

test "scan roundtrip single row" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    var pixels: [100]u16 = undefined;
    for (0..100) |i| {
        pixels[i] = @intCast(i);
    }
    const w: usize = 100;
    const h: usize = 1;

    const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 16, 1);
    defer allocator.free(encoded);

    const decoded = try decodeScan(allocator, encoded, &ht, w, h, 16, 1, 0);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u16, &pixels, decoded);
}

test "scan roundtrip single column" {
    const allocator = std.testing.allocator;
    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    var pixels: [100]u16 = undefined;
    for (0..100) |i| {
        pixels[i] = @intCast(i);
    }
    const w: usize = 1;
    const h: usize = 100;

    const encoded = try encodeScan(allocator, &ht, &pixels, w, h, 16, 1);
    defer allocator.free(encoded);

    const decoded = try decodeScan(allocator, encoded, &ht, w, h, 16, 1, 0);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u16, &pixels, decoded);
}
