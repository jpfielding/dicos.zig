//! JPEG 2000 codestream reader / writer and public encode / decode functions.
//!
//! Generates and parses the codestream structure:
//! SOC -> SIZ -> COD -> QCD -> SOT -> SOD -> [tile data] -> EOC

const std = @import("std");
const Allocator = std.mem.Allocator;
const bitstream = @import("bitstream.zig");
const markers = @import("markers.zig");
const tile_mod = @import("tile.zig");

const ByteReader = bitstream.ByteReader;
const ByteWriter = bitstream.ByteWriter;
const TileEncoder = tile_mod.TileEncoder;
const TileDecoder = tile_mod.TileDecoder;
const SizMarker = markers.SizMarker;
const CodMarker = markers.CodMarker;
const QcdMarker = markers.QcdMarker;
const SotMarker = markers.SotMarker;
const ComponentInfo = markers.ComponentInfo;
const ProgressionOrder = markers.ProgressionOrder;
const TransformType = markers.TransformType;

pub const CodecError = error{
    InvalidData,
    DimensionMismatch,
    OutOfMemory,
    EndOfStream,
    Unsupported,
};

/// Options for JPEG 2000 encoding.
pub const Jpeg2kOptions = struct {
    /// Tile width (0 = single tile)
    tile_width: u32 = 0,
    /// Tile height (0 = single tile)
    tile_height: u32 = 0,
    /// Code-block width exponent (typical: 6 for 64)
    cb_width_exp: u8 = 6,
    /// Code-block height exponent (typical: 6 for 64)
    cb_height_exp: u8 = 6,
    /// Number of decomposition levels
    num_decomp_levels: u8 = 5,
};

// ---------------------------------------------------------------------------
// Codestream writer (encoder side)
// ---------------------------------------------------------------------------

const CodestreamWriter = struct {
    bw: ByteWriter,

    fn init(allocator: Allocator) CodestreamWriter {
        return .{ .bw = ByteWriter.init(allocator) };
    }

    fn deinit(self: *CodestreamWriter) void {
        self.bw.deinit();
    }

    fn writeSoc(self: *CodestreamWriter) Allocator.Error!void {
        try self.bw.writeU16(markers.MARKER_SOC);
    }

    fn writeSiz(self: *CodestreamWriter, siz: *const SizMarker) Allocator.Error!void {
        try self.bw.writeU16(markers.MARKER_SIZ);
        // Length: 38 + 3 * num_components
        const length: u16 = @intCast(38 + 3 * siz.components.len);
        try self.bw.writeU16(length);
        try self.bw.writeU16(siz.rsiz);
        try self.bw.writeU32(siz.x_siz);
        try self.bw.writeU32(siz.y_siz);
        try self.bw.writeU32(siz.x_osiz);
        try self.bw.writeU32(siz.y_osiz);
        try self.bw.writeU32(siz.x_tsiz);
        try self.bw.writeU32(siz.y_tsiz);
        try self.bw.writeU32(siz.x_tosiz);
        try self.bw.writeU32(siz.y_tosiz);
        try self.bw.writeU16(@intCast(siz.components.len));
        for (siz.components) |comp| {
            var ssiz = comp.precision - 1;
            if (comp.signed) {
                ssiz |= 0x80;
            }
            try self.bw.writeU8(ssiz);
            try self.bw.writeU8(comp.x_rsiz);
            try self.bw.writeU8(comp.y_rsiz);
        }
    }

    fn writeCod(self: *CodestreamWriter, cod: *const CodMarker) Allocator.Error!void {
        try self.bw.writeU16(markers.MARKER_COD);
        var length: u16 = 12;
        if (cod.scod & markers.CODING_STYLE_PRECINCTS_USER != 0) {
            length += @intCast(cod.precinct_sizes.len);
        }
        try self.bw.writeU16(length);
        try self.bw.writeU8(cod.scod);
        try self.bw.writeU8(@intFromEnum(cod.progression));
        try self.bw.writeU16(cod.num_layers);
        try self.bw.writeU8(cod.mct);
        try self.bw.writeU8(cod.decomp_levels);
        try self.bw.writeU8(cod.cb_width_exp);
        try self.bw.writeU8(cod.cb_height_exp);
        try self.bw.writeU8(cod.cb_style);
        try self.bw.writeU8(@intFromEnum(cod.transform));
        if (cod.scod & markers.CODING_STYLE_PRECINCTS_USER != 0) {
            try self.bw.writeBytes(cod.precinct_sizes);
        }
    }

    fn writeQcd(self: *CodestreamWriter, qcd: *const QcdMarker) Allocator.Error!void {
        try self.bw.writeU16(markers.MARKER_QCD);
        const length: u16 = @intCast(3 + qcd.step_sizes.len);
        try self.bw.writeU16(length);
        const sqcd = (qcd.guard_bits << 5) | (qcd.sqcd & 0x1F);
        try self.bw.writeU8(sqcd);
        // For reversible coding each step size is 1 byte (exponent only).
        for (qcd.step_sizes) |step| {
            const exp: u8 = @intCast(@as(u16, @bitCast(step << 3)) & 0xFF);
            try self.bw.writeU8(exp);
        }
    }

    fn writeSot(self: *CodestreamWriter, sot: *const SotMarker) Allocator.Error!void {
        try self.bw.writeU16(markers.MARKER_SOT);
        try self.bw.writeU16(10); // fixed length
        try self.bw.writeU16(sot.tile_index);
        try self.bw.writeU32(sot.tile_part_len);
        try self.bw.writeU8(sot.tile_part_idx);
        try self.bw.writeU8(sot.num_tile_parts);
    }

    fn writeSod(self: *CodestreamWriter) Allocator.Error!void {
        try self.bw.writeU16(markers.MARKER_SOD);
    }

    fn writeEoc(self: *CodestreamWriter) Allocator.Error!void {
        try self.bw.writeU16(markers.MARKER_EOC);
    }

    fn writeBytes(self: *CodestreamWriter, data: []const u8) Allocator.Error!void {
        try self.bw.writeBytes(data);
    }

    fn toOwnedSlice(self: *CodestreamWriter) Allocator.Error![]u8 {
        return self.bw.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------------
// Codestream reader (decoder side)
// ---------------------------------------------------------------------------

const CodestreamReader = struct {
    br: ByteReader,
    siz: ?SizMarker,
    cod: ?CodMarker,
    qcd: ?QcdMarker,
    allocator: Allocator,

    fn init(allocator: Allocator, data: []const u8) CodestreamReader {
        return .{
            .br = ByteReader.init(data),
            .siz = null,
            .cod = null,
            .qcd = null,
            .allocator = allocator,
        };
    }

    fn deinit(self: *CodestreamReader) void {
        if (self.siz) |*siz| siz.deinit();
        if (self.cod) |*cod| cod.deinit();
        if (self.qcd) |*qcd| qcd.deinit();
    }

    /// Read the main header (SOC through first SOT or SOD).
    fn readMainHeader(self: *CodestreamReader) CodecError!void {
        // Read SOC.
        const marker = try self.readMarker();
        if (marker != markers.MARKER_SOC) {
            return error.InvalidData;
        }

        while (true) {
            const m = try self.readMarker();
            switch (m) {
                markers.MARKER_SIZ => try self.readSiz(),
                markers.MARKER_COD => try self.readCod(),
                markers.MARKER_QCD => try self.readQcd(),
                markers.MARKER_SOT, markers.MARKER_SOD => return,
                else => {
                    // Skip unknown marker segment.
                    const length = try self.br.readU16();
                    if (length >= 2) {
                        try self.br.skip(length - 2);
                    }
                },
            }
        }
    }

    fn readMarker(self: *CodestreamReader) CodecError!u16 {
        return self.br.readU16() catch return error.EndOfStream;
    }

    fn readSiz(self: *CodestreamReader) CodecError!void {
        const length = self.br.readU16() catch return error.EndOfStream;
        if (length < 41) return error.InvalidData;
        const rsiz = self.br.readU16() catch return error.EndOfStream;
        const x_siz = self.br.readU32() catch return error.EndOfStream;
        const y_siz = self.br.readU32() catch return error.EndOfStream;
        const x_osiz = self.br.readU32() catch return error.EndOfStream;
        const y_osiz = self.br.readU32() catch return error.EndOfStream;
        const x_tsiz = self.br.readU32() catch return error.EndOfStream;
        const y_tsiz = self.br.readU32() catch return error.EndOfStream;
        const x_tosiz = self.br.readU32() catch return error.EndOfStream;
        const y_tosiz = self.br.readU32() catch return error.EndOfStream;
        const num_comps = self.br.readU16() catch return error.EndOfStream;

        const components = try self.allocator.alloc(ComponentInfo, num_comps);
        errdefer self.allocator.free(components);
        for (0..num_comps) |i| {
            const ssiz = self.br.readU8() catch return error.EndOfStream;
            const signed = (ssiz & 0x80) != 0;
            const precision = (ssiz & 0x7F) + 1;
            const x_rsiz = self.br.readU8() catch return error.EndOfStream;
            const y_rsiz = self.br.readU8() catch return error.EndOfStream;
            components[i] = .{
                .precision = precision,
                .signed = signed,
                .x_rsiz = x_rsiz,
                .y_rsiz = y_rsiz,
            };
        }

        self.siz = .{
            .rsiz = rsiz,
            .x_siz = x_siz,
            .y_siz = y_siz,
            .x_osiz = x_osiz,
            .y_osiz = y_osiz,
            .x_tsiz = x_tsiz,
            .y_tsiz = y_tsiz,
            .x_tosiz = x_tosiz,
            .y_tosiz = y_tosiz,
            .components = components,
            .allocator = self.allocator,
        };
    }

    fn readCod(self: *CodestreamReader) CodecError!void {
        const length = self.br.readU16() catch return error.EndOfStream;
        if (length < 12) return error.InvalidData;
        const scod = self.br.readU8() catch return error.EndOfStream;
        const prog_byte = self.br.readU8() catch return error.EndOfStream;
        const progression = ProgressionOrder.fromByte(prog_byte) orelse return error.InvalidData;
        const num_layers = self.br.readU16() catch return error.EndOfStream;
        const mct = self.br.readU8() catch return error.EndOfStream;
        const decomp_levels = self.br.readU8() catch return error.EndOfStream;
        const cb_width_exp = self.br.readU8() catch return error.EndOfStream;
        const cb_height_exp = self.br.readU8() catch return error.EndOfStream;
        const cb_style = self.br.readU8() catch return error.EndOfStream;
        const transform_byte = self.br.readU8() catch return error.EndOfStream;
        const transform = TransformType.fromByte(transform_byte) orelse return error.InvalidData;

        var precinct_sizes: []u8 = &.{};
        var alloc_used: ?Allocator = null;
        if (scod & markers.CODING_STYLE_PRECINCTS_USER != 0) {
            const remaining = @as(usize, length) -| 12;
            if (remaining > 0) {
                precinct_sizes = try self.allocator.alloc(u8, remaining);
                alloc_used = self.allocator;
                for (0..remaining) |i| {
                    precinct_sizes[i] = self.br.readU8() catch return error.EndOfStream;
                }
            }
        }

        self.cod = .{
            .scod = scod,
            .progression = progression,
            .num_layers = num_layers,
            .mct = mct,
            .decomp_levels = decomp_levels,
            .cb_width_exp = cb_width_exp,
            .cb_height_exp = cb_height_exp,
            .cb_style = cb_style,
            .transform = transform,
            .precinct_sizes = precinct_sizes,
            .allocator = alloc_used,
        };
    }

    fn readQcd(self: *CodestreamReader) CodecError!void {
        const length = self.br.readU16() catch return error.EndOfStream;
        if (length < 4) return error.InvalidData;
        const sqcd_byte = self.br.readU8() catch return error.EndOfStream;
        const guard_bits = (sqcd_byte >> 5) & 0x07;
        const q_style = sqcd_byte & 0x1F;

        const remaining = @as(usize, length) -| 3;
        var step_sizes: []i16 = &.{};
        var alloc_used: ?Allocator = null;

        if (q_style == 0) {
            // No quantization (reversible) -- each entry is 1 byte.
            if (remaining > 0) {
                step_sizes = try self.allocator.alloc(i16, remaining);
                alloc_used = self.allocator;
                for (0..remaining) |i| {
                    const exp = self.br.readU8() catch return error.EndOfStream;
                    step_sizes[i] = @as(i16, exp >> 3);
                }
            }
        } else {
            // Skip unsupported quantization styles.
            self.br.skip(remaining) catch return error.EndOfStream;
        }

        self.qcd = .{
            .sqcd = q_style,
            .guard_bits = guard_bits,
            .step_sizes = step_sizes,
            .allocator = alloc_used,
        };
    }
};

// ---------------------------------------------------------------------------
// Find a marker in raw data
// ---------------------------------------------------------------------------

fn findMarker(data: []const u8, marker: u16) ?usize {
    const hi: u8 = @intCast((marker >> 8) & 0xFF);
    const lo: u8 = @intCast(marker & 0xFF);
    if (data.len < 2) return null;
    for (0..data.len - 1) |i| {
        if (data[i] == hi and data[i + 1] == lo) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Public API: encode
// ---------------------------------------------------------------------------

/// Encode a 16-bit grayscale image into JPEG 2000 codestream format.
///
/// `pixels` is a row-major pixel buffer of length `img_width * img_height`.
/// Caller owns the returned slice and must free it with `allocator`.
pub fn encode(
    allocator: Allocator,
    pixels: []const u16,
    img_width: u32,
    img_height: u32,
    options: *const Jpeg2kOptions,
) CodecError![]u8 {
    const width: usize = img_width;
    const height: usize = img_height;
    const expected = width * height;

    if (pixels.len != expected) {
        return error.DimensionMismatch;
    }

    if (width == 0 or height == 0) {
        return error.InvalidData;
    }

    // Convert pixel data to i32 for DWT processing.
    const component = try allocator.alloc(i32, expected);
    defer allocator.free(component);
    for (0..expected) |i| {
        component[i] = @as(i32, pixels[i]);
    }

    // Build marker structures.
    var comp_info = [_]ComponentInfo{.{
        .precision = 16,
        .signed = false,
        .x_rsiz = 1,
        .y_rsiz = 1,
    }};
    var siz = markers.buildSiz(
        @intCast(width),
        @intCast(height),
        &comp_info,
        options.tile_width,
        options.tile_height,
    );
    const cod = markers.buildDefaultCod(options.num_decomp_levels, 1, false);
    var qcd = try markers.buildDefaultQcd(allocator, options.num_decomp_levels, 2);
    defer qcd.deinit();

    // Encode the tile.
    const te = TileEncoder.init(width, height, options.num_decomp_levels);
    const tile_data = try te.encodeTile(allocator, component);
    defer allocator.free(tile_data);

    // Build the codestream.
    var cw = CodestreamWriter.init(allocator);
    errdefer cw.deinit();
    try cw.writeSoc();
    try cw.writeSiz(&siz);
    try cw.writeCod(&cod);
    try cw.writeQcd(&qcd);

    // SOT: total length = 12 (SOT marker segment) + 2 (SOD marker) + tile_data
    const tile_part_len: u32 = @intCast(12 + 2 + tile_data.len);
    const num_tiles = siz.numTiles();
    for (0..num_tiles) |tile_idx| {
        const sot = SotMarker{
            .tile_index = @intCast(tile_idx),
            .tile_part_len = tile_part_len,
            .tile_part_idx = 0,
            .num_tile_parts = 1,
        };
        try cw.writeSot(&sot);
        try cw.writeSod();
        try cw.writeBytes(tile_data);
    }

    try cw.writeEoc();

    return cw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Public API: decode
// ---------------------------------------------------------------------------

/// Decode a JPEG 2000 codestream into a 16-bit grayscale pixel buffer.
///
/// The `width` and `height` parameters are used for validation against the
/// SIZ marker.
///
/// Returns `(pixels, width, height)` where pixels is a row-major slice.
/// Caller owns the returned pixels slice and must free it with `allocator`.
pub fn decode(
    allocator: Allocator,
    data: []const u8,
    width: u32,
    height: u32,
) CodecError!struct { []u16, u32, u32 } {
    if (data.len < 4) {
        return error.InvalidData;
    }

    // Check SOC.
    if (data[0] != 0xFF or data[1] != 0x4F) {
        return error.InvalidData;
    }

    // Parse main header.
    var cr = CodestreamReader.init(allocator, data);
    defer cr.deinit();
    try cr.readMainHeader();

    const siz = cr.siz orelse return error.InvalidData;
    const cod = cr.cod orelse return error.InvalidData;

    const img_w = siz.x_siz - siz.x_osiz;
    const img_h = siz.y_siz - siz.y_osiz;

    // Validate against caller-provided dimensions.
    if (img_w != width or img_h != height) {
        return error.DimensionMismatch;
    }

    const decomp_levels: usize = cod.decomp_levels;

    // Find SOT marker.
    const sot_pos = findMarker(data, markers.MARKER_SOT) orelse return error.InvalidData;

    // Skip SOT marker (2 bytes) + SOT length field.
    var pos = sot_pos + 2;
    const sot_len = (@as(usize, data[pos]) << 8) | @as(usize, data[pos + 1]);
    pos += sot_len;

    // Find SOD.
    const sod_pos = findMarker(data[pos..], markers.MARKER_SOD) orelse return error.InvalidData;
    pos += sod_pos + 2; // skip SOD marker

    // Decode tile data for each component (we only support 1 component).
    const td = TileDecoder.init(decomp_levels);
    if (pos >= data.len) {
        return error.InvalidData;
    }

    const result = try td.decodeTile(allocator, data[pos..]);
    defer allocator.free(result[2]);
    const dw = result[0];
    const dh = result[1];
    const pixels_i32 = result[2];

    if (dw != img_w or dh != img_h) {
        return error.DimensionMismatch;
    }

    // Convert i32 back to u16, clamping to valid range.
    const pixel_count = pixels_i32.len;
    const expected_count = @as(usize, width) * @as(usize, height);

    if (pixel_count != expected_count) {
        return error.DimensionMismatch;
    }

    const u16_pixels = try allocator.alloc(u16, pixel_count);
    errdefer allocator.free(u16_pixels);
    for (0..pixel_count) |i| {
        u16_pixels[i] = @intCast(std.math.clamp(pixels_i32[i], 0, std.math.maxInt(u16)));
    }

    return .{ u16_pixels, width, height };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Helper to create test pixels.
fn makeTestPixels(allocator: Allocator, w: u32, h: u32, comptime patternFn: fn (u32, u32) u16) Allocator.Error![]u16 {
    const data = try allocator.alloc(u16, @as(usize, w) * @as(usize, h));
    var idx: usize = 0;
    for (0..h) |y| {
        for (0..w) |x| {
            data[idx] = patternFn(@intCast(x), @intCast(y));
            idx += 1;
        }
    }
    return data;
}

fn constantPattern(_: u32, _: u32) u16 {
    return 1000;
}

fn gradientPattern(x: u32, y: u32) u16 {
    return @intCast((x + y * 32) % 65536);
}

fn zeroPattern(_: u32, _: u32) u16 {
    return 0;
}

fn maxPattern(_: u32, _: u32) u16 {
    return std.math.maxInt(u16);
}

fn checkerPattern(x: u32, y: u32) u16 {
    return if ((x + y) % 2 == 0) 0 else 65535;
}

fn nonSquarePattern(x: u32, y: u32) u16 {
    return @intCast(x * 100 + y * 10);
}

fn oddDimsPattern(x: u32, y: u32) u16 {
    return @intCast(x * y);
}

fn largeImagePattern(x: u32, y: u32) u16 {
    return @intCast((x *% 31 ^ y *% 17) % 65536);
}

fn constPattern42(_: u32, _: u32) u16 {
    return 42;
}

fn constPattern100(_: u32, _: u32) u16 {
    return 100;
}

fn constPattern12345(_: u32, _: u32) u16 {
    return 12345;
}

fn decomp1Pattern(x: u32, y: u32) u16 {
    return @intCast(x * 256 + y * 16);
}

test "codestream roundtrip constant image" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 16, 16, constantPattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 16, 16, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 16, 16);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip gradient" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 32, 32, gradientPattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 32, 32, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 32, 32);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip all zeros" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 8, 8, zeroPattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 8, 8, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 8, 8);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip max value" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 8, 8, maxPattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 8, 8, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 8, 8);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip checkerboard" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 16, 16, checkerPattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 16, 16, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 16, 16);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip non square" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 24, 8, nonSquarePattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{ .num_decomp_levels = 3 };
    const buf = try encode(allocator, pixels, 24, 8, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 24, 8);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip odd dims" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 13, 7, oddDimsPattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{ .num_decomp_levels = 2 };
    const buf = try encode(allocator, pixels, 13, 7, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 13, 7);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip large image" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 128, 128, largeImagePattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 128, 128, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 128, 128);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream starts with soc" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 8, 8, constPattern42);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 8, 8, &opts);
    defer allocator.free(buf);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x4F), buf[1]);
}

test "codestream ends with eoc" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 8, 8, constPattern42);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 8, 8, &opts);
    defer allocator.free(buf);
    const n = buf.len;
    try std.testing.expectEqual(@as(u8, 0xFF), buf[n - 2]);
    try std.testing.expectEqual(@as(u8, 0xD9), buf[n - 1]);
}

test "decode invalid data" {
    const allocator = std.testing.allocator;
    const result1 = decode(allocator, &.{}, 8, 8);
    try std.testing.expectError(error.InvalidData, result1);
    const result2 = decode(allocator, &.{ 0x00, 0x00 }, 8, 8);
    try std.testing.expectError(error.InvalidData, result2);
}

test "decode dimension mismatch" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 8, 8, constPattern100);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{};
    const buf = try encode(allocator, pixels, 8, 8, &opts);
    defer allocator.free(buf);
    // Try decoding with wrong dimensions.
    const result = decode(allocator, buf, 16, 16);
    try std.testing.expectError(error.DimensionMismatch, result);
}

test "codestream roundtrip single pixel" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 2, 2, constPattern12345);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{ .num_decomp_levels = 1 };
    const buf = try encode(allocator, pixels, 2, 2, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 2, 2);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}

test "codestream roundtrip decomp levels 1" {
    const allocator = std.testing.allocator;
    const pixels = try makeTestPixels(allocator, 16, 16, decomp1Pattern);
    defer allocator.free(pixels);
    const opts = Jpeg2kOptions{ .num_decomp_levels = 1 };
    const buf = try encode(allocator, pixels, 16, 16, &opts);
    defer allocator.free(buf);
    const result = try decode(allocator, buf, 16, 16);
    defer allocator.free(result[0]);
    try std.testing.expectEqualSlices(u16, pixels, result[0]);
}
