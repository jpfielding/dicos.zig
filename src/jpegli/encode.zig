//! Full JPEG Lossless encoding pipeline.
//!
//! Writes a complete JPEG Lossless bitstream with SOI, APP0, SOF3, DHT, SOS,
//! entropy-coded scan data, and EOI markers.

const std = @import("std");
const huffman = @import("huffman.zig");
const scan = @import("scan.zig");

const HuffmanTable = huffman.HuffmanTable;

// ---------------------------------------------------------------------------
// JPEG markers
// ---------------------------------------------------------------------------

const MARKER_SOI: u16 = 0xFFD8;
const MARKER_EOI: u16 = 0xFFD9;
const MARKER_SOF3: u16 = 0xFFC3;
const MARKER_DHT: u16 = 0xFFC4;
const MARKER_SOS: u16 = 0xFFDA;
const MARKER_APP0: u16 = 0xFFE0;

/// Default predictor selection (predictor 1 = Ra, previous pixel in row).
const DEFAULT_PREDICTOR: u8 = 1;

/// Default point transform (0 = no shift, full precision).
const DEFAULT_POINT_TRANSFORM: u8 = 0;

/// Precision for 16-bit images.
const PRECISION_16: u8 = 16;

/// Codec error type.
pub const CodecError = error{
    InvalidData,
    DimensionMismatch,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encode a 16-bit grayscale image into JPEG Lossless format.
///
/// `pixels` is a row-major pixel buffer of length `width * height`.
/// Returns the complete JPEG bitstream (SOI through EOI). Caller owns the memory.
/// Uses predictor 1 (left neighbor) and no point transform.
pub fn encode(
    allocator: std.mem.Allocator,
    pixels: []const u16,
    width: u32,
    height: u32,
) ![]u8 {
    const width_usize: usize = @intCast(width);
    const height_usize: usize = @intCast(height);
    const expected = width_usize * height_usize;

    if (pixels.len != expected) {
        return error.DimensionMismatch;
    }
    if (width_usize == 0 or height_usize == 0) {
        return error.InvalidData;
    }
    if (width_usize > 65535 or height_usize > 65535) {
        return error.InvalidData;
    }

    var ht = try huffman.buildDefaultTable(allocator);
    defer ht.deinit();

    var output = std.array_list.AlignedManaged(u8, null).init(allocator);
    errdefer output.deinit();

    try writeMarker(&output, MARKER_SOI);
    try writeApp0(&output);
    try writeSof3(&output, width_usize, height_usize, PRECISION_16);
    try writeDht(&output, &ht);
    try writeSosAndScan(allocator, &output, &ht, pixels, width_usize, height_usize, PRECISION_16, DEFAULT_PREDICTOR);
    try writeMarker(&output, MARKER_EOI);

    return try output.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Marker writers
// ---------------------------------------------------------------------------

fn writeMarker(output: *std.array_list.AlignedManaged(u8, null), marker: u16) !void {
    const bytes = std.mem.toBytes(std.mem.nativeToBig(u16, marker));
    try output.appendSlice(&bytes);
}

/// Write JFIF APP0 marker segment.
fn writeApp0(output: *std.array_list.AlignedManaged(u8, null)) !void {
    try writeMarker(output, MARKER_APP0);
    const data = [_]u8{
        0x00, 0x10, // Length = 16
        0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
        0x01, 0x01, // Version 1.1
        0x00, // Units: no units
        0x00, 0x01, // X density = 1
        0x00, 0x01, // Y density = 1
        0x00, 0x00, // No thumbnail
    };
    try output.appendSlice(&data);
}

/// Write SOF3 (Start of Frame -- Lossless Huffman) marker segment.
fn writeSof3(output: *std.array_list.AlignedManaged(u8, null), width: usize, height: usize, precision: u8) !void {
    try writeMarker(output, MARKER_SOF3);
    // Length = 2(len) + 1(prec) + 2(height) + 2(width) + 1(ncomp) + 3(comp) = 11
    const length: u16 = 11;
    var data: [11]u8 = undefined;
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, length));
    data[0] = len_bytes[0];
    data[1] = len_bytes[1];
    data[2] = precision;
    data[3] = @intCast(height >> 8);
    data[4] = @intCast(height & 0xFF);
    data[5] = @intCast(width >> 8);
    data[6] = @intCast(width & 0xFF);
    data[7] = 1; // 1 component
    data[8] = 1; // Component ID = 1
    data[9] = 0x11; // H=1, V=1 sampling
    data[10] = 0; // Quantization table (unused in lossless)
    try output.appendSlice(&data);
}

/// Write DHT (Define Huffman Table) marker segment.
fn writeDht(output: *std.array_list.AlignedManaged(u8, null), ht: *const HuffmanTable) !void {
    try writeMarker(output, MARKER_DHT);
    // Length = 2(len) + 1(class|id) + 16(bits) + N(values)
    const length: u16 = @intCast(2 + 1 + 16 + ht.values.len);
    const len_bytes = std.mem.toBytes(std.mem.nativeToBig(u16, length));
    try output.appendSlice(&len_bytes);
    try output.append(0x00); // Table class 0 (DC), Table ID 0
    // Write BITS[1..=16]
    try output.appendSlice(ht.bits[1..17]);
    // Write HUFFVAL
    try output.appendSlice(ht.values);
}

/// Write SOS header and entropy-coded scan data.
fn writeSosAndScan(
    allocator: std.mem.Allocator,
    output: *std.array_list.AlignedManaged(u8, null),
    ht: *const HuffmanTable,
    pixels: []const u16,
    width: usize,
    height: usize,
    precision: u8,
    predictor: u8,
) !void {
    try writeMarker(output, MARKER_SOS);
    // Length = 2(len) + 1(ncomp) + 2(comp spec) + 3(Ss,Se,Ah|Al) = 8
    const header = [_]u8{
        0x00, 0x08, // Length = 8
        1, // 1 component
        1, // Component ID = 1
        0x00, // DC table 0, AC table 0
        predictor, // Ss = predictor selection
        0, // Se = 0 (lossless)
        DEFAULT_POINT_TRANSFORM, // Ah=0, Al=point transform
    };
    try output.appendSlice(&header);

    // Write entropy-coded scan data
    const scan_data = try scan.encodeScan(allocator, ht, pixels, width, height, precision, predictor);
    defer allocator.free(scan_data);
    try output.appendSlice(scan_data);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "encode writes soi and eoi" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 100, 200, 300, 400 };
    const buf = try encode(allocator, &pixels, 2, 2);
    defer allocator.free(buf);

    // Starts with SOI
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xD8), buf[1]);
    // Ends with EOI
    try std.testing.expectEqual(@as(u8, 0xFF), buf[buf.len - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), buf[buf.len - 1]);
}

test "encode contains sof3" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 100, 200, 300, 400 };
    const buf = try encode(allocator, &pixels, 2, 2);
    defer allocator.free(buf);

    // Search for SOF3 marker 0xFFC3
    var has_sof3 = false;
    for (0..buf.len - 1) |i| {
        if (buf[i] == 0xFF and buf[i + 1] == 0xC3) {
            has_sof3 = true;
            break;
        }
    }
    try std.testing.expect(has_sof3);
}

test "encode contains dht" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 100, 200, 300, 400 };
    const buf = try encode(allocator, &pixels, 2, 2);
    defer allocator.free(buf);

    var has_dht = false;
    for (0..buf.len - 1) |i| {
        if (buf[i] == 0xFF and buf[i + 1] == 0xC4) {
            has_dht = true;
            break;
        }
    }
    try std.testing.expect(has_dht);
}

test "encode contains sos" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 100, 200, 300, 400 };
    const buf = try encode(allocator, &pixels, 2, 2);
    defer allocator.free(buf);

    var has_sos = false;
    for (0..buf.len - 1) |i| {
        if (buf[i] == 0xFF and buf[i + 1] == 0xDA) {
            has_sos = true;
            break;
        }
    }
    try std.testing.expect(has_sos);
}

test "encode zero dimension fails" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{};
    const result = encode(allocator, &pixels, 0, 10);
    try std.testing.expectError(error.InvalidData, result);
}

test "encode nonempty output" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{0} ** 16;
    const buf = try encode(allocator, &pixels, 4, 4);
    defer allocator.free(buf);
    // A valid JPEG must be longer than just SOI+EOI (4 bytes)
    try std.testing.expect(buf.len > 4);
}

test "sof3 encodes dimensions" {
    const allocator = std.testing.allocator;
    var output = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer output.deinit();

    try writeSof3(&output, 320, 240, 16);

    const buf = output.items;
    // write_sof3 writes: marker(2) + data(11) = 13 bytes
    // Marker: FF C3 at [0..2]
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xC3), buf[1]);
    // Length bytes at [2..4] = 0x000B = 11
    try std.testing.expectEqual(@as(u8, 0x00), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x0B), buf[3]);
    // Precision at [4]
    try std.testing.expectEqual(@as(u8, 16), buf[4]);
    // Height = 240 = 0x00F0 at [5..7]
    try std.testing.expectEqual(@as(u8, 0x00), buf[5]);
    try std.testing.expectEqual(@as(u8, 0xF0), buf[6]);
    // Width = 320 = 0x0140 at [7..9]
    try std.testing.expectEqual(@as(u8, 0x01), buf[7]);
    try std.testing.expectEqual(@as(u8, 0x40), buf[8]);
}
