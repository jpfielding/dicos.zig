//! DICOS core library -- NEMA IIC 1 v04-2023 compliant.
//!
//! The foundation for working with DICOS (Digital Imaging and Communications
//! for Security) files used in security screening imaging. Zig port of the
//! Rust `dicos` 2.1.0 crate.
//!
//! Modules:
//! - `tag` -- Tag constants for standard DICOM/DICOS data elements
//! - `vr` -- Value Representation definitions
//! - `transfer` -- Transfer Syntax UID constants and properties
//! - `uid` -- Standard SOP Class UID constants
//! - `types` -- Core types: Dataset, Element, Value, PixelData
//! - `reader` -- DICOS file parser
//! - `writer` -- DICOS file writer
//! - `codec_registry` -- Codec lookup by name, transfer syntax or signature
//! - `codec` -- Codec interface
//! - `img` -- GrayImage pixel buffer
//! - `err` -- Error sets and diagnostics
//!
//! Build options (Rust feature flags): `-Ddicos-rle`, `-Ddicos-jpegls`,
//! `-Ddicos-jpegli`, `-Ddicos-jpeg2k` (all default to true).

pub const err = @import("error.zig");
pub const tag = @import("tag.zig");
pub const vr = @import("vr.zig");
pub const transfer = @import("transfer.zig");
pub const uid = @import("uid.zig");
pub const img = @import("img.zig");
pub const types = @import("types.zig");
pub const reader = @import("reader.zig");
pub const writer = @import("writer.zig");
pub const codec = @import("codec.zig");
pub const codec_registry = @import("codec_registry.zig");

// Re-exports at the crate root, mirroring Rust's `pub use`.
pub const Tag = tag.Tag;
pub const Vr = vr.Vr;
pub const TransferSyntax = transfer.TransferSyntax;
pub const Dataset = types.Dataset;
pub const Element = types.Element;
pub const Value = types.Value;
pub const PixelData = types.PixelData;
pub const GrayImage = img.GrayImage;
pub const Codec = codec.Codec;
pub const CodecError = err.CodecError;
pub const DicosError = err.DicosError;
pub const Diagnostic = err.Diagnostic;
pub const CodecDiagnostic = err.CodecDiagnostic;
pub const ParseWarning = reader.ParseWarning;
pub const ParseResult = reader.ParseResult;
pub const parse = reader.parse;
pub const parseWithLimit = reader.parseWithLimit;
pub const parseWithWarnings = reader.parseWithWarnings;
pub const parseWithWarningsAndLimit = reader.parseWithWarningsAndLimit;
pub const parseBytes = reader.parseBytes;
pub const write = writer.write;

test {
    _ = err;
    _ = tag;
    _ = vr;
    _ = transfer;
    _ = uid;
    _ = img;
    _ = types;
    _ = reader;
    _ = writer;
    _ = codec;
    _ = codec_registry;
    _ = @import("tests/roundtrip_prop.zig");
    _ = @import("tests/synthetic_luggage_example.zig");
}
