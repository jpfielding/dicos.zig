//! JPEG 2000 marker definitions and structures (ITU-T T.800 Part-1).
//!
//! Defines SOC, SIZ, COD, QCD, SOT, SOD, EOC markers and their associated
//! data structures for codestream parsing and generation.

const std = @import("std");

// ---------------------------------------------------------------------------
// Marker codes (ITU-T T.800 Table A.1)
// ---------------------------------------------------------------------------

/// Start of codestream.
pub const MARKER_SOC: u16 = 0xFF4F;
/// Image and tile size.
pub const MARKER_SIZ: u16 = 0xFF51;
/// Coding style default.
pub const MARKER_COD: u16 = 0xFF52;
/// Coding style component.
pub const MARKER_COC: u16 = 0xFF53;
/// Quantization default.
pub const MARKER_QCD: u16 = 0xFF5C;
/// Quantization component.
pub const MARKER_QCC: u16 = 0xFF5D;
/// Region of interest.
pub const MARKER_RGN: u16 = 0xFF5E;
/// Progression order change.
pub const MARKER_POC: u16 = 0xFF5F;
/// Tile-part lengths, main header.
pub const MARKER_TLM: u16 = 0xFF55;
/// Packet length, main header.
pub const MARKER_PLM: u16 = 0xFF57;
/// Packet length, tile-part header.
pub const MARKER_PLT: u16 = 0xFF58;
/// Packed packet headers, main header.
pub const MARKER_PPM: u16 = 0xFF60;
/// Packed packet headers, tile-part header.
pub const MARKER_PPT: u16 = 0xFF61;
/// Start of tile-part.
pub const MARKER_SOT: u16 = 0xFF90;
/// Start of data (ITU-T T.800 Table A-1: `0xFF93`).
pub const MARKER_SOD: u16 = 0xFF93;
/// Start of data as emitted by the non-conformant v1.0.0 / Go writer
/// (`0xFFD3`). Accepted by the decoder so archived legacy files keep decoding.
pub const MARKER_SOD_LEGACY: u16 = 0xFFD3;
/// End of codestream.
pub const MARKER_EOC: u16 = 0xFFD9;
/// Component registration.
pub const MARKER_CRG: u16 = 0xFF63;
/// Comment.
pub const MARKER_COM: u16 = 0xFF64;

// ---------------------------------------------------------------------------
// Progression order / transform type
// ---------------------------------------------------------------------------

/// Progression order for a JPEG 2000 codestream.
pub const ProgressionOrder = enum(u8) {
    /// Layer-Resolution-Component-Position.
    lrcp = 0,
    /// Resolution-Layer-Component-Position.
    rlcp = 1,
    /// Resolution-Position-Component-Layer.
    rpcl = 2,
    /// Position-Component-Resolution-Layer.
    pcrl = 3,
    /// Component-Position-Resolution-Layer.
    cprl = 4,

    pub fn fromByte(b: u8) ?ProgressionOrder {
        return std.meta.intToEnum(ProgressionOrder, b) catch null;
    }
};

/// Wavelet transform type.
pub const TransformType = enum(u8) {
    /// 9/7 irreversible (lossy).
    irreversible_97 = 0,
    /// 5/3 reversible (lossless).
    reversible_53 = 1,

    pub fn fromByte(b: u8) ?TransformType {
        return std.meta.intToEnum(TransformType, b) catch null;
    }
};

// ---------------------------------------------------------------------------
// Coding style flags (ITU-T T.800 Table A.13)
// ---------------------------------------------------------------------------

/// Custom precinct sizes present (Scod bit 0).
pub const CODING_STYLE_PRECINCTS_USER: u8 = 0x01;
/// SOP marker segments used (Scod bit 1).
pub const CODING_STYLE_SOP: u8 = 0x02;
/// EPH marker segments used (Scod bit 2).
pub const CODING_STYLE_EPH: u8 = 0x04;

// ---------------------------------------------------------------------------
// Marker segment structures
// ---------------------------------------------------------------------------

/// Per-component information from the SIZ marker.
pub const ComponentInfo = struct {
    /// Bit depth (1-38).
    precision: u8,
    /// `true` if signed samples.
    signed: bool,
    /// Horizontal sub-sampling factor.
    x_rsiz: u8,
    /// Vertical sub-sampling factor.
    y_rsiz: u8,
};

/// Image and tile size parameters (T.800 A.5.1).
pub const SizMarker = struct {
    rsiz: u16,
    x_siz: u32,
    y_siz: u32,
    x_osiz: u32,
    y_osiz: u32,
    x_tsiz: u32,
    y_tsiz: u32,
    x_tosiz: u32,
    y_tosiz: u32,
    /// Per-component info (borrowed).
    components: []const ComponentInfo,

    /// Number of tiles horizontally.
    pub fn numXTiles(self: *const SizMarker) u32 {
        return std.math.divCeil(u32, self.x_siz - self.x_tosiz, self.x_tsiz) catch unreachable;
    }

    /// Number of tiles vertically.
    pub fn numYTiles(self: *const SizMarker) u32 {
        return std.math.divCeil(u32, self.y_siz - self.y_tosiz, self.y_tsiz) catch unreachable;
    }

    /// Total number of tiles.
    pub fn numTiles(self: *const SizMarker) u32 {
        return self.numXTiles() * self.numYTiles();
    }
};

/// Coding style default parameters (T.800 A.6.1).
pub const CodMarker = struct {
    scod: u8,
    progression: ProgressionOrder,
    num_layers: u16,
    /// Multiple component transform (0 = none, 1 = RCT/ICT).
    mct: u8,
    decomp_levels: u8,
    /// Code-block width exponent offset (actual exp = value + 2).
    cb_width_exp: u8,
    /// Code-block height exponent offset (actual exp = value + 2).
    cb_height_exp: u8,
    cb_style: u8,
    transform: TransformType,
    /// Precinct sizes (if `scod & 0x01`; always empty in this profile).
    precinct_sizes: []const u8 = &.{},

    /// Actual code-block width.
    pub fn codeBlockWidth(self: *const CodMarker) usize {
        return @as(usize, 1) << @intCast(self.cb_width_exp + 2);
    }

    /// Actual code-block height.
    pub fn codeBlockHeight(self: *const CodMarker) usize {
        return @as(usize, 1) << @intCast(self.cb_height_exp + 2);
    }
};

/// Quantization default parameters (T.800 A.6.4).
pub const QcdMarker = struct {
    /// Quantization style (lower 5 bits of Sqcd).
    sqcd: u8,
    /// Number of guard bits (upper 3 bits of Sqcd).
    guard_bits: u8,
    /// Quantization exponents (borrowed or owned by the caller).
    step_sizes: []const i16,
};

/// Tile-part header parameters (T.800 A.4.2).
pub const SotMarker = struct {
    tile_index: u16,
    /// Length of tile-part (incl. SOT marker segment).
    tile_part_len: u32,
    tile_part_idx: u8,
    /// Number of tile-parts (0 = not specified).
    num_tile_parts: u8,
};

// ---------------------------------------------------------------------------
// Builder helpers
// ---------------------------------------------------------------------------

/// Build a SIZ marker for the given image dimensions and components.
pub fn buildSiz(
    width: u32,
    height: u32,
    components: []const ComponentInfo,
    tile_width: u32,
    tile_height: u32,
) SizMarker {
    return .{
        .rsiz = 0,
        .x_siz = width,
        .y_siz = height,
        .x_osiz = 0,
        .y_osiz = 0,
        .x_tsiz = if (tile_width == 0) width else tile_width,
        .y_tsiz = if (tile_height == 0) height else tile_height,
        .x_tosiz = 0,
        .y_tosiz = 0,
        .components = components,
    };
}

/// Build the COD marker for the supported lossless profile.
///
/// `cb_width_exp` / `cb_height_exp` are the **actual** code-block exponents
/// (block size `2^exp`, legal range `2..=10`). Per T.800 A.6.1 the COD stores
/// them offset by `-2`. The profile fixes `Scod = 0`, LRCP, one layer, no
/// MCT, `cb_style = 0`, reversible 5/3.
pub fn buildCod(num_decomp_levels: u8, cb_width_exp: u8, cb_height_exp: u8) CodMarker {
    return .{
        .scod = 0,
        .progression = .lrcp,
        .num_layers = 1,
        .mct = 0,
        .decomp_levels = num_decomp_levels,
        .cb_width_exp = cb_width_exp -| 2,
        .cb_height_exp = cb_height_exp -| 2,
        .cb_style = 0,
        .transform = .reversible_53,
    };
}

// ---------------------------------------------------------------------------
// Subband
// ---------------------------------------------------------------------------

/// Identifies a subband in the DWT decomposition.
pub const Subband = enum {
    /// Low-Low (approximation).
    LL,
    /// High-Low (horizontal detail).
    HL,
    /// Low-High (vertical detail).
    LH,
    /// High-High (diagonal detail).
    HH,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const gray16 = [_]ComponentInfo{.{ .precision = 16, .signed = false, .x_rsiz = 1, .y_rsiz = 1 }};

test "siz num tiles single" {
    const siz = buildSiz(256, 256, &gray16, 0, 0);
    try testing.expectEqual(@as(u32, 1), siz.numTiles());
}

test "siz num tiles multiple" {
    const siz = buildSiz(256, 256, &gray16, 128, 128);
    try testing.expectEqual(@as(u32, 4), siz.numTiles());
}

test "cod code block dims" {
    // Actual exponent 6 -> 64x64 blocks; the marker stores exp - 2 = 4.
    const cod = buildCod(5, 6, 6);
    try testing.expectEqual(@as(u8, 4), cod.cb_width_exp);
    try testing.expectEqual(@as(u8, 4), cod.cb_height_exp);
    try testing.expectEqual(@as(usize, 64), cod.codeBlockWidth());
    try testing.expectEqual(@as(usize, 64), cod.codeBlockHeight());
    try testing.expectEqual(@as(u16, 1), cod.num_layers);
    try testing.expectEqual(@as(u8, 0), cod.mct);
    try testing.expectEqual(@as(u8, 0), cod.scod);
}

test "cod smallest blocks" {
    const cod = buildCod(1, 2, 2);
    try testing.expectEqual(@as(u8, 0), cod.cb_width_exp);
    try testing.expectEqual(@as(usize, 4), cod.codeBlockWidth());
}

test "progression order roundtrip" {
    for ([_]u8{ 0, 1, 2, 3, 4 }) |b| {
        const p = ProgressionOrder.fromByte(b).?;
        try testing.expectEqual(b, @intFromEnum(p));
    }
    try testing.expect(ProgressionOrder.fromByte(5) == null);
}

test "transform type roundtrip" {
    try testing.expectEqual(TransformType.irreversible_97, TransformType.fromByte(0).?);
    try testing.expectEqual(TransformType.reversible_53, TransformType.fromByte(1).?);
    try testing.expect(TransformType.fromByte(2) == null);
}
