//! JPEG-LS decoder.
//!
//! Parses SOI, SOF55, LSE, SOS markers and then entropy-decodes the scan data
//! to reconstruct 16-bit samples. The default `Profile.t87` path is ITU-T
//! T.87 conformant; `Profile.legacy_go` reads frozen 1.0.0 bytes.

const std = @import("std");
const bitstream = @import("bitstream.zig");
const context = @import("context.zig");
const errors = @import("error.zig");
const legacy = @import("legacy.zig");
const options = @import("options.zig");
const predictor = @import("predictor.zig");
const run_mode = @import("run_mode.zig");

const BitReader = bitstream.BitReader;
const CodecError = errors.CodecError;
const ContextModel = context.ContextModel;
const DecodeImageOptions = options.DecodeImageOptions;
const DecodeOptions = options.DecodeOptions;
const Diagnostic = errors.Diagnostic;
const Profile = options.Profile;
const clamp = predictor.clamp;
const iabs = predictor.iabs;
const predictMed = predictor.predictMed;

// ---------------------------------------------------------------------------
// JPEG-LS markers
// ---------------------------------------------------------------------------

const MARKER_SOI: u16 = 0xFFD8;
const MARKER_EOI: u16 = 0xFFD9;
const MARKER_SOS: u16 = 0xFFDA;
const MARKER_SOF55: u16 = 0xFFF7;
const MARKER_LSE: u16 = 0xFFF8;
const MARKER_DRI: u16 = 0xFFDD;

/// Default statistics reset threshold (T.87 A.2.1 RESET).
const DEFAULT_RESET: i32 = 64;

/// Hard cap on decoded image size (pixels), guarding the row-major sample
/// allocation against untrusted SOF55 dimensions (`1 << 28` = 268 435 456
/// pixels ~= 512 MiB), matching the Rust crate.
pub const MAX_PIXELS: usize = 1 << 28;

/// Minimum permitted LSE RESET value (T.87 C.2.4.1.1). A RESET below this
/// would suppress statistics halving and risk i32 overflow on long scans.
const MIN_RESET: i32 = 3;

// ---------------------------------------------------------------------------
// Frame / scan headers + LSE presets
// ---------------------------------------------------------------------------

const FrameHeader = struct {
    precision: u8,
    height: usize,
    width: usize,
    /// Number of components (Nf): 1 (grayscale) or 3 (e.g. RGB).
    components: usize,
    component_ids: [3]u8,
};

const ScanHeader = struct {
    component_id: u8,
    near: i32,
};

/// LSE ID=1 coding-parameter presets (T.87 C.2.4.1.1); `null` = spec default.
const Presets = struct {
    maxval: ?i32 = null,
    t1: ?i32 = null,
    t2: ?i32 = null,
    t3: ?i32 = null,
    reset: ?i32 = null,
};

const Headers = struct { frame: FrameHeader, presets: Presets, scan: ScanHeader };

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Decode a JPEG-LS compressed bitstream into a 16-bit grayscale pixel buffer.
///
/// `width` and `height` are the *expected* image dimensions, cross-checked
/// against the SOF55 marker. Uses the default `DecodeOptions` (`Profile.t87`).
///
/// Returns a row-major slice of `width * height` samples owned by the caller.
pub fn decode(allocator: std.mem.Allocator, data: []const u8, width: u32, height: u32) CodecError![]u16 {
    return decodeWithOptions(allocator, data, width, height, .{});
}

/// Decode a JPEG-LS bitstream with explicit `DecodeOptions`.
pub fn decodeWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
    opts: DecodeOptions,
) CodecError![]u16 {
    var dec = Decoder{ .data = data, .diag = opts.diagnostic };
    return dec.decodeGray(allocator, width, height, opts.profile);
}

/// A decoded JPEG-LS image with the frame metadata a DICOM caller needs.
///
/// Supports grayscale (`components == 1`) and 3-component **planar** (ILV 0)
/// frames. Line- and sample-interleaved scans (ILV 1/2) are rejected with
/// `error.Unsupported`, so `interleave_mode` is always `0` on success.
pub const DecodedImage = struct {
    /// Samples in component-planar order -- all of component 0, then
    /// component 1, ... Length `width * height * components`.
    samples: []u16,
    /// Image width in pixels (from the codestream).
    width: u32,
    /// Image height in pixels (from the codestream).
    height: u32,
    /// Sample precision in bits (2..=16).
    bits_per_sample: u8,
    /// Component count (1 or 3).
    components: u8,
    /// Interleave mode from the scan headers; `0` (none/planar) on success.
    interleave_mode: u8,
    /// NEAR error bound (0 = lossless).
    near: u8,

    pub fn deinit(self: *DecodedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        self.* = undefined;
    }
};

/// Decode a JPEG-LS bitstream, reading the geometry from the codestream.
///
/// Unlike `decode`, this takes no expected dimensions and returns the full
/// frame metadata, including 3-component planar (ILV 0) frames. T.87
/// conformant path only. The output sample buffer is limited to 64 MiB; use
/// `decodeImageWithOptions` to select a different budget.
pub fn decodeImage(allocator: std.mem.Allocator, data: []const u8) CodecError!DecodedImage {
    return decodeImageWithOptions(allocator, data, .{});
}

/// Decode with a caller-supplied output allocation limit, checked before
/// allocation.
pub fn decodeImageWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    opts: DecodeImageOptions,
) CodecError!DecodedImage {
    var dec = Decoder{ .data = data, .diag = opts.diagnostic };
    return dec.decodeFull(allocator, opts.max_decoded_bytes);
}

// ---------------------------------------------------------------------------
// Decoder state
// ---------------------------------------------------------------------------

const Decoder = struct {
    data: []const u8,
    pos: usize = 0,
    diag: ?*Diagnostic,

    // -- byte-level helpers ------------------------------------------------

    fn readByte(self: *Decoder) CodecError!u8 {
        if (self.pos >= self.data.len) return errors.invalidData(self.diag, "unexpected end of JPEG-LS data", .{});
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn readU16be(self: *Decoder) CodecError!u16 {
        const hi = try self.readByte();
        const lo = try self.readByte();
        return @as(u16, hi) << 8 | lo;
    }

    fn skip(self: *Decoder, n: usize) CodecError!void {
        if (n > self.data.len - self.pos) return errors.invalidData(self.diag, "unexpected end of data during skip", .{});
        self.pos += n;
    }

    // -- marker parsing ----------------------------------------------------

    fn expectMarker(self: *Decoder, expected: u16) CodecError!void {
        const marker = try self.readU16be();
        if (marker != expected) {
            return errors.invalidData(self.diag, "expected marker 0x{X:0>4}, got 0x{X:0>4}", .{ expected, marker });
        }
    }

    const MarkerSegment = struct { marker: u16, len: usize };

    fn readMarker(self: *Decoder) CodecError!MarkerSegment {
        var b = try self.readByte();
        if (b != 0xFF) return errors.invalidData(self.diag, "expected 0xFF marker prefix, got 0x{X:0>2}", .{b});
        // A marker may be preceded by any number of 0xFF fill bytes
        // (T.81 B.1.1.2); skip them. The first non-0xFF byte is the code.
        while (b == 0xFF) b = try self.readByte();
        const marker = 0xFF00 | @as(u16, b);
        const length: usize = try self.readU16be();
        // Length field includes its own 2 bytes.
        return .{ .marker = marker, .len = length -| 2 };
    }

    fn readSof(self: *Decoder, payload_len: usize) CodecError!FrameHeader {
        const diag = self.diag;
        // P(1) + Y(2) + X(2) + Nf(1); checked before reading so a short
        // segment cannot pull its fields from the following marker.
        if (payload_len < 6) {
            return errors.invalidData(diag, "SOF55 segment too short ({d} payload bytes, need >= 6)", .{payload_len});
        }
        const p = try self.readByte();
        if (p < 2 or p > 16) return errors.invalidParameter(diag, "precision", p, "2..=16");
        const height: usize = try self.readU16be();
        const width: usize = try self.readU16be();

        // Reject degenerate / oversized frames before any large allocation.
        if (width == 0 or height == 0) return errors.invalidData(diag, "SOF55 dimensions must be non-zero", .{});
        if (width * height > MAX_PIXELS) {
            return errors.invalidParameter(diag, "width*height", @intCast(width * height), "product <= 268435456 pixels (1<<28)");
        }

        const nf = try self.readByte();
        if (nf != 1 and nf != 3) {
            return errors.unsupported(diag, "JPEG-LS component count {d} not supported (only 1 or 3)", .{nf});
        }

        // T.87 C.2.2: Lf = 8 + 3*Nf, i.e. the payload is exactly 6 + 3*Nf.
        const expected = 6 + 3 * @as(usize, nf);
        if (payload_len != expected) {
            return errors.invalidData(diag, "SOF55 payload is {d} bytes, expected {d} for Nf = {d}", .{ payload_len, expected, nf });
        }
        var ids: [3]u8 = undefined;
        // Component specs: [Ci, sampling (Hi<<4 | Vi), Tqi] per component.
        // Require 1:1 sampling and no per-component mapping table (Tq 0);
        // component IDs must be unique.
        for (0..nf) |i| {
            const ci = try self.readByte();
            if (std.mem.indexOfScalar(u8, ids[0..i], ci) != null) {
                return errors.invalidData(diag, "duplicate SOF55 component ID", .{});
            }
            ids[i] = ci;
            const sampling = try self.readByte();
            const tq = try self.readByte();
            if (sampling != 0x11) {
                return errors.unsupported(diag, "JPEG-LS component sampling 0x{x:0>2} not supported (must be 1:1 = 0x11)", .{sampling});
            }
            if (tq != 0) {
                return errors.unsupported(diag, "JPEG-LS component mapping table {d} not supported (must be 0)", .{tq});
            }
        }
        return .{ .precision = p, .height = height, .width = width, .components = nf, .component_ids = ids };
    }

    /// Parse an LSE segment. Only ID=1 (coding parameters) is supported.
    fn readLse(self: *Decoder, payload_len: usize, presets: *Presets) CodecError!void {
        const diag = self.diag;
        if (payload_len < 1) return errors.invalidData(diag, "empty LSE segment", .{});
        const id = try self.readByte();
        switch (id) {
            1 => {
                if (payload_len < 11) return errors.invalidData(diag, "LSE ID=1 segment too short", .{});
                const maxval: i32 = try self.readU16be();
                const t1: i32 = try self.readU16be();
                const t2: i32 = try self.readU16be();
                const t3: i32 = try self.readU16be();
                const reset: i32 = try self.readU16be();
                // A field of 0 means "use the default" for MAXVAL/T1/T2/T3.
                presets.maxval = if (maxval > 0) maxval else null;
                presets.t1 = if (t1 > 0) t1 else null;
                presets.t2 = if (t2 > 0) t2 else null;
                presets.t3 = if (t3 > 0) t3 else null;
                // RESET must be an explicit, valid halving threshold (>= 3).
                if (reset < MIN_RESET) {
                    return errors.invalidData(diag, "LSE RESET={d} invalid (must be >= {d})", .{ reset, MIN_RESET });
                }
                presets.reset = reset;
                // Skip any trailing bytes in an over-long segment.
                try self.skip(payload_len - 11);
            },
            2...4 => return errors.unsupported(diag, "LSE ID={d} (mapping tables) not supported", .{id}),
            else => return errors.invalidData(diag, "unknown LSE ID={d}", .{id}),
        }
    }

    /// `nf` is the frame's component count when SOF55 has already been read
    /// (`null` if SOS precedes it; that stream fails later as missing SOF55).
    fn readSos(self: *Decoder, payload_len: usize, nf: ?usize) CodecError!ScanHeader {
        const diag = self.diag;
        if (payload_len < 6) return errors.invalidData(diag, "SOS segment too short", .{});
        const ns = try self.readByte();
        // T.87 C.2.3: 1 <= Ns <= 4, and a scan cannot cover more components
        // than the frame has: malformed, so InvalidData.
        if (ns == 0 or ns > 4 or (nf != null and ns > nf.?)) {
            if (nf) |n| return errors.invalidData(diag, "SOS component count Ns = {d} is invalid for a frame with Nf = {d}", .{ ns, n });
            return errors.invalidData(diag, "SOS component count Ns = {d} is invalid", .{ns});
        }
        if (ns != 1) {
            // A scan over several components (ILV 1/2) is unsupported.
            return errors.unsupported(diag, "multi-component scan (Ns != 1) not supported", .{});
        }
        if (payload_len != 6) return errors.invalidData(diag, "SOS length does not match component count", .{});
        const component_id = try self.readByte();
        const mapping = try self.readByte();
        if (mapping != 0) {
            return errors.unsupported(diag, "SOS mapping-table selector {d} not supported (must be 0)", .{mapping});
        }
        const near = try self.readByte();
        const ilv = try self.readByte();
        const al_ah = try self.readByte();
        if (ilv != 0) return errors.unsupported(diag, "interleaved scan (ILV != 0) not supported", .{});
        // Point transform (the Ah/Al byte) must be 0.
        if (al_ah != 0) return errors.invalidData(diag, "SOS point-transform byte 0x{x:0>2} must be 0", .{al_ah});
        return .{ .component_id = component_id, .near = near };
    }

    fn expectEoi(self: *Decoder) CodecError!void {
        const b1 = try self.readByte();
        var b2 = try self.readByte();
        // 0xFF fill bytes may precede the EOI (T.81 B.1.1.2); DCMTK pads an
        // odd-length stream to even this way (`FF FF D9`).
        if (b1 == 0xFF) {
            while (b2 == 0xFF) b2 = try self.readByte();
        }
        const marker = @as(u16, b1) << 8 | b2;
        if (marker != MARKER_EOI) {
            return errors.invalidData(self.diag, "expected EOI (0xFFD9) after scan, got 0x{X:0>4}", .{marker});
        }
    }

    fn readHeaders(self: *Decoder) CodecError!Headers {
        try self.expectMarker(MARKER_SOI);

        var frame: ?FrameHeader = null;
        var presets: Presets = .{};
        const scan: ScanHeader = while (true) {
            const seg = try self.readMarker();
            switch (seg.marker) {
                MARKER_SOF55 => frame = try self.readSof(seg.len),
                MARKER_LSE => try self.readLse(seg.len, &presets),
                // Tolerate and skip DRI, as CharLS does. A non-zero interval
                // that actually emits RSTn markers in the scan is rejected by
                // the entropy decoder (scanError).
                MARKER_DRI => try self.skip(seg.len),
                MARKER_SOS => break try self.readSos(seg.len, if (frame) |f| f.components else null),
                MARKER_EOI => return errors.invalidData(self.diag, "unexpected EOI before SOS", .{}),
                else => try self.skip(seg.len),
            }
        };

        const f = frame orelse return errors.invalidData(self.diag, "missing SOF55 marker", .{});
        return .{ .frame = f, .presets = presets, .scan = scan };
    }

    // -- main decode flow --------------------------------------------------

    fn decodeGray(self: *Decoder, allocator: std.mem.Allocator, exp_width: u32, exp_height: u32, profile: Profile) CodecError![]u16 {
        const diag = self.diag;
        const hdr = try self.readHeaders();
        const frame = hdr.frame;

        if (frame.width != exp_width or frame.height != exp_height) {
            return errors.dimensionMismatch(diag, @as(usize, exp_width) * exp_height, frame.width * frame.height);
        }

        // Grayscale-only contract for this entry; 3-component streams go
        // through `decodeImage` (which handles planar ILV 0).
        if (frame.components != 1) {
            return errors.unsupported(diag, "decode() is grayscale-only; {d}-component frames need decode_image()", .{frame.components});
        }
        if (hdr.scan.component_id != frame.component_ids[0]) {
            return errors.invalidData(diag, "unknown SOS component selector", .{});
        }
        const vp = try validateParams(diag, frame, hdr.presets, hdr.scan.near);

        const w: usize = exp_width;
        const h: usize = exp_height;
        const pixels = try allocator.alloc(u16, w * h);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);

        switch (profile) {
            .legacy_go => try legacy.decodeScan(allocator, self.data[self.pos..], pixels, w, h, vp.max_val, hdr.scan.near, diag),
            .t87 => {
                const ctx = ContextModel.withPresets(vp.max_val, hdr.scan.near, vp.reset, hdr.presets.t1, hdr.presets.t2, hdr.presets.t3);
                const scan_start = self.pos;
                const consumed = try decodeScanT87(allocator, diag, self.data[scan_start..], pixels, w, h, ctx, scan_start);
                self.pos = scan_start + consumed;
                try self.expectEoi();
            },
        }
        return pixels;
    }

    /// Decode a full image (grayscale or 3-component planar), reading geometry
    /// from the codestream. T.87 path only.
    fn decodeFull(self: *Decoder, allocator: std.mem.Allocator, max_decoded_bytes: usize) CodecError!DecodedImage {
        const diag = self.diag;
        const hdr = try self.readHeaders();
        const frame = hdr.frame;
        const near = hdr.scan.near;
        const vp = try validateParams(diag, frame, hdr.presets, near);

        const w = frame.width;
        const h = frame.height;
        const components = frame.components;
        // Cannot overflow: readSof caps w*h at MAX_PIXELS and components <= 3.
        const plane = w * h;
        const count = plane * components;
        const bytes = count * @sizeOf(u16);
        if (bytes > max_decoded_bytes) {
            return errors.invalidData(diag, "decoded image needs {d} bytes, limit is {d}", .{ bytes, max_decoded_bytes });
        }
        const samples = allocator.alloc(u16, count) catch
            return errors.invalidData(diag, "decoded image allocation failed", .{});
        errdefer allocator.free(samples);
        @memset(samples, 0);

        var seen = [_]bool{false} ** 3;
        var scan = hdr.scan;

        // ILV 0 codes one component per scan; the first SOS is already read.
        for (0..components) |c| {
            if (c > 0) {
                const seg = try self.readMarker();
                if (seg.marker != MARKER_SOS) {
                    return errors.invalidData(diag, "expected SOS for component {d}, got marker 0x{X:0>4}", .{ c, seg.marker });
                }
                scan = try self.readSos(seg.len, components);
                if (scan.near != near) {
                    return errors.invalidData(diag, "per-scan NEAR differs across components ({d} then {d})", .{ near, scan.near });
                }
            }
            const index = std.mem.indexOfScalar(u8, frame.component_ids[0..components], scan.component_id) orelse
                return errors.invalidData(diag, "unknown SOS component selector", .{});
            if (seen[index]) return errors.invalidData(diag, "duplicate SOS component selector", .{});
            seen[index] = true;
            const plane_slot = samples[index * plane .. (index + 1) * plane];
            const ctx = ContextModel.withPresets(vp.max_val, near, vp.reset, hdr.presets.t1, hdr.presets.t2, hdr.presets.t3);
            const scan_start = self.pos;
            const consumed = try decodeScanT87(allocator, diag, self.data[scan_start..], plane_slot, w, h, ctx, scan_start);
            self.pos = scan_start + consumed;
        }
        try self.expectEoi();

        return .{
            .samples = samples,
            .width = @intCast(w),
            .height = @intCast(h),
            .bits_per_sample = frame.precision,
            .components = @intCast(components),
            .interleave_mode = 0,
            .near = @intCast(near),
        };
    }
};

const ValidParams = struct { max_val: i32, reset: i32 };

/// Validate MAXVAL / NEAR / threshold ordering (T.87 C.2.4.1.1) for a scan and
/// return the effective `(max_val, reset)`. `near` is the scan's NEAR;
/// `presets` carries any LSE ID=1 overrides (`null` = spec default).
fn validateParams(diag: ?*Diagnostic, frame: FrameHeader, presets: Presets, near: i32) CodecError!ValidParams {
    const sof_max_val: i32 = (@as(i32, 1) << @intCast(frame.precision)) - 1;
    const max_val = presets.maxval orelse sof_max_val;

    // Effective MAXVAL must be positive and fit the SOF precision range.
    if (max_val <= 0 or max_val > sof_max_val) {
        return errors.invalidData(diag, "LSE MAXVAL={d} outside 1..={d} for precision {d}", .{ max_val, sof_max_val, frame.precision });
    }

    // NEAR validity depends on the effective MAXVAL.
    const near_max = @min(@divTrunc(max_val, 2), 255);
    if (near < 0 or near > near_max) return errors.invalidParameter(diag, "near", near, "0..=min(255, MAXVAL/2)");

    // Thresholds must satisfy NEAR < T1 <= T2 <= T3 <= MAXVAL. Preset fields
    // left at their default fall back to the spec defaults (already valid).
    const dt = ContextModel.defaultThresholds(max_val, near);
    const t1 = presets.t1 orelse dt.t1;
    const t2 = presets.t2 orelse dt.t2;
    const t3 = presets.t3 orelse dt.t3;
    if (!(near < t1 and t1 <= t2 and t2 <= t3 and t3 <= max_val)) {
        return errors.invalidData(diag, "LSE thresholds violate NEAR<T1<=T2<=T3<=MAXVAL (NEAR={d}, T1={d}, T2={d}, T3={d}, MAXVAL={d})", .{ near, t1, t2, t3, max_val });
    }

    return .{ .max_val = max_val, .reset = presets.reset orelse DEFAULT_RESET };
}

// ---------------------------------------------------------------------------
// T.87 conformant scan decode (regular + run mode)
// ---------------------------------------------------------------------------

/// Classify a bit-reader error hit mid-scan (before all samples are decoded).
fn scanError(diag: ?*Diagnostic, e: bitstream.ReadError, br: *const BitReader, base_offset: usize) CodecError {
    const offset = base_offset + br.pos;
    switch (e) {
        error.Marker => {
            const m = br.pending_marker orelse 0;
            if (m >= 0xFFD0 and m <= 0xFFD7) {
                return errors.unsupported(diag, "JPEG-LS restart markers (RSTn) in scan not supported", .{});
            }
            return errors.truncated(diag, offset, "entropy-coded scan");
        },
        error.InvalidData => return errors.truncated(diag, offset, "entropy-coded scan"),
    }
}

/// Decode the entropy-coded scan (T.87 A.4-A.7); returns bytes consumed.
pub fn decodeScanT87(
    allocator: std.mem.Allocator,
    diag: ?*Diagnostic,
    scan_data: []const u8,
    pixels: []u16,
    width: usize,
    height: usize,
    ctx_in: ContextModel,
    base_offset: usize,
) CodecError!usize {
    var ctx = ctx_in;
    var br = BitReader.init(scan_data);
    const near = ctx.near;
    const max_val = ctx.max_val;
    const range = ctx.range;

    const lines = try allocator.alloc(i32, 2 * width + 4);
    defer allocator.free(lines);
    @memset(lines, 0);
    var prev = lines[0 .. width + 2];
    var cur = lines[width + 2 ..];

    for (0..height) |y| {
        cur[0] = prev[1];
        prev[width + 1] = prev[width];
        const row = pixels[y * width .. (y + 1) * width];

        var x: usize = 0;
        while (x < width) {
            const ra = cur[x];
            const rb = prev[x + 1];
            const rc = prev[x];
            const rd = prev[x + 2];

            const d1 = rd - rb;
            const d2 = rb - rc;
            const d3 = rc - ra;

            if (iabs(d1) <= near and iabs(d2) <= near and iabs(d3) <= near) {
                const before = x;
                x = run_mode.decodeRun(&br, &ctx, cur, prev, x, width) catch |e|
                    return scanError(diag, e, &br, base_offset);
                for (row[before..x], cur[before + 1 .. x + 1]) |*dst, v| dst.* = @intCast(v);
                continue;
            }

            const ci = ctx.getContextIndex(d1, d2, d3);
            const q = ci.q;
            const sign = ci.sign;
            const k = ctx.computeK(q);
            var px = predictMed(ra, rb, rc);
            px += sign * ctx.c[q];
            px = clamp(px, 0, max_val);

            const correction: i32 = if (k == 0 and near == 0 and 2 * ctx.b[q] <= -ctx.n[q]) -1 else 0;
            const mapped = br.readLimitedGolomb(k, ctx.limit, ctx.qbpp) catch |e|
                return scanError(diag, e, &br, base_offset);
            const err_q = run_mode.unmapError(mapped, correction);
            run_mode.checkErrval(err_q, range) catch |e| return scanError(diag, e, &br, base_offset);
            ctx.updateStats(q, err_q);

            const recon = run_mode.fixReconstructed(px + sign * err_q * (2 * near + 1), near, range, max_val);
            cur[x + 1] = recon;
            row[x] = @intCast(recon);
            x += 1;
        }

        std.mem.swap([]i32, &prev, &cur);
    }

    return br.markerPos();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const util = @import("tests/util.zig");
const encode_mod = @import("encode.zig");
const ta = testing.allocator;

fn roundtrip(pixels: []const u16, w: u32, h: u32) !void {
    const buf = try util.encodeOpts(pixels, w, h, .{});
    defer ta.free(buf);
    try util.expectDecodes(buf, w, h, pixels);
}

test "roundtrip small gradient" {
    var pixels: [35]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 3 % 256);
    try roundtrip(&pixels, 7, 5);
}

test "roundtrip constant forces run" {
    try roundtrip(&([_]u16{777} ** (24 * 8)), 24, 8);
}

test "roundtrip 1x1" {
    try roundtrip(&.{42}, 1, 1);
}

/// Append big-endian u16.
fn be(list: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try list.appendSlice(ta, &b);
}

/// SOI + SOF55 (Nf=1) for a w x h frame at `precision`.
fn soiSof(list: *std.ArrayList(u8), precision: u8, w: u16, h: u16) !void {
    try list.appendSlice(ta, &.{ 0xFF, 0xD8, 0xFF, 0xF7 });
    try be(list, 11);
    try list.append(ta, precision);
    try be(list, h);
    try be(list, w);
    try list.appendSlice(ta, &.{ 1, 1, 0x11, 0x00 });
}

fn lseId1(list: *std.ArrayList(u8), fields: [5]u16) !void {
    try list.appendSlice(ta, &.{ 0xFF, 0xF8 });
    try be(list, 13);
    try list.append(ta, 1);
    for (fields) |v| try be(list, v);
}

fn sos(list: *std.ArrayList(u8), near: u8) !void {
    try list.appendSlice(ta, &.{ 0xFF, 0xDA, 0x00, 0x08, 1, 1, 0x00, near, 0, 0 });
}

test "lse id1 presets honored" {
    const w = 16;
    const h = 12;
    var pixels: [w * h]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast((i * 5) % 200);
    const maxval = 255;
    const t1 = 5;
    const t2 = 12;
    const t3 = 40;
    const reset = 32;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try soiSof(&out, 8, w, h);
    try lseId1(&out, .{ maxval, t1, t2, t3, reset });
    try sos(&out, 0);
    var aw = std.Io.Writer.Allocating.fromArrayList(ta, &out);
    defer aw.deinit();
    const ctx = ContextModel.withPresets(maxval, 0, reset, t1, t2, t3);
    try encode_mod.encodeScanT87(ta, null, &aw.writer, &pixels, w, h, ctx);
    try aw.writer.writeAll(&.{ 0xFF, 0xD9 });
    try util.expectDecodes(aw.written(), w, h, &pixels);
}

/// SOI + SOF55 + LSE(ID=1) + SOS carrying the given preset fields.
/// Validation fires before scan decode, so no scan/EOI bytes are needed.
fn lsePresetStream(precision: u8, w: u16, h: u16, fields: [5]u16, near: u8) !std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ta);
    try soiSof(&out, precision, w, h);
    try lseId1(&out, fields);
    try sos(&out, near);
    return out;
}

test "sof zero dimension rejected" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try soiSof(&out, 8, 4, 0);
    try util.expectErr(error.InvalidData, util.decodeErr(out.items, 4, 0));
}

test "sof length must match component count" {
    const buf = try util.encodeOpts(&([_]u16{0} ** 16), 4, 4, .{});
    defer ta.free(buf);
    const sof = util.find(buf, &.{ 0xFF, 0xF7 }).?;
    try testing.expectEqualSlices(u8, &.{ 0x00, 11 }, buf[sof + 2 .. sof + 4]);
    for ([_]u8{ 2, 5, 8, 10, 12 }) |lf| {
        const bad = try ta.dupe(u8, buf);
        defer ta.free(bad);
        bad[sof + 3] = lf;
        try util.expectErr(error.InvalidData, util.decodeErr(bad, 4, 4));
    }
}

test "sof huge dimensions rejected not aborted" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try soiSof(&out, 8, 65535, 65535);
    var diag: Diagnostic = .{};
    try util.expectErr(error.InvalidParameter, util.decodeErrOpts(out.items, 65535, 65535, .{ .diagnostic = &diag }));
    try testing.expectEqualStrings("width*height", diag.name);
}

test "lse maxval exceeds precision rejected" {
    var out = try lsePresetStream(8, 4, 4, .{ 65535, 0, 0, 0, 64 }, 0);
    defer out.deinit(ta);
    try util.expectErr(error.InvalidData, util.decodeErr(out.items, 4, 4));
}

test "lse threshold ordering rejected" {
    var out = try lsePresetStream(8, 4, 4, .{ 0, 100, 50, 200, 64 }, 0);
    defer out.deinit(ta);
    try util.expectErr(error.InvalidData, util.decodeErr(out.items, 4, 4));
}

test "lse t3 exceeds maxval rejected" {
    var out = try lsePresetStream(8, 4, 4, .{ 200, 5, 12, 250, 64 }, 0);
    defer out.deinit(ta);
    try util.expectErr(error.InvalidData, util.decodeErr(out.items, 4, 4));
}

test "lse reset zero rejected" {
    var out = try lsePresetStream(8, 4, 4, .{ 0, 0, 0, 0, 0 }, 0);
    defer out.deinit(ta);
    try util.expectErr(error.InvalidData, util.decodeErr(out.items, 4, 4));
}

test "lse id2 unsupported" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try soiSof(&out, 8, 4, 4);
    try out.appendSlice(ta, &.{ 0xFF, 0xF8, 0x00, 0x04, 2, 0 });
    try util.expectErr(error.Unsupported, util.decodeErr(out.items, 4, 4));
}

fn mono4x4() !struct { []u8, [16]u16 } {
    var pixels: [16]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 4);
    return .{ try util.encodeOpts(&pixels, 4, 4, .{}), pixels };
}

test "dri zero interval is tolerated" {
    const buf, const pixels = try mono4x4();
    defer ta.free(buf);
    const s = util.find(buf, &.{ 0xFF, 0xDA }).?;
    const with_dri = try util.concat(&.{ buf[0..s], &.{ 0xFF, 0xDD, 0x00, 0x04, 0x00, 0x00 }, buf[s..] });
    defer ta.free(with_dri);
    try util.expectDecodes(with_dri, 4, 4, &pixels);
}

test "fill bytes before marker tolerated" {
    const buf, const pixels = try mono4x4();
    defer ta.free(buf);
    const filled = try util.concat(&.{ buf[0..2], &.{ 0xFF, 0xFF }, buf[2..] });
    defer ta.free(filled);
    try util.expectDecodes(filled, 4, 4, &pixels);
}

test "fill bytes before eoi tolerated" {
    const buf, const pixels = try mono4x4();
    defer ta.free(buf);
    const scan = buf[0 .. buf.len - 2];
    const eoi = buf[buf.len - 2 ..];
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, eoi);
    for (1..4) |fill| {
        const filled = try util.concat(&.{ scan, ([_]u8{0xFF} ** 3)[0..fill], eoi });
        defer ta.free(filled);
        try util.expectDecodes(filled, 4, 4, &pixels);
        var img = try decodeImage(ta, filled);
        defer img.deinit(ta);
        try testing.expectEqualSlices(u16, &pixels, img.samples);
    }
}

test "fill bytes without eoi rejected" {
    const buf, _ = try mono4x4();
    defer ta.free(buf);
    const scan = buf[0 .. buf.len - 2];
    const tails = [_][]const u8{ &.{0xFF}, &.{ 0xFF, 0xFF }, &.{ 0xFF, 0xFF, 0xD8 } };
    for (tails) |tail| {
        const bad = try util.concat(&.{ scan, tail });
        defer ta.free(bad);
        try testing.expect(util.decodeErr(bad, 4, 4) != null);
        try testing.expect(util.decodeImageErr(bad) != null);
    }
}

test "sos mapping table and point transform rejected" {
    const buf, _ = try mono4x4();
    defer ta.free(buf);
    const s = util.find(buf, &.{ 0xFF, 0xDA }).?;
    const mapping = try ta.dupe(u8, buf);
    defer ta.free(mapping);
    mapping[s + 6] = 1;
    try util.expectErr(error.Unsupported, util.decodeErr(mapping, 4, 4));
    const point = try ta.dupe(u8, buf);
    defer ta.free(point);
    point[s + 9] = 3;
    try util.expectErr(error.InvalidData, util.decodeErr(point, 4, 4));
}

/// Assemble a 3-component, planar (ILV 0) JPEG-LS stream: one SOS + scan
/// per plane, sharing one SOF55 (Nf = 3). Lossless, default presets.
fn buildPlanarRgb(planes: []const []const u16, w: u16, h: u16, precision: u8) ![]u8 {
    const nf: u8 = @intCast(planes.len);
    const max_val: i32 = (@as(i32, 1) << @intCast(precision)) - 1;
    var aw = std.Io.Writer.Allocating.init(ta);
    defer aw.deinit();
    const wr = &aw.writer;
    try wr.writeAll(&.{ 0xFF, 0xD8, 0xFF, 0xF7 });
    try wr.writeInt(u16, 8 + 3 * @as(u16, nf), .big);
    try wr.writeByte(precision);
    try wr.writeInt(u16, h, .big);
    try wr.writeInt(u16, w, .big);
    try wr.writeByte(nf);
    for (0..nf) |c| try wr.writeAll(&.{ @intCast(c + 1), 0x11, 0x00 });
    for (planes, 0..) |plane, c| {
        try wr.writeAll(&.{ 0xFF, 0xDA, 0x00, 0x08, 1, @intCast(c + 1), 0x00, 0x00, 0x00, 0x00 });
        try encode_mod.encodeScanT87(ta, null, wr, plane, w, h, ContextModel.init(max_val, 0, DEFAULT_RESET));
    }
    try wr.writeAll(&.{ 0xFF, 0xD9 });
    return aw.toOwnedSlice();
}

test "sos component count is validated against the frame" {
    const mono, _ = try mono4x4();
    defer ta.free(mono);
    const s = util.find(mono, &.{ 0xFF, 0xDA }).?;
    for ([_]u8{ 0, 2, 5, 7 }) |ns| {
        const bad = try ta.dupe(u8, mono);
        defer ta.free(bad);
        bad[s + 4] = ns;
        var diag: Diagnostic = .{};
        try util.expectErr(error.InvalidData, util.decodeErrOpts(bad, 4, 4, .{ .diagnostic = &diag }));
        try testing.expect(std.mem.indexOf(u8, diag.message(), "Ns = ") != null);
    }

    var planes: [3][16]u16 = undefined;
    for (&planes, 0..) |*p, c| @memset(p, @intCast(c * 40));
    const rgb = try buildPlanarRgb(&.{ &planes[0], &planes[1], &planes[2] }, 4, 4, 8);
    defer ta.free(rgb);
    const rs = util.find(rgb, &.{ 0xFF, 0xDA }).?;
    const interleaved = try ta.dupe(u8, rgb);
    defer ta.free(interleaved);
    interleaved[rs + 4] = 3;
    try util.expectErr(error.Unsupported, util.decodeImageErr(interleaved));
    const too_many = try ta.dupe(u8, rgb);
    defer ta.free(too_many);
    too_many[rs + 4] = 4;
    try util.expectErr(error.InvalidData, util.decodeImageErr(too_many));
}

test "sof subsampling and component mapping rejected" {
    const buf, _ = try mono4x4();
    defer ta.free(buf);
    const sof = util.find(buf, &.{ 0xFF, 0xF7 }).?;
    const sub = try ta.dupe(u8, buf);
    defer ta.free(sub);
    sub[sof + 11] = 0x22;
    try util.expectErr(error.Unsupported, util.decodeErr(sub, 4, 4));
    const tq = try ta.dupe(u8, buf);
    defer ta.free(tq);
    tq[sof + 12] = 1;
    try util.expectErr(error.Unsupported, util.decodeErr(tq, 4, 4));
}

test "decode is grayscale only" {
    var plane: [16]u16 = undefined;
    for (&plane, 0..) |*p, i| p.* = @intCast(i);
    const s = try buildPlanarRgb(&.{ &plane, &plane, &plane }, 4, 4, 8);
    defer ta.free(s);
    try util.expectErr(error.Unsupported, util.decodeErr(s, 4, 4));
}

test "decode image rgb planar roundtrip" {
    const n = 15;
    var expected: [3 * n]u16 = undefined;
    for (0..n) |i| {
        const iu: u16 = @intCast(i);
        expected[i] = iu * 3 % 256;
        expected[n + i] = (iu * 7 + 1) % 256;
        expected[2 * n + i] = (200 -% iu * 5) % 256;
    }
    const s = try buildPlanarRgb(&.{ expected[0..n], expected[n .. 2 * n], expected[2 * n ..] }, 5, 3, 8);
    defer ta.free(s);
    var img = try decodeImage(ta, s);
    defer img.deinit(ta);
    try testing.expectEqual(@as(u32, 5), img.width);
    try testing.expectEqual(@as(u32, 3), img.height);
    try testing.expectEqual(@as(u8, 3), img.components);
    try testing.expectEqual(@as(u8, 0), img.interleave_mode);
    try testing.expectEqual(@as(u8, 0), img.near);
    try testing.expectEqual(@as(u8, 8), img.bits_per_sample);
    try testing.expectEqualSlices(u16, &expected, img.samples);
}

test "decode image mono matches source" {
    var pixels: [35]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 3 % 256);
    const buf = try util.encodeOpts(&pixels, 7, 5, .{});
    defer ta.free(buf);
    var img = try decodeImage(ta, buf);
    defer img.deinit(ta);
    try testing.expectEqual(@as(u8, 1), img.components);
    try testing.expectEqual(@as(u32, 7), img.width);
    try testing.expectEqual(@as(u32, 5), img.height);
    try testing.expectEqualSlices(u16, &pixels, img.samples);
}

test "encode image roundtrips through decode image" {
    var mono: [35]u16 = undefined;
    for (&mono, 0..) |*p, i| p.* = @intCast(i * 3 % 256);
    {
        const buf = try util.encodeImg(&mono, 7, 5, 1, .{});
        defer ta.free(buf);
        var img = try decodeImage(ta, buf);
        defer img.deinit(ta);
        try testing.expectEqual(@as(u8, 1), img.components);
        try testing.expectEqual(@as(u32, 7), img.width);
        try testing.expectEqual(@as(u32, 5), img.height);
        try testing.expectEqualSlices(u16, &mono, img.samples);
    }
    const n = 15;
    var planar: [3 * n]u16 = undefined;
    for (0..n) |i| {
        const iu: u16 = @intCast(i);
        planar[i] = iu * 3 % 256;
        planar[n + i] = (iu * 7 + 1) % 256;
        planar[2 * n + i] = (200 -% iu * 5) % 256;
    }
    const buf = try util.encodeImg(&planar, 5, 3, 3, .{});
    defer ta.free(buf);
    var img = try decodeImage(ta, buf);
    defer img.deinit(ta);
    try testing.expectEqual(@as(u8, 3), img.components);
    try testing.expectEqual(@as(u8, 0), img.interleave_mode);
    try testing.expectEqualSlices(u16, &planar, img.samples);
}

test "precision out of range rejected" {
    for ([_]u8{ 0, 1, 17 }) |bad| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ta);
        try soiSof(&out, bad, 4, 4);
        var diag: Diagnostic = .{};
        try util.expectErr(error.InvalidParameter, util.decodeErrOpts(out.items, 4, 4, .{ .diagnostic = &diag }));
        try testing.expectEqualStrings("precision", diag.name);
    }
}

fn ramp64() [64]u16 {
    var pixels: [64]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 4);
    return pixels;
}

test "truncated scan is error not panic" {
    const pixels = ramp64();
    const buf = try util.encodeOpts(&pixels, 8, 8, .{});
    defer ta.free(buf);
    const e = util.decodeErr(buf[0 .. buf.len - 3], 8, 8).?;
    try testing.expect(e == error.Truncated or e == error.InvalidData);
}

test "missing eoi rejected" {
    const pixels = ramp64();
    const buf = try util.encodeOpts(&pixels, 8, 8, .{});
    defer ta.free(buf);
    buf[buf.len - 2] = 0x12;
    buf[buf.len - 1] = 0x34;
    try testing.expect(util.decodeErr(buf, 8, 8) != null);
}

test "decode rejects bad soi" {
    try testing.expect(util.decodeErr(&.{ 0, 0, 0, 0 }, 1, 1) != null);
}

test "t87 differs from legacy bytes" {
    var pixels: [64]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 4 % 256);
    const t87 = try util.encodeOpts(&pixels, 8, 8, .{});
    defer ta.free(t87);
    const leg = try util.encodeOpts(&pixels, 8, 8, .{ .profile = .legacy_go });
    defer ta.free(leg);
    try testing.expect(!std.mem.eql(u8, t87, leg));
    const d1 = try decodeWithOptions(ta, t87, 8, 8, .{});
    defer ta.free(d1);
    const d2 = try decodeWithOptions(ta, leg, 8, 8, .{ .profile = .legacy_go });
    defer ta.free(d2);
    try testing.expectEqualSlices(u16, &pixels, d1);
    try testing.expectEqualSlices(u16, &pixels, d2);
}
