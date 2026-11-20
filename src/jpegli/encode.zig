//! Full JPEG Lossless encoding pipeline.
//!
//! Writes a complete JPEG Lossless bitstream with SOI, APP0, SOF3, DHT, [DRI],
//! SOS, entropy-coded scan data, and EOI markers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const huffman = @import("huffman.zig");
const scan = @import("scan.zig");
const errors = @import("error.zig");

const HuffmanTable = huffman.HuffmanTable;
const CodecError = errors.CodecError;
const Diagnostics = errors.Diagnostics;
const Output = std.ArrayList(u8);

// ---------------------------------------------------------------------------
// JPEG markers
// ---------------------------------------------------------------------------

const MARKER_SOI: u16 = 0xFFD8;
const MARKER_EOI: u16 = 0xFFD9;
const MARKER_SOF3: u16 = 0xFFC3;
const MARKER_DHT: u16 = 0xFFC4;
const MARKER_SOS: u16 = 0xFFDA;
const MARKER_APP0: u16 = 0xFFE0;
const MARKER_DRI: u16 = 0xFFDD;

// ---------------------------------------------------------------------------
// Encode options
// ---------------------------------------------------------------------------

/// Options controlling JPEG Lossless (T.81 Annex H) encoding.
pub const EncodeOptions = struct {
    /// DPCM predictor selector (SOS `Ss`), 1..=7. Default 1 (Ra, left neighbor).
    predictor: u8 = 1,
    /// Point transform (SOS `Al` / `Pt`), 0..=precision-1. Default 0.
    ///
    /// The codec operates in the reduced domain P' = precision - point_transform:
    /// every input sample is shifted right by `point_transform` before coding.
    point_transform: u8 = 0,
    /// Restart every N MCU rows; 0 disables restart intervals. The emitted DRI
    /// value is `restart_interval_rows * width` (validated to fit in a `u16`).
    restart_interval_rows: u16 = 0,
    /// Sample precision P (SOF3), 2..=16. Default 16.
    precision: u8 = 16,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a 16-bit grayscale image into JPEG Lossless format using default
/// options (predictor 1, no point transform, 16-bit precision, no restarts).
///
/// `pixels` is a row-major buffer of length `width * height`. Returns the
/// complete JPEG bitstream (SOI through EOI); the caller owns the memory.
pub fn encode(allocator: Allocator, pixels: []const u16, width: u32, height: u32) CodecError![]u8 {
    return encodeWithOptionsDiag(allocator, pixels, width, height, .{}, null);
}

/// Encode with explicit `EncodeOptions`. See `encode`.
pub fn encodeWithOptions(
    allocator: Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
    opts: EncodeOptions,
) CodecError![]u8 {
    return encodeWithOptionsDiag(allocator, pixels, width, height, opts, null);
}

/// Like `encodeWithOptions`, additionally filling `diag` (when non-null) with
/// the details of any returned error (e.g. the offending parameter name).
pub fn encodeWithOptionsDiag(
    allocator: Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
    opts: EncodeOptions,
    diag: ?*Diagnostics,
) CodecError![]u8 {
    const width_usize: usize = width;
    const height_usize: usize = height;
    const expected = width_usize * height_usize;

    if (pixels.len != expected) return errors.dimensionMismatch(diag, expected, pixels.len);
    if (width_usize == 0 or height_usize == 0)
        return errors.invalidData(diag, "image dimensions must be non-zero");
    if (width_usize > 65535 or height_usize > 65535)
        return errors.invalidData(diag, "image dimensions exceed JPEG maximum (65535)");

    // --- Option validation (T.81 Table B.3 / B.2.2) --------------------------
    if (opts.precision < 2 or opts.precision > 16)
        return errors.invalidParameter(diag, "precision", opts.precision, "2..=16");
    if (opts.predictor < 1 or opts.predictor > 7)
        return errors.invalidParameter(diag, "predictor", opts.predictor, "1..=7");
    if (opts.point_transform >= opts.precision)
        return errors.invalidParameter(diag, "point_transform", opts.point_transform, "< precision");

    // Every sample must fit in `precision` bits.
    const sample_limit: u32 = @as(u32, 1) << @intCast(opts.precision);
    var max_sample: u16 = 0;
    for (pixels) |p| max_sample = @max(max_sample, p);
    if (pixels.len > 0 and @as(u32, max_sample) >= sample_limit)
        return errors.invalidParameter(diag, "sample_value", max_sample, "< 2^precision");

    // Restart-interval math must fit in the 16-bit DRI field (T.81 H.1.1: the DRI
    // value is `restart_interval_rows * width` MCUs, one MCU per sample).
    var restart_interval: u16 = 0;
    if (opts.restart_interval_rows > 0) {
        const dri = @as(u32, opts.restart_interval_rows) * @as(u32, @intCast(width_usize));
        if (dri == 0 or dri > 65535)
            return errors.invalidData(diag, "restart interval (rows x width) does not fit in the 16-bit DRI field");
        restart_interval = @intCast(dri);
    }

    var ht = huffman.buildDefaultTable(allocator) catch return error.OutOfMemory;
    defer ht.deinit();

    var out: Output = .empty;
    errdefer out.deinit(allocator);

    try writeMarker(allocator, &out, MARKER_SOI);
    try writeApp0(allocator, &out);
    try writeSof3(allocator, &out, width_usize, height_usize, opts.precision);
    try writeDht(allocator, &out, &ht);
    if (restart_interval > 0) try writeDri(allocator, &out, restart_interval);
    try writeSosAndScan(allocator, &out, &ht, pixels, width_usize, height_usize, opts);
    try writeMarker(allocator, &out, MARKER_EOI);

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Marker writers
// ---------------------------------------------------------------------------

fn writeMarker(allocator: Allocator, out: *Output, marker: u16) Allocator.Error!void {
    try out.appendSlice(allocator, &.{ @intCast(marker >> 8), @intCast(marker & 0xFF) });
}

/// Write JFIF APP0 marker segment.
fn writeApp0(allocator: Allocator, out: *Output) Allocator.Error!void {
    try writeMarker(allocator, out, MARKER_APP0);
    try out.appendSlice(allocator, &.{
        0x00, 0x10, // Length = 16
        0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
        0x01, 0x01, // Version 1.1
        0x00, // Units: no units
        0x00, 0x01, // X density = 1
        0x00, 0x01, // Y density = 1
        0x00, 0x00, // No thumbnail
    });
}

/// Write SOF3 (Start of Frame -- Lossless Huffman) marker segment.
fn writeSof3(allocator: Allocator, out: *Output, width: usize, height: usize, precision: u8) Allocator.Error!void {
    try writeMarker(allocator, out, MARKER_SOF3);
    // Length = 2(len) + 1(prec) + 2(height) + 2(width) + 1(ncomp) + 3(comp) = 11
    try out.appendSlice(allocator, &.{
        0x00,
        0x0B,
        precision,
        @intCast(height >> 8),
        @intCast(height & 0xFF),
        @intCast(width >> 8),
        @intCast(width & 0xFF),
        1, // 1 component
        1, // Component ID = 1
        0x11, // H=1, V=1 sampling
        0, // Quantization table (unused in lossless)
    });
}

/// Write DHT (Define Huffman Table) marker segment.
fn writeDht(allocator: Allocator, out: *Output, ht: *const HuffmanTable) Allocator.Error!void {
    try writeMarker(allocator, out, MARKER_DHT);
    // Length = 2(len) + 1(class|id) + 16(bits) + N(values)
    const length: u16 = @intCast(2 + 1 + 16 + ht.values.len);
    try out.appendSlice(allocator, &.{ @intCast(length >> 8), @intCast(length & 0xFF) });
    try out.append(allocator, 0x00); // Table class 0 (DC), Table ID 0
    try out.appendSlice(allocator, ht.bits[1..17]); // BITS[1..=16]
    try out.appendSlice(allocator, ht.values); // HUFFVAL
}

/// Write DRI (Define Restart Interval) marker segment (T.81 B.2.4).
fn writeDri(allocator: Allocator, out: *Output, restart_interval: u16) Allocator.Error!void {
    try writeMarker(allocator, out, MARKER_DRI);
    try out.appendSlice(allocator, &.{
        0x00,
        0x04,
        @intCast(restart_interval >> 8),
        @intCast(restart_interval & 0xFF),
    });
}

/// Write SOS header and entropy-coded scan data.
fn writeSosAndScan(
    allocator: Allocator,
    out: *Output,
    ht: *const HuffmanTable,
    pixels: []const u16,
    width: usize,
    height: usize,
    opts: EncodeOptions,
) Allocator.Error!void {
    try writeMarker(allocator, out, MARKER_SOS);
    // Length = 2(len) + 1(ncomp) + 2(comp spec) + 3(Ss,Se,Ah|Al) = 8
    try out.appendSlice(allocator, &.{
        0x00, 0x08,
        1, // 1 component
        1, // Component ID = 1
        0x00, // DC table 0, AC table 0
        opts.predictor, // Ss = predictor selection
        0, // Se = 0 (lossless)
        opts.point_transform, // Ah=0, Al=point transform (Pt)
    });

    try scan.encodeScan(
        allocator,
        out,
        ht,
        pixels,
        width,
        height,
        opts.precision,
        opts.predictor,
        opts.point_transform,
        opts.restart_interval_rows,
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn findMarker(buf: []const u8, hi: u8, lo: u8) ?usize {
    if (buf.len < 2) return null;
    for (0..buf.len - 1) |i| {
        if (buf[i] == hi and buf[i + 1] == lo) return i;
    }
    return null;
}

const sample4 = [_]u16{ 100, 200, 300, 400 };

test "encode writes soi and eoi" {
    const buf = try encode(testing.allocator, &sample4, 2, 2);
    defer testing.allocator.free(buf);
    try testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try testing.expectEqual(@as(u8, 0xD8), buf[1]);
    try testing.expectEqual(@as(u8, 0xFF), buf[buf.len - 2]);
    try testing.expectEqual(@as(u8, 0xD9), buf[buf.len - 1]);
}

test "encode contains sof3" {
    const buf = try encode(testing.allocator, &sample4, 2, 2);
    defer testing.allocator.free(buf);
    try testing.expect(findMarker(buf, 0xFF, 0xC3) != null);
}

test "encode contains dht" {
    const buf = try encode(testing.allocator, &sample4, 2, 2);
    defer testing.allocator.free(buf);
    try testing.expect(findMarker(buf, 0xFF, 0xC4) != null);
}

test "encode contains sos" {
    const buf = try encode(testing.allocator, &sample4, 2, 2);
    defer testing.allocator.free(buf);
    try testing.expect(findMarker(buf, 0xFF, 0xDA) != null);
}

test "encode zero dimension fails" {
    try testing.expectError(error.InvalidData, encode(testing.allocator, &.{}, 0, 10));
}

test "encode nonempty output" {
    const pixels = [_]u16{0} ** 16;
    const buf = try encode(testing.allocator, &pixels, 4, 4);
    defer testing.allocator.free(buf);
    // A valid JPEG must be longer than just SOI+EOI (4 bytes)
    try testing.expect(buf.len > 4);
}

test "encode dimension mismatch" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.DimensionMismatch, encodeWithOptionsDiag(testing.allocator, &sample4, 3, 3, .{}, &diag));
    try testing.expectEqual(@as(usize, 9), diag.expected);
    try testing.expectEqual(@as(usize, 4), diag.actual);
}

test "sof3 encodes dimensions" {
    var out: Output = .empty;
    defer out.deinit(testing.allocator);
    try writeSof3(testing.allocator, &out, 320, 240, 16);
    const buf = out.items;
    // marker(2) + data(11) = 13 bytes
    try testing.expectEqual(@as(usize, 13), buf.len);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xC3 }, buf[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x0B }, buf[2..4]);
    try testing.expectEqual(@as(u8, 16), buf[4]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xF0 }, buf[5..7]); // height 240
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x40 }, buf[7..9]); // width 320
}

// ---------------------------------------------------------------------------
// EncodeOptions
// ---------------------------------------------------------------------------

fn optsOf(predictor: u8, point_transform: u8, precision: u8) EncodeOptions {
    return .{ .predictor = predictor, .point_transform = point_transform, .restart_interval_rows = 0, .precision = precision };
}

fn expectParam(res: CodecError![]u8, diag: Diagnostics, name: []const u8) !void {
    if (res) |buf| {
        testing.allocator.free(buf);
        return error.TestExpectedError;
    } else |e| {
        try testing.expectEqual(error.InvalidParameter, e);
        try testing.expectEqualStrings(name, diag.parameter);
    }
}

test "default options values" {
    const o: EncodeOptions = .{};
    try testing.expectEqual(@as(u8, 1), o.predictor);
    try testing.expectEqual(@as(u8, 0), o.point_transform);
    try testing.expectEqual(@as(u16, 0), o.restart_interval_rows);
    try testing.expectEqual(@as(u8, 16), o.precision);
}

test "options write ss and al" {
    const pixels = [_]u16{ 0, 4, 8, 12 };
    const buf = try encodeWithOptions(testing.allocator, &pixels, 2, 2, optsOf(5, 2, 12));
    defer testing.allocator.free(buf);

    const pos = findMarker(buf, 0xFF, 0xDA).?;
    // header layout: FF DA, len(2)=0008, ncomp=1, id=1, table=00, Ss, Se, Ah|Al
    try testing.expectEqual(@as(u8, 5), buf[pos + 7]); // Ss == predictor
    try testing.expectEqual(@as(u8, 0), buf[pos + 8]); // Se == 0
    try testing.expectEqual(@as(u8, 2), buf[pos + 9]); // Al == point transform

    const sof = findMarker(buf, 0xFF, 0xC3).?;
    try testing.expectEqual(@as(u8, 12), buf[sof + 4]); // SOF3 precision
}

test "reject predictor out of range" {
    const pixels = [_]u16{0} ** 4;
    for ([_]u8{ 0, 8 }) |p| {
        var diag: Diagnostics = .{};
        try expectParam(encodeWithOptionsDiag(testing.allocator, &pixels, 2, 2, optsOf(p, 0, 16), &diag), diag, "predictor");
    }
}

test "reject precision out of range" {
    const pixels = [_]u16{0} ** 4;
    for ([_]u8{ 0, 1, 17 }) |p| {
        var diag: Diagnostics = .{};
        try expectParam(encodeWithOptionsDiag(testing.allocator, &pixels, 2, 2, optsOf(1, 0, p), &diag), diag, "precision");
    }
}

test "reject point transform ge precision" {
    const pixels = [_]u16{0} ** 4;
    var diag: Diagnostics = .{};
    try expectParam(encodeWithOptionsDiag(testing.allocator, &pixels, 2, 2, optsOf(1, 8, 8), &diag), diag, "point_transform");
}

test "reject sample exceeding precision" {
    // precision 8 => samples must be < 256.
    const pixels = [_]u16{ 10, 20, 300, 40 };
    var diag: Diagnostics = .{};
    try expectParam(encodeWithOptionsDiag(testing.allocator, &pixels, 2, 2, optsOf(1, 0, 8), &diag), diag, "sample_value");
}

test "restart interval emits dri marker" {
    const pixels = [_]u16{0} ** 16;
    const buf = try encodeWithOptions(testing.allocator, &pixels, 4, 4, .{ .restart_interval_rows = 1 });
    defer testing.allocator.free(buf);

    const dri = findMarker(buf, 0xFF, 0xDD).?;
    const sos = findMarker(buf, 0xFF, 0xDA).?;
    try testing.expect(dri < sos);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x04 }, buf[dri + 2 .. dri + 4]); // length
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x04 }, buf[dri + 4 .. dri + 6]); // Ri = rows*width
}

test "restart interval overflow is invalid" {
    // 100 rows x 1000 width = 100_000 does not fit the 16-bit DRI field.
    const pixels = [_]u16{0} ** 1000;
    try testing.expectError(error.InvalidData, encodeWithOptions(testing.allocator, &pixels, 1000, 1, .{ .restart_interval_rows = 100 }));
}
