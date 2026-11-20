//! Error set for JPEG-LS encode/decode operations (mirrors the Rust crate's
//! `error.rs` `CodecError`).
//!
//! Zig errors carry no payload, so the structured fields the Rust variants
//! hold (parameter name/value, truncation offset, marker code, the
//! human-readable message) are reported through an optional caller-owned
//! [`Diagnostic`] passed in the options structs.

const std = @import("std");

/// Errors from JPEG-LS codec encode/decode operations.
pub const CodecError = error{
    /// The output writer failed (Rust `Io`).
    Io,
    /// Malformed or inconsistent codestream.
    InvalidData,
    /// A valid codestream feature this codec does not implement.
    Unsupported,
    /// Sample count does not match the declared/expected geometry.
    DimensionMismatch,
    /// The entropy-coded scan ended before all samples were decoded (a marker
    /// or end-of-data was hit mid-scan). See `Diagnostic.offset`.
    Truncated,
    /// A caller-supplied or in-stream parameter was outside the permitted
    /// range. See `Diagnostic.name` / `value` / `allowed`.
    InvalidParameter,
    /// A JPEG marker (0xFFxx, xx >= 0x80) was encountered while decoding the
    /// entropy-coded scan. See `Diagnostic.marker`.
    Marker,
    /// An allocator failed.
    OutOfMemory,
};

/// Optional detail for the most recent error, filled in by the codec when a
/// pointer to it is supplied through the options structs.
pub const Diagnostic = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    /// `InvalidParameter`: parameter name, offending value, allowed range.
    name: []const u8 = "",
    value: i64 = 0,
    allowed: []const u8 = "",

    /// `DimensionMismatch`: expected / actual sample counts.
    expected: usize = 0,
    actual: usize = 0,

    /// `Truncated`: byte offset within the input and the decoding phase.
    offset: usize = 0,
    context: []const u8 = "",

    /// `Marker`: the full 16-bit marker code.
    marker: u16 = 0,

    /// The human-readable error text (same wording as the Rust `Display`).
    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    /// Format the message, truncating it if it does not fit.
    pub fn print(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        var w = std.Io.Writer.fixed(&self.buf);
        w.print(fmt, args) catch {};
        self.len = w.end;
    }
};

pub fn invalidData(diag: ?*Diagnostic, comptime fmt: []const u8, args: anytype) CodecError {
    if (diag) |d| d.print("invalid data: " ++ fmt, args);
    return error.InvalidData;
}

pub fn unsupported(diag: ?*Diagnostic, comptime fmt: []const u8, args: anytype) CodecError {
    if (diag) |d| d.print("unsupported: " ++ fmt, args);
    return error.Unsupported;
}

pub fn invalidParameter(diag: ?*Diagnostic, name: []const u8, value: i64, allowed: []const u8) CodecError {
    if (diag) |d| {
        d.name = name;
        d.value = value;
        d.allowed = allowed;
        d.print("invalid parameter {s}={d} (allowed: {s})", .{ name, value, allowed });
    }
    return error.InvalidParameter;
}

pub fn dimensionMismatch(diag: ?*Diagnostic, expected: usize, actual: usize) CodecError {
    if (diag) |d| {
        d.expected = expected;
        d.actual = actual;
        d.print("dimension mismatch: expected {d} pixels, got {d}", .{ expected, actual });
    }
    return error.DimensionMismatch;
}

pub fn truncated(diag: ?*Diagnostic, offset: usize, context: []const u8) CodecError {
    if (diag) |d| {
        d.offset = offset;
        d.context = context;
        d.print("truncated JPEG-LS stream at offset {d} ({s})", .{ offset, context });
    }
    return error.Truncated;
}

pub fn io(diag: ?*Diagnostic) CodecError {
    if (diag) |d| d.print("I/O error: write failed", .{});
    return error.Io;
}

test "diagnostic formats and truncates" {
    var d: Diagnostic = .{};
    try std.testing.expectEqual(error.InvalidParameter, invalidParameter(&d, "width", 65536, "1..=65535"));
    try std.testing.expectEqualStrings("width", d.name);
    try std.testing.expectEqualStrings("invalid parameter width=65536 (allowed: 1..=65535)", d.message());

    var long: Diagnostic = .{};
    long.print("{s}", .{"x" ** 400});
    try std.testing.expectEqual(@as(usize, 256), long.message().len);
}
