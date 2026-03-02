const std = @import("std");
const img_mod = @import("img.zig");
const err = @import("error.zig");

/// Managed ArrayList(u8) used as the output buffer for codec encoding.
pub const ByteList = std.array_list.AlignedManaged(u8, null);

/// Trait-like interface for lossless image codecs used in DICOS/DICOM.
///
/// Implementors provide encode/decode for 16-bit grayscale frames.
/// All DICOS codecs are lossless -- decoded output must be pixel-identical
/// to the original input.
///
/// Implemented as a Zig vtable (fat pointer pattern).
pub const Codec = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        encode: *const fn (ctx: *const anyopaque, data: []const u16, width: u32, height: u32, out: *ByteList) err.CodecError!void,
        decode: *const fn (ctx: *const anyopaque, data: []const u8, width: u32, height: u32, allocator: std.mem.Allocator) (err.CodecError || error{OutOfMemory})!img_mod.GrayImage(u16),
        name: *const fn (ctx: *const anyopaque) []const u8,
        transferSyntaxUid: *const fn (ctx: *const anyopaque) []const u8,
    };

    /// Encode a 16-bit grayscale image to the codec's compressed format.
    pub fn encode(self: Codec, data: []const u16, width: u32, height: u32, out: *ByteList) err.CodecError!void {
        return self.vtable.encode(self.ptr, data, width, height, out);
    }

    /// Decode compressed data back into a 16-bit grayscale image.
    pub fn decode(self: Codec, data: []const u8, width: u32, height: u32, allocator: std.mem.Allocator) !img_mod.GrayImage(u16) {
        return self.vtable.decode(self.ptr, data, width, height, allocator);
    }

    /// Human-readable codec name.
    pub fn getName(self: Codec) []const u8 {
        return self.vtable.name(self.ptr);
    }

    /// DICOM Transfer Syntax UID for this codec.
    pub fn getTransferSyntaxUid(self: Codec) []const u8 {
        return self.vtable.transferSyntaxUid(self.ptr);
    }
};
