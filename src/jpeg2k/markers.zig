//! JPEG 2000 marker definitions and structures (ITU-T T.800 Part-1).
//!
//! Defines SOC, SIZ, COD, QCD, SOT, SOD, EOC markers and their
//! associated data structures for codestream parsing and generation.

const std = @import("std");
const Allocator = std.mem.Allocator;

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
/// Start of tile-part.
pub const MARKER_SOT: u16 = 0xFF90;
/// Start of data.
pub const MARKER_SOD: u16 = 0xFFD3;
/// End of codestream.
pub const MARKER_EOC: u16 = 0xFFD9;
/// Comment.
pub const MARKER_COM: u16 = 0xFF64;

// ---------------------------------------------------------------------------
// Progression order
// ---------------------------------------------------------------------------

/// Progression order for JPEG 2000 codestream.
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
        return std.enums.fromInt(ProgressionOrder, b);
    }
};

// ---------------------------------------------------------------------------
// Transform type
// ---------------------------------------------------------------------------

/// Wavelet transform type.
pub const TransformType = enum(u8) {
    /// 9/7 irreversible (lossy).
    irreversible97 = 0,
    /// 5/3 reversible (lossless).
    reversible53 = 1,

    pub fn fromByte(b: u8) ?TransformType {
        return std.enums.fromInt(TransformType, b);
    }
};

// ---------------------------------------------------------------------------
// Coding style flags (ITU-T T.800 Table A.13)
// ---------------------------------------------------------------------------

/// Custom precinct sizes present.
pub const CODING_STYLE_PRECINCTS_USER: u8 = 0x01;

// ---------------------------------------------------------------------------
// Component info
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

// ---------------------------------------------------------------------------
// SIZ marker (ITU-T T.800 A.5.1)
// ---------------------------------------------------------------------------

/// Image and tile size parameters.
pub const SizMarker = struct {
    /// Capabilities required.
    rsiz: u16,
    /// Reference grid width.
    x_siz: u32,
    /// Reference grid height.
    y_siz: u32,
    /// Horizontal image offset.
    x_osiz: u32,
    /// Vertical image offset.
    y_osiz: u32,
    /// Tile width.
    x_tsiz: u32,
    /// Tile height.
    y_tsiz: u32,
    /// Tile horizontal offset.
    x_tosiz: u32,
    /// Tile vertical offset.
    y_tosiz: u32,
    /// Per-component info (heap-allocated).
    components: []ComponentInfo,
    /// Allocator used for components (null if not heap-allocated).
    allocator: ?Allocator,

    /// Number of tiles horizontally.
    pub fn numXTiles(self: *const SizMarker) u32 {
        return (self.x_siz - self.x_tosiz + self.x_tsiz - 1) / self.x_tsiz;
    }

    /// Number of tiles vertically.
    pub fn numYTiles(self: *const SizMarker) u32 {
        return (self.y_siz - self.y_tosiz + self.y_tsiz - 1) / self.y_tsiz;
    }

    /// Total number of tiles.
    pub fn numTiles(self: *const SizMarker) u32 {
        return self.numXTiles() * self.numYTiles();
    }

    pub fn deinit(self: *SizMarker) void {
        if (self.allocator) |alloc| {
            alloc.free(self.components);
        }
    }
};

// ---------------------------------------------------------------------------
// COD marker (ITU-T T.800 A.6.1)
// ---------------------------------------------------------------------------

/// Coding style default parameters.
pub const CodMarker = struct {
    /// Coding style byte (Scod).
    scod: u8,
    /// Progression order.
    progression: ProgressionOrder,
    /// Number of quality layers.
    num_layers: u16,
    /// Multiple component transform (0 = none, 1 = RCT/ICT).
    mct: u8,
    /// Number of decomposition levels.
    decomp_levels: u8,
    /// Code-block width exponent offset (actual exp = value + 2).
    cb_width_exp: u8,
    /// Code-block height exponent offset (actual exp = value + 2).
    cb_height_exp: u8,
    /// Code-block style flags.
    cb_style: u8,
    /// Wavelet transform type.
    transform: TransformType,
    /// Precinct sizes (if `scod & 0x01`), heap-allocated.
    precinct_sizes: []u8,
    /// Allocator used for precinct_sizes (null if not heap-allocated).
    allocator: ?Allocator,

    /// Actual code-block width.
    pub fn codeBlockWidth(self: *const CodMarker) usize {
        return @as(usize, 1) << @intCast(self.cb_width_exp + 2);
    }

    /// Actual code-block height.
    pub fn codeBlockHeight(self: *const CodMarker) usize {
        return @as(usize, 1) << @intCast(self.cb_height_exp + 2);
    }

    pub fn deinit(self: *CodMarker) void {
        if (self.allocator) |alloc| {
            if (self.precinct_sizes.len > 0) {
                alloc.free(self.precinct_sizes);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// QCD marker (ITU-T T.800 A.6.4)
// ---------------------------------------------------------------------------

/// Quantization default parameters.
pub const QcdMarker = struct {
    /// Quantization style (lower 5 bits of Sqcd).
    sqcd: u8,
    /// Number of guard bits (upper 3 bits of Sqcd).
    guard_bits: u8,
    /// Quantization step sizes / exponents, heap-allocated.
    step_sizes: []i16,
    /// Allocator used for step_sizes (null if not heap-allocated).
    allocator: ?Allocator,

    pub fn deinit(self: *QcdMarker) void {
        if (self.allocator) |alloc| {
            alloc.free(self.step_sizes);
        }
    }
};

// ---------------------------------------------------------------------------
// SOT marker (ITU-T T.800 A.4.2)
// ---------------------------------------------------------------------------

/// Tile-part header parameters.
pub const SotMarker = struct {
    /// Tile index.
    tile_index: u16,
    /// Length of tile-part (incl. SOT marker segment).
    tile_part_len: u32,
    /// Tile-part index.
    tile_part_idx: u8,
    /// Number of tile-parts (0 = not specified).
    num_tile_parts: u8,
};

// ---------------------------------------------------------------------------
// Builder helpers
// ---------------------------------------------------------------------------

/// Build a SIZ marker for the given image dimensions and components.
/// The `components` slice is borrowed (not copied), so caller retains ownership.
pub fn buildSiz(
    width: u32,
    height: u32,
    components: []ComponentInfo,
    tile_width: u32,
    tile_height: u32,
) SizMarker {
    const tw = if (tile_width == 0) width else tile_width;
    const th = if (tile_height == 0) height else tile_height;
    return .{
        .rsiz = 0,
        .x_siz = width,
        .y_siz = height,
        .x_osiz = 0,
        .y_osiz = 0,
        .x_tsiz = tw,
        .y_tsiz = th,
        .x_tosiz = 0,
        .y_tosiz = 0,
        .components = components,
        .allocator = null,
    };
}

/// Build a default COD marker for lossless encoding.
pub fn buildDefaultCod(decomp_levels: u8, num_layers: u16, mct: bool) CodMarker {
    return .{
        .scod = 0,
        .progression = .lrcp,
        .num_layers = num_layers,
        .mct = if (mct) 1 else 0,
        .decomp_levels = decomp_levels,
        .cb_width_exp = 4, // 64x64 code-blocks
        .cb_height_exp = 4,
        .cb_style = 0,
        .transform = .reversible53,
        .precinct_sizes = &.{},
        .allocator = null,
    };
}

/// Build a default QCD marker for lossless (reversible) encoding.
pub fn buildDefaultQcd(allocator: Allocator, decomp_levels: u8, guard_bits: u8) Allocator.Error!QcdMarker {
    const num_subbands = 3 * @as(usize, decomp_levels) + 1;
    const step_sizes = try allocator.alloc(i16, num_subbands);
    @memset(step_sizes, 0);
    return .{
        .sqcd = 0, // Reversible, no quantization
        .guard_bits = guard_bits,
        .step_sizes = step_sizes,
        .allocator = allocator,
    };
}

// ---------------------------------------------------------------------------
// Subband
// ---------------------------------------------------------------------------

/// Identifies a subband in the DWT decomposition.
pub const Subband = enum {
    /// Low-Low (approximation).
    ll,
    /// High-Low (horizontal detail).
    hl,
    /// Low-High (vertical detail).
    lh,
    /// High-High (diagonal detail).
    hh,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "siz num tiles single" {
    var comp = [_]ComponentInfo{.{
        .precision = 16,
        .signed = false,
        .x_rsiz = 1,
        .y_rsiz = 1,
    }};
    var siz = buildSiz(256, 256, &comp, 0, 0);
    _ = &siz;
    try std.testing.expectEqual(@as(u32, 1), siz.numTiles());
}

test "siz num tiles multiple" {
    var comp = [_]ComponentInfo{.{
        .precision = 16,
        .signed = false,
        .x_rsiz = 1,
        .y_rsiz = 1,
    }};
    var siz = buildSiz(256, 256, &comp, 128, 128);
    _ = &siz;
    try std.testing.expectEqual(@as(u32, 4), siz.numTiles());
}

test "cod code block dims" {
    const cod = buildDefaultCod(5, 1, false);
    try std.testing.expectEqual(@as(usize, 64), cod.codeBlockWidth());
    try std.testing.expectEqual(@as(usize, 64), cod.codeBlockHeight());
}

test "qcd subband count" {
    const allocator = std.testing.allocator;
    var qcd = try buildDefaultQcd(allocator, 5, 2);
    defer qcd.deinit();
    try std.testing.expectEqual(@as(usize, 16), qcd.step_sizes.len); // 3*5 + 1
}

test "progression order roundtrip" {
    const bytes = [_]u8{ 0, 1, 2, 3, 4 };
    for (bytes) |b| {
        const p = ProgressionOrder.fromByte(b);
        try std.testing.expect(p != null);
        try std.testing.expectEqual(b, @intFromEnum(p.?));
    }
    try std.testing.expect(ProgressionOrder.fromByte(5) == null);
}

test "transform type roundtrip" {
    try std.testing.expectEqual(TransformType.irreversible97, TransformType.fromByte(0).?);
    try std.testing.expectEqual(TransformType.reversible53, TransformType.fromByte(1).?);
    try std.testing.expect(TransformType.fromByte(2) == null);
}
