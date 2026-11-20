//! JPEG 2000 Part-1 lossless codec (ITU-T T.800).
//!
//! Implements reversible 5/3 DWT, EBCOT tier-1/tier-2 coding, and MQ
//! arithmetic coding for lossless image compression. Zig port of the Rust
//! `pure_jpeg2k` crate 2.1.0 (byte-identical encoder output).
//!
//! # Conformance scope
//!
//! Emits conformant T.800 codestreams for a single unsigned-16-bit component,
//! one tile, LRCP, one layer, `cb_style = 0`, zero grid origins; everything
//! else legal-but-unsupported is rejected via a validated support matrix.
//! 1.0.0 / Go raw-DWT files remain decodable via `LegacyPolicy` (`auto` by
//! default).

const std = @import("std");

pub const bitstream = @import("bitstream.zig");
pub const codestream = @import("codestream.zig");
pub const dwt = @import("dwt.zig");
pub const ebcot = @import("ebcot.zig");
pub const geometry = @import("geometry.zig");
pub const legacy = @import("legacy.zig");
pub const markers = @import("markers.zig");
pub const mq = @import("mq.zig");
pub const packet = @import("packet.zig");
pub const rct = @import("rct.zig");
pub const tagtree = @import("tagtree.zig");
pub const tile = @import("tile.zig");

pub const CodecError = @import("error.zig").CodecError;

pub const encode = codestream.encode;
pub const encodeWithOptions = codestream.encodeWithOptions;
pub const decode = codestream.decode;
pub const decodeWithOptions = codestream.decodeWithOptions;
pub const DecodeOptions = codestream.DecodeOptions;
pub const LegacyPolicy = codestream.LegacyPolicy;
pub const DecodedImage = codestream.DecodedImage;

/// DICOM Transfer Syntax UID for JPEG 2000 Lossless.
pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.4.90";

/// Options for JPEG 2000 encoding.
pub const Jpeg2kOptions = struct {
    /// Tile width (0 = single tile). Non-zero is `Unsupported`.
    tile_width: u32 = 0,
    /// Tile height (0 = single tile). Non-zero is `Unsupported`.
    tile_height: u32 = 0,
    /// Code-block width exponent (typical: 6 for 64).
    cb_width_exp: u8 = 6,
    /// Code-block height exponent (typical: 6 for 64).
    cb_height_exp: u8 = 6,
    /// Number of decomposition levels.
    num_decomp_levels: u8 = 5,

    /// Validate against the supported T.800 profile:
    /// - code-block exponents each in `2..=10`, sum `<= 12` (Table A.18)
    ///   -> `InvalidData`;
    /// - decomposition levels `<= 32` -> `InvalidData`;
    /// - tiling (`tile_width`/`tile_height` non-zero) -> `Unsupported`.
    pub fn validate(self: Jpeg2kOptions) CodecError!void {
        if (self.cb_width_exp < 2 or self.cb_width_exp > 10) return error.InvalidData;
        if (self.cb_height_exp < 2 or self.cb_height_exp > 10) return error.InvalidData;
        if (@as(u16, self.cb_width_exp) + self.cb_height_exp > 12) return error.InvalidData;
        if (self.num_decomp_levels > 32) return error.InvalidData;
        if (self.tile_width != 0 or self.tile_height != 0) return error.Unsupported;
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests/mutation.zig");
    _ = @import("tests/legacy_fixtures.zig");
    _ = @import("tests/interop.zig");
    _ = @import("tests/parity.zig");
}
