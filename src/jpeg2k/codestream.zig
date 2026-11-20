//! JPEG 2000 codestream reader / writer and public encode / decode functions.
//!
//! Generates and parses the conformant (ITU-T T.800) codestream structure:
//! `SOC -> SIZ -> COD -> QCD -> SOT -> SOD -> [LRCP packets] -> EOC`.
//!
//! Supported profile (everything else is rejected loudly by the decode
//! support matrix): one tile, one component (unsigned 16-bit), reversible 5/3
//! DWT, LRCP progression, one quality layer, `cb_style = 0`, zero origins.
//!
//! `encode` emits this conformant stream. `decode` parses it and, by default
//! (`LegacyPolicy.auto`), also transparently decodes the non-conformant
//! v1.0.0 / Go "legacy" raw-DWT format.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CodecError = @import("error.zig").CodecError;
const bitstream = @import("bitstream.zig");
const geometry = @import("geometry.zig");
const markers = @import("markers.zig");
const tile = @import("tile.zig");
const legacy = @import("legacy.zig");
const Jpeg2kOptions = @import("root.zig").Jpeg2kOptions;

const ByteReader = bitstream.ByteReader;
const ByteWriter = bitstream.ByteWriter;
const BandKind = geometry.BandKind;
const CodMarker = markers.CodMarker;

// ---------------------------------------------------------------------------
// Profile constants and the single-source-of-truth quantization helpers
// ---------------------------------------------------------------------------

/// Component bit depth `RI` (unsigned 16-bit).
const BIT_DEPTH: u8 = 16;
/// Guard bits `G` (T.800 E.1).
const GUARD_BITS: u8 = 2;
/// DC level shift for unsigned 16-bit samples: `2^(BIT_DEPTH-1)`.
const DC_SHIFT: i32 = 1 << (BIT_DEPTH - 1);
/// Allocation cap on `Xsiz * Ysiz` (samples), guarding hostile SIZ values.
pub const MAX_IMAGE_AREA: u64 = 1 << 28;

/// Whether the legacy (v1.0.0 / Go raw-DWT) decode path is compiled in. On by
/// default (Rust feature `legacy-decode`); an application can disable it by
/// declaring `pub const jpeg2k_legacy_decode = false;` in its root file. With
/// it off, `auto` behaves as `standard_only` and `legacy_only` errors.
pub const legacy_available: bool = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "jpeg2k_legacy_decode")) root.jpeg2k_legacy_decode else true;
};

/// QCD exponent `eps_b` for the reversible case (T.800 E-10):
/// `eps_b = RI + log2(gain_b)`. Shared by the QCD writer and `Mb`.
fn qcdEpsilon(kind: BandKind) u8 {
    return BIT_DEPTH + geometry.gainLog2(kind);
}

/// `Mb = eps_b + G - 1` (wrapping, as Rust release: an all-zero `eps`/`G`
/// pair wraps huge and is then rejected by the `Mb >= 32` guard).
fn mbFromEpsilon(epsilon: u8, guard_bits: u8) u32 {
    return @as(u32, epsilon) + guard_bits -% 1;
}

/// Index into the spec-order QCD exponent list (LL_NL, then HL/LH/HH for
/// n = NL..1) for band `kind` at decomposition `level`.
fn qcdBandIndex(kind: BandKind, level: u8, num_levels: u8) usize {
    const base = 3 * @as(usize, num_levels - level);
    return switch (kind) {
        .LL => 0,
        .HL => 1 + base,
        .LH => 2 + base,
        .HH => 3 + base,
    };
}

/// `Mb` provider for the encoder: the profile's own exponents.
const EncodeMb = struct {
    pub fn mb(_: EncodeMb, kind: BandKind, _: u8) u32 {
        return mbFromEpsilon(qcdEpsilon(kind), GUARD_BITS);
    }
};

/// `Mb` provider for the decoder: parsed QCD exponents (raw SPqcd bytes).
const DecodeMb = struct {
    raw: []const u8,
    nl: u8,
    guard: u8,
    pub fn mb(self: DecodeMb, kind: BandKind, level: u8) u32 {
        return mbFromEpsilon(self.raw[qcdBandIndex(kind, level, self.nl)] >> 3, self.guard);
    }
};

// ---------------------------------------------------------------------------
// Public API: encode
// ---------------------------------------------------------------------------

/// Encode with default options. See `encodeWithOptions`.
pub fn encode(gpa: Allocator, pixels: []const u16, img_width: u32, img_height: u32, out: *std.Io.Writer) CodecError!void {
    return encodeWithOptions(gpa, pixels, img_width, img_height, .{}, out);
}

/// Encode a 16-bit grayscale image into a conformant JPEG 2000 (T.800)
/// codestream written to `out` (not flushed). `pixels` is row-major
/// `img_width * img_height`. The stream is single-tile, single-component,
/// reversible 5/3, LRCP, one quality layer.
pub fn encodeWithOptions(
    gpa: Allocator,
    pixels: []const u16,
    img_width: u32,
    img_height: u32,
    options: Jpeg2kOptions,
    out: *std.Io.Writer,
) CodecError!void {
    try options.validate();

    const expected = std.math.mul(usize, img_width, img_height) catch return error.InvalidData;
    if (pixels.len != expected) return error.DimensionMismatch;
    // "image has zero dimension"
    if (img_width == 0 or img_height == 0) return error.InvalidData;

    const num_levels = options.num_decomp_levels;
    const xcb = options.cb_width_exp;
    const ycb = options.cb_height_exp;

    // DC level shift: unsigned samples -> signed, centred about zero.
    const component = try gpa.alloc(i32, expected);
    defer gpa.free(component);
    for (component, pixels) |*c, p| c.* = @as(i32, p) - DC_SHIFT;

    const comp_info = [_]markers.ComponentInfo{.{ .precision = BIT_DEPTH, .signed = false, .x_rsiz = 1, .y_rsiz = 1 }};
    const siz = markers.buildSiz(img_width, img_height, &comp_info, 0, 0);
    const cod = markers.buildCod(num_levels, xcb, ycb);

    const tile_bitstream = try tile.encodeTile(gpa, component, img_width, img_height, num_levels, xcb, ycb, EncodeMb{});
    defer gpa.free(tile_bitstream);

    var bw = ByteWriter.init(gpa);
    defer bw.deinit();

    // SOC
    try bw.writeU16(markers.MARKER_SOC);

    // SIZ: Lsiz = 38 + 3 * Csiz.
    try bw.writeU16(markers.MARKER_SIZ);
    try bw.writeU16(@intCast(38 + 3 * siz.components.len));
    try bw.writeU16(siz.rsiz);
    for ([_]u32{ siz.x_siz, siz.y_siz, siz.x_osiz, siz.y_osiz, siz.x_tsiz, siz.y_tsiz, siz.x_tosiz, siz.y_tosiz }) |v| try bw.writeU32(v);
    try bw.writeU16(@intCast(siz.components.len));
    for (siz.components) |c| {
        try bw.writeU8((c.precision - 1) | @as(u8, if (c.signed) 0x80 else 0));
        try bw.writeU8(c.x_rsiz);
        try bw.writeU8(c.y_rsiz);
    }

    // COD (no user precincts in this profile -> Lcod = 12).
    try bw.writeU16(markers.MARKER_COD);
    try bw.writeU16(12);
    try bw.writeU8(cod.scod);
    try bw.writeU8(@intFromEnum(cod.progression));
    try bw.writeU16(cod.num_layers);
    try bw.writeU8(cod.mct);
    try bw.writeU8(cod.decomp_levels);
    try bw.writeU8(cod.cb_width_exp);
    try bw.writeU8(cod.cb_height_exp);
    try bw.writeU8(cod.cb_style);
    try bw.writeU8(@intFromEnum(cod.transform));

    // QCD: E-10 exponents in spec order, G = 2, reversible style (one byte
    // per band carrying eps_b << 3).
    try bw.writeU16(markers.MARKER_QCD);
    try bw.writeU16(@intCast(3 + 3 * @as(usize, num_levels) + 1));
    try bw.writeU8((GUARD_BITS << 5) | 0);
    try bw.writeU8(qcdEpsilon(.LL) << 3);
    for (0..num_levels) |_| {
        try bw.writeU8(qcdEpsilon(.HL) << 3);
        try bw.writeU8(qcdEpsilon(.LH) << 3);
        try bw.writeU8(qcdEpsilon(.HH) << 3);
    }

    // SOT. Psot (A.4.2) = SOT segment (12) + SOD marker (2) + data.
    const psot = std.math.cast(u32, 14 + @as(u64, tile_bitstream.len)) orelse return error.InvalidData;
    try bw.writeU16(markers.MARKER_SOT);
    try bw.writeU16(10);
    try bw.writeU16(0); // Isot
    try bw.writeU32(psot);
    try bw.writeU8(0); // TPsot
    try bw.writeU8(1); // TNsot
    try bw.writeU16(markers.MARKER_SOD);
    try bw.writeBytes(tile_bitstream);
    try bw.writeU16(markers.MARKER_EOC);

    out.writeAll(bw.bytes()) catch return error.IoError;
}

// ---------------------------------------------------------------------------
// Decode options / legacy policy
// ---------------------------------------------------------------------------

/// How `decodeWithOptions` treats the non-conformant v1.0.0 / Go "legacy"
/// raw-DWT format.
pub const LegacyPolicy = enum {
    /// Decode conformant streams; transparently fall back to the legacy format
    /// when its fingerprint is present. The default for `decode`.
    auto,
    /// Only decode conformant T.800 streams; reject legacy input.
    standard_only,
    /// Only decode legacy streams; reject conformant input.
    legacy_only,
};

/// Options controlling `decodeWithOptions`.
pub const DecodeOptions = struct {
    legacy: LegacyPolicy = .auto,
};

/// A decoded 16-bit grayscale image. `pixels` is row-major, owned by caller.
pub const DecodedImage = struct {
    pixels: []u16,
    width: u32,
    height: u32,

    pub fn deinit(self: *DecodedImage, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Structured main-header + tile-part parse (no marker rescans)
// ---------------------------------------------------------------------------

/// Everything the decoder needs, recovered from one bounds-checked walk.
/// Borrows from the input.
const Parsed = struct {
    cod: CodMarker,
    /// Raw SPqcd bytes (`eps_b << 3` each, reversible style).
    qcd_raw: []const u8,
    guard_bits: u8,
    img_w: u32,
    img_h: u32,
    /// The tile-part data between SOD and the end of the tile-part.
    payload: []const u8,

    fn allZeroExps(self: *const Parsed) bool {
        for (self.qcd_raw) |b| if (b >> 3 != 0) return false;
        return true;
    }
};

/// Map a reader EOF to `IoError` (Rust maps `std::io::Error` to `Io`).
inline fn rd(v: anytype) CodecError!@typeInfo(@TypeOf(v)).error_union.payload {
    return v catch error.IoError;
}

/// Absolute index one past a segment's content (length counts itself).
fn segContentEnd(br: *const ByteReader, length: u16) CodecError!usize {
    // "marker segment length < 2"
    if (length < 2) return error.InvalidData;
    return br.position() + (length - 2);
}

/// Advance to `end`, erroring if the fields already overran it.
fn seekTo(br: *ByteReader, end: usize) CodecError!void {
    // "marker segment fields exceed its declared length"
    if (br.position() > end) return error.InvalidData;
    try rd(br.skip(end - br.position()));
}

const SizInfo = struct { w: u32, h: u32 };

fn readSiz(br: *ByteReader) CodecError!SizInfo {
    const length = try rd(br.readU16());
    const end = try segContentEnd(br, length);
    _ = try rd(br.readU16()); // Rsiz
    const x_siz = try rd(br.readU32());
    const y_siz = try rd(br.readU32());
    const x_osiz = try rd(br.readU32());
    const y_osiz = try rd(br.readU32());
    const x_tsiz = try rd(br.readU32());
    const y_tsiz = try rd(br.readU32());
    const x_tosiz = try rd(br.readU32());
    const y_tosiz = try rd(br.readU32());
    const num_comps = try rd(br.readU16());

    // "only single-component images supported"
    if (num_comps != 1) return error.Unsupported;

    const ssiz = try rd(br.readU8());
    _ = try rd(br.readU8()); // XRsiz
    _ = try rd(br.readU8()); // YRsiz
    const signed = ssiz & 0x80 != 0;
    const precision = (ssiz & 0x7F) + 1;
    // "only unsigned 16-bit samples supported"
    if (signed or precision != BIT_DEPTH) return error.Unsupported;

    // "non-zero grid origins not supported"
    if (x_osiz != 0 or y_osiz != 0 or x_tosiz != 0 or y_tosiz != 0) return error.Unsupported;
    // "SIZ tile size has a zero dimension" / "SIZ image has a zero dimension"
    if (x_tsiz == 0 or y_tsiz == 0) return error.InvalidData;
    if (x_siz == 0 or y_siz == 0) return error.InvalidData;
    // "multi-tile images not supported"
    if (x_tsiz < x_siz or y_tsiz < y_siz) return error.Unsupported;
    // "image area exceeds the sample cap"
    if (@as(u64, x_siz) * y_siz > MAX_IMAGE_AREA) return error.InvalidData;

    try seekTo(br, end);
    return .{ .w = x_siz - x_osiz, .h = y_siz - y_osiz };
}

fn readCod(br: *ByteReader) CodecError!CodMarker {
    const length = try rd(br.readU16());
    const end = try segContentEnd(br, length);
    const scod = try rd(br.readU8());
    const prog_byte = try rd(br.readU8());
    const num_layers = try rd(br.readU16());
    const mct = try rd(br.readU8());
    const decomp_levels = try rd(br.readU8());
    const cb_width_exp = try rd(br.readU8());
    const cb_height_exp = try rd(br.readU8());
    const cb_style = try rd(br.readU8());
    const transform_byte = try rd(br.readU8());

    // "COD Scod precinct/SOP/EPH flags not supported"
    if (scod & (markers.CODING_STYLE_PRECINCTS_USER | markers.CODING_STYLE_SOP | markers.CODING_STYLE_EPH) != 0)
        return error.Unsupported;
    // "unknown progression order" / "only LRCP progression supported"
    const progression = markers.ProgressionOrder.fromByte(prog_byte) orelse return error.InvalidData;
    if (progression != .lrcp) return error.Unsupported;
    // "only a single quality layer supported"
    if (num_layers != 1) return error.Unsupported;
    // "multiple-component transform not supported (MCT != 0)"
    if (mct != 0) return error.Unsupported;
    // "unknown transform type" / "only reversible 5/3 transform supported"
    const transform = markers.TransformType.fromByte(transform_byte) orelse return error.InvalidData;
    if (transform != .reversible_53) return error.Unsupported;
    // "code-block style flags not supported"
    if (cb_style != 0) return error.Unsupported;
    // "decomposition levels exceed 32"
    if (decomp_levels > 32) return error.InvalidData;
    // "illegal code-block exponents" (stored exp - 2; exp in 2..=10, sum <= 12)
    if (cb_width_exp > 8 or cb_height_exp > 8 or cb_width_exp + cb_height_exp > 8) return error.InvalidData;

    try seekTo(br, end);
    return .{
        .scod = scod,
        .progression = progression,
        .num_layers = num_layers,
        .mct = mct,
        .decomp_levels = decomp_levels,
        .cb_width_exp = cb_width_exp,
        .cb_height_exp = cb_height_exp,
        .cb_style = cb_style,
        .transform = transform,
    };
}

const QcdInfo = struct { raw: []const u8, guard_bits: u8 };

fn readQcd(br: *ByteReader) CodecError!QcdInfo {
    const length = try rd(br.readU16());
    const end = try segContentEnd(br, length);
    const sqcd = try rd(br.readU8());
    const guard_bits = (sqcd >> 5) & 0x07;
    // "only no-quantization (reversible) QCD supported"
    if (sqcd & 0x1F != 0) return error.Unsupported;
    const remaining = end -| br.position();
    const raw = try rd(br.readBytes(remaining));
    try seekTo(br, end);
    return .{ .raw = raw, .guard_bits = guard_bits };
}

/// Skip an informational (CRG/COM/TLM) marker segment.
fn skipSegment(br: *ByteReader) CodecError!void {
    const length = try rd(br.readU16());
    if (length < 2) return error.InvalidData;
    try rd(br.skip(length - 2));
}

fn parseCodestream(data: []const u8) CodecError!Parsed {
    var br = ByteReader.init(data);
    // "missing SOC marker"
    if (try rd(br.readU16()) != markers.MARKER_SOC) return error.InvalidData;

    var siz: ?SizInfo = null;
    var cod: ?CodMarker = null;
    var qcd: ?QcdInfo = null;

    // Main header up to (not past) the first SOT.
    const sot_marker_off = while (true) {
        const off = br.position();
        switch (try rd(br.readU16())) {
            markers.MARKER_SIZ => siz = try readSiz(&br),
            markers.MARKER_COD => cod = try readCod(&br),
            markers.MARKER_QCD => qcd = try readQcd(&br),
            markers.MARKER_SOT => break off,
            // Legal but unsupported: reject by marker code.
            markers.MARKER_COC, markers.MARKER_QCC, markers.MARKER_RGN, markers.MARKER_POC, markers.MARKER_PPM, markers.MARKER_PLM => return error.Unsupported,
            // Informational: skip silently.
            markers.MARKER_CRG, markers.MARKER_COM, markers.MARKER_TLM => try skipSegment(&br),
            // "unexpected marker in main header"
            else => return error.InvalidData,
        }
    };

    // "missing SIZ/COD/QCD marker"
    const s = siz orelse return error.InvalidData;
    const c = cod orelse return error.InvalidData;
    const q = qcd orelse return error.InvalidData;

    // SOT segment (marker already consumed).
    // "unexpected Lsot"
    if (try rd(br.readU16()) != 10) return error.InvalidData;
    // "only tile index 0 supported"
    if (try rd(br.readU16()) != 0) return error.Unsupported;
    const psot = try rd(br.readU32());
    const tpsot = try rd(br.readU8());
    const tnsot = try rd(br.readU8());
    // "only the first tile-part supported" / "multiple tile-parts not supported"
    if (tpsot != 0) return error.Unsupported;
    if (tnsot > 1) return error.Unsupported;

    // Require SOD (conformant 0xFF93 or legacy 0xFFD3), skipping CRG/COM.
    const payload_start = while (true) {
        switch (try rd(br.readU16())) {
            markers.MARKER_SOD, markers.MARKER_SOD_LEGACY => break br.position(),
            markers.MARKER_CRG, markers.MARKER_COM => try skipSegment(&br),
            markers.MARKER_PPT, markers.MARKER_PLT => return error.Unsupported,
            // "expected SOD after SOT"
            else => return error.InvalidData,
        }
    };

    const isEoc = struct {
        fn f(b: []const u8) bool {
            return b.len == 2 and b[0] == 0xFF and b[1] == 0xD9;
        }
    }.f;

    // Tile-part data bounds (A.4.2): Psot spans SOT's first byte to the end
    // of the tile-part data, which must be followed by EOC and nothing else.
    const payload_end: usize = if (psot == 0) blk: {
        // Psot == 0: data extends to a mandatory trailing EOC.
        if (data.len < 2) return error.InvalidData;
        const e = data.len - 2;
        // "Psot = 0 but no trailing EOC"
        if (e < payload_start or !isEoc(data[e..])) return error.InvalidData;
        break :blk e;
    } else blk: {
        const tile_part_end = @as(u64, sot_marker_off) + psot;
        // "Psot exceeds buffer"
        if (tile_part_end > data.len) return error.InvalidData;
        const end: usize = @intCast(tile_part_end);
        // "Psot shorter than tile-part header"
        if (end < payload_start) return error.InvalidData;
        // "expected EOC immediately after the tile-part (trailing garbage?)"
        if (!isEoc(data[end..])) return error.InvalidData;
        break :blk end;
    };

    return .{
        .cod = c,
        .qcd_raw = q.raw,
        .guard_bits = q.guard_bits,
        .img_w = s.w,
        .img_h = s.h,
        .payload = data[payload_start..payload_end],
    };
}

// ---------------------------------------------------------------------------
// Public API: decode
// ---------------------------------------------------------------------------

/// Decode using `LegacyPolicy.auto`. See `decodeWithOptions`.
pub fn decode(gpa: Allocator, data: []const u8, width: u32, height: u32) CodecError!DecodedImage {
    return decodeWithOptions(gpa, data, width, height, .{});
}

/// Decode a JPEG 2000 codestream into a 16-bit grayscale image.
///
/// SIZ is authoritative for the dimensions. A non-zero `width`/`height` is
/// validated against SIZ (`error.DimensionMismatch`); `0` means "trust SIZ".
///
/// Legacy detection (`auto`): v1.0.0 / Go streams carry the same markers but
/// their payload is `[Xsiz u16be, Ysiz u16be, Xsiz*Ysiz i32be]` and their QCD
/// has **all-zero** exponents -- impossible for a conformant 16-bit stream
/// (exponents are always >= 16). A stream with all-zero exponents *and* a
/// matching payload layout takes the frozen legacy path.
pub fn decodeWithOptions(gpa: Allocator, data: []const u8, width: u32, height: u32, opts: DecodeOptions) CodecError!DecodedImage {
    const parsed = try parseCodestream(data);
    const img_w = parsed.img_w;
    const img_h = parsed.img_h;

    if ((width != 0 and width != img_w) or (height != 0 and height != img_h)) return error.DimensionMismatch;

    const is_legacy_fp = parsed.allZeroExps() and legacyPayloadMatches(parsed.payload, img_w, img_h);

    const pixels = switch (opts.legacy) {
        .standard_only => try decodeStandard(gpa, &parsed),
        .legacy_only => blk: {
            // "legacy-decode feature disabled"
            if (!legacy_available) return error.Unsupported;
            // "LegacyOnly: input is not a legacy raw-DWT stream"
            if (!is_legacy_fp) return error.InvalidData;
            break :blk try decodeLegacy(gpa, parsed.payload, img_w, img_h, parsed.cod.decomp_levels);
        },
        .auto => if (legacy_available and is_legacy_fp)
            try decodeLegacy(gpa, parsed.payload, img_w, img_h, parsed.cod.decomp_levels)
        else
            try decodeStandard(gpa, &parsed),
    };
    return .{ .pixels = pixels, .width = img_w, .height = img_h };
}

/// Conformant T.800 tile decode with DC un-shift.
fn decodeStandard(gpa: Allocator, parsed: *const Parsed) CodecError![]u16 {
    const nl = parsed.cod.decomp_levels;
    const raw = parsed.qcd_raw;
    // "all-zero QCD exponents: not a conformant 16-bit stream"
    if (parsed.allZeroExps()) return error.InvalidData;
    const needed = 3 * @as(usize, nl) + 1;
    // "QCD has too few exponents for NL levels"
    if (raw.len < needed) return error.InvalidData;

    const guard = parsed.guard_bits;
    // Adversarial-QCD guard: Mb >= 32 would let tier-1 shift `1 << 31+` and
    // overflow the i32 coefficient range.
    for (raw[0..needed]) |b| {
        if (mbFromEpsilon(b >> 3, guard) >= 32) return error.Unsupported;
    }

    const xcb = parsed.cod.cb_width_exp + 2;
    const ycb = parsed.cod.cb_height_exp + 2;
    const coeffs = try tile.decodeTile(gpa, parsed.payload, parsed.img_w, parsed.img_h, nl, xcb, ycb, DecodeMb{ .raw = raw, .nl = nl, .guard = guard });
    defer gpa.free(coeffs);

    const out = try gpa.alloc(u16, coeffs.len);
    for (out, coeffs) |*o, v| o.* = @intCast(std.math.clamp(v +% DC_SHIFT, 0, std.math.maxInt(u16)));
    return out;
}

/// Does `payload` match the legacy layout `[w u16be, h u16be, w*h i32be]`?
fn legacyPayloadMatches(payload: []const u8, w: u32, h: u32) bool {
    if (w > std.math.maxInt(u16) or h > std.math.maxInt(u16)) return false;
    const expected = @as(u64, w) * h * 4 + 4;
    return payload.len == expected and
        payload[0] == @as(u8, @truncate(w >> 8)) and payload[1] == @as(u8, @truncate(w)) and
        payload[2] == @as(u8, @truncate(h >> 8)) and payload[3] == @as(u8, @truncate(h));
}

fn decodeLegacy(gpa: Allocator, payload: []const u8, w: u32, h: u32, nl: u8) CodecError![]u16 {
    if (!legacy_available) return error.Unsupported;
    const td = legacy.TileDecoder.init(nl);
    const dec = try td.decodeTile(gpa, payload);
    defer gpa.free(dec.pixels);
    if (dec.width != w or dec.height != h) return error.DimensionMismatch;
    // Legacy files stored the raw (un-shifted) pixel DWT: no DC un-shift.
    const out = try gpa.alloc(u16, dec.pixels.len);
    for (out, dec.pixels) |*o, v| o.* = @intCast(std.math.clamp(v, 0, std.math.maxInt(u16)));
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

/// Encode to an owned byte slice (test helper).
pub fn encodeToOwned(gpa: Allocator, pixels: []const u16, w: u32, h: u32, opts: Jpeg2kOptions) CodecError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try encodeWithOptions(gpa, pixels, w, h, opts, &aw.writer);
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

fn makePixels(w: u32, h: u32, comptime pat: fn (u32, u32) u16) ![]u16 {
    const v = try ta.alloc(u16, @as(usize, w) * h);
    for (0..h) |y| for (0..w) |x| {
        v[y * w + x] = pat(@intCast(x), @intCast(y));
    };
    return v;
}

fn patternPixels(kind: usize, w: u32, h: u32) ![]u16 {
    const n: usize = @as(usize, w) * h;
    const v = try ta.alloc(u16, n);
    switch (kind) {
        0 => @memset(v, 40000),
        1 => for (v, 0..) |*p, i| {
            const iu: u32 = @intCast(i);
            p.* = @intCast(((iu % w) * 250 + (iu / w) * 70) % 65536);
        },
        2 => {
            var s: u64 = 0x9E37_79B9_7F4A_7C15 ^ (@as(u64, w) << 20) ^ @as(u64, h);
            for (v) |*p| {
                s = s *% 6364136223846793005 +% 1;
                p.* = @truncate(s >> 40);
            }
        },
        else => {
            @memset(v, 0);
            v[0] = 65535;
            v[n / 2] = 32768;
            v[n - 1] = 1;
        },
    }
    return v;
}

test "roundtrip matrix auto and standard only" {
    const dims = [_]u32{ 1, 2, 5, 13, 64, 130, 200 };
    const levels = [_]u8{ 0, 1, 5 };
    const cbs = [_][2]u8{ .{ 2, 2 }, .{ 6, 6 } };
    for (dims) |w| for (dims) |h| for (levels) |nl| for (cbs) |cb| for (0..4) |kind| {
        const px = try patternPixels(kind, w, h);
        defer ta.free(px);
        const buf = try encodeToOwned(ta, px, w, h, .{ .num_decomp_levels = nl, .cb_width_exp = cb[0], .cb_height_exp = cb[1] });
        defer ta.free(buf);
        var d = try decode(ta, buf, w, h);
        defer d.deinit(ta);
        try testing.expectEqual(w, d.width);
        try testing.expectEqual(h, d.height);
        try testing.expectEqualSlices(u16, px, d.pixels);
        var d2 = try decodeWithOptions(ta, buf, w, h, .{ .legacy = .standard_only });
        defer d2.deinit(ta);
        try testing.expectEqualSlices(u16, px, d2.pixels);
    };
}

test "decode trusts siz when dims zero" {
    const px = try makePixels(20, 12, struct {
        fn f(x: u32, y: u32) u16 {
            return @intCast(x * 300 + y);
        }
    }.f);
    defer ta.free(px);
    const buf = try encodeToOwned(ta, px, 20, 12, .{});
    defer ta.free(buf);
    var d = try decode(ta, buf, 0, 0);
    defer d.deinit(ta);
    try testing.expectEqual(@as(u32, 20), d.width);
    try testing.expectEqual(@as(u32, 12), d.height);
    try testing.expectEqualSlices(u16, px, d.pixels);
}

fn constPat(comptime c: u16) fn (u32, u32) u16 {
    return struct {
        fn f(_: u32, _: u32) u16 {
            return c;
        }
    }.f;
}

test "codestream starts with soc and ends with eoc" {
    const px = try makePixels(8, 8, constPat(42));
    defer ta.free(px);
    const buf = try encodeToOwned(ta, px, 8, 8, .{});
    defer ta.free(buf);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x4F }, buf[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, buf[buf.len - 2 ..]);
}

test "conformant sod marker is ff93" {
    const px = try makePixels(8, 8, constPat(7));
    defer ta.free(px);
    const buf = try encodeToOwned(ta, px, 8, 8, .{});
    defer ta.free(buf);
    try testing.expect(std.mem.indexOf(u8, buf, &.{ 0xFF, 0x93 }) != null);
    try testing.expect(std.mem.indexOf(u8, buf, &.{ 0xFF, 0xD3 }) == null);
}

test "qcd exponents are conformant nonzero" {
    const px = try makePixels(4, 4, constPat(100));
    defer ta.free(px);
    const buf = try encodeToOwned(ta, px, 4, 4, .{ .num_decomp_levels = 1 });
    defer ta.free(buf);
    const q = std.mem.indexOf(u8, buf, &.{ 0xFF, 0x5C }).?;
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x07 }, buf[q + 2 .. q + 4]);
    try testing.expectEqual(@as(u8, 0x40), buf[q + 4]);
    try testing.expectEqualSlices(u8, &.{ 16 << 3, 17 << 3, 17 << 3, 18 << 3 }, buf[q + 5 .. q + 9]);
}

test "decode dimension mismatch" {
    const px = try makePixels(8, 8, constPat(100));
    defer ta.free(px);
    const buf = try encodeToOwned(ta, px, 8, 8, .{});
    defer ta.free(buf);
    try testing.expectError(error.DimensionMismatch, decode(ta, buf, 16, 16));
}

test "decode invalid data" {
    try testing.expect(std.meta.isError(decode(ta, &.{}, 8, 8)));
    try testing.expect(std.meta.isError(decode(ta, &.{ 0x00, 0x00 }, 8, 8)));
    try testing.expect(std.meta.isError(decode(ta, &.{ 0xFF, 0x4F }, 8, 8)));
}

test "encode rejects multi tile options" {
    const px = try makePixels(8, 8, constPat(100));
    defer ta.free(px);
    try testing.expectError(error.Unsupported, encodeToOwned(ta, px, 8, 8, .{ .tile_width = 4, .tile_height = 4 }));
}

test "encode rejects bad cb exp" {
    const px = try makePixels(8, 8, constPat(100));
    defer ta.free(px);
    try testing.expectError(error.InvalidData, encodeToOwned(ta, px, 8, 8, .{ .cb_width_exp = 11 }));
    try testing.expectError(error.InvalidData, encodeToOwned(ta, px, 8, 8, .{ .cb_width_exp = 8, .cb_height_exp = 8 }));
}

// -- support matrix rejection ------------------------------------------------

fn markerOff(buf: []const u8, marker: u16) usize {
    const m = [2]u8{ @truncate(marker >> 8), @truncate(marker) };
    return std.mem.indexOf(u8, buf, &m).?;
}

fn validStream() ![]u8 {
    const px = try makePixels(16, 16, struct {
        fn f(x: u32, y: u32) u16 {
            return @intCast(x * 400 + y * 40);
        }
    }.f);
    defer ta.free(px);
    return encodeToOwned(ta, px, 16, 16, .{ .num_decomp_levels = 2 });
}

fn expectUnsupported(buf: []const u8) !void {
    try testing.expectError(error.Unsupported, decode(ta, buf, 16, 16));
}

fn mutateAndExpectUnsupported(comptime marker: u16, comptime edits: []const struct { usize, u8 }) !void {
    const buf = try validStream();
    defer ta.free(buf);
    const off = markerOff(buf, marker);
    for (edits) |e| buf[off + e[0]] = e[1];
    try expectUnsupported(buf);
}

test "reject 8bit ssiz" {
    // Ssiz at siz+40 (FF51 + Lsiz + Rsiz + 8x4 + Csiz).
    try mutateAndExpectUnsupported(markers.MARKER_SIZ, &.{.{ 40, 7 }});
}

test "reject signed ssiz" {
    try mutateAndExpectUnsupported(markers.MARKER_SIZ, &.{.{ 40, 0x8F }});
}

test "reject multi component" {
    try mutateAndExpectUnsupported(markers.MARKER_SIZ, &.{ .{ 38, 0x00 }, .{ 39, 0x03 } });
}

test "reject multi tile" {
    // XTsiz at siz+22 -> 8 < Xsiz(16).
    try mutateAndExpectUnsupported(markers.MARKER_SIZ, &.{ .{ 22, 0 }, .{ 23, 0 }, .{ 24, 0 }, .{ 25, 8 } });
}

test "reject non lrcp progression" {
    try mutateAndExpectUnsupported(markers.MARKER_COD, &.{.{ 5, 1 }});
}

test "reject multiple layers" {
    try mutateAndExpectUnsupported(markers.MARKER_COD, &.{ .{ 6, 0 }, .{ 7, 2 } });
}

test "reject mct" {
    try mutateAndExpectUnsupported(markers.MARKER_COD, &.{.{ 8, 1 }});
}

test "reject cb style" {
    try mutateAndExpectUnsupported(markers.MARKER_COD, &.{.{ 12, 0x01 }});
}

test "reject transform 97" {
    try mutateAndExpectUnsupported(markers.MARKER_COD, &.{.{ 13, 0 }});
}

test "reject precinct flag" {
    try mutateAndExpectUnsupported(markers.MARKER_COD, &.{.{ 4, 0x01 }});
}

test "reject coc marker" {
    const buf = try validStream();
    defer ta.free(buf);
    const sot = markerOff(buf, markers.MARKER_SOT);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try out.appendSlice(ta, buf[0..sot]);
    try out.appendSlice(ta, &.{ 0xFF, 0x53, 0x00, 0x03, 0x00 });
    try out.appendSlice(ta, buf[sot..]);
    try expectUnsupported(out.items);
}

test "reject qcd mb overflow shift" {
    // eps_b = 31 (0xF8) and G = 7 (0xE0) -> Mb ~ 37: must be a clean error.
    const buf = try validStream();
    defer ta.free(buf);
    const q = markerOff(buf, markers.MARKER_QCD);
    buf[q + 4] = 0xE0;
    buf[q + 5] = 0xF8;
    const r = decode(ta, buf, 16, 16);
    if (r) |img| {
        var i = img;
        i.deinit(ta);
        return error.TestUnexpectedResult;
    } else |e| try testing.expect(e == error.Unsupported or e == error.InvalidData);
}

test "encode rejects multi precinct" {
    // 32769 > 2^15 precinct span at resolution NL -> two precincts.
    const w: u32 = 32769;
    const px = try ta.alloc(u16, w);
    defer ta.free(px);
    @memset(px, 0);
    try testing.expectError(error.Unsupported, encodeToOwned(ta, px, w, 1, .{}));
}

test "decode rejects multi precinct" {
    const buf = try validStream();
    defer ta.free(buf);
    const siz = markerOff(buf, markers.MARKER_SIZ);
    std.mem.writeInt(u32, buf[siz + 6 ..][0..4], 32769, .big); // Xsiz
    std.mem.writeInt(u32, buf[siz + 22 ..][0..4], 32769, .big); // XTsiz
    try testing.expectError(error.Unsupported, decode(ta, buf, 0, 0));
}

test "reject tnsot multiple tile parts" {
    try mutateAndExpectUnsupported(markers.MARKER_SOT, &.{.{ 11, 2 }});
}

test "reject trailing garbage" {
    const buf = try validStream();
    defer ta.free(buf);
    const longer = try ta.alloc(u8, buf.len + 1);
    defer ta.free(longer);
    @memcpy(longer[0..buf.len], buf);
    longer[buf.len] = 0;
    try testing.expectError(error.InvalidData, decode(ta, longer, 16, 16));
}

test "truncation never panics" {
    const buf = try validStream();
    defer ta.free(buf);
    for (0..buf.len) |cut| {
        if (decode(ta, buf[0..cut], 16, 16)) |img| {
            var i = img;
            i.deinit(ta);
        } else |_| {}
    }
    var d = try decode(ta, buf, 16, 16);
    d.deinit(ta);
}
