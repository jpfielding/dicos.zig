//! Codec registry for DICOS pixel data compression.
//!
//! Maps codec names and transfer syntax UIDs to `Codec` implementations.
//! Codecs are selected at build time, mirroring the Rust feature flags:
//!
//! - `-Ddicos-rle`    -- RLE PackBits      (`jpegrle`)
//! - `-Ddicos-jpegls` -- JPEG-LS           (`jpegls`)
//! - `-Ddicos-jpegli` -- JPEG Lossless SV1 (`jpegli`)
//! - `-Ddicos-jpeg2k` -- JPEG 2000         (`jpeg2k`)
//!
//! All default to enabled. A disabled codec's module is never imported.
//!
//! # UID binding invariant
//!
//! Registry encodes always use each codec's **defaults** (predictor 1 for
//! JPEG Lossless, the T.87 profile for JPEG-LS, no restart intervals, the
//! default JPEG 2000 options). A DICOM Transfer Syntax UID encodes a specific
//! compression mode -- e.g. `1.2.840.10008.1.2.4.70` (JPEG Lossless SV1)
//! means predictor 1 -- so pinning the registry to defaults keeps every
//! `Codec.transfer_syntax_uid` truthful for the bytes it produces. Callers
//! needing non-default options must use the codec modules directly and
//! advertise a matching transfer syntax themselves.

const std = @import("std");
const options = @import("dicos_options");
const codec_mod = @import("codec.zig");
const err = @import("error.zig");
const transfer = @import("transfer.zig");

pub const Codec = codec_mod.Codec;
const GrayImage16 = codec_mod.GrayImage16;
const CodecError = err.CodecError;
const CodecDiagnostic = err.CodecDiagnostic;
const Diagnostic = err.Diagnostic;
const DicosError = err.DicosError;
const Allocator = std.mem.Allocator;

pub const has_rle = options.rle;
pub const has_jpegls = options.jpegls;
pub const has_jpegli = options.jpegli;
pub const has_jpeg2k = options.jpeg2k;

/// A backend decode result, normalized across the codec modules' shapes.
pub const Decoded = struct { pixels: []u16, width: u32, height: u32 };

// ---------------------------------------------------------------------------
// Adapter builder -- the Zig counterpart of Rust's `codec_adapter!` macro.
//
// `Backend` must declare
//   fn encode(Allocator, []const u16, u32, u32, *std.Io.Writer) anyerror!void
//   fn decode(Allocator, []const u8, u32, u32) anyerror!Decoded
// Backend errors other than OutOfMemory map to `error.Backend` with the
// display name and original error recorded in the diagnostic (Rust
// `CodecError::Backend { codec, source }`). The decoded pixel count is
// checked against the *returned* dimensions and reported honestly.
// ---------------------------------------------------------------------------

pub fn adapter(comptime display: []const u8, comptime ts_uid: []const u8, comptime Backend: type) Codec {
    const Impl = struct {
        fn backendError(e: anyerror, diag: ?*CodecDiagnostic) CodecError {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            if (diag) |d| d.detail = .{ .backend = .{ .codec = display, .source = e } };
            return error.Backend;
        }

        fn encode(img: *const GrayImage16, w: *std.Io.Writer, allocator: Allocator, diag: ?*CodecDiagnostic) CodecError!void {
            Backend.encode(allocator, img.data, img.width, img.height, w) catch |e| return backendError(e, diag);
        }

        fn decode(data: []const u8, width: u32, height: u32, allocator: Allocator, diag: ?*CodecDiagnostic) CodecError!GrayImage16 {
            const out = Backend.decode(allocator, data, width, height) catch |e| return backendError(e, diag);
            // Capture the real length before ownership moves into the image.
            const actual = out.pixels.len;
            return GrayImage16.fromData(allocator, out.width, out.height, out.pixels) orelse {
                allocator.free(out.pixels);
                if (diag) |d| d.detail = .{ .dimension_mismatch = .{
                    .expected = @as(usize, out.width) * @as(usize, out.height),
                    .actual = actual,
                } };
                return error.DimensionMismatch;
            };
        }

        const vtable: Codec.VTable = .{ .encode = encode, .decode = decode };
    };
    return .{ .name = display, .transfer_syntax_uid = ts_uid, .vtable = &Impl.vtable };
}

// ---------------------------------------------------------------------------
// Shape normalization. The codec modules disagree on whether encode returns
// an owned slice or writes to a `*std.Io.Writer`, and on whether decode
// returns a bare slice, a tuple or a named struct. Normalizing at comptime
// keeps the adapters compiling while the codec APIs converge.
// ---------------------------------------------------------------------------

fn callEncode(comptime f: anytype, allocator: Allocator, pixels: []const u16, width: u32, height: u32, extra: anytype, w: *std.Io.Writer) anyerror!void {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const last = info.params[info.params.len - 1].type.?;
    if (last == *std.Io.Writer) {
        return @call(.auto, f, .{ allocator, pixels, width, height } ++ extra ++ .{w});
    }
    const bytes = try @call(.auto, f, .{ allocator, pixels, width, height } ++ extra);
    defer allocator.free(bytes);
    try w.writeAll(bytes);
}

fn normalizeDecoded(result: anytype, width: u32, height: u32) Decoded {
    const R = @TypeOf(result);
    if (R == []u16) return .{ .pixels = result, .width = width, .height = height };
    const s = @typeInfo(R).@"struct";
    if (s.is_tuple) return .{ .pixels = result[0], .width = result[1], .height = result[2] };
    return .{ .pixels = result.pixels, .width = result.width, .height = result.height };
}

// ---------------------------------------------------------------------------
// Backends
// ---------------------------------------------------------------------------

const RleBackend = struct {
    const m = @import("jpegrle");
    fn encode(a: Allocator, px: []const u16, w: u32, h: u32, out: *std.Io.Writer) anyerror!void {
        return callEncode(m.encode, a, px, w, h, .{}, out);
    }
    fn decode(a: Allocator, data: []const u8, w: u32, h: u32) anyerror!Decoded {
        return normalizeDecoded(try m.decode(a, data, w, h), w, h);
    }
};

const JpegLsBackend = struct {
    const m = @import("jpegls");
    fn encode(a: Allocator, px: []const u16, w: u32, h: u32, out: *std.Io.Writer) anyerror!void {
        return callEncode(m.encode, a, px, w, h, .{}, out);
    }
    fn decode(a: Allocator, data: []const u8, w: u32, h: u32) anyerror!Decoded {
        return normalizeDecoded(try m.decode(a, data, w, h), w, h);
    }
};

const JpegLiBackend = struct {
    const m = @import("jpegli");
    fn encode(a: Allocator, px: []const u16, w: u32, h: u32, out: *std.Io.Writer) anyerror!void {
        return callEncode(m.encode, a, px, w, h, .{}, out);
    }
    fn decode(a: Allocator, data: []const u8, w: u32, h: u32) anyerror!Decoded {
        return normalizeDecoded(try m.decode(a, data, w, h), w, h);
    }
};

/// Registry decodes of transfer-syntax-tagged data are untrusted input, so
/// the legacy raw-DWT fallback is disabled (`standard_only`): a corrupted
/// conformant stream must not be reinterpreted as legacy coefficients under
/// the same UID. Pre-2.0 archives should be decoded via `jpeg2k.decode`
/// directly (its default `auto` policy fingerprints the legacy format).
const Jpeg2kBackend = struct {
    const m = @import("jpeg2k");
    fn encode(a: Allocator, px: []const u16, w: u32, h: u32, out: *std.Io.Writer) anyerror!void {
        // Default Jpeg2kOptions: `encode` pins them (Rust passes
        // `Jpeg2kOptions::default()` explicitly).
        return callEncode(m.encode, a, px, w, h, .{}, out);
    }
    fn decode(a: Allocator, data: []const u8, w: u32, h: u32) anyerror!Decoded {
        var opts: m.DecodeOptions = .{};
        opts.legacy = .standard_only;
        return normalizeDecoded(try m.decodeWithOptions(a, data, w, h, opts), w, h);
    }
};

pub const RLE_CODEC: ?Codec = if (has_rle) adapter("RLE", @import("jpegrle").TRANSFER_SYNTAX_UID, RleBackend) else null;
pub const JPEGLS_CODEC: ?Codec = if (has_jpegls) adapter("JPEG-LS", @import("jpegls").TRANSFER_SYNTAX_UID, JpegLsBackend) else null;
pub const JPEGLI_CODEC: ?Codec = if (has_jpegli) adapter("JPEG Lossless", @import("jpegli").TRANSFER_SYNTAX_UID, JpegLiBackend) else null;
pub const JPEG2K_CODEC: ?Codec = if (has_jpeg2k) adapter("JPEG 2000", @import("jpeg2k").TRANSFER_SYNTAX_UID, Jpeg2kBackend) else null;

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

fn eqlIgnoreCase(a: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |n| if (std.ascii.eqlIgnoreCase(a, n)) return true;
    return false;
}

/// Returns a codec by human-readable name (ASCII case-insensitive):
/// `rle`; `jpeg-ls`/`jpegls`; `jpeg-li`/`jpegli`/`jpeg-lossless`;
/// `jpeg-2000`/`jpeg2000`/`j2k`. `null` if unknown or not built in.
pub fn codecByName(name: []const u8) ?Codec {
    if (eqlIgnoreCase(name, &.{"rle"})) return RLE_CODEC;
    if (eqlIgnoreCase(name, &.{ "jpeg-ls", "jpegls" })) return JPEGLS_CODEC;
    if (eqlIgnoreCase(name, &.{ "jpeg-li", "jpegli", "jpeg-lossless" })) return JPEGLI_CODEC;
    if (eqlIgnoreCase(name, &.{ "jpeg-2000", "jpeg2000", "j2k" })) return JPEG2K_CODEC;
    return null;
}

/// Returns the codec for a DICOM Transfer Syntax UID, or `null` if the
/// syntax is uncompressed, unrecognized, or its codec is not built in.
pub fn codecForTransferSyntax(ts_uid: []const u8) ?Codec {
    const eq = std.mem.eql;
    if (eq(u8, ts_uid, transfer.RLE_LOSSLESS)) return RLE_CODEC;
    if (eq(u8, ts_uid, transfer.JPEG_LS_LOSSLESS) or eq(u8, ts_uid, transfer.JPEG_LS_NEAR_LOSSLESS)) return JPEGLS_CODEC;
    if (eq(u8, ts_uid, transfer.JPEG_LOSSLESS) or eq(u8, ts_uid, transfer.JPEG_LOSSLESS_FIRST_ORDER)) return JPEGLI_CODEC;
    if (eq(u8, ts_uid, transfer.JPEG_2000_LOSSLESS) or eq(u8, ts_uid, transfer.JPEG_2000)) return JPEG2K_CODEC;
    return null;
}

/// Identifies a codec from the leading bytes of compressed data.
///
/// - JPEG 2000: the codestream SOC marker `FF 4F`. JP2 boxes are not
///   recognized (the decoder is codestream-only).
/// - JPEG-LS / JPEG Lossless: a bounded, structured marker walk from the
///   `FF D8` SOI to the first SOF (`FF F7` SOF55 -> JPEG-LS, `FF C3` SOF3 ->
///   JPEG Lossless), skipping length-prefixed segments and stopping at SOS.
///
/// RLE has no reliable signature and is never sniffed.
pub fn sniffCodec(data: []const u8) ?Codec {
    if (data.len < 2) return null;
    if (has_jpeg2k and data[0] == 0xFF and data[1] == 0x4F) return JPEG2K_CODEC;
    if ((has_jpegls or has_jpegli) and data[0] == 0xFF and data[1] == 0xD8) return sniffJpegSof(data);
    return null;
}

fn sniffJpegSof(data: []const u8) ?Codec {
    var i: usize = 2;
    while (true) {
        if (i >= data.len or data[i] != 0xFF) return null;
        while (i < data.len and data[i] == 0xFF) i += 1;
        if (i >= data.len) return null;
        const marker = data[i];
        i += 1;
        switch (marker) {
            // Standalone markers with no length: TEM, RSTn, SOI, EOI.
            0x01, 0xD0...0xD9 => continue,
            // Start of Scan: past the frame header with no SOF.
            0xDA => return null,
            0xC3 => if (has_jpegli) return JPEGLI_CODEC else {
                if (!skipSegment(data, &i)) return null;
            },
            0xF7 => if (has_jpegls) return JPEGLS_CODEC else {
                if (!skipSegment(data, &i)) return null;
            },
            else => if (!skipSegment(data, &i)) return null,
        }
    }
}

/// Skips a segment whose 2-byte big-endian length includes itself.
fn skipSegment(data: []const u8, i: *usize) bool {
    if (i.* + 1 >= data.len) return false;
    const seg_len: usize = std.mem.readInt(u16, data[i.*..][0..2], .big);
    if (seg_len < 2) return false;
    const next = i.* + seg_len;
    if (next > data.len) return false;
    i.* = next;
    return true;
}

/// Decodes one compressed frame, selecting the codec by transfer syntax.
///
/// An unknown or unsupported transfer syntax always yields
/// `error.UnsupportedTransferSyntax` -- there is no sniffing fallback (use
/// `decodeFrameSniffed` for that). Returns pixels owned by `allocator`.
pub fn decodeFrame(allocator: Allocator, data: []const u8, width: u32, height: u32, ts_uid: []const u8, diag: ?*Diagnostic) DicosError![]u16 {
    const codec = codecForTransferSyntax(ts_uid) orelse {
        Diagnostic.set(diag, .{ .unsupported_transfer_syntax = err.Message.init("{s}", .{ts_uid}) });
        return error.UnsupportedTransferSyntax;
    };
    return decodeWith(codec, allocator, data, width, height, diag);
}

/// Decodes one compressed frame, selecting the codec by sniffing the data.
/// Prefer `decodeFrame` whenever the transfer syntax is known.
pub fn decodeFrameSniffed(allocator: Allocator, data: []const u8, width: u32, height: u32, diag: ?*Diagnostic) DicosError![]u16 {
    const codec = sniffCodec(data) orelse {
        Diagnostic.set(diag, .{ .unsupported_transfer_syntax = err.Message.init("unable to identify codec from data signature", .{}) });
        return error.UnsupportedTransferSyntax;
    };
    return decodeWith(codec, allocator, data, width, height, diag);
}

fn decodeWith(codec: Codec, allocator: Allocator, data: []const u8, width: u32, height: u32, diag: ?*Diagnostic) DicosError![]u16 {
    var cd: CodecDiagnostic = .{};
    var img = codec.decodeDiag(data, width, height, allocator, &cd) catch |e| {
        Diagnostic.set(diag, .{ .codec = cd });
        return e;
    };
    return img.intoData();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "unknown codec name returns null" {
    try testing.expect(codecByName("unknown-codec") == null);
    try testing.expect(codecByName("") == null);
}

test "unknown transfer syntax returns null" {
    try testing.expect(codecForTransferSyntax("1.2.3.4.5.999") == null);
    try testing.expect(codecForTransferSyntax("") == null);
}

test "uncompressed transfer syntax returns null" {
    try testing.expect(codecForTransferSyntax(transfer.IMPLICIT_VR_LITTLE_ENDIAN) == null);
    try testing.expect(codecForTransferSyntax(transfer.EXPLICIT_VR_LITTLE_ENDIAN) == null);
}

test "sniff empty data returns null" {
    try testing.expect(sniffCodec(&.{}) == null);
    try testing.expect(sniffCodec(&.{0xFF}) == null);
}

test "sniff random data returns null" {
    try testing.expect(sniffCodec(&.{ 0x00, 0x00 }) == null);
}

test "decode frame unknown ts is unsupported even for rle shaped data" {
    const rle_shaped = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC, 0xDD };
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnsupportedTransferSyntax, decodeFrame(testing.allocator, &rle_shaped, 2, 2, "1.2.3.4.5.unknown", &diag));
    try testing.expectEqualStrings("1.2.3.4.5.unknown", diag.detail.unsupported_transfer_syntax.slice());
}

test "sniff rejects malformed jpeg marker structure" {
    // SOI then a non-0xFF byte, a zero-length segment, and a segment that
    // overruns the buffer: all must stop the walk without a match.
    try testing.expect(sniffCodec(&.{ 0xFF, 0xD8, 0x00 }) == null);
    try testing.expect(sniffCodec(&.{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01 }) == null);
    try testing.expect(sniffCodec(&.{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x09, 0xAA }) == null);
    // SOS before any SOF.
    try testing.expect(sniffCodec(&.{ 0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02 }) == null);
    // A bare SOF55 marker byte inside an APP0 payload is not a frame header.
    try testing.expect(sniffCodec(&.{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0xFF, 0xF7, 0xFF, 0xDA }) == null);
}

// Honest DimensionMismatch: a mock backend that declares 4x4 but returns 9.
const MockBackend = struct {
    fn encode(_: Allocator, _: []const u16, _: u32, _: u32, _: *std.Io.Writer) anyerror!void {}
    fn decode(a: Allocator, _: []const u8, _: u32, _: u32) anyerror!Decoded {
        const px = try a.alloc(u16, 9);
        @memset(px, 0);
        return .{ .pixels = px, .width = 4, .height = 4 };
    }
};

const FailingBackend = struct {
    fn encode(_: Allocator, _: []const u16, _: u32, _: u32, _: *std.Io.Writer) anyerror!void {
        return error.InvalidData;
    }
    fn decode(_: Allocator, _: []const u8, _: u32, _: u32) anyerror!Decoded {
        return error.InvalidData;
    }
};

test "dimension mismatch reports real decoded length" {
    const mock = adapter("MOCK", "1.2.3.mock", MockBackend);
    var cd: CodecDiagnostic = .{};
    try testing.expectError(error.DimensionMismatch, mock.decodeDiag(&.{ 0, 0, 0, 0 }, 4, 4, testing.allocator, &cd));
    try testing.expectEqual(@as(usize, 16), cd.detail.dimension_mismatch.expected);
    try testing.expectEqual(@as(usize, 9), cd.detail.dimension_mismatch.actual);
}

test "backend errors are attributed to the backend" {
    const failing = adapter("FAIL", "1.2.3.fail", FailingBackend);
    var cd: CodecDiagnostic = .{};
    try testing.expectError(error.Backend, failing.decodeDiag(&.{}, 1, 1, testing.allocator, &cd));
    try testing.expectEqualStrings("FAIL", cd.detail.backend.codec);
    try testing.expectEqual(error.InvalidData, cd.detail.backend.source);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("FAIL codec error: InvalidData", try std.fmt.bufPrint(&buf, "{f}", .{cd}));
}

fn roundtripCodec(c: Codec, pixels: []const u16, w: u32, h: u32) !void {
    const a = testing.allocator;
    var img = try GrayImage16.init(a, w, h, 0);
    defer img.deinit();
    @memcpy(img.data, pixels);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try c.encode(&img, &out.writer, a);
    var back = try c.decode(out.written(), w, h, a);
    defer back.deinit();
    try testing.expectEqualSlices(u16, pixels, back.data);
}

const sample_pixels = [_]u16{ 10, 20, 30, 40, 50, 60, 1000, 65535, 0, 7, 7, 7 };

test "rle registry roundtrip and lookups" {
    if (!has_rle) return error.SkipZigTest;
    const c = codecByName("RLE").?;
    try testing.expectEqualStrings("RLE", c.name);
    try testing.expectEqualStrings(transfer.RLE_LOSSLESS, codecForTransferSyntax(transfer.RLE_LOSSLESS).?.transfer_syntax_uid);
    try roundtripCodec(c, &sample_pixels, 4, 3);
}

test "jpegls registry roundtrip and lookups" {
    if (!has_jpegls) return error.SkipZigTest;
    const c = codecByName("jpeg-ls").?;
    try testing.expectEqualStrings("JPEG-LS", c.name);
    try testing.expectEqualStrings("JPEG-LS", codecByName("jpegls").?.name);
    try testing.expectEqualStrings(transfer.JPEG_LS_LOSSLESS, codecForTransferSyntax(transfer.JPEG_LS_LOSSLESS).?.transfer_syntax_uid);
    try roundtripCodec(c, &sample_pixels, 4, 3);
}

test "sniff walks past appn segment to find sof55" {
    if (!has_jpegls) return error.SkipZigTest;
    const data = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0xAA, 0xBB, 0xFF, 0xF7, 0x00, 0x0B };
    try testing.expectEqualStrings("JPEG-LS", sniffCodec(&data).?.name);
}

test "decode frame sniffed decodes jpegls frame" {
    if (!has_jpegls) return error.SkipZigTest;
    const a = testing.allocator;
    const pixels = [_]u16{ 10, 20, 30, 40, 50, 60 };
    var img = try GrayImage16.init(a, 3, 2, 0);
    defer img.deinit();
    @memcpy(img.data, &pixels);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try JPEGLS_CODEC.?.encode(&img, &out.writer, a);
    const decoded = try decodeFrameSniffed(a, out.written(), 3, 2, null);
    defer a.free(decoded);
    try testing.expectEqualSlices(u16, &pixels, decoded);
}

test "jpegli registry roundtrip and lookups" {
    if (!has_jpegli) return error.SkipZigTest;
    const c = codecByName("jpegli").?;
    try testing.expectEqualStrings("JPEG Lossless", c.name);
    try testing.expectEqualStrings("JPEG Lossless", codecByName("jpeg-lossless").?.name);
    try testing.expectEqualStrings(
        transfer.JPEG_LOSSLESS_FIRST_ORDER,
        codecForTransferSyntax(transfer.JPEG_LOSSLESS_FIRST_ORDER).?.transfer_syntax_uid,
    );
    try roundtripCodec(c, &sample_pixels, 4, 3);
    // Truthful UID: the encoded stream must sniff as JPEG Lossless (SOF3).
    const a = testing.allocator;
    var img = try GrayImage16.init(a, 4, 3, 0);
    defer img.deinit();
    @memcpy(img.data, &sample_pixels);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try c.encode(&img, &out.writer, a);
    try testing.expectEqualStrings("JPEG Lossless", sniffCodec(out.written()).?.name);
}

test "jpeg2k registry roundtrip and lookups" {
    if (!has_jpeg2k) return error.SkipZigTest;
    const c = codecByName("jpeg-2000").?;
    try testing.expectEqualStrings("JPEG 2000", c.name);
    try testing.expectEqualStrings("JPEG 2000", codecByName("j2k").?.name);
    try testing.expectEqualStrings(transfer.JPEG_2000_LOSSLESS, codecForTransferSyntax(transfer.JPEG_2000_LOSSLESS).?.transfer_syntax_uid);
    try roundtripCodec(c, &sample_pixels, 4, 3);
}

test "sniff jpeg2k codestream" {
    if (!has_jpeg2k) return error.SkipZigTest;
    try testing.expectEqualStrings("JPEG 2000", sniffCodec(&.{ 0xFF, 0x4F, 0xFF, 0x51, 0x00, 0x00 }).?.name);
}

test "decode frame by transfer syntax maps backend failures to codec errors" {
    if (!has_jpegls) return error.SkipZigTest;
    var diag: Diagnostic = .{};
    const garbage = [_]u8{ 0xFF, 0xD8, 0xFF, 0xF7, 0x00 };
    const r = decodeFrame(testing.allocator, &garbage, 2, 2, transfer.JPEG_LS_LOSSLESS, &diag);
    try testing.expectError(error.Backend, r);
    try testing.expectEqualStrings("JPEG-LS", diag.detail.codec.detail.backend.codec);
}
