//! Codec interface for lossless image codecs used in DICOS/DICOM.
//!
//! Port of the Rust `Codec` trait as a by-value vtable. Implementors provide
//! encode/decode for 16-bit grayscale frames. All DICOS codecs are lossless:
//! decoded output must be pixel-identical to the original input.

const std = @import("std");
const img_mod = @import("img.zig");
const err = @import("error.zig");

pub const GrayImage16 = img_mod.GrayImage(u16);
pub const CodecError = err.CodecError;
pub const CodecDiagnostic = err.CodecDiagnostic;

pub const Codec = struct {
    /// Human-readable codec name (e.g. "RLE", "JPEG-LS"). Rust `name()`.
    name: []const u8,
    /// DICOM Transfer Syntax UID this codec emits. Rust `transfer_syntax_uid()`.
    transfer_syntax_uid: []const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        encode: *const fn (img: *const GrayImage16, w: *std.Io.Writer, allocator: std.mem.Allocator, diag: ?*CodecDiagnostic) CodecError!void,
        decode: *const fn (data: []const u8, width: u32, height: u32, allocator: std.mem.Allocator, diag: ?*CodecDiagnostic) CodecError!GrayImage16,
    };

    /// Encodes a 16-bit grayscale image, writing the compressed bitstream to `w`.
    pub fn encode(self: Codec, img: *const GrayImage16, w: *std.Io.Writer, allocator: std.mem.Allocator) CodecError!void {
        return self.vtable.encode(img, w, allocator, null);
    }

    /// `encode` with a diagnostic out-param (backend name + original error).
    pub fn encodeDiag(self: Codec, img: *const GrayImage16, w: *std.Io.Writer, allocator: std.mem.Allocator, diag: ?*CodecDiagnostic) CodecError!void {
        return self.vtable.encode(img, w, allocator, diag);
    }

    /// Decodes compressed data into a 16-bit grayscale image owned by `allocator`.
    pub fn decode(self: Codec, data: []const u8, width: u32, height: u32, allocator: std.mem.Allocator) CodecError!GrayImage16 {
        return self.vtable.decode(data, width, height, allocator, null);
    }

    /// `decode` with a diagnostic out-param.
    pub fn decodeDiag(self: Codec, data: []const u8, width: u32, height: u32, allocator: std.mem.Allocator, diag: ?*CodecDiagnostic) CodecError!GrayImage16 {
        return self.vtable.decode(data, width, height, allocator, diag);
    }
};
