//! Scan data parsing and writing for JPEG Lossless.
//!
//! Handles bit-level I/O with JPEG byte stuffing (0xFF -> 0xFF 0x00),
//! Huffman symbol decoding, DPCM predictor selection (1-7), and the
//! overall scan encode/decode loops.

const std = @import("std");
const Allocator = std.mem.Allocator;
const huffman = @import("huffman.zig");
const errors = @import("error.zig");

const HuffmanTable = huffman.HuffmanTable;
const Diagnostics = errors.Diagnostics;

/// Errors from entropy-coded scan processing. `UnexpectedEof` means the entropy
/// stream ended prematurely (the caller maps it to `CodecError.Truncated`).
pub const ScanError = error{ UnexpectedEof, InvalidData, OutOfMemory };

// ---------------------------------------------------------------------------
// Bit reader (decoding)
// ---------------------------------------------------------------------------

/// Reads bits from a JPEG entropy-coded segment held in memory, handling byte
/// stuffing. Never reads past `data`.
pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    buf: u32 = 0,
    bits: u8 = 0,
    eof: bool = false,
    /// The most recent marker byte (second byte of an `0xFF Mn` pair) that
    /// `fill` stopped at without consuming as entropy data. `fill` never
    /// silently skips a marker; restart handling inspects and clears this.
    pending_marker: ?u8 = null,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    fn nextByte(self: *BitReader) ?u8 {
        if (self.pos >= self.data.len) return null;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// Fill the internal buffer up to at least 24 bits (or until end / marker).
    ///
    /// On ANY marker (`0xFF` followed by a non-`0x00` byte, including RSTn) the
    /// fill stops, records the marker byte in `pending_marker`, and sets `eof` so
    /// bit-consuming paths report exhaustion. It never continues past a marker.
    fn fill(self: *BitReader) void {
        while (self.bits < 24 and !self.eof) {
            const c = self.nextByte() orelse {
                self.eof = true;
                return;
            };
            if (c == 0xFF) {
                const next = self.nextByte() orelse {
                    self.eof = true;
                    return;
                };
                if (next == 0x00) {
                    self.buf = (self.buf << 8) | 0xFF;
                    self.bits += 8;
                } else {
                    self.pending_marker = next;
                    self.eof = true;
                    return;
                }
            } else {
                self.buf = (self.buf << 8) | c;
                self.bits += 8;
            }
        }
    }

    /// Consume a restart marker at an interval boundary (T.81 H.1.1 / B.2.1).
    ///
    /// Discards buffered bits back to a byte boundary, then requires the next
    /// marker to be `RSTn` with `n == expected_index`. The marker may already
    /// have been seen by `fill` or still be unread in the data.
    fn readRestart(self: *BitReader, expected_index: u8, diag: ?*Diagnostics) ScanError!void {
        self.buf = 0;
        self.bits = 0;

        const marker: u8 = if (self.pending_marker) |m| blk: {
            self.pending_marker = null;
            break :blk m;
        } else blk: {
            const b = self.nextByte() orelse
                return errors.invalidData(diag, "expected restart marker (H.1.1), got end of scan data");
            if (b != 0xFF)
                return errors.invalidData(diag, "expected restart marker prefix 0xFF (H.1.1)");
            while (true) {
                const m = self.nextByte() orelse
                    return errors.invalidData(diag, "truncated restart marker (H.1.1)");
                if (m != 0xFF) break :blk m;
            }
        };

        if (marker != 0xD0 + expected_index)
            return errors.invalidData(diag, "restart marker out of order (H.1.1)");

        self.eof = false;
    }

    /// True when no more real entropy bits are available: the buffer is empty and
    /// the data is exhausted or stopped at a marker.
    fn atEnd(self: *BitReader) bool {
        if (self.bits == 0 and !self.eof) self.fill();
        return self.bits == 0 and self.eof;
    }

    /// Read exactly `n` bits (n <= 24).
    pub fn readBits(self: *BitReader, n: u8) ScanError!u32 {
        std.debug.assert(n <= 24);
        if (n == 0) return 0;
        while (self.bits < n) {
            self.fill();
            if (self.eof and self.bits < n) return error.UnexpectedEof;
        }
        self.bits -= n;
        const mask = (@as(u32, 1) << @intCast(n)) - 1;
        return (self.buf >> @intCast(self.bits)) & mask;
    }

    /// Peek at the top `n` bits without consuming them; zero-pads past the end.
    pub fn peekBits(self: *BitReader, n: u8) u32 {
        std.debug.assert(n <= 24);
        while (self.bits < n) {
            self.fill();
            if (self.eof and self.bits < n) {
                const have = self.buf & ((@as(u32, 1) << @intCast(self.bits)) - 1);
                const missing: u5 = @intCast(n - self.bits);
                return have << missing;
            }
        }
        const mask = (@as(u32, 1) << @intCast(n)) - 1;
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

/// Writes bits to a JPEG entropy-coded segment with byte stuffing, appending to
/// a caller-owned list.
pub const BitWriter = struct {
    out: *std.ArrayList(u8),
    allocator: Allocator,
    buf: u32 = 0,
    bits: u8 = 0,

    pub fn init(allocator: Allocator, out: *std.ArrayList(u8)) BitWriter {
        return .{ .out = out, .allocator = allocator };
    }

    fn emit(self: *BitWriter, byte_val: u8) Allocator.Error!void {
        try self.out.append(self.allocator, byte_val);
        if (byte_val == 0xFF) try self.out.append(self.allocator, 0x00); // stuffing
    }

    /// Write `n` bits (MSB-first) from the low `n` bits of `val` (n <= 16).
    pub fn writeBits(self: *BitWriter, val: u32, n: u8) Allocator.Error!void {
        std.debug.assert(n <= 16);
        const mask = (@as(u32, 1) << @intCast(n)) - 1;
        self.buf = (self.buf << @intCast(n)) | (val & mask);
        self.bits += n;
        while (self.bits >= 8) {
            self.bits -= 8;
            try self.emit(@truncate(self.buf >> @intCast(self.bits)));
        }
    }

    /// Pad the current partial byte with 1-bits to the next byte boundary and
    /// emit it (T.81 B.1.1.5). A padded `0xFF` is still stuffed. No-op when
    /// already aligned.
    pub fn padAndAlign(self: *BitWriter) Allocator.Error!void {
        if (self.bits > 0) {
            const pad: u5 = @intCast(8 - self.bits);
            const padded = (self.buf << pad) | ((@as(u32, 1) << pad) - 1);
            try self.emit(@truncate(padded));
            self.bits = 0;
            self.buf = 0;
        }
    }

    /// Write restart marker `RSTn` (`0xFF 0xD0+index`) at an interval boundary.
    /// Pads/aligns first; the marker bytes are written raw (never stuffed).
    pub fn writeRestart(self: *BitWriter, index: u8) Allocator.Error!void {
        try self.padAndAlign();
        try self.out.appendSlice(self.allocator, &.{ 0xFF, 0xD0 + index });
    }

    /// Flush remaining bits, padding with 1-bits to a byte boundary.
    pub fn flush(self: *BitWriter) Allocator.Error!void {
        try self.padAndAlign();
    }
};

// ---------------------------------------------------------------------------
// Huffman decode helper
// ---------------------------------------------------------------------------

/// Decode one Huffman symbol from the bit reader using `ht`.
pub fn decodeHuffman(br: *BitReader, ht: *const HuffmanTable) ScanError!u8 {
    // A genuinely exhausted entropy stream must not be decoded as a run of SSSS=0
    // symbols (that would fabricate a full-size but wrong image).
    if (br.atEnd()) return error.UnexpectedEof;

    // Fast path: 8-bit lookup. Resolves any code of length <= 8 even when the
    // buffer is short (peek zero-pads beyond the end).
    const peek: u8 = @intCast(br.peekBits(8));
    if (ht.fastLookup(peek)) |e| {
        // A match that consumed more bits than are buffered at the end relied on
        // zero-padding past the data: that is truncation.
        if (br.eof and e.size > br.bits) return error.UnexpectedEof;
        br.consumeBits(e.size);
        return e.value;
    }

    // Slow path: decode bit by bit (codes 9..=16 bits, e.g. the SSSS=16 code).
    var code: u16 = 0;
    var size: u8 = 1;
    while (size <= 16) : (size += 1) {
        const bit = try br.readBits(1);
        code = (code << 1) | @as(u16, @intCast(bit));
        if (ht.decodeSlow(code, size)) |v| return v;
    }
    return error.InvalidData;
}

// ---------------------------------------------------------------------------
// Predictor
// ---------------------------------------------------------------------------

/// Compute the predicted sample using one of the 7 DPCM predictors (T.81 Table H.1).
///
/// - `curr_row`: current row decoded so far (indices < x are valid)
/// - `prev_row`: previous row (fully decoded)
/// - `first_line`: true for the top row AND for the first row after a restart
///   (T.81 H.1.2.1: prediction restarts exactly as at scan start)
///
/// Special cases: first line/first column predicts 2^(precision-1); remaining
/// first-line samples use Ra; remaining first-column samples use Rb.
///
/// The `/2` in predictors 5 and 6 is an arithmetic shift (`>> 1`, floor), as
/// T.81 H.1.2.1 and libjpeg-turbo define it. This differs from truncating
/// division for negative odd differences.
pub fn predict(
    curr_row: []const i32,
    prev_row: []const i32,
    x: usize,
    first_line: bool,
    predictor: u8,
    precision: u8,
) i32 {
    const ra: i32 = if (x > 0) curr_row[x - 1] else 0;
    const rb: i32 = if (!first_line) prev_row[x] else 0;
    const rc: i32 = if (x > 0 and !first_line) prev_row[x - 1] else 0;

    if (first_line and x == 0) return @as(i32, 1) << @intCast(precision - 1);
    if (first_line) return ra;
    if (x == 0) return rb;

    return switch (predictor) {
        0 => 0,
        1 => ra,
        2 => rb,
        3 => rc,
        4 => ra + rb - rc,
        5 => ra + ((rb - rc) >> 1),
        6 => rb + ((ra - rc) >> 1),
        7 => (ra + rb) >> 1,
        else => ra,
    };
}

// ---------------------------------------------------------------------------
// Scan decode
// ---------------------------------------------------------------------------

/// Decode a full scan of JPEG Lossless data into a flat pixel buffer.
///
/// `restart_interval` is the DRI value in MCUs (== samples for non-interleaved
/// single-component lossless); 0 disables restarts. Per T.81 H.1.1 it must be a
/// multiple of `width` (validated by the caller), so restarts fall on row
/// boundaries.
///
/// Requires `2 <= precision <= 16`, `point_transform < precision`,
/// `1 <= predictor <= 7`, `width > 0`. Returns a `[]u16` of length `width * height`
/// owned by the caller.
pub fn decodeScan(
    allocator: Allocator,
    data: []const u8,
    ht: *const HuffmanTable,
    width: usize,
    height: usize,
    precision: u8,
    predictor: u8,
    point_transform: u8,
    restart_interval: usize,
    diag: ?*Diagnostics,
) ScanError![]u16 {
    const num_pixels = std.math.mul(usize, width, height) catch return error.InvalidData;
    // Every sample costs at least one entropy bit (shortest Huffman code is 1
    // bit), so a stream with fewer bits than samples is truncated. Checking this
    // before allocating bounds memory by the input size, not the declared dims.
    if (data.len < (num_pixels + 7) / 8) return error.UnexpectedEof;

    // The codec works in the reduced domain P' = P - Pt; each reconstructed
    // sample is shifted left by Pt on store.
    const p_prime = precision - point_transform;
    const max_val: i32 = (@as(i32, 1) << @intCast(p_prime)) - 1;
    const pt: u5 = @intCast(point_transform);
    var br = BitReader.init(data);

    const pixels = try allocator.alloc(u16, num_pixels);
    errdefer allocator.free(pixels);
    const rows = try allocator.alloc(i32, 2 * width);
    defer allocator.free(rows);
    @memset(rows, 0);
    var prev_row = rows[0..width];
    var curr_row = rows[width..];
    var restart_index: u8 = 0;

    for (0..height) |y| {
        // Row-aligned restart boundary (H.1.1): every `restart_interval` samples.
        const restart_boundary = restart_interval > 0 and (y * width) % restart_interval == 0;
        if (restart_boundary and y > 0) {
            try br.readRestart(restart_index, diag);
            restart_index = (restart_index + 1) % 8;
        }
        // H.1.2.1: prediction restarts as at scan start.
        const first_line = y == 0 or restart_boundary;

        for (0..width) |x| {
            const ssss = decodeHuffman(&br, ht) catch |e| switch (e) {
                error.UnexpectedEof => {
                    // A reader that stopped at RSTn while no DRI was declared is
                    // an illegal restart (H.1.1), not truncation.
                    if (restart_interval == 0) {
                        if (br.pending_marker) |m| {
                            if (m >= 0xD0 and m <= 0xD7)
                                return errors.invalidData(diag, "unexpected restart marker without DRI (H.1.1)");
                        }
                    }
                    return e;
                },
                else => return e,
            };

            // T.81 permits SSSS only in 0..=16; a corrupted DHT can map a valid
            // code to a larger symbol, which must be rejected before readBits.
            if (ssss > 16)
                return errors.invalidData(diag, "SSSS category out of range (T.81 allows 0..=16)");

            // SSSS==16 is the T.81 H.1.2.2 / Table H.2 special case: the modular
            // difference 32768 carries NO appended bits, and is only legal when
            // P' == 16.
            const diff: i32 = if (ssss == 16) blk: {
                if (p_prime < 16)
                    return errors.invalidData(diag, "SSSS category 16 is only valid at P' == 16 (H.1.2.2)");
                break :blk 32768;
            } else if (ssss > 0) blk: {
                const b = try br.readBits(ssss);
                break :blk huffman.extend(b, ssss);
            } else 0;

            const pred = predict(curr_row, prev_row, x, first_line, predictor, p_prime);
            const val = (pred + diff) & max_val;

            curr_row[x] = val;
            pixels[y * width + x] = @intCast(val << pt);
        }
        std.mem.swap([]i32, &prev_row, &curr_row);
        @memset(curr_row, 0);
    }

    // Without a DRI a restart marker is illegal (H.1.1).
    if (restart_interval == 0) {
        if (br.pending_marker) |m| {
            if (m >= 0xD0 and m <= 0xD7)
                return errors.invalidData(diag, "unexpected restart marker without DRI (H.1.1)");
        }
    }

    return pixels;
}

// ---------------------------------------------------------------------------
// Scan encode
// ---------------------------------------------------------------------------

/// Encode a full scan of pixel data, appending the entropy-coded segment (no
/// markers other than RSTn) to `out`.
///
/// Requires validated parameters: `2 <= precision <= 16`, `point_transform <
/// precision`, `1 <= predictor <= 7`, `pixels.len == width * height`.
pub fn encodeScan(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    ht: *const HuffmanTable,
    pixels: []const u16,
    width: usize,
    height: usize,
    precision: u8,
    predictor: u8,
    point_transform: u8,
    restart_interval_rows: usize,
) Allocator.Error!void {
    // Operate entirely in the reduced domain P' = P - Pt.
    const p_prime = precision - point_transform;
    const max_val: i32 = (@as(i32, 1) << @intCast(p_prime)) - 1;
    const pt: u4 = @intCast(point_transform);
    var bw = BitWriter.init(allocator, out);

    const rows = try allocator.alloc(i32, 2 * width);
    defer allocator.free(rows);
    @memset(rows, 0);
    var prev_row = rows[0..width];
    var curr_row = rows[width..];
    var restart_index: u8 = 0;

    for (0..height) |y| {
        // Emit RSTn before every `restart_interval_rows` rows, never after the last.
        const restart_boundary = restart_interval_rows > 0 and y % restart_interval_rows == 0;
        if (restart_boundary and y > 0) {
            try bw.writeRestart(restart_index);
            restart_index = (restart_index + 1) % 8;
        }
        const first_line = y == 0 or restart_boundary;

        for (0..width) |x| {
            const val: i32 = pixels[y * width + x] >> pt;
            curr_row[x] = val;

            const pred = predict(curr_row, prev_row, x, first_line, predictor, p_prime);

            // Modular difference
            var diff = (val - pred) & max_val;
            if (diff > @divTrunc(max_val, 2)) diff -= max_val + 1;

            const ssss = huffman.categorize(diff);
            if (ht.encodeSymbol(ssss)) |cs| try bw.writeBits(cs.code, cs.size);

            // SSSS==16 (modular difference 32768) carries no appended bits.
            if (ssss > 0 and ssss < 16) {
                const additional: u32 = if (diff < 0)
                    @intCast(diff + (@as(i32, 1) << @intCast(ssss)) - 1)
                else
                    @intCast(diff);
                try bw.writeBits(additional, ssss);
            }
        }
        std.mem.swap([]i32, &prev_row, &curr_row);
        @memset(curr_row, 0);
    }

    try bw.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn encodeScanOwned(
    ht: *const HuffmanTable,
    pixels: []const u16,
    w: usize,
    h: usize,
    precision: u8,
    predictor: u8,
    pt: u8,
    rows: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try encodeScan(testing.allocator, &out, ht, pixels, w, h, precision, predictor, pt, rows);
    return out.toOwnedSlice(testing.allocator);
}

/// Encode then decode, comparing against `expected`.
fn expectScanRoundtrip(
    ht: *const HuffmanTable,
    pixels: []const u16,
    expected: []const u16,
    w: usize,
    h: usize,
    precision: u8,
    predictor: u8,
    pt: u8,
    rows: usize,
) !void {
    const encoded = try encodeScanOwned(ht, pixels, w, h, precision, predictor, pt, rows);
    defer testing.allocator.free(encoded);
    const decoded = try decodeScan(testing.allocator, encoded, ht, w, h, precision, predictor, pt, w * rows, null);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u16, expected, decoded);
}

test "predict first pixel" {
    const curr = [_]i32{0} ** 4;
    const prev = [_]i32{0} ** 4;
    try testing.expectEqual(@as(i32, 128), predict(&curr, &prev, 0, true, 1, 8));
    try testing.expectEqual(@as(i32, 32768), predict(&curr, &prev, 0, true, 1, 16));
}

test "predict first row uses left" {
    const curr = [_]i32{ 100, 0, 0, 0 };
    const prev = [_]i32{0} ** 4;
    var p: u8 = 1;
    while (p <= 7) : (p += 1) try testing.expectEqual(@as(i32, 100), predict(&curr, &prev, 1, true, p, 8));
}

test "predict first col uses above" {
    const curr = [_]i32{0} ** 4;
    const prev = [_]i32{ 200, 0, 0, 0 };
    var p: u8 = 1;
    while (p <= 7) : (p += 1) try testing.expectEqual(@as(i32, 200), predict(&curr, &prev, 0, false, p, 8));
}

test "predict all seven" {
    // Interior pixel: Ra=10, Rb=20, Rc=5
    const curr = [_]i32{ 10, 0 };
    const prev = [_]i32{ 5, 20 };
    try testing.expectEqual(@as(i32, 10), predict(&curr, &prev, 1, false, 1, 8));
    try testing.expectEqual(@as(i32, 20), predict(&curr, &prev, 1, false, 2, 8));
    try testing.expectEqual(@as(i32, 5), predict(&curr, &prev, 1, false, 3, 8));
    try testing.expectEqual(@as(i32, 25), predict(&curr, &prev, 1, false, 4, 8));
    try testing.expectEqual(@as(i32, 17), predict(&curr, &prev, 1, false, 5, 8));
    try testing.expectEqual(@as(i32, 22), predict(&curr, &prev, 1, false, 6, 8));
    try testing.expectEqual(@as(i32, 15), predict(&curr, &prev, 1, false, 7, 8));
}

test "predict 5 and 6 floor for negative odd differences (T.81 >> 1)" {
    // Ra=10, Rb=20, Rc=33: Rb-Rc = -13 -> floor(-6.5) = -7; Ra-Rc = -23 -> -12.
    const curr = [_]i32{ 10, 0 };
    const prev = [_]i32{ 33, 20 };
    try testing.expectEqual(@as(i32, 3), predict(&curr, &prev, 1, false, 5, 8)); // 10 + (-7)
    try testing.expectEqual(@as(i32, 8), predict(&curr, &prev, 1, false, 6, 8)); // 20 + (-12)
}

test "bit writer reader roundtrip" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var bw = BitWriter.init(testing.allocator, &buf);
    try bw.writeBits(0b101, 3);
    try bw.writeBits(0b1100, 4);
    try bw.writeBits(0b1, 1); // byte boundary: 0b10111001 = 0xB9
    try bw.writeBits(0xFF, 8); // byte-stuffed
    try bw.flush();

    var br = BitReader.init(buf.items);
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try testing.expectEqual(@as(u32, 0b1100), try br.readBits(4));
    try testing.expectEqual(@as(u32, 0b1), try br.readBits(1));
    try testing.expectEqual(@as(u32, 0xFF), try br.readBits(8));
}

test "bit writer byte stuffing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var bw = BitWriter.init(testing.allocator, &buf);
    try bw.writeBits(0xFF, 8);
    try bw.flush();
    try testing.expect(buf.items.len >= 2);
    try testing.expectEqual(@as(u8, 0xFF), buf.items[0]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[1]);
}

test "scan roundtrip small 8bit" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 100, 102, 104, 103, 101, 105, 108, 107, 106 };
    try expectScanRoundtrip(&ht, &px, &px, 3, 3, 8, 1, 0, 0);
}

test "scan roundtrip 16bit" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 1000, 1002, 1005, 1003, 1001, 1006, 1010, 1008, 1007 };
    try expectScanRoundtrip(&ht, &px, &px, 3, 3, 16, 1, 0, 0);
}

test "scan roundtrip all predictors" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 100, 105, 110, 108, 102, 107, 112, 109, 104, 108, 115, 111, 103, 106, 113, 110 };
    var p: u8 = 1;
    while (p <= 7) : (p += 1) try expectScanRoundtrip(&ht, &px, &px, 4, 4, 16, p, 0, 0);
}

test "scan roundtrip constant image" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{42} ** 16;
    try expectScanRoundtrip(&ht, &px, &px, 4, 4, 16, 1, 0, 0);
}

test "scan roundtrip max values" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 65535, 0, 65535, 0 };
    try expectScanRoundtrip(&ht, &px, &px, 2, 2, 16, 1, 0, 0);
}

test "scan roundtrip single pixel" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{12345};
    try expectScanRoundtrip(&ht, &px, &px, 1, 1, 16, 1, 0, 0);
}

test "scan roundtrip single row" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    var px: [100]u16 = undefined;
    for (&px, 0..) |*v, i| v.* = @intCast(i);
    try expectScanRoundtrip(&ht, &px, &px, 100, 1, 16, 1, 0, 0);
}

test "scan roundtrip single column" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    var px: [100]u16 = undefined;
    for (&px, 0..) |*v, i| v.* = @intCast(i);
    try expectScanRoundtrip(&ht, &px, &px, 1, 100, 16, 1, 0, 0);
}

// SSSS = 16 (T.81 H.1.2.2 / Table H.2): the modular difference 32768 is coded as
// category 16 with NO appended bits.
test "ssss16 emits no appended bits exact vector" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{0};
    const encoded = try encodeScanOwned(&ht, &px, 1, 1, 16, 1, 0, 0);
    defer testing.allocator.free(encoded);
    // Category-16 code is 14 bits (0b11111111111110); flush pads with 1s.
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0xFB }, encoded);

    const decoded = try decodeScan(testing.allocator, encoded, &ht, 1, 1, 16, 1, 0, 0, null);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u16, &px, decoded);
}

test "ssss16 rejected below full precision" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const encoded = try encodeScanOwned(&ht, &[_]u16{0}, 1, 1, 16, 1, 0, 0);
    defer testing.allocator.free(encoded);
    try testing.expectError(error.InvalidData, decodeScan(testing.allocator, encoded, &ht, 1, 1, 8, 1, 0, 0, null));
}

test "ssss16 roundtrip boundary values" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 0, 32768, 65535, 32767, 0, 32768 };
    try expectScanRoundtrip(&ht, &px, &px, 3, 2, 16, 1, 0, 0);
}

test "scan point transform reduced domain" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 0, 4, 8, 12, 2044, 4092, 100, 2048, 4000 };
    var expected: [9]u16 = undefined;
    for (px, 0..) |p, i| expected[i] = (p >> 2) << 2;
    try expectScanRoundtrip(&ht, &px, &expected, 3, 3, 12, 1, 2, 0);
}

test "scan restart roundtrip and reset" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 10, 250, 240, 5, 128, 200, 7, 190 };
    for (1..5) |rows| try expectScanRoundtrip(&ht, &px, &px, 2, 4, 8, 2, 0, rows);
}

test "scan restart first sample predicts half range" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 250, 3 };
    const encoded = try encodeScanOwned(&ht, &px, 1, 2, 8, 1, 0, 1);
    defer testing.allocator.free(encoded);
    var found = false;
    for (0..encoded.len - 1) |i| {
        if (encoded[i] == 0xFF and encoded[i + 1] == 0xD0) found = true;
    }
    try testing.expect(found);
    const decoded = try decodeScan(testing.allocator, encoded, &ht, 1, 2, 8, 1, 0, 1, null);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u16, &px, decoded);
}

test "scan point transform property all predictors" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const px = [_]u16{ 1000, 1005, 1010, 1008, 1002, 1007, 1012, 1009, 1004, 1008, 1015, 1011, 1003, 1006, 1013, 1010 };
    var p: u8 = 1;
    while (p <= 7) : (p += 1) {
        for ([_]u8{ 0, 2 }) |pt| {
            var expected: [16]u16 = undefined;
            for (px, 0..) |v, i| expected[i] = (v >> @intCast(pt)) << @intCast(pt);
            try expectScanRoundtrip(&ht, &px, &expected, 4, 4, 12, p, pt, 0);
        }
    }
}

test "decode scan rejects declared size beyond input without allocating" {
    var ht = try huffman.buildDefaultTable(testing.allocator);
    defer ht.deinit();
    // 65535 x 65535 samples from 2 bytes: must fail before any pixel allocation.
    try testing.expectError(error.UnexpectedEof, decodeScan(testing.allocator, &.{ 0x00, 0x00 }, &ht, 65535, 65535, 16, 1, 0, 0, null));
}
