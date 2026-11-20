//! Full JPEG Lossless decoding pipeline.
//!
//! Parses a complete JPEG Lossless bitstream (SOI through EOI), extracting the
//! frame header (SOF3), Huffman tables (DHT), restart interval (DRI) and scan
//! parameters (SOS), then decodes the entropy-coded scan with DPCM prediction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const huffman = @import("huffman.zig");
const scan = @import("scan.zig");
const errors = @import("error.zig");
const encode_mod = @import("encode.zig");

const HuffmanTable = huffman.HuffmanTable;
const CodecError = errors.CodecError;
const Diagnostics = errors.Diagnostics;

// ---------------------------------------------------------------------------
// JPEG markers
// ---------------------------------------------------------------------------

const MARKER_SOI: u16 = 0xFFD8;
const MARKER_EOI: u16 = 0xFFD9;
const MARKER_SOF3: u16 = 0xFFC3;
const MARKER_DHT: u16 = 0xFFC4;
const MARKER_SOS: u16 = 0xFFDA;
const MARKER_DRI: u16 = 0xFFDD;

/// Hard cap on the number of pixels a single decode will allocate for. Guards
/// against corrupted SOF3 dimensions forcing an unbounded allocation.
const MAX_PIXELS: usize = 1 << 28;

/// Result of a successful decode. Free with `deinit`.
pub const DecodeResult = struct {
    pixels: []u16,
    width: u32,
    height: u32,

    pub fn deinit(self: DecodeResult, allocator: Allocator) void {
        allocator.free(self.pixels);
    }
};

// ---------------------------------------------------------------------------
// Decoder state
// ---------------------------------------------------------------------------

/// Byte cursor over the input; reads never go past the end.
const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn readExact(self: *Cursor, n: usize) ?[]const u8 {
        if (n > self.data.len - self.pos) return null;
        const s = self.data[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn readU16(self: *Cursor) ?u16 {
        const s = self.readExact(2) orelse return null;
        return std.mem.readInt(u16, s[0..2], .big);
    }
};

/// Internal decoder state accumulated while parsing JPEG markers.
const Decoder = struct {
    allocator: Allocator,
    diag: ?*Diagnostics,
    precision: u8 = 0,
    height: u16 = 0,
    width: u16 = 0,
    comp_id: u8 = 0,
    /// Initially the SOF3 `Tq` byte; replaced by the SOS `Td` selector.
    comp_table_index: u8 = 0,
    dc_tables: [4]?HuffmanTable = .{ null, null, null, null },
    predictor: u8 = 1,
    point_transform: u8 = 0,
    restart_interval: u16 = 0,

    fn deinit(self: *Decoder) void {
        for (&self.dc_tables) |*t| {
            if (t.*) |*tbl| tbl.deinit();
        }
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Decode a JPEG Lossless bitstream into a 16-bit grayscale pixel buffer.
///
/// `width` and `height` are validated against the SOF3 frame header; the actual
/// dimensions come from the JPEG data itself. The caller owns the result.
pub fn decode(allocator: Allocator, data: []const u8, width: u32, height: u32) CodecError!DecodeResult {
    return decodeDiag(allocator, data, width, height, null);
}

/// Like `decode`, additionally filling `diag` (when non-null) with the details
/// of any returned error (parameter name, truncation offset, ...).
pub fn decodeDiag(
    allocator: Allocator,
    data: []const u8,
    width: u32,
    height: u32,
    diag: ?*Diagnostics,
) CodecError!DecodeResult {
    var cur = Cursor{ .data = data };
    var dec = Decoder{ .allocator = allocator, .diag = diag };
    defer dec.deinit();

    // Read SOI
    const soi = try readMarker(&cur, diag);
    if (soi != MARKER_SOI) return errors.invalidData(diag, "expected SOI marker 0xFFD8");

    // Parse markers until SOS
    while (true) {
        const marker = try readMarker(&cur, diag);
        switch (marker) {
            MARKER_SOF3 => try parseSof3(&cur, &dec),
            MARKER_DHT => try parseDht(&cur, &dec),
            MARKER_SOS => {
                try parseSos(&cur, &dec);
                break;
            },
            MARKER_DRI => try parseDri(&cur, &dec),
            MARKER_EOI => return errors.invalidData(diag, "unexpected EOI before scan data"),
            else => {
                // Any other SOFn/DAC marker (0xFFC0..=0xFFCF) is unsupported; APPn,
                // COM and unknown markers are skipped.
                if (marker >= 0xFFC0 and marker <= 0xFFCF)
                    return errors.unsupported(diag, "unsupported SOF marker");
                try skipMarkerData(&cur, diag);
            },
        }
    }

    // Validate dimensions
    const jpeg_w: u32 = dec.width;
    const jpeg_h: u32 = dec.height;
    if (jpeg_w != width or jpeg_h != height)
        return errors.dimensionMismatch(diag, @as(usize, width) * @as(usize, height), @as(usize, jpeg_w) * @as(usize, jpeg_h));

    // Guard against dimensions that would force an unbounded allocation in the
    // scan decoder, before any such allocation happens.
    const num_pixels = @as(usize, jpeg_w) * @as(usize, jpeg_h);
    if (num_pixels > MAX_PIXELS)
        return errors.invalidParameter(diag, "width*height", @intCast(num_pixels), "product <= 268435456 pixels (1<<28)");

    // Get Huffman table. An out-of-range index (e.g. a SOF3 component whose Tq
    // byte is >= 4) is a missing table, not an out-of-bounds access.
    const table_idx: usize = dec.comp_table_index;
    const ht: *const HuffmanTable = if (table_idx < dec.dc_tables.len)
        if (dec.dc_tables[table_idx]) |*t| t else return errors.invalidData(diag, "missing Huffman table")
    else
        return errors.invalidData(diag, "missing Huffman table");

    // Restart interval (DRI) validation. T.81 H.1.1: for a non-interleaved
    // single-component lossless scan 1 MCU = 1 sample, and Ri must be an integer
    // multiple of the samples-per-row (== width).
    const restart_interval: usize = dec.restart_interval;
    if (restart_interval != 0 and restart_interval % jpeg_w != 0)
        return errors.invalidData(diag, "restart interval is not a multiple of width (H.1.1)");

    // Decode the scan data (remaining bytes after the SOS header)
    const pixels = scan.decodeScan(
        allocator,
        data[cur.pos..],
        ht,
        jpeg_w,
        jpeg_h,
        dec.precision,
        dec.predictor,
        dec.point_transform,
        restart_interval,
        diag,
    ) catch |e| switch (e) {
        // A prematurely exhausted entropy stream maps to the dedicated Truncated
        // error so callers can distinguish truncation from malformed-scan errors.
        error.UnexpectedEof => return errors.truncated(diag, cur.pos, "entropy scan"),
        error.InvalidData => {
            if (diag) |d| {
                if (d.message.len == 0) d.message = "scan decode error";
            }
            return error.InvalidData;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{ .pixels = pixels, .width = jpeg_w, .height = jpeg_h };
}

// ---------------------------------------------------------------------------
// Marker parsing
// ---------------------------------------------------------------------------

/// Read a 2-byte JPEG marker, skipping any fill bytes (0xFF).
fn readMarker(cur: *Cursor, diag: ?*Diagnostics) CodecError!u16 {
    const buf = cur.readExact(2) orelse return errors.ioError(diag, "unexpected end of data reading marker");
    if (buf[0] != 0xFF) return errors.invalidData(diag, "expected marker prefix 0xFF");
    var lo = buf[1];
    while (lo == 0xFF) {
        const b = cur.readExact(1) orelse return errors.ioError(diag, "unexpected end of data reading marker");
        lo = b[0];
    }
    return 0xFF00 | @as(u16, lo);
}

/// Read the 2-byte marker data length and skip that many bytes. Skipping past the
/// end of input stops at the end silently; the next marker read then fails.
fn skipMarkerData(cur: *Cursor, diag: ?*Diagnostics) CodecError!void {
    const length: usize = cur.readU16() orelse return errors.ioError(diag, "unexpected end of data reading segment length");
    if (length < 2) return;
    cur.pos += @min(length - 2, cur.data.len - cur.pos);
}

/// Read a segment's length field and return its payload (length - 2 bytes).
fn readSegment(cur: *Cursor, diag: ?*Diagnostics, comptime name: []const u8) CodecError![]const u8 {
    const length: usize = cur.readU16() orelse return errors.ioError(diag, "unexpected end of data reading segment length");
    if (length < 2) return errors.invalidData(diag, name ++ " length too short");
    return cur.readExact(length - 2) orelse errors.ioError(diag, "unexpected end of data reading segment payload");
}

/// Parse SOF3 (Start of Frame - Lossless Huffman).
fn parseSof3(cur: *Cursor, dec: *Decoder) CodecError!void {
    const diag = dec.diag;
    const data = try readSegment(cur, diag, "SOF3");
    if (data.len < 6) return errors.invalidData(diag, "SOF3 payload too short for header");

    dec.precision = data[0];
    dec.height = std.mem.readInt(u16, data[1..3], .big);
    dec.width = std.mem.readInt(u16, data[3..5], .big);
    const components = data[5];

    // T.81 B.2.2: Y (lines) and X (samples/line) must be > 0. A zero dimension
    // yields an empty image and, with a DRI present, a division by zero in the
    // restart-interval validation.
    if (dec.width == 0 or dec.height == 0)
        return errors.invalidParameter(diag, "dimensions", 0, "width > 0 && height > 0");

    // T.81 B.2.2: sample precision P for lossless is 2..=16.
    if (dec.precision < 2 or dec.precision > 16)
        return errors.invalidParameter(diag, "precision", dec.precision, "2..=16");

    // This codec supports single-component (grayscale) frames only.
    if (components != 1)
        return errors.unsupported(diag, "SOF3 with multiple components; only single-component frames are supported");

    const offset = 6;
    if (offset + 2 >= data.len) return errors.invalidData(diag, "SOF3 payload too short for components");
    dec.comp_id = data[offset];
    dec.comp_table_index = data[offset + 2];
}

/// Parse DHT (Define Huffman Table).
fn parseDht(cur: *Cursor, dec: *Decoder) CodecError!void {
    const diag = dec.diag;
    const data = try readSegment(cur, diag, "DHT");

    var offset: usize = 0;
    while (offset < data.len) {
        const table_info = data[offset];
        const table_class = table_info >> 4; // 0 = DC
        const table_id: usize = table_info & 0x0F;
        offset += 1;

        if (table_class != 0) {
            // Lossless only uses DC tables; skip the AC table definition.
            var count: usize = 0;
            for (0..16) |i| {
                if (offset + i >= data.len) break;
                count += data[offset + i];
            }
            offset += 16 + count;
            continue;
        }

        if (table_id >= 4) return errors.invalidData(diag, "invalid Huffman table ID");

        // Read BITS[1..=16]
        var bits = [_]u8{0} ** 17;
        var total_codes: usize = 0;
        for (0..16) |i| {
            if (offset + i >= data.len) return errors.invalidData(diag, "DHT data truncated");
            bits[i + 1] = data[offset + i];
            total_codes += data[offset + i];
        }
        offset += 16;

        // Read HUFFVAL
        if (offset + total_codes > data.len) return errors.invalidData(diag, "DHT values truncated");
        const values = data[offset .. offset + total_codes];
        offset += total_codes;

        // Reject an oversubscribed (invalid) code assignment before building the
        // table (T.81 Annex C / Kraft inequality).
        if (!huffman.bitsValid(&bits)) return errors.invalidData(diag, "oversubscribed Huffman table (T.81 Annex C)");

        var table = HuffmanTable.fromBitsValues(dec.allocator, bits, values) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTable => return errors.invalidData(diag, "invalid Huffman table"),
        };
        errdefer table.deinit();
        if (dec.dc_tables[table_id]) |*old| old.deinit();
        dec.dc_tables[table_id] = table;
    }
}

/// Parse SOS (Start of Scan).
fn parseSos(cur: *Cursor, dec: *Decoder) CodecError!void {
    const diag = dec.diag;
    const data = try readSegment(cur, diag, "SOS");
    if (data.len == 0) return errors.invalidData(diag, "SOS payload empty");

    const num_components: usize = data[0];
    var offset: usize = 1;

    for (0..num_components) |_| {
        if (offset + 1 >= data.len) return errors.invalidData(diag, "SOS payload too short for component specs");
        const selector = data[offset];
        const table_mapping = data[offset + 1];
        offset += 2;

        // Td (high nibble) selects the DC Huffman table and indexes the 4-entry
        // table array (T.81 B.2.3: Td in 0..=3).
        const dc_selector = table_mapping >> 4;
        if (dc_selector >= dec.dc_tables.len)
            return errors.invalidParameter(diag, "dc_table_selector", dc_selector, "< 4");

        if (dec.comp_id == selector) dec.comp_table_index = dc_selector;
    }

    // Need three more bytes: Ss, Se, Ah|Al (T.81 B.2.3).
    if (offset + 2 >= data.len) return errors.invalidData(diag, "SOS payload too short for spectral selection");

    // Ss = predictor selection. Table B.3 restricts lossless Ss to 1..=7.
    dec.predictor = data[offset];
    offset += 1;
    if (dec.predictor < 1 or dec.predictor > 7)
        return errors.invalidParameter(diag, "predictor", dec.predictor, "1..=7");

    // Se must be 0 for lossless.
    const se = data[offset];
    offset += 1;
    if (se != 0) return errors.invalidParameter(diag, "Se", se, "0 (lossless)");

    // Ah (high nibble) must be 0; Al (low nibble) = Pt = point transform.
    const ah = data[offset] >> 4;
    const al = data[offset] & 0x0F;
    if (ah != 0) return errors.invalidParameter(diag, "Ah", ah, "0 (lossless)");
    // Pt must be strictly less than the sample precision (T.81 Table B.3).
    if (al >= dec.precision) return errors.invalidParameter(diag, "point_transform", al, "< sample precision");
    dec.point_transform = al;
}

/// Parse DRI (Define Restart Interval).
fn parseDri(cur: *Cursor, dec: *Decoder) CodecError!void {
    const buf = cur.readExact(4) orelse return errors.ioError(dec.diag, "unexpected end of data reading DRI");
    // buf[0..2] = length (always 4), buf[2..4] = restart interval
    dec.restart_interval = std.mem.readInt(u16, buf[2..4], .big);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Bytes = std.ArrayList(u8);

/// Decode `data` and require it to fail with exactly `expected`.
fn expectDecodeErr(expected: CodecError, data: []const u8, w: u32, h: u32, diag: ?*Diagnostics) !void {
    if (decodeDiag(testing.allocator, data, w, h, diag)) |r| {
        r.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |e| try testing.expectEqual(expected, e);
}

/// Decode `data` and require it to fail with any error.
fn expectDecodeFails(data: []const u8, w: u32, h: u32) !void {
    if (decode(testing.allocator, data, w, h)) |r| {
        r.deinit(testing.allocator);
        return error.TestExpectedError;
    } else |_| {}
}

fn expectDecodeParam(data: []const u8, w: u32, h: u32, name: []const u8) !void {
    var diag: Diagnostics = .{};
    try expectDecodeErr(error.InvalidParameter, data, w, h, &diag);
    try testing.expectEqualStrings(name, diag.parameter);
}

fn expectDecodeOk(data: []const u8, w: u32, h: u32, expected: []const u16) !void {
    const r = try decode(testing.allocator, data, w, h);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(w, r.width);
    try testing.expectEqual(h, r.height);
    try testing.expectEqualSlices(u16, expected, r.pixels);
}

fn encodeTest(pixels: []const u16, w: u32, h: u32) ![]u8 {
    return encode_mod.encode(testing.allocator, pixels, w, h);
}

test "decode minimal roundtrip" {
    const pixels = [_]u16{ 100, 200, 300, 400 };
    const enc = try encodeTest(&pixels, 2, 2);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, 2, 2, &pixels);
}

test "decode dimension mismatch" {
    const enc = try encodeTest(&[_]u16{ 100, 200, 300, 400 }, 2, 2);
    defer testing.allocator.free(enc);
    try expectDecodeErr(error.DimensionMismatch, enc, 3, 3, null);
}

test "decode missing soi" {
    try expectDecodeErr(error.InvalidData, &.{ 0x00, 0x00, 0xFF, 0xD9 }, 1, 1, null);
}

test "decode truncated" {
    // Just SOI, nothing else
    try expectDecodeErr(error.Io, &.{ 0xFF, 0xD8 }, 1, 1, null);
}

test "decode unsupported sof" {
    // SOI + SOF0 (baseline DCT, not lossless)
    try expectDecodeErr(error.Unsupported, &.{ 0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x02 }, 1, 1, null);
}

// ---------------------------------------------------------------------------
// Validation: SOF3 / SOS contract per T.81 Table B.3.
// ---------------------------------------------------------------------------

fn appendSegment(list: *Bytes, marker: u8, payload: []const u8) !void {
    const a = testing.allocator;
    try list.appendSlice(a, &.{ 0xFF, marker });
    const len: u16 = @intCast(payload.len + 2);
    try list.appendSlice(a, &.{ @intCast(len >> 8), @intCast(len & 0xFF) });
    try list.appendSlice(a, payload);
}

/// SOI + SOF3 (only) with the given precision / component count.
fn sof3Stream(precision: u8, ncomp: u8) !Bytes {
    var v: Bytes = .empty;
    errdefer v.deinit(testing.allocator);
    try v.appendSlice(testing.allocator, &.{ 0xFF, 0xD8 });
    var payload: Bytes = .empty;
    defer payload.deinit(testing.allocator);
    try payload.appendSlice(testing.allocator, &.{ precision, 0x00, 0x01, 0x00, 0x01, ncomp });
    var i: u8 = 0;
    while (i < ncomp) : (i += 1) try payload.appendSlice(testing.allocator, &.{ i + 1, 0x11, 0x00 });
    try appendSegment(&v, 0xC3, payload.items);
    return v;
}

/// SOI + valid SOF3 (P=8, 1 comp) + SOS with the given Ss / Se / Ah|Al.
fn sosStream(ss: u8, se: u8, ah_al: u8) !Bytes {
    var v = try sof3Stream(8, 1);
    errdefer v.deinit(testing.allocator);
    try appendSegment(&v, 0xDA, &.{ 1, 1, 0x00, ss, se, ah_al });
    return v;
}

test "reject precision zero one seventeen" {
    for ([_]u8{ 0, 1, 17 }) |p| {
        var v = try sof3Stream(p, 1);
        defer v.deinit(testing.allocator);
        try expectDecodeParam(v.items, 1, 1, "precision");
    }
}

test "reject multi component" {
    var v = try sof3Stream(8, 3);
    defer v.deinit(testing.allocator);
    try expectDecodeErr(error.Unsupported, v.items, 1, 1, null);
}

test "reject predictor zero and eight" {
    for ([_]u8{ 0, 8 }) |ss| {
        var v = try sosStream(ss, 0, 0);
        defer v.deinit(testing.allocator);
        try expectDecodeParam(v.items, 1, 1, "predictor");
    }
}

test "reject nonzero se" {
    var v = try sosStream(1, 5, 0);
    defer v.deinit(testing.allocator);
    try expectDecodeParam(v.items, 1, 1, "Se");
}

test "reject nonzero ah" {
    var v = try sosStream(1, 0, 0x10);
    defer v.deinit(testing.allocator);
    try expectDecodeParam(v.items, 1, 1, "Ah");
}

test "reject point transform ge precision" {
    // precision = 8, Al = 8 must be rejected.
    var v = try sosStream(1, 0, 0x08);
    defer v.deinit(testing.allocator);
    try expectDecodeParam(v.items, 1, 1, "point_transform");
}

test "decode huge dims rejected not abort" {
    // SOF3 width/height are 16-bit fields, so the largest representable (and the
    // largest that can pass the caller-dimension check) is 65535 x 65535 (~4.29
    // billion pixels). Must return an error, not allocate.
    var v: Bytes = .empty;
    defer v.deinit(testing.allocator);
    try v.appendSlice(testing.allocator, &.{ 0xFF, 0xD8 });
    try appendSegment(&v, 0xC3, &.{ 8, 0xFF, 0xFF, 0xFF, 0xFF, 1, 1, 0x11, 0x00 });
    try appendSegment(&v, 0xDA, &.{ 1, 1, 0x00, 1, 0, 0 });
    try expectDecodeParam(v.items, 0xFFFF, 0xFFFF, "width*height");
}

// An oversubscribed DHT (three length-1 codes) must be rejected, not panic while
// building the fast-lookup index.
test "reject oversubscribed dht" {
    var v: Bytes = .empty;
    defer v.deinit(testing.allocator);
    try v.appendSlice(testing.allocator, &.{ 0xFF, 0xD8 });
    var payload = [_]u8{0} ** 20;
    payload[1] = 3; // BITS[1] = 3
    payload[17] = 0;
    payload[18] = 1;
    payload[19] = 2;
    try appendSegment(&v, 0xC4, &payload);
    try expectDecodeErr(error.InvalidData, v.items, 1, 1, null);
}

// A SOS DC table selector (Td, high nibble) of 4 indexes past the 4-entry table
// array; it must be rejected rather than indexing out of bounds.
test "reject dc selector out of range" {
    var v = try sof3Stream(8, 1);
    defer v.deinit(testing.allocator);
    try appendSegment(&v, 0xDA, &.{ 1, 1, 0x40, 1, 0, 0 });
    try expectDecodeParam(v.items, 1, 1, "dc_table_selector");
}

fn sof3Dims(w: u16, h: u16) !Bytes {
    var v: Bytes = .empty;
    errdefer v.deinit(testing.allocator);
    try v.appendSlice(testing.allocator, &.{ 0xFF, 0xD8 });
    try appendSegment(&v, 0xC3, &.{ 8, @intCast(h >> 8), @intCast(h & 0xFF), @intCast(w >> 8), @intCast(w & 0xFF), 1, 1, 0x11, 0x00 });
    return v;
}

// Zero width or height in SOF3 must be rejected (T.81 B.2.2). A DRI in the same
// stream must not trigger a division by zero in restart validation.
test "reject zero dimensions" {
    for ([_][2]u16{ .{ 0, 4 }, .{ 4, 0 } }) |wh| {
        var v = try sof3Dims(wh[0], wh[1]);
        defer v.deinit(testing.allocator);
        try expectDecodeParam(v.items, wh[0], wh[1], "dimensions");
    }

    // DRI + zero-width SOF3: must error (no div-by-zero), not panic.
    var s = try sof3Dims(0, 4);
    defer s.deinit(testing.allocator);
    var with_dri: Bytes = .empty;
    defer with_dri.deinit(testing.allocator);
    try with_dri.appendSlice(testing.allocator, &.{ 0xFF, 0xD8, 0xFF, 0xDD, 0x00, 0x04, 0x00, 0x04 });
    try with_dri.appendSlice(testing.allocator, s.items[2..]);
    try expectDecodeFails(with_dri.items, 0, 4);
}

// ---------------------------------------------------------------------------
// Full-pipeline round-trips: predictor x point-transform x precision.
// ---------------------------------------------------------------------------

test "roundtrip matrix predictor pt precision" {
    const w = 5;
    const h = 4;
    for ([_]u8{ 2, 8, 12, 16 }) |precision| {
        const modulus: u64 = @as(u64, 1) << @intCast(precision);
        var pixels: [w * h]u16 = undefined;
        for (&pixels, 0..) |*p, i| p.* = @intCast((@as(u64, i) * 2_654_435_761) % modulus);
        var predictor: u8 = 1;
        while (predictor <= 7) : (predictor += 1) {
            for ([_]u8{ 0, 2 }) |pt| {
                if (pt >= precision) continue;
                const buf = try encode_mod.encodeWithOptions(testing.allocator, &pixels, w, h, .{
                    .predictor = predictor,
                    .point_transform = pt,
                    .restart_interval_rows = 0,
                    .precision = precision,
                });
                defer testing.allocator.free(buf);
                var expected: [w * h]u16 = undefined;
                for (pixels, 0..) |p, i| expected[i] = (p >> @intCast(pt)) << @intCast(pt);
                try expectDecodeOk(buf, w, h, &expected);
            }
        }
    }
}

test "roundtrip constant image" {
    const pixels = [_]u16{12345} ** 64;
    const enc = try encodeTest(&pixels, 8, 8);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, 8, 8, &pixels);
}

test "roundtrip gradient" {
    var pixels: [256]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i);
    const enc = try encodeTest(&pixels, 16, 16);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, 16, 16, &pixels);
}

test "roundtrip 16bit full range" {
    const pixels = [_]u16{ 0, 1, 65534, 65535, 32768, 32767, 100, 60000 };
    const enc = try encodeTest(&pixels, 4, 2);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, 4, 2, &pixels);
}

test "roundtrip large image" {
    const w = 64;
    const h = 64;
    var pixels: [w * h]u16 = undefined;
    for (0..h) |y| {
        for (0..w) |x| pixels[y * w + x] = @intCast((x * 100 + y * 200) % 65536);
    }
    const enc = try encodeTest(&pixels, w, h);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, w, h, &pixels);
}

test "roundtrip single pixel" {
    const pixels = [_]u16{42000};
    const enc = try encodeTest(&pixels, 1, 1);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, 1, 1, &pixels);
}

test "roundtrip single row" {
    var pixels: [128]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 512);
    const enc = try encodeTest(&pixels, 128, 1);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, 128, 1, &pixels);
}

test "roundtrip single column" {
    var pixels: [128]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 512);
    const enc = try encodeTest(&pixels, 1, 128);
    defer testing.allocator.free(enc);
    try expectDecodeOk(enc, 1, 128, &pixels);
}

// ---------------------------------------------------------------------------
// Restart intervals: T.81 Annex H.1.1 row-aligned restarts.
// ---------------------------------------------------------------------------

/// Deterministic image whose samples all fit in `precision` bits.
fn detImage(allocator: Allocator, w: usize, h: usize, precision: u8) ![]u16 {
    const modulus: u64 = @as(u64, 1) << @intCast(precision);
    const px = try allocator.alloc(u16, w * h);
    for (px, 0..) |*p, i| p.* = @intCast((@as(u64, i) * 2_654_435_761 + 12345) % modulus);
    return px;
}

fn restartOpts(predictor: u8, pt: u8, precision: u8, rows: u16) encode_mod.EncodeOptions {
    return .{ .predictor = predictor, .point_transform = pt, .restart_interval_rows = rows, .precision = precision };
}

/// Restart-marker indices (RST0..RST7 -> 0..7) in stream order. `0xFF Dn` is
/// unambiguously a restart marker: entropy 0xFF bytes are always stuffed.
fn restartMarkers(allocator: Allocator, buf: []const u8) ![]u8 {
    var out: Bytes = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i + 1 < buf.len) {
        if (buf[i] == 0xFF and buf[i + 1] >= 0xD0 and buf[i + 1] <= 0xD7) {
            try out.append(allocator, buf[i + 1] - 0xD0);
            i += 2;
        } else i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "restart roundtrip matrix" {
    const Dim = struct { w: usize, h: usize };
    for ([_]Dim{ .{ .w = 8, .h = 6 }, .{ .w = 5, .h = 5 }, .{ .w = 1, .h = 4 } }) |d| {
        for ([_]u8{ 8, 16 }) |precision| {
            const pixels = try detImage(testing.allocator, d.w, d.h, precision);
            defer testing.allocator.free(pixels);
            for ([_]u16{ 1, 2, 3, @intCast(d.h) }) |rows| {
                for ([_]u8{ 1, 4, 7 }) |predictor| {
                    for ([_]u8{ 0, 2 }) |pt| {
                        const buf = try encode_mod.encodeWithOptions(testing.allocator, pixels, @intCast(d.w), @intCast(d.h), restartOpts(predictor, pt, precision, rows));
                        defer testing.allocator.free(buf);
                        const expected = try testing.allocator.alloc(u16, pixels.len);
                        defer testing.allocator.free(expected);
                        for (pixels, 0..) |p, i| expected[i] = (p >> @intCast(pt)) << @intCast(pt);
                        try expectDecodeOk(buf, @intCast(d.w), @intCast(d.h), expected);
                    }
                }
            }
        }
    }
}

test "restart markers cycle mod 8" {
    // A tall 1-wide image with rows=1 forces one restart per row after the first:
    // 10 rows -> 9 restarts, indices cycling 0..7 then wrapping to 0.
    const pixels = try detImage(testing.allocator, 1, 10, 8);
    defer testing.allocator.free(pixels);
    const buf = try encode_mod.encodeWithOptions(testing.allocator, pixels, 1, 10, restartOpts(1, 0, 8, 1));
    defer testing.allocator.free(buf);

    const markers = try restartMarkers(testing.allocator, buf);
    defer testing.allocator.free(markers);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 0 }, markers);
    try expectDecodeOk(buf, 1, 10, pixels);
}

test "restart dri value is rows times width" {
    const pixels = try detImage(testing.allocator, 6, 4, 8);
    defer testing.allocator.free(pixels);
    const buf = try encode_mod.encodeWithOptions(testing.allocator, pixels, 6, 4, restartOpts(1, 0, 8, 2)); // 2 x 6 = 12
    defer testing.allocator.free(buf);

    const dri = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xDD }).?;
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x04 }, buf[dri + 2 .. dri + 4]);
    try testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, buf[dri + 4 ..][0..2], .big));
}

// Restart resets prediction (H.1.2.1): the segment after a restart is coded
// independently of the rows before it, so two images sharing row 1 but differing
// in row 0 must produce byte-identical entropy after the RST0 marker.
test "restart resets predictor row independence" {
    const row1 = [_]u16{ 100, 110, 120 };
    const img_a = [_]u16{ 10, 20, 30 } ++ row1;
    const img_b = [_]u16{ 200, 150, 90 } ++ row1;
    const opts = restartOpts(4, 0, 8, 1);

    const a = try encode_mod.encodeWithOptions(testing.allocator, &img_a, 3, 2, opts);
    defer testing.allocator.free(a);
    const b = try encode_mod.encodeWithOptions(testing.allocator, &img_b, 3, 2, opts);
    defer testing.allocator.free(b);

    const ta = a[std.mem.indexOf(u8, a, &.{ 0xFF, 0xD0 }).? .. a.len - 2];
    const tb = b[std.mem.indexOf(u8, b, &.{ 0xFF, 0xD0 }).? .. b.len - 2];
    try testing.expectEqualSlices(u8, ta, tb);

    try expectDecodeOk(a, 3, 2, &img_a);
    try expectDecodeOk(b, 3, 2, &img_b);
}

fn restartStream(w: usize, h: usize, rows: u16) ![]u8 {
    const pixels = try detImage(testing.allocator, w, h, 8);
    defer testing.allocator.free(pixels);
    return encode_mod.encodeWithOptions(testing.allocator, pixels, @intCast(w), @intCast(h), restartOpts(1, 0, 8, rows));
}

test "reject ri not multiple of width" {
    // width 4, valid Ri = 4; corrupt the DRI value to 3.
    const buf = try restartStream(4, 4, 1);
    defer testing.allocator.free(buf);
    const dri = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xDD }).?;
    buf[dri + 4] = 0x00;
    buf[dri + 5] = 0x03;
    try expectDecodeErr(error.InvalidData, buf, 4, 4, null);
}

test "reject restart out of order" {
    // Corrupt the first RST0 (0xD0) into RST3 (0xD3).
    const buf = try restartStream(4, 4, 1);
    defer testing.allocator.free(buf);
    const rst = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xD0 }).?;
    buf[rst + 1] = 0xD3;
    try expectDecodeErr(error.InvalidData, buf, 4, 4, null);
}

test "reject restart without dri" {
    // Remove the DRI segment (6 bytes) but keep the RSTn markers in the entropy.
    const buf = try restartStream(4, 4, 1);
    defer testing.allocator.free(buf);
    const dri = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xDD }).?;
    var stripped: Bytes = .empty;
    defer stripped.deinit(testing.allocator);
    try stripped.appendSlice(testing.allocator, buf[0..dri]);
    try stripped.appendSlice(testing.allocator, buf[dri + 6 ..]);
    try expectDecodeErr(error.InvalidData, stripped.items, 4, 4, null);
}

test "reject missing restart marker" {
    // Splice out the first RST marker so the expected restart is gone.
    const buf = try restartStream(4, 6, 1);
    defer testing.allocator.free(buf);
    const rst = std.mem.indexOf(u8, buf, &.{ 0xFF, 0xD0 }).?;
    var stripped: Bytes = .empty;
    defer stripped.deinit(testing.allocator);
    try stripped.appendSlice(testing.allocator, buf[0..rst]);
    try stripped.appendSlice(testing.allocator, buf[rst + 2 ..]);
    try expectDecodeFails(stripped.items, 4, 6);
}

test "truncation inside restart interval errors" {
    const full = try restartStream(4, 8, 1);
    defer testing.allocator.free(full);
    const sos = std.mem.indexOf(u8, full, &.{ 0xFF, 0xDA }).?;
    // Keep the SOS header (8 bytes) plus a few entropy bytes, drop the rest.
    const cut = @min(sos + 8 + 3, full.len);
    try expectDecodeFails(full[0..cut], 4, 8);
}

test "truncated entropy reports offset" {
    const full = try restartStream(4, 8, 1);
    defer testing.allocator.free(full);
    const sos = std.mem.indexOf(u8, full, &.{ 0xFF, 0xDA }).?;
    var diag: Diagnostics = .{};
    try expectDecodeErr(error.Truncated, full[0 .. sos + 2 + 8 + 2], 4, 8, &diag);
    try testing.expectEqual(sos + 2 + 8, diag.offset);
    try testing.expectEqualStrings("entropy scan", diag.context);
}
