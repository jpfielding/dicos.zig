//! JPEG Lossless codec (ITU-T T.81 Annex H).
//!
//! Implements DICOM Process 14 Selection Value 1 with 7 DPCM predictors and
//! Huffman entropy coding for single-component grayscale (precision `2..=16`),
//! with point transform and row-aligned restart intervals (H.1.1). Verified
//! against libjpeg-turbo >= 3.0.
//!
//! | Selection | Formula             | Name       |
//! |-----------|---------------------|------------|
//! | 1         | Ra                  | Left       |
//! | 2         | Rb                  | Above      |
//! | 3         | Rc                  | Above-left |
//! | 4         | Ra + Rb - Rc        | Linear     |
//! | 5         | Ra + ((Rb - Rc)>>1) |            |
//! | 6         | Rb + ((Ra - Rc)>>1) |            |
//! | 7         | (Ra + Rb) >> 1      | Average    |
//!
//! ```zig
//! const buf = try jpegli.encode(allocator, &pixels, 2, 2);
//! defer allocator.free(buf);
//! const res = try jpegli.decode(allocator, buf, 2, 2);
//! defer res.deinit(allocator);
//! ```

const encode_mod = @import("encode.zig");
const decode_mod = @import("decode.zig");

/// Error set and optional error details (mirrors the Rust `error` module).
pub const errors = @import("error.zig");
pub const CodecError = errors.CodecError;
pub const Diagnostics = errors.Diagnostics;

pub const EncodeOptions = encode_mod.EncodeOptions;
pub const encode = encode_mod.encode;
pub const encodeWithOptions = encode_mod.encodeWithOptions;
pub const encodeWithOptionsDiag = encode_mod.encodeWithOptionsDiag;

pub const DecodeResult = decode_mod.DecodeResult;
pub const decode = decode_mod.decode;
pub const decodeDiag = decode_mod.decodeDiag;

/// DICOM Transfer Syntax UID for JPEG Lossless, Non-Hierarchical (Process 14, SV1).
pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.4.70";

test {
    _ = @import("error.zig");
    _ = @import("huffman.zig");
    _ = @import("scan.zig");
    _ = @import("encode.zig");
    _ = @import("decode.zig");
    _ = @import("mutation_test.zig");
    _ = @import("interop_test.zig");
}
