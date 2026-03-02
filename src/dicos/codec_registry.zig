const std = @import("std");
const codec_mod = @import("codec.zig");
const transfer = @import("transfer.zig");

const Codec = codec_mod.Codec;

/// Returns a codec by human-readable name (case-insensitive comparison).
pub fn codecByName(name_str: []const u8) ?Codec {
    // Build lowercase version for comparison
    var buf: [64]u8 = undefined;
    const lower = toLower(name_str, &buf) orelse return null;

    if (std.mem.eql(u8, lower, "rle")) return getRleCodec();
    if (std.mem.eql(u8, lower, "jpeg-ls") or std.mem.eql(u8, lower, "jpegls")) return getJpegLsCodec();
    if (std.mem.eql(u8, lower, "jpeg-li") or std.mem.eql(u8, lower, "jpegli") or std.mem.eql(u8, lower, "jpeg-lossless")) return getJpegLiCodec();
    if (std.mem.eql(u8, lower, "jpeg-2000") or std.mem.eql(u8, lower, "jpeg2000") or std.mem.eql(u8, lower, "j2k")) return getJpeg2kCodec();

    return null;
}

/// Returns a codec for the given DICOM Transfer Syntax UID.
pub fn codecForTransferSyntax(ts_uid: []const u8) ?Codec {
    if (std.mem.eql(u8, ts_uid, transfer.RLE_LOSSLESS)) return getRleCodec();
    if (std.mem.eql(u8, ts_uid, transfer.JPEG_LS_LOSSLESS) or std.mem.eql(u8, ts_uid, transfer.JPEG_LS_NEAR_LOSSLESS)) return getJpegLsCodec();
    if (std.mem.eql(u8, ts_uid, transfer.JPEG_LOSSLESS) or std.mem.eql(u8, ts_uid, transfer.JPEG_LOSSLESS_FIRST_ORDER)) return getJpegLiCodec();
    if (std.mem.eql(u8, ts_uid, transfer.JPEG_2000_LOSSLESS) or std.mem.eql(u8, ts_uid, transfer.JPEG_2000)) return getJpeg2kCodec();
    return null;
}

/// Attempts to identify the codec from leading bytes of compressed data.
pub fn sniffCodec(data: []const u8) ?Codec {
    if (data.len < 2) return null;

    // JPEG 2000 codestream: FF 4F
    if (data[0] == 0xFF and data[1] == 0x4F) return getJpeg2kCodec();

    // JPEG 2000 JP2 box: 00 00 00 0C 6A 50
    if (data.len >= 6 and
        data[0] == 0x00 and data[1] == 0x00 and data[2] == 0x00 and
        data[3] == 0x0C and data[4] == 0x6A and data[5] == 0x50)
    {
        return getJpeg2kCodec();
    }

    // JPEG-LS: FF D8 then SOF55 (FF F7)
    if (data.len >= 4 and data[0] == 0xFF and data[1] == 0xD8) {
        var i: usize = 2;
        while (i + 1 < data.len) : (i += 1) {
            if (data[i] == 0xFF and data[i + 1] == 0xF7) return getJpegLsCodec();
        }
    }

    // JPEG Lossless: FF D8 then SOF3 (FF C3)
    if (data.len >= 4 and data[0] == 0xFF and data[1] == 0xD8) {
        var i: usize = 2;
        while (i + 1 < data.len) : (i += 1) {
            if (data[i] == 0xFF and data[i + 1] == 0xC3) return getJpegLiCodec();
        }
    }

    // RLE: header starts with segment count (1-15)
    if (data.len >= 64) {
        const num_segments = std.mem.readInt(u32, data[0..4], .little);
        if (num_segments >= 1 and num_segments <= 15) return getRleCodec();
    }

    return null;
}

// ---------------------------------------------------------------------------
// Codec accessor stubs — filled by codec modules at import time
// ---------------------------------------------------------------------------

var rle_codec: ?Codec = null;
var jpegls_codec: ?Codec = null;
var jpegli_codec: ?Codec = null;
var jpeg2k_codec: ?Codec = null;

pub fn registerRle(c: Codec) void {
    rle_codec = c;
}
pub fn registerJpegLs(c: Codec) void {
    jpegls_codec = c;
}
pub fn registerJpegLi(c: Codec) void {
    jpegli_codec = c;
}
pub fn registerJpeg2k(c: Codec) void {
    jpeg2k_codec = c;
}

fn getRleCodec() ?Codec {
    return rle_codec;
}
fn getJpegLsCodec() ?Codec {
    return jpegls_codec;
}
fn getJpegLiCodec() ?Codec {
    return jpegli_codec;
}
fn getJpeg2kCodec() ?Codec {
    return jpeg2k_codec;
}

fn toLower(s: []const u8, buf: []u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..s.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "unknown codec name returns null" {
    try std.testing.expect(codecByName("unknown-codec") == null);
    try std.testing.expect(codecByName("") == null);
}

test "unknown transfer syntax returns null" {
    try std.testing.expect(codecForTransferSyntax("1.2.3.4.5.999") == null);
    try std.testing.expect(codecForTransferSyntax("") == null);
}

test "uncompressed transfer syntax returns null" {
    try std.testing.expect(codecForTransferSyntax(transfer.IMPLICIT_VR_LITTLE_ENDIAN) == null);
    try std.testing.expect(codecForTransferSyntax(transfer.EXPLICIT_VR_LITTLE_ENDIAN) == null);
}

test "sniff empty data returns null" {
    try std.testing.expect(sniffCodec(&.{}) == null);
    try std.testing.expect(sniffCodec(&[_]u8{0xFF}) == null);
}

test "sniff random data returns null" {
    try std.testing.expect(sniffCodec(&[_]u8{ 0x00, 0x00 }) == null);
}
