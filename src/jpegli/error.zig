//! Error set and optional diagnostics for the JPEG Lossless codec.
//!
//! Mirrors `CodecError` from the Rust crate (`error.rs`). Zig error sets cannot
//! carry payloads, so the payload fields of the Rust variants (offsets, parameter
//! names, ...) are reported through an optional [`Diagnostics`] out-parameter
//! accepted by `decodeDiag` / `encodeWithOptionsDiag`.

/// Errors from JPEG Lossless codec encode/decode operations.
pub const CodecError = error{
    /// I/O failure, including a marker segment that ended before its declared length.
    Io,
    /// The stream (or an argument) is malformed.
    InvalidData,
    /// The stream uses a feature this codec does not implement.
    Unsupported,
    /// Pixel count and dimensions disagree.
    DimensionMismatch,
    /// The entropy-coded scan ended before all expected data was read.
    Truncated,
    /// A caller-supplied or in-stream parameter was outside the permitted range.
    InvalidParameter,
    OutOfMemory,
};

/// Detail for the most recent error. Only the fields relevant to the returned
/// error are meaningful:
///
/// - `InvalidData`, `Unsupported`, `Io`: `message`
/// - `InvalidParameter`: `parameter`, `value`, `allowed`
/// - `Truncated`: `offset`, `context`
/// - `DimensionMismatch`: `expected`, `actual`
pub const Diagnostics = struct {
    message: []const u8 = "",
    parameter: []const u8 = "",
    value: i64 = 0,
    allowed: []const u8 = "",
    offset: usize = 0,
    context: []const u8 = "",
    expected: usize = 0,
    actual: usize = 0,

    pub fn reset(self: *Diagnostics) void {
        self.* = .{};
    }
};

pub fn invalidData(diag: ?*Diagnostics, message: []const u8) error{InvalidData} {
    if (diag) |d| d.* = .{ .message = message };
    return error.InvalidData;
}

pub fn unsupported(diag: ?*Diagnostics, message: []const u8) error{Unsupported} {
    if (diag) |d| d.* = .{ .message = message };
    return error.Unsupported;
}

pub fn ioError(diag: ?*Diagnostics, message: []const u8) error{Io} {
    if (diag) |d| d.* = .{ .message = message };
    return error.Io;
}

pub fn invalidParameter(
    diag: ?*Diagnostics,
    name: []const u8,
    value: i64,
    allowed: []const u8,
) error{InvalidParameter} {
    if (diag) |d| d.* = .{ .parameter = name, .value = value, .allowed = allowed };
    return error.InvalidParameter;
}

pub fn truncated(diag: ?*Diagnostics, offset: usize, context: []const u8) error{Truncated} {
    if (diag) |d| d.* = .{ .offset = offset, .context = context };
    return error.Truncated;
}

pub fn dimensionMismatch(diag: ?*Diagnostics, expected: usize, actual: usize) error{DimensionMismatch} {
    if (diag) |d| d.* = .{ .expected = expected, .actual = actual };
    return error.DimensionMismatch;
}
