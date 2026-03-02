//! JPEG Lossless (Process 14, SV1) codec.
//!
//! Implements ITU-T T.81 Annex H -- JPEG Lossless coding with
//! 7 DPCM predictors and Huffman entropy coding.

pub const huffman = @import("huffman.zig");
pub const scan = @import("scan.zig");
pub const encode = @import("encode.zig");
pub const decode = @import("decode.zig");

pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.4.70";

test {
    _ = @import("huffman.zig");
    _ = @import("scan.zig");
    _ = @import("encode.zig");
    _ = @import("decode.zig");
}
