//! DICOM RLE PackBits Lossless codec.
//!
//! Implements DICOM Part 5 Section 8.1.1 -- RLE compression for
//! 16-bit grayscale images using byte-plane splitting and PackBits.

pub const packbits = @import("packbits.zig");
pub const encode = @import("encode.zig");
pub const decode = @import("decode.zig");

pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.5";

test {
    _ = @import("packbits.zig");
    _ = @import("encode.zig");
    _ = @import("decode.zig");
}
