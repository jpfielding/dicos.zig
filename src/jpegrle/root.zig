//! DICOM RLE PackBits lossless codec.
//!
//! Implements DICOM Part 5 Section 8.1.1 Run Length Encoding. 16-bit images are
//! split into high-byte and low-byte segments for improved compression.
//!
//! ```zig
//! const buf = try jpegrle.encode(allocator, &pixels, 2, 2);
//! defer allocator.free(buf);
//! const res = try jpegrle.decode(allocator, buf, 2, 2);
//! defer res.deinit(allocator);
//! ```

const encode_mod = @import("encode.zig");
const decode_mod = @import("decode.zig");

/// Error set and optional error details (mirrors the Rust `error` module).
pub const errors = @import("error.zig");
pub const CodecError = errors.CodecError;
pub const Diagnostics = errors.Diagnostics;

pub const encode = encode_mod.encode;
pub const encodeDiag = encode_mod.encodeDiag;

pub const DecodeResult = decode_mod.DecodeResult;
pub const decode = decode_mod.decode;
pub const decodeDiag = decode_mod.decodeDiag;

/// DICOM Transfer Syntax UID for RLE Lossless.
pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.5";

test {
    _ = @import("error.zig");
    _ = @import("packbits.zig");
    _ = @import("encode.zig");
    _ = @import("decode.zig");
    _ = @import("mutation_test.zig");
}
