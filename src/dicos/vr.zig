const std = @import("std");

/// DICOM Value Representation.
///
/// Each variant represents one of the 31 standard DICOM VR types as defined
/// in DICOM Part 5 Section 6.2.
pub const Vr = enum(u16) {
    AE = asU16("AE"), // Application Entity
    AS = asU16("AS"), // Age String
    AT = asU16("AT"), // Attribute Tag
    CS = asU16("CS"), // Code String
    DA = asU16("DA"), // Date
    DS = asU16("DS"), // Decimal String
    DT = asU16("DT"), // DateTime
    FL = asU16("FL"), // Floating Point Single
    FD = asU16("FD"), // Floating Point Double
    IS = asU16("IS"), // Integer String
    LO = asU16("LO"), // Long String
    LT = asU16("LT"), // Long Text
    OB = asU16("OB"), // Other Byte
    OD = asU16("OD"), // Other Double
    OF = asU16("OF"), // Other Float
    OL = asU16("OL"), // Other Long
    OW = asU16("OW"), // Other Word
    PN = asU16("PN"), // Person Name
    SH = asU16("SH"), // Short String
    SL = asU16("SL"), // Signed Long
    SQ = asU16("SQ"), // Sequence
    SS = asU16("SS"), // Signed Short
    ST = asU16("ST"), // Short Text
    TM = asU16("TM"), // Time
    UC = asU16("UC"), // Unlimited Characters
    UI = asU16("UI"), // Unique Identifier
    UL = asU16("UL"), // Unsigned Long
    UN = asU16("UN"), // Unknown
    UR = asU16("UR"), // URI
    US = asU16("US"), // Unsigned Short
    UT = asU16("UT"), // Unlimited Text

    fn asU16(comptime s: *const [2]u8) u16 {
        return @as(u16, s[0]) | (@as(u16, s[1]) << 8);
    }

    /// Returns `true` if this VR contains string data.
    pub fn isString(self: Vr) bool {
        return switch (self) {
            .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC, .UI, .UR, .UT => true,
            else => false,
        };
    }

    /// Returns `true` if this VR contains binary data.
    pub fn isBinary(self: Vr) bool {
        return switch (self) {
            .AT, .FL, .FD, .OB, .OD, .OF, .OL, .OW, .SL, .SS, .UL, .UN, .US => true,
            else => false,
        };
    }

    /// Returns `true` if this is a sequence VR.
    pub fn isSequence(self: Vr) bool {
        return self == .SQ;
    }

    /// Returns `true` if this VR uses a 4-byte length field in explicit VR encoding.
    pub fn isLongVr(self: Vr) bool {
        return switch (self) {
            .OB, .OD, .OF, .OL, .OW, .SQ, .UC, .UN, .UR, .UT => true,
            else => false,
        };
    }

    /// Returns the fixed size in bytes for fixed-size VRs, or null for variable-length.
    pub fn fixedSize(self: Vr) ?usize {
        return switch (self) {
            .AT => 4,
            .FL => 4,
            .FD => 8,
            .SL => 4,
            .SS => 2,
            .UL => 4,
            .US => 2,
            else => null,
        };
    }

    /// Parses a VR from a two-byte ASCII slice.
    pub fn fromBytes(bytes: []const u8) ?Vr {
        if (bytes.len < 2) return null;
        const val: u16 = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
        return std.enums.fromInt(Vr, val);
    }

    /// Returns the two-byte ASCII representation of this VR.
    pub fn asBytes(self: Vr) [2]u8 {
        const val: u16 = @intFromEnum(self);
        return .{ @truncate(val), @truncate(val >> 8) };
    }

    /// Format for display.
    pub fn format(self: Vr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const b = self.asBytes();
        try writer.writeAll(&b);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "string vrs" {
    const string_vrs = [_]Vr{ .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC, .UI, .UR, .UT };
    for (string_vrs) |vr| {
        try std.testing.expect(vr.isString());
        try std.testing.expect(!vr.isBinary());
    }
}

test "binary vrs" {
    const binary_vrs = [_]Vr{ .AT, .FL, .FD, .OB, .OD, .OF, .OL, .OW, .SL, .SS, .UL, .UN, .US };
    for (binary_vrs) |vr| {
        try std.testing.expect(vr.isBinary());
        try std.testing.expect(!vr.isString());
    }
}

test "sequence vr" {
    try std.testing.expect(Vr.SQ.isSequence());
    try std.testing.expect(!Vr.US.isSequence());
    try std.testing.expect(!Vr.SQ.isString());
    try std.testing.expect(!Vr.SQ.isBinary());
}

test "long vrs" {
    const long_vrs = [_]Vr{ .OB, .OD, .OF, .OL, .OW, .SQ, .UC, .UN, .UR, .UT };
    for (long_vrs) |vr| {
        try std.testing.expect(vr.isLongVr());
    }
    const short_vrs = [_]Vr{ .AE, .AS, .AT, .CS, .DA, .DS, .DT, .FL, .FD, .IS, .LO, .LT, .PN, .SH, .SL, .SS, .ST, .TM, .UI, .UL, .US };
    for (short_vrs) |vr| {
        try std.testing.expect(!vr.isLongVr());
    }
}

test "fixed sizes" {
    try std.testing.expectEqual(@as(?usize, 4), Vr.AT.fixedSize());
    try std.testing.expectEqual(@as(?usize, 4), Vr.FL.fixedSize());
    try std.testing.expectEqual(@as(?usize, 8), Vr.FD.fixedSize());
    try std.testing.expectEqual(@as(?usize, 4), Vr.SL.fixedSize());
    try std.testing.expectEqual(@as(?usize, 2), Vr.SS.fixedSize());
    try std.testing.expectEqual(@as(?usize, 4), Vr.UL.fixedSize());
    try std.testing.expectEqual(@as(?usize, 2), Vr.US.fixedSize());
    try std.testing.expectEqual(@as(?usize, null), Vr.OB.fixedSize());
    try std.testing.expectEqual(@as(?usize, null), Vr.LO.fixedSize());
    try std.testing.expectEqual(@as(?usize, null), Vr.SQ.fixedSize());
}

test "from bytes all vrs" {
    try std.testing.expectEqual(@as(?Vr, .AE), Vr.fromBytes("AE"));
    try std.testing.expectEqual(@as(?Vr, .US), Vr.fromBytes("US"));
    try std.testing.expectEqual(@as(?Vr, .SQ), Vr.fromBytes("SQ"));
    try std.testing.expectEqual(@as(?Vr, .OW), Vr.fromBytes("OW"));
    try std.testing.expectEqual(@as(?Vr, .UT), Vr.fromBytes("UT"));
}

test "from bytes invalid" {
    try std.testing.expectEqual(@as(?Vr, null), Vr.fromBytes("XX"));
    try std.testing.expectEqual(@as(?Vr, null), Vr.fromBytes("A"));
    try std.testing.expectEqual(@as(?Vr, null), Vr.fromBytes(""));
}

test "as bytes roundtrip" {
    const all = [_]Vr{ .AE, .AS, .AT, .CS, .DA, .DS, .DT, .FL, .FD, .IS, .LO, .LT, .OB, .OD, .OF, .OL, .OW, .PN, .SH, .SL, .SQ, .SS, .ST, .TM, .UC, .UI, .UL, .UN, .UR, .US, .UT };
    for (all) |vr| {
        const bytes = vr.asBytes();
        const back = Vr.fromBytes(&bytes);
        try std.testing.expectEqual(@as(?Vr, vr), back);
    }
}

test "every vr has exactly one category" {
    const all = [_]Vr{ .AE, .AS, .AT, .CS, .DA, .DS, .DT, .FL, .FD, .IS, .LO, .LT, .OB, .OD, .OF, .OL, .OW, .PN, .SH, .SL, .SQ, .SS, .ST, .TM, .UC, .UI, .UL, .UN, .UR, .US, .UT };
    for (all) |vr| {
        const count = @as(u8, @intFromBool(vr.isString())) + @as(u8, @intFromBool(vr.isBinary())) + @as(u8, @intFromBool(vr.isSequence()));
        try std.testing.expectEqual(@as(u8, 1), count);
    }
}
