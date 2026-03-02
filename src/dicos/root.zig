//! DICOS core library -- NEMA IIC 1 v04-2023 compliant.
//!
//! Provides the foundation for working with DICOS (Digital Imaging and
//! Communications for Security) files used in security screening imaging.

pub const err = @import("error.zig");
pub const tag = @import("tag.zig");
pub const vr = @import("vr.zig");
pub const transfer = @import("transfer.zig");
pub const img = @import("img.zig");
pub const types = @import("types.zig");
pub const reader = @import("reader.zig");
pub const writer = @import("writer.zig");
pub const codec = @import("codec.zig");
pub const codec_registry = @import("codec_registry.zig");

// Re-export commonly used types
pub const Tag = tag.Tag;
pub const Vr = vr.Vr;
pub const TransferSyntax = transfer.TransferSyntax;
pub const Dataset = types.Dataset;
pub const Element = types.Element;
pub const Value = types.Value;
pub const PixelData = types.PixelData;
pub const Frame = types.Frame;
pub const GrayImage = img.GrayImage;
pub const Codec = codec.Codec;
pub const CodecError = err.CodecError;
pub const DicosError = err.DicosError;

test {
    _ = @import("error.zig");
    _ = @import("tag.zig");
    _ = @import("vr.zig");
    _ = @import("transfer.zig");
    _ = @import("img.zig");
    _ = @import("types.zig");
    _ = @import("reader.zig");
    _ = @import("writer.zig");
    _ = @import("codec.zig");
    _ = @import("codec_registry.zig");
}
