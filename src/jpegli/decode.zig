//! Full JPEG Lossless decoding pipeline.
//!
//! Parses a complete JPEG Lossless bitstream (SOI through EOI), extracting
//! the frame header (SOF3), Huffman table (DHT), and scan parameters (SOS),
//! then decodes the entropy-coded scan data using DPCM prediction.

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
const MARKER_DRI: u16 = 0xFFDD;

/// Codec error type.
pub const CodecError = error{
    InvalidData,
    DimensionMismatch,
    Unsupported,
    EndOfStream,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Component info
// ---------------------------------------------------------------------------

const ComponentInfo = struct {
    id: u8,
    h_sampling: u8,
    v_sampling: u8,
    table_index: u8,
};

// ---------------------------------------------------------------------------
// Decoder state
// ---------------------------------------------------------------------------

/// Internal decoder state accumulated while parsing JPEG markers.
const Decoder = struct {
    precision: u8,
    height: u16,
    width: u16,
    components: u8,
    comp_info: std.array_list.AlignedManaged(ComponentInfo, null),
    dc_tables: [4]?HuffmanTable,
    predictor: u8,
    point_transform: u8,
    restart_interval: u16,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Decoder {
        return .{
            .precision = 0,
            .height = 0,
            .width = 0,
            .components = 0,
            .comp_info = std.array_list.AlignedManaged(ComponentInfo, null).init(allocator),
            .dc_tables = [_]?HuffmanTable{ null, null, null, null },
            .predictor = 1,
            .point_transform = 0,
            .restart_interval = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Decoder) void {
        self.comp_info.deinit();
        for (&self.dc_tables) |*table_opt| {
            if (table_opt.*) |*table| {
                table.deinit();
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Decode a JPEG Lossless compressed bitstream into a 16-bit grayscale pixel buffer.
///
/// The `width` and `height` parameters are used for validation against the
/// dimensions encoded in the SOF3 frame header. The actual dimensions come
/// from the JPEG data itself.
///
/// Returns `{ pixels, width, height }` where pixels is a row-major slice.
/// Caller owns the returned pixels memory.
pub fn decode(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
) !struct { pixels: []u16, width: u32, height: u32 } {
    var pos: usize = 0;
    var dec = Decoder.init(allocator);
    defer dec.deinit();

    // Read SOI
    const soi_marker = try readMarker(data, &pos);
    if (soi_marker != MARKER_SOI) {
        return error.InvalidData;
    }

    // Parse markers until SOS
    var found_sos = false;
    while (!found_sos) {
        const marker = try readMarker(data, &pos);
        switch (marker) {
            MARKER_SOF3 => try parseSof3(data, &pos, &dec),
            MARKER_DHT => try parseDht(allocator, data, &pos, &dec),
            MARKER_SOS => {
                try parseSos(data, &pos, &dec);
                found_sos = true;
            },
            MARKER_DRI => try parseDri(data, &pos, &dec),
            MARKER_EOI => return error.InvalidData,
            else => {
                if (marker >= 0xFFE0 and marker <= 0xFFEF) {
                    // APP markers: skip
                    try skipMarkerData(data, &pos);
                } else if (marker >= 0xFFC0 and marker <= 0xFFCF) {
                    // Unsupported SOF marker
                    return error.Unsupported;
                } else if (marker == 0xFFFE) {
                    // COM marker: skip
                    try skipMarkerData(data, &pos);
                } else {
                    // Unknown marker: skip its data
                    try skipMarkerData(data, &pos);
                }
            },
        }
    }

    // Validate dimensions
    const jpeg_w: u32 = @intCast(dec.width);
    const jpeg_h: u32 = @intCast(dec.height);
    if (jpeg_w != width or jpeg_h != height) {
        return error.DimensionMismatch;
    }

    // Get Huffman table
    const table_idx: usize = if (dec.comp_info.items.len > 0)
        @intCast(dec.comp_info.items[0].table_index)
    else
        0;
    const ht = &(dec.dc_tables[table_idx] orelse return error.InvalidData);

    // Decode the scan data (remaining bytes after SOS header)
    const remaining = data[pos..];
    const pixels = try scan.decodeScan(
        allocator,
        remaining,
        ht,
        @intCast(jpeg_w),
        @intCast(jpeg_h),
        dec.precision,
        dec.predictor,
        dec.point_transform,
    );

    const pixel_count = pixels.len;
    const expected: usize = @intCast(jpeg_w * jpeg_h);
    if (pixel_count != expected) {
        allocator.free(pixels);
        return error.DimensionMismatch;
    }

    return .{ .pixels = pixels, .width = jpeg_w, .height = jpeg_h };
}

// ---------------------------------------------------------------------------
// Marker parsing helpers
// ---------------------------------------------------------------------------

/// Read a 2-byte JPEG marker, skipping any fill bytes (0xFF).
fn readMarker(data: []const u8, pos: *usize) !u16 {
    if (pos.* + 1 >= data.len) return error.EndOfStream;
    const b0 = data[pos.*];
    pos.* += 1;
    if (b0 != 0xFF) {
        return error.InvalidData;
    }
    // Skip fill bytes
    var b1 = data[pos.*];
    pos.* += 1;
    while (b1 == 0xFF) {
        if (pos.* >= data.len) return error.EndOfStream;
        b1 = data[pos.*];
        pos.* += 1;
    }
    return (@as(u16, b0) << 8) | @as(u16, b1);
}

/// Read the 2-byte marker data length and skip that many bytes.
fn skipMarkerData(data: []const u8, pos: *usize) !void {
    if (pos.* + 1 >= data.len) return error.EndOfStream;
    const length = (@as(u16, data[pos.*]) << 8) | @as(u16, data[pos.* + 1]);
    pos.* += 2;
    if (length < 2) return;
    const skip = length - 2;
    if (pos.* + skip > data.len) return error.EndOfStream;
    pos.* += skip;
}

/// Parse SOF3 (Start of Frame - Lossless Huffman).
fn parseSof3(data: []const u8, pos: *usize, dec: *Decoder) !void {
    if (pos.* + 1 >= data.len) return error.EndOfStream;
    const length = (@as(u16, data[pos.*]) << 8) | @as(u16, data[pos.* + 1]);
    pos.* += 2;
    if (length < 2) return error.InvalidData;
    const payload_len: usize = length - 2;
    if (pos.* + payload_len > data.len) return error.EndOfStream;
    const payload = data[pos.* .. pos.* + payload_len];
    pos.* += payload_len;

    if (payload.len < 6) return error.InvalidData;

    dec.precision = payload[0];
    dec.height = (@as(u16, payload[1]) << 8) | @as(u16, payload[2]);
    dec.width = (@as(u16, payload[3]) << 8) | @as(u16, payload[4]);
    dec.components = payload[5];

    dec.comp_info.clearRetainingCapacity();
    var i: usize = 0;
    while (i < dec.components) : (i += 1) {
        const offset = 6 + i * 3;
        if (offset + 2 >= payload.len) return error.InvalidData;
        try dec.comp_info.append(.{
            .id = payload[offset],
            .h_sampling = payload[offset + 1] >> 4,
            .v_sampling = payload[offset + 1] & 0x0F,
            .table_index = payload[offset + 2],
        });
    }
}

/// Parse DHT (Define Huffman Table).
fn parseDht(allocator: std.mem.Allocator, data: []const u8, pos: *usize, dec: *Decoder) !void {
    if (pos.* + 1 >= data.len) return error.EndOfStream;
    const length = (@as(u16, data[pos.*]) << 8) | @as(u16, data[pos.* + 1]);
    pos.* += 2;
    if (length < 2) return error.InvalidData;
    const payload_len: usize = length - 2;
    if (pos.* + payload_len > data.len) return error.EndOfStream;
    const payload = data[pos.* .. pos.* + payload_len];
    pos.* += payload_len;

    var offset: usize = 0;
    while (offset < payload.len) {
        if (offset >= payload.len) break;
        const table_info = payload[offset];
        const table_class = table_info >> 4; // 0 = DC
        const table_id: usize = @intCast(table_info & 0x0F);
        offset += 1;

        if (table_class != 0) {
            // Lossless only uses DC tables; skip AC table definition
            var count: usize = 0;
            for (0..16) |j| {
                if (offset + j >= payload.len) break;
                count += @as(usize, payload[offset + j]);
            }
            offset += 16 + count;
            continue;
        }

        if (table_id >= 4) return error.InvalidData;

        // Read BITS[1..=16]
        var bits = [_]u8{0} ** 17;
        var total_codes: usize = 0;
        for (0..16) |j| {
            if (offset + j >= payload.len) return error.InvalidData;
            bits[j + 1] = payload[offset + j];
            total_codes += @as(usize, payload[offset + j]);
        }
        offset += 16;

        // Read HUFFVAL
        if (offset + total_codes > payload.len) return error.InvalidData;
        const values = payload[offset .. offset + total_codes];
        offset += total_codes;

        // Free old table if it exists
        if (dec.dc_tables[table_id]) |*old_table| {
            old_table.deinit();
        }
        dec.dc_tables[table_id] = try HuffmanTable.fromBitsValues(allocator, bits, values);
    }
}

/// Parse SOS (Start of Scan).
fn parseSos(data: []const u8, pos: *usize, dec: *Decoder) !void {
    if (pos.* + 1 >= data.len) return error.EndOfStream;
    const length = (@as(u16, data[pos.*]) << 8) | @as(u16, data[pos.* + 1]);
    pos.* += 2;
    if (length < 2) return error.InvalidData;
    const payload_len: usize = length - 2;
    if (pos.* + payload_len > data.len) return error.EndOfStream;
    const payload = data[pos.* .. pos.* + payload_len];
    pos.* += payload_len;

    if (payload.len == 0) return error.InvalidData;

    const num_components: usize = @intCast(payload[0]);
    var offset: usize = 1;

    for (0..num_components) |_| {
        if (offset + 1 >= payload.len) return error.InvalidData;
        const selector = payload[offset];
        const table_mapping = payload[offset + 1];
        offset += 2;

        // Update table index for the matching component
        for (dec.comp_info.items) |*ci| {
            if (ci.id == selector) {
                ci.table_index = table_mapping >> 4;
                break;
            }
        }
    }

    if (offset >= payload.len) return error.InvalidData;

    // Ss = predictor selection
    dec.predictor = payload[offset];
    offset += 1;

    // Se = always 0 for lossless
    offset += 1;

    // Ah (high nibble) | Al (low nibble) = point transform
    if (offset < payload.len) {
        dec.point_transform = payload[offset] & 0x0F;
    }
}

/// Parse DRI (Define Restart Interval).
fn parseDri(data: []const u8, pos: *usize, dec: *Decoder) !void {
    if (pos.* + 3 >= data.len) return error.EndOfStream;
    // buf[0..2] = length (always 4), buf[2..4] = restart interval
    pos.* += 2; // skip length
    dec.restart_interval = (@as(u16, data[pos.*]) << 8) | @as(u16, data[pos.* + 1]);
    pos.* += 2;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const enc = @import("encode.zig");

test "decode minimal roundtrip" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 100, 200, 300, 400 };
    const encoded = try enc.encode(allocator, &pixels, 2, 2);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, 2, 2);
    defer allocator.free(result.pixels);

    try std.testing.expectEqual(@as(u32, 2), result.width);
    try std.testing.expectEqual(@as(u32, 2), result.height);
    try std.testing.expectEqualSlices(u16, &[_]u16{ 100, 200, 300, 400 }, result.pixels);
}

test "decode dimension mismatch" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{ 100, 200, 300, 400 };
    const encoded = try enc.encode(allocator, &pixels, 2, 2);
    defer allocator.free(encoded);

    // Ask for wrong dimensions
    const result = decode(allocator, encoded, 3, 3);
    try std.testing.expectError(error.DimensionMismatch, result);
}

test "decode missing soi" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x00, 0xFF, 0xD9 };
    const result = decode(allocator, &data, 1, 1);
    try std.testing.expectError(error.InvalidData, result);
}

test "decode truncated" {
    const allocator = std.testing.allocator;
    // Just SOI, nothing else
    const data = [_]u8{ 0xFF, 0xD8 };
    const result = decode(allocator, &data, 1, 1);
    try std.testing.expectError(error.EndOfStream, result);
}

test "decode unsupported sof" {
    const allocator = std.testing.allocator;
    // SOI + SOF0 (baseline DCT, not lossless)
    const data = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x02 };
    const result = decode(allocator, &data, 1, 1);
    try std.testing.expectError(error.Unsupported, result);
}

test "roundtrip constant image" {
    const allocator = std.testing.allocator;
    const val: u16 = 12345;
    const pixels = [_]u16{val} ** 64;
    const encoded = try enc.encode(allocator, &pixels, 8, 8);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, 8, 8);
    defer allocator.free(result.pixels);

    try std.testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip gradient" {
    const allocator = std.testing.allocator;
    var pixels: [256]u16 = undefined;
    for (0..256) |i| {
        pixels[i] = @intCast(i);
    }
    const encoded = try enc.encode(allocator, &pixels, 16, 16);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, 16, 16);
    defer allocator.free(result.pixels);

    try std.testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip 16bit full range" {
    const allocator = std.testing.allocator;
    // Exercise full 16-bit range
    const pixels = [_]u16{ 0, 1, 65534, 65535, 32768, 32767, 100, 60000 };
    const encoded = try enc.encode(allocator, &pixels, 4, 2);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, 4, 2);
    defer allocator.free(result.pixels);

    try std.testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip large image" {
    const allocator = std.testing.allocator;
    // A larger image to stress-test the codec
    const width: u32 = 64;
    const height: u32 = 64;
    var pixels: [width * height]u16 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            // A pattern that exercises the predictor
            pixels[y * width + x] = @intCast((x * 100 + y * 200) % 65536);
        }
    }
    const encoded = try enc.encode(allocator, &pixels, width, height);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, width, height);
    defer allocator.free(result.pixels);

    try std.testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip single pixel" {
    const allocator = std.testing.allocator;
    const pixels = [_]u16{42000};
    const encoded = try enc.encode(allocator, &pixels, 1, 1);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, 1, 1);
    defer allocator.free(result.pixels);

    try std.testing.expectEqualSlices(u16, &[_]u16{42000}, result.pixels);
}

test "roundtrip single row" {
    const allocator = std.testing.allocator;
    var pixels: [128]u16 = undefined;
    for (0..128) |i| {
        pixels[i] = @intCast(i * 512);
    }
    const encoded = try enc.encode(allocator, &pixels, 128, 1);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, 128, 1);
    defer allocator.free(result.pixels);

    try std.testing.expectEqualSlices(u16, &pixels, result.pixels);
}

test "roundtrip single column" {
    const allocator = std.testing.allocator;
    var pixels: [128]u16 = undefined;
    for (0..128) |i| {
        pixels[i] = @intCast(i * 512);
    }
    const encoded = try enc.encode(allocator, &pixels, 1, 128);
    defer allocator.free(encoded);

    const result = try decode(allocator, encoded, 1, 128);
    defer allocator.free(result.pixels);

    try std.testing.expectEqualSlices(u16, &pixels, result.pixels);
}
