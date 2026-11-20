//! Error sets and diagnostics for DICOS and codec operations.
//!
//! Zig errors cannot carry payloads, so every operation that can fail with a
//! data-bearing error (the Rust `DicosError` / `CodecError` variants with
//! fields) accepts an optional `*Diagnostic` / `*CodecDiagnostic` out-param.
//! When supplied, it is filled with the structured details of the failure and
//! formats (`{f}`) to the same message text the Rust crate produces.

const std = @import("std");
const tag_mod = @import("tag.zig");

const Tag = tag_mod.Tag;

/// Errors from codec encode/decode operations.
///
/// Mirrors Rust `dicos::CodecError` (`Io`, `InvalidData`, `Unsupported`,
/// `DimensionMismatch`, `Backend`). `OutOfMemory` is Zig-specific.
pub const CodecError = error{
    /// I/O error while writing encoded output.
    IoError,
    /// The compressed data is malformed or truncated.
    InvalidData,
    /// The codec does not support this operation or format.
    Unsupported,
    /// The number of decoded pixels does not match the expected dimensions.
    DimensionMismatch,
    /// A codec backend failed. `CodecDiagnostic.backend` names the backend
    /// and carries its original error.
    Backend,
    /// Out of memory.
    OutOfMemory,
};

/// Errors from DICOS file operations.
///
/// Mirrors Rust `dicos::DicosError`. The Rust `Codec(CodecError)` variant is
/// expressed by merging `CodecError` into this set; the codec details live in
/// `Diagnostic.detail.codec`.
pub const DicosError = error{
    /// I/O error from the underlying reader or writer.
    IoError,
    /// Last-resort, free-form file error.
    InvalidFile,
    /// The file is not a valid DICOM/DICOS Part-10 stream.
    BadPreamble,
    /// Sequence/item nesting exceeded the maximum allowed depth.
    NestingTooDeep,
    /// A structural tag did not match what the parser expected.
    UnexpectedTag,
    /// A declared element length exceeded the configured allocation limit.
    LengthExceedsLimit,
    /// A declared length exceeded the bytes remaining in the enclosing buffer.
    LengthExceedsBuffer,
    /// An undefined-length item appeared inside a fixed-length sequence.
    UndefinedLengthInFixedSq,
    /// The stream ended in the middle of an element or header.
    Truncated,
    /// A required attribute is missing from the dataset.
    MissingAttribute,
    /// An attribute has an invalid value.
    InvalidValue,
    /// The transfer syntax is not supported.
    UnsupportedTransferSyntax,
    /// Validation constraint violated (writer limits, 8-bit overflow, ...).
    Validation,
} || CodecError;

/// Structured details for a `CodecError`.
pub const CodecDiagnostic = struct {
    detail: Detail = .none,

    pub const Detail = union(enum) {
        none,
        io: anyerror,
        invalid_data: Message,
        unsupported: Message,
        dimension_mismatch: struct { expected: usize, actual: usize },
        /// A codec backend failed: `codec` is the backend display name
        /// (e.g. "JPEG-LS"), `source` the backend's own error.
        backend: struct { codec: []const u8, source: anyerror },
    };

    pub fn format(self: CodecDiagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.detail) {
            .none => try w.writeAll("codec error"),
            .io => |e| try w.print("I/O error: {s}", .{@errorName(e)}),
            .invalid_data => |m| try w.print("invalid data: {s}", .{m.slice()}),
            .unsupported => |m| try w.print("unsupported: {s}", .{m.slice()}),
            .dimension_mismatch => |d| try w.print(
                "dimension mismatch: expected {d} pixels, got {d}",
                .{ d.expected, d.actual },
            ),
            .backend => |b| try w.print("{s} codec error: {s}", .{ b.codec, @errorName(b.source) }),
        }
    }
};

/// A small fixed-capacity message buffer so diagnostics never allocate.
pub const Message = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn init(comptime fmt: []const u8, args: anytype) Message {
        var m: Message = .{};
        const s = std.fmt.bufPrint(&m.buf, fmt, args) catch blk: {
            // Truncate on overflow; keep what fit.
            break :blk m.buf[0..];
        };
        m.len = s.len;
        return m;
    }

    pub fn slice(self: *const Message) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Structured details for a `DicosError`, mirroring the Rust variant payloads.
pub const Diagnostic = struct {
    detail: Detail = .none,

    pub const Detail = union(enum) {
        none,
        io: anyerror,
        invalid_file: Message,
        bad_preamble: struct { reason: []const u8 },
        nesting_too_deep: struct { max: usize },
        unexpected_tag: struct { expected: Tag, got: Tag, context: []const u8 },
        length_exceeds_limit: struct { length: usize, limit: usize },
        length_exceeds_buffer: struct { length: usize, remaining: usize },
        undefined_length_in_fixed_sq,
        truncated: struct { offset: u64, context: []const u8 },
        missing_attribute: struct { group: u16, element: u16 },
        invalid_value: struct { group: u16, element: u16, reason: Message },
        unsupported_transfer_syntax: Message,
        codec: CodecDiagnostic,
        validation: Message,
    };

    /// Records `detail` into `diag` when non-null. Convenience for callers
    /// threading an optional diagnostic.
    pub fn set(diag: ?*Diagnostic, detail: Detail) void {
        if (diag) |d| d.detail = detail;
    }

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.detail) {
            .none => try w.writeAll("DICOS error"),
            .io => |e| try w.print("I/O error: {s}", .{@errorName(e)}),
            .invalid_file => |m| try w.print("invalid DICOS file: {s}", .{m.slice()}),
            .bad_preamble => |b| try w.print("not a DICOM/DICOS Part-10 file: {s}", .{b.reason}),
            .nesting_too_deep => |n| try w.print("sequence nesting exceeds maximum depth ({d})", .{n.max}),
            .unexpected_tag => |u| try w.print("{s}: expected tag {f}, got {f}", .{ u.context, u.expected, u.got }),
            .length_exceeds_limit => |l| try w.print("element length {d} exceeds limit ({d})", .{ l.length, l.limit }),
            .length_exceeds_buffer => |l| try w.print("length {d} exceeds remaining buffer ({d})", .{ l.length, l.remaining }),
            .undefined_length_in_fixed_sq => try w.writeAll("undefined-length item inside fixed-length SQ"),
            .truncated => |t| try w.print("truncated at byte {d} ({s})", .{ t.offset, t.context }),
            .missing_attribute => |m| try w.print("missing required attribute: (0x{x:0>4},0x{x:0>4})", .{ m.group, m.element }),
            .invalid_value => |v| try w.print("invalid value for (0x{x:0>4},0x{x:0>4}): {s}", .{ v.group, v.element, v.reason.slice() }),
            .unsupported_transfer_syntax => |m| try w.print("unsupported transfer syntax: {s}", .{m.slice()}),
            .codec => |c| try w.print("codec error: {f}", .{c}),
            .validation => |m| try w.print("validation error: {s}", .{m.slice()}),
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectFmt(expected: []const u8, value: anytype) !void {
    var buf: [512]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{value});
    try std.testing.expectEqualStrings(expected, s);
}

test "diagnostic messages match the Rust Display text" {
    try expectFmt("not a DICOM/DICOS Part-10 file: missing DICM magic number", Diagnostic{
        .detail = .{ .bad_preamble = .{ .reason = "missing DICM magic number" } },
    });
    try expectFmt("truncated at byte 133 (element tag)", Diagnostic{
        .detail = .{ .truncated = .{ .offset = 133, .context = "element tag" } },
    });
    try expectFmt("sequence item: expected tag (FFFE,E000), got (0008,0060)", Diagnostic{
        .detail = .{ .unexpected_tag = .{
            .expected = tag_mod.ITEM,
            .got = tag_mod.MODALITY,
            .context = "sequence item",
        } },
    });
    try expectFmt("missing required attribute: (0x0028,0x0010)", Diagnostic{
        .detail = .{ .missing_attribute = .{ .group = 0x0028, .element = 0x0010 } },
    });
    try expectFmt("codec error: JPEG-LS codec error: InvalidData", Diagnostic{
        .detail = .{ .codec = .{ .detail = .{ .backend = .{ .codec = "JPEG-LS", .source = error.InvalidData } } } },
    });
    try expectFmt("validation error: native sample 256 does not fit in 8-bit pixel data", Diagnostic{
        .detail = .{ .validation = Message.init("native sample {d} does not fit in 8-bit pixel data", .{256}) },
    });
}

test "message truncates instead of overflowing" {
    const long = "x" ** 400;
    const m = Message.init("{s}", .{long});
    try std.testing.expectEqual(@as(usize, 256), m.slice().len);
}
