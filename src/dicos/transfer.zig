const std = @import("std");

// ---------------------------------------------------------------------------
// Transfer Syntax UID constants
// ---------------------------------------------------------------------------
pub const IMPLICIT_VR_LITTLE_ENDIAN = "1.2.840.10008.1.2";
pub const EXPLICIT_VR_LITTLE_ENDIAN = "1.2.840.10008.1.2.1";
pub const EXPLICIT_VR_LITTLE_ENDIAN_EXT = "1.2.840.10008.1.2.1.64";
pub const EXPLICIT_VR_BIG_ENDIAN = "1.2.840.10008.1.2.2";
pub const JPEG_LOSSLESS = "1.2.840.10008.1.2.4.57";
pub const JPEG_LOSSLESS_FIRST_ORDER = "1.2.840.10008.1.2.4.70";
pub const JPEG_LS_LOSSLESS = "1.2.840.10008.1.2.4.80";
pub const JPEG_LS_NEAR_LOSSLESS = "1.2.840.10008.1.2.4.81";
pub const JPEG_2000_LOSSLESS = "1.2.840.10008.1.2.4.90";
pub const JPEG_2000 = "1.2.840.10008.1.2.4.91";
pub const JPEG_BASELINE = "1.2.840.10008.1.2.4.50";
pub const JPEG_EXTENDED = "1.2.840.10008.1.2.4.51";
pub const RLE_LOSSLESS = "1.2.840.10008.1.2.5";
pub const DEFLATED_EXPLICIT_VR = "1.2.840.10008.1.2.1.99";

/// A DICOM Transfer Syntax identified by its UID string.
pub const TransferSyntax = struct {
    uid: []const u8,

    pub fn init(uid: []const u8) TransferSyntax {
        return .{ .uid = uid };
    }

    /// Returns the UID string.
    pub fn getUid(self: TransferSyntax) []const u8 {
        return self.uid;
    }

    /// Returns `true` if this transfer syntax uses explicit VR encoding.
    pub fn isExplicitVr(self: TransferSyntax) bool {
        return !std.mem.eql(u8, self.uid, IMPLICIT_VR_LITTLE_ENDIAN);
    }

    /// Returns `true` if this transfer syntax uses little-endian byte order.
    pub fn isLittleEndian(self: TransferSyntax) bool {
        return !std.mem.eql(u8, self.uid, EXPLICIT_VR_BIG_ENDIAN);
    }

    /// Returns `true` if pixel data is encapsulated (compressed).
    pub fn isEncapsulated(self: TransferSyntax) bool {
        if (std.mem.eql(u8, self.uid, IMPLICIT_VR_LITTLE_ENDIAN)) return false;
        if (std.mem.eql(u8, self.uid, EXPLICIT_VR_LITTLE_ENDIAN)) return false;
        if (std.mem.eql(u8, self.uid, EXPLICIT_VR_LITTLE_ENDIAN_EXT)) return false;
        if (std.mem.eql(u8, self.uid, EXPLICIT_VR_BIG_ENDIAN)) return false;
        return true;
    }

    /// Returns `true` if this is a JPEG-LS transfer syntax.
    pub fn isJpegLs(self: TransferSyntax) bool {
        return std.mem.eql(u8, self.uid, JPEG_LS_LOSSLESS) or
            std.mem.eql(u8, self.uid, JPEG_LS_NEAR_LOSSLESS);
    }

    /// Returns `true` if this is a JPEG Lossless transfer syntax.
    pub fn isJpegLossless(self: TransferSyntax) bool {
        return std.mem.eql(u8, self.uid, JPEG_LOSSLESS) or
            std.mem.eql(u8, self.uid, JPEG_LOSSLESS_FIRST_ORDER);
    }

    /// Returns `true` if this is a JPEG 2000 transfer syntax.
    pub fn isJpeg2000(self: TransferSyntax) bool {
        return std.mem.eql(u8, self.uid, JPEG_2000_LOSSLESS) or
            std.mem.eql(u8, self.uid, JPEG_2000);
    }

    /// Returns `true` if this is an RLE transfer syntax.
    pub fn isRle(self: TransferSyntax) bool {
        return std.mem.eql(u8, self.uid, RLE_LOSSLESS);
    }

    /// Returns a human-readable name for this transfer syntax.
    pub fn getName(self: TransferSyntax) []const u8 {
        if (std.mem.eql(u8, self.uid, IMPLICIT_VR_LITTLE_ENDIAN)) return "Implicit VR Little Endian";
        if (std.mem.eql(u8, self.uid, EXPLICIT_VR_LITTLE_ENDIAN)) return "Explicit VR Little Endian";
        if (std.mem.eql(u8, self.uid, EXPLICIT_VR_LITTLE_ENDIAN_EXT)) return "Explicit VR Little Endian Extended";
        if (std.mem.eql(u8, self.uid, EXPLICIT_VR_BIG_ENDIAN)) return "Explicit VR Big Endian (Retired)";
        if (std.mem.eql(u8, self.uid, JPEG_LOSSLESS)) return "JPEG Lossless (Process 14)";
        if (std.mem.eql(u8, self.uid, JPEG_LOSSLESS_FIRST_ORDER)) return "JPEG Lossless First-Order (Process 14, SV1)";
        if (std.mem.eql(u8, self.uid, JPEG_LS_LOSSLESS)) return "JPEG-LS Lossless";
        if (std.mem.eql(u8, self.uid, JPEG_LS_NEAR_LOSSLESS)) return "JPEG-LS Near-Lossless";
        if (std.mem.eql(u8, self.uid, JPEG_2000_LOSSLESS)) return "JPEG 2000 Lossless";
        if (std.mem.eql(u8, self.uid, JPEG_2000)) return "JPEG 2000";
        if (std.mem.eql(u8, self.uid, JPEG_BASELINE)) return "JPEG Baseline (Process 1)";
        if (std.mem.eql(u8, self.uid, JPEG_EXTENDED)) return "JPEG Extended (Process 2 & 4)";
        if (std.mem.eql(u8, self.uid, RLE_LOSSLESS)) return "RLE Lossless";
        if (std.mem.eql(u8, self.uid, DEFLATED_EXPLICIT_VR)) return "Deflated Explicit VR Little Endian";
        return self.uid;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "implicit vr little endian properties" {
    const ts = TransferSyntax.init(IMPLICIT_VR_LITTLE_ENDIAN);
    try std.testing.expect(!ts.isExplicitVr());
    try std.testing.expect(ts.isLittleEndian());
    try std.testing.expect(!ts.isEncapsulated());
    try std.testing.expect(!ts.isJpegLs());
    try std.testing.expect(!ts.isJpegLossless());
    try std.testing.expect(!ts.isJpeg2000());
    try std.testing.expect(!ts.isRle());
    try std.testing.expectEqualStrings("Implicit VR Little Endian", ts.getName());
}

test "explicit vr little endian properties" {
    const ts = TransferSyntax.init(EXPLICIT_VR_LITTLE_ENDIAN);
    try std.testing.expect(ts.isExplicitVr());
    try std.testing.expect(ts.isLittleEndian());
    try std.testing.expect(!ts.isEncapsulated());
    try std.testing.expectEqualStrings("Explicit VR Little Endian", ts.getName());
}

test "explicit vr big endian properties" {
    const ts = TransferSyntax.init(EXPLICIT_VR_BIG_ENDIAN);
    try std.testing.expect(ts.isExplicitVr());
    try std.testing.expect(!ts.isLittleEndian());
    try std.testing.expect(!ts.isEncapsulated());
}

test "jpeg ls lossless properties" {
    const ts = TransferSyntax.init(JPEG_LS_LOSSLESS);
    try std.testing.expect(ts.isExplicitVr());
    try std.testing.expect(ts.isLittleEndian());
    try std.testing.expect(ts.isEncapsulated());
    try std.testing.expect(ts.isJpegLs());
    try std.testing.expect(!ts.isJpegLossless());
    try std.testing.expect(!ts.isJpeg2000());
    try std.testing.expect(!ts.isRle());
}

test "jpeg 2000 lossless properties" {
    const ts = TransferSyntax.init(JPEG_2000_LOSSLESS);
    try std.testing.expect(ts.isJpeg2000());
    try std.testing.expect(ts.isEncapsulated());
    try std.testing.expect(!ts.isJpegLs());
    try std.testing.expect(!ts.isJpegLossless());
}

test "rle lossless properties" {
    const ts = TransferSyntax.init(RLE_LOSSLESS);
    try std.testing.expect(ts.isRle());
    try std.testing.expect(ts.isEncapsulated());
}

test "all compressed syntaxes are encapsulated" {
    const compressed = [_][]const u8{
        JPEG_LOSSLESS,
        JPEG_LOSSLESS_FIRST_ORDER,
        JPEG_LS_LOSSLESS,
        JPEG_LS_NEAR_LOSSLESS,
        JPEG_2000_LOSSLESS,
        JPEG_2000,
        JPEG_BASELINE,
        JPEG_EXTENDED,
        RLE_LOSSLESS,
        DEFLATED_EXPLICIT_VR,
    };
    for (compressed) |uid| {
        const ts = TransferSyntax.init(uid);
        try std.testing.expect(ts.isEncapsulated());
    }
}

test "uncompressed syntaxes are not encapsulated" {
    const uncompressed = [_][]const u8{
        IMPLICIT_VR_LITTLE_ENDIAN,
        EXPLICIT_VR_LITTLE_ENDIAN,
        EXPLICIT_VR_LITTLE_ENDIAN_EXT,
        EXPLICIT_VR_BIG_ENDIAN,
    };
    for (uncompressed) |uid| {
        const ts = TransferSyntax.init(uid);
        try std.testing.expect(!ts.isEncapsulated());
    }
}

test "unknown transfer syntax name" {
    const ts = TransferSyntax.init("1.2.3.4.5.999");
    try std.testing.expectEqualStrings("1.2.3.4.5.999", ts.getName());
}
