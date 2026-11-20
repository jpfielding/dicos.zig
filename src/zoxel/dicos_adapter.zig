//! DICOS adapter: the only zoxel module that imports the `dicos` library.
//!
//! Turns parsed DICOS datasets (single files, or a stack of per-slice files)
//! into a `volume.Volume`, and extracts threat ROIs from TDR sidecars. This is
//! a port of roxel's `volume/dataset.rs` and `volume/threats.rs`.
//!
//! Everything here works on in-memory bytes with an explicit allocator: no
//! file-system access and no threads (outside tests), so it also compiles for
//! wasm32. Directory listing and file reading live in the caller.

const std = @import("std");
const dicos = @import("dicos");
const volume = @import("volume.zig");

const Allocator = std.mem.Allocator;
const Dataset = dicos.Dataset;
const Value = dicos.Value;
const Tag = dicos.Tag;
const tag = dicos.tag;

/// Upper bound on voxels in one loaded volume (2 GiB of u16 samples). A
/// malformed header can never request more than this.
pub const max_voxels: usize = 1 << 30;

/// A named in-memory file (name is used for ordering, filtering and errors).
pub const NamedBytes = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const LoadError = error{
    MissingRows,
    MissingColumns,
    ZeroRows,
    ZeroColumns,
    MissingPixelData,
    UnexpectedPixelDataType,
    UnsupportedPixelRepresentation,
    UnsupportedBitsAllocated,
    UnsupportedBitsStored,
    InvalidRescaleSlope,
    PixelCountMismatch,
    OddPixelLength,
    TooLarge,
    UnsupportedCodec,
    NoImageFiles,
    MixedRescale,
    OutOfMemory,
} || dicos.err.DicosError;

/// Where a stack load failed (borrowed from the caller's file list).
pub const Diagnostic = struct {
    file_name: []const u8 = "",
};

/// Short user-facing message for an error from this module.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingRows => "missing Rows attribute",
        error.MissingColumns => "missing Columns attribute",
        error.ZeroRows => "Rows is zero",
        error.ZeroColumns => "Columns is zero",
        error.MissingPixelData => "no pixel data",
        error.UnexpectedPixelDataType => "pixel data has an unexpected form",
        error.UnsupportedPixelRepresentation => "unsupported PixelRepresentation (expected 0 or 1)",
        error.UnsupportedBitsAllocated => "signed pixel data needs BitsAllocated 8 or 16",
        error.UnsupportedBitsStored => "signed pixel data with BitsStored smaller than BitsAllocated is unsupported",
        error.InvalidRescaleSlope => "RescaleSlope is not a finite number",
        error.PixelCountMismatch => "pixel data size does not match Rows x Columns x frames",
        error.OddPixelLength => "pixel data has an odd byte length",
        error.TooLarge => "volume dimensions are too large",
        error.UnsupportedCodec => "unsupported or unavailable image codec",
        error.NoImageFiles => "no DICOS image files found",
        error.MixedRescale => "slices differ in RescaleSlope/RescaleIntercept/PixelRepresentation",
        error.OutOfMemory => "out of memory",
        error.InvalidFile, error.BadPreamble => "not a valid DICOS file",
        error.Truncated => "file is truncated",
        error.UnsupportedTransferSyntax => "unsupported transfer syntax",
        error.InvalidData => "image data is corrupt",
        else => @errorName(err),
    };
}

/// Map any error to the `LoadError` member of the same name, else `InvalidFile`.
fn mapError(e: anyerror) LoadError {
    inline for (@typeInfo(LoadError).error_set.?) |er| {
        if (std.mem.eql(u8, er.name, @errorName(e))) return @field(LoadError, er.name);
    }
    return error.InvalidFile;
}

// ---------------------------------------------------------------------------
// Text / number parsing of raw values (port of parse_text / parse_numbers)
// ---------------------------------------------------------------------------

const ws_chars = " \t\r\n\x0b\x0c";

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, ws_chars);
}

/// Rust `s.trim().trim_matches('\0')`.
fn trimWsNul(s: []const u8) []const u8 {
    return std.mem.trim(u8, trimWs(s), "\x00");
}

/// True when `s` is valid UTF-8 with no control characters.
fn isPrintableUtf8(s: []const u8) bool {
    var it = (std.unicode.Utf8View.init(s) catch return false).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    }
    return true;
}

fn parseF64(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    // Zig's parser also takes hex floats and `_` separators; Rust's does not.
    for (s) |c| switch (c) {
        '_', 'x', 'X', 'p', 'P' => return null,
        else => {},
    };
    return std.fmt.parseFloat(f64, s) catch null;
}

fn allocNumberText(gpa: Allocator, comptime T: type, v: T) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{d}", .{v});
}

fn textFromStr(gpa: Allocator, s: []const u8) Allocator.Error!?[]u8 {
    const t = trimWsNul(s);
    if (t.len == 0) return null;
    if (isPrintableUtf8(t)) return try gpa.dupe(u8, t);
    // DELIBERATE DEVIATION from roxel: parse_text only applied the
    // "non-printable 2 bytes -> u16 LE, 4 bytes -> u32 LE" rule to raw bytes.
    // The Zig reader decodes LO/SH/... into `.str` (trailing NULs already
    // stripped), so e.g. PotentialThreatObjectID stored as `01 00` arrives as
    // the one-byte string "\x01" and would become a control character in the
    // threat name. Treat short non-printable strings as zero-padded LE numbers.
    if (t.len <= 2) {
        var b = [2]u8{ 0, 0 };
        @memcpy(b[0..t.len], t);
        return try allocNumberText(gpa, u16, std.mem.readInt(u16, &b, .little));
    }
    if (t.len <= 4) {
        var b = [4]u8{ 0, 0, 0, 0 };
        @memcpy(b[0..t.len], t);
        return try allocNumberText(gpa, u32, std.mem.readInt(u32, &b, .little));
    }
    return try gpa.dupe(u8, t);
}

fn textFromBytes(gpa: Allocator, raw: []const u8) Allocator.Error!?[]u8 {
    if (raw.len == 0) return null;
    if (std.unicode.utf8ValidateSlice(raw)) {
        const t = trimWsNul(raw);
        if (t.len != 0 and isPrintableUtf8(t)) return try gpa.dupe(u8, t);
    }
    if (raw.len == 2) return try allocNumberText(gpa, u16, std.mem.readInt(u16, raw[0..2], .little));
    if (raw.len == 4) return try allocNumberText(gpa, u32, std.mem.readInt(u32, raw[0..4], .little));
    return null;
}

/// Best-effort text of a raw value (port of `parse_text`). Returns an owned
/// string, or null when the value carries no usable text.
pub fn parseText(gpa: Allocator, value: *const Value) Allocator.Error!?[]u8 {
    return switch (value.*) {
        .str => |s| try textFromStr(gpa, s),
        .strings => |vs| if (vs.len == 0) null else try textFromStr(gpa, vs[0]),
        .bytes => |raw| try textFromBytes(gpa, raw),
        .u16_val => |v| try allocNumberText(gpa, u16, v),
        .u32_val => |v| try allocNumberText(gpa, u32, v),
        .i16_val => |v| try allocNumberText(gpa, i16, v),
        .i32_val => |v| try allocNumberText(gpa, i32, v),
        .f32_val => |v| try allocNumberText(gpa, f32, v),
        .f64_val => |v| try allocNumberText(gpa, f64, v),
        else => null,
    };
}

/// Textual numeric list: separators are `\`, `,`, `;` and space.
fn numericText(gpa: Allocator, raw: []const u8) Allocator.Error!?[]f64 {
    if (!std.unicode.utf8ValidateSlice(raw)) return null;
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, trimWsNul(raw), "\\,; ");
    while (it.next()) |part| {
        if (parseF64(trimWs(part))) |v| try out.append(gpa, v);
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

fn leF32s(gpa: Allocator, raw: []const u8) Allocator.Error!?[]f64 {
    if (raw.len % 4 != 0) return null;
    const out = try gpa.alloc(f64, raw.len / 4);
    errdefer gpa.free(out);
    for (out, 0..) |*o, i| {
        const f: f32 = @bitCast(std.mem.readInt(u32, raw[i * 4 ..][0..4], .little));
        if (!std.math.isFinite(f)) {
            gpa.free(out);
            return null;
        }
        o.* = f;
    }
    return out;
}

/// All numbers carried by a raw value (port of `parse_numbers`). Bytes
/// precedence: text > little-endian f32 > little-endian u16. Owned result.
pub fn parseNumbers(gpa: Allocator, value: *const Value) Allocator.Error![]f64 {
    var out: std.ArrayList(f64) = .empty;
    errdefer out.deinit(gpa);
    switch (value.*) {
        .str => |s| {
            var it = std.mem.splitScalar(u8, trimWs(s), '\\');
            while (it.next()) |part| if (parseF64(trimWs(part))) |v| try out.append(gpa, v);
        },
        .strings => |vs| for (vs) |part| if (parseF64(trimWs(part))) |v| try out.append(gpa, v),
        .u16_val => |v| try out.append(gpa, @floatFromInt(v)),
        .u16s => |vs| for (vs) |v| try out.append(gpa, @floatFromInt(v)),
        .u32_val => |v| try out.append(gpa, @floatFromInt(v)),
        .i16_val => |v| try out.append(gpa, @floatFromInt(v)),
        .i32_val => |v| try out.append(gpa, @floatFromInt(v)),
        .f32_val => |v| try out.append(gpa, v),
        .f64_val => |v| try out.append(gpa, v),
        .f32s => |vs| for (vs) |v| try out.append(gpa, v),
        .f64s => |vs| try out.appendSlice(gpa, vs),
        .bytes => |raw| {
            if (raw.len == 0) return out.toOwnedSlice(gpa);
            if (try numericText(gpa, raw)) |v| return v;
            if (try leF32s(gpa, raw)) |v| return v;
            if (raw.len % 2 == 0) {
                var i: usize = 0;
                while (i < raw.len) : (i += 2) try out.append(gpa, @floatFromInt(std.mem.readInt(u16, raw[i..][0..2], .little)));
            }
        },
        else => {},
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Dataset attribute helpers
// ---------------------------------------------------------------------------

/// A single DS / numeric attribute (first component when multi-valued).
fn parseDsF64(ds: *const Dataset, t: Tag) ?f64 {
    if (ds.getStrs(t)) |vals| {
        if (vals.len > 0) if (parseF64(trimWs(vals[0]))) |v| return v;
    }
    if (ds.getString(t)) |s| if (parseF64(trimWs(s))) |v| return v;
    return ds.getF64(t);
}

/// First `n` components of a multi-valued DS (also splitting unsplit
/// backslash-separated strings). Null when fewer than `n` exist or any
/// component fails to parse.
fn dsNumbersFixed(ds: *const Dataset, t: Tag, comptime n: usize) ?[n]f64 {
    const parts = ds.getStrs(t) orelse return null;
    var out: [n]f64 = undefined;
    var count: usize = 0;
    for (parts) |p| {
        var it = std.mem.splitScalar(u8, p, '\\');
        while (it.next()) |q| {
            const v = parseF64(trimWs(q)) orelse return null;
            if (count < n) out[count] = v;
            count += 1;
        }
    }
    if (count < n) return null;
    return out;
}

fn transferSyntaxUid(ds: *const Dataset) []const u8 {
    if (ds.getString(tag.TRANSFER_SYNTAX_UID)) |s| return std.mem.trim(u8, s, " \x00");
    return dicos.transfer.EXPLICIT_VR_LITTLE_ENDIAN;
}

// ---------------------------------------------------------------------------
// Volume extraction
// ---------------------------------------------------------------------------

/// Parse one in-memory DICOS file and extract its volume.
pub fn loadVolumeBytes(gpa: Allocator, bytes: []const u8) LoadError!volume.Volume {
    var ds = dicos.reader.parseBytes(gpa, bytes) catch |e| return mapError(e);
    defer ds.deinit();
    return volumeFromDataset(gpa, &ds);
}

/// Native samples from raw `PixelData` bytes. The size is validated before
/// any allocation.
fn samplesFromBytes(gpa: Allocator, raw: []const u8, bits_allocated: u16, n: usize) LoadError![]u16 {
    if (bits_allocated == 8) {
        // One byte per sample, optionally padded to an even length.
        if (raw.len != n and raw.len != n + (n & 1)) return error.PixelCountMismatch;
        const out = try gpa.alloc(u16, n);
        for (out, raw[0..n]) |*o, b| o.* = b;
        return out;
    }
    if (raw.len % 2 != 0) return error.OddPixelLength;
    if (raw.len / 2 != n) return error.PixelCountMismatch;
    const out = try gpa.alloc(u16, n);
    for (out, 0..) |*o, i| o.* = std.mem.readInt(u16, raw[i * 2 ..][0..2], .little);
    return out;
}

fn samplesFromPixelData(
    gpa: Allocator,
    ds: *const Dataset,
    pd: *const dicos.PixelData,
    cols: usize,
    rows: usize,
    n: usize,
) LoadError![]u16 {
    if (pd.nativeFrames()) |frames| {
        var total: usize = 0;
        for (frames) |f| total = std.math.add(usize, total, f.len) catch return error.PixelCountMismatch;
        if (total != n) return error.PixelCountMismatch;
        const out = try gpa.alloc(u16, n);
        var at: usize = 0;
        for (frames) |f| {
            @memcpy(out[at..][0..f.len], f);
            at += f.len;
        }
        return out;
    }
    if (pd.encapsulatedFrames()) |frames| {
        const codec = dicos.codec_registry.codecForTransferSyntax(transferSyntaxUid(ds)) orelse
            return error.UnsupportedCodec;
        const px = cols * rows;
        if (frames.len == 0 or frames.len > n / px or frames.len * px != n) return error.PixelCountMismatch;
        // Plausibility: lossless coding cannot shrink pixels by more than a
        // few thousand to one, so a tiny payload cannot back a huge claim and
        // we never ask a decoder to allocate for it.
        var compressed: usize = 0;
        for (frames) |f| compressed +|= f.len;
        if (n / 65536 > compressed +| 1024) return error.PixelCountMismatch;

        const out = try gpa.alloc(u16, n);
        errdefer gpa.free(out);
        for (frames, 0..) |f, i| {
            var img = codec.decode(f, @intCast(cols), @intCast(rows), gpa) catch |e| return mapError(e);
            defer img.deinit();
            if (img.data.len != px) return error.PixelCountMismatch;
            @memcpy(out[i * px ..][0..px], img.data);
        }
        return out;
    }
    return error.UnexpectedPixelDataType;
}

/// Extract a volume from a parsed DICOS dataset (port of `volume_from_dataset`).
pub fn volumeFromDataset(gpa: Allocator, ds: *const Dataset) LoadError!volume.Volume {
    // Rows/Columns have no DICOM default: absent and zero are distinct errors.
    const cols: usize = ds.columns() orelse return error.MissingColumns;
    const rows: usize = ds.rows() orelse return error.MissingRows;
    const num_frames: u64 = ds.numberOfFrames();
    if (rows == 0) return error.ZeroRows;
    if (cols == 0) return error.ZeroColumns;
    if (num_frames == 0) return error.PixelCountMismatch;

    // Bound the allocation from the header alone, before looking at pixels.
    const expected64 = std.math.mul(u64, std.math.mul(u64, cols, rows) catch return error.TooLarge, num_frames) catch
        return error.TooLarge;
    if (expected64 > max_voxels) return error.TooLarge;
    const n: usize = @intCast(expected64);

    const wc_values = ds.getStrs(tag.WINDOW_CENTER);
    const ww_values = ds.getStrs(tag.WINDOW_WIDTH);
    const multi_window = (if (wc_values) |v| v.len > 1 else false) or
        (if (ww_values) |v| v.len > 1 else false);
    const window_center: f64 = blk: {
        if (wc_values) |v| if (v.len > 0) if (parseF64(trimWs(v[0]))) |x| break :blk x;
        break :blk 32768.0;
    };
    const window_width: f64 = blk: {
        if (ww_values) |v| if (v.len > 0) if (parseF64(trimWs(v[0]))) |x| break :blk x;
        break :blk 65536.0;
    };

    const rescale_intercept = parseDsF64(ds, tag.RESCALE_INTERCEPT) orelse 0.0;
    const rescale_slope = parseDsF64(ds, tag.RESCALE_SLOPE) orelse 1.0;
    if (!std.math.isFinite(rescale_slope)) return error.InvalidRescaleSlope;

    const pixel_representation = ds.pixelRepresentation() orelse 0;
    if (pixel_representation != 0 and pixel_representation != 1) return error.UnsupportedPixelRepresentation;
    const signed_pixels = pixel_representation == 1;
    const bits_allocated = ds.bitsAllocated() orelse 16;
    if (signed_pixels and bits_allocated != 8 and bits_allocated != 16) return error.UnsupportedBitsAllocated;
    // Signed samples are sign-extended from BitsAllocated; a narrower
    // BitsStored cannot be interpreted correctly, so reject it.
    if (signed_pixels) {
        if (ds.getU16(tag.BITS_STORED)) |bits_stored| {
            if (bits_stored != bits_allocated) return error.UnsupportedBitsStored;
        }
    }

    const pixel_elem = ds.get(tag.PIXEL_DATA) orelse return error.MissingPixelData;
    const samples: []u16 = switch (pixel_elem.value) {
        .bytes => |raw| try samplesFromBytes(gpa, raw, bits_allocated, n),
        .pixel_data => |*pd| try samplesFromPixelData(gpa, ds, pd, cols, rows, n),
        else => return error.UnexpectedPixelDataType,
    };
    errdefer gpa.free(samples);

    const dim_z: usize = if (num_frames > 1) @intCast(num_frames) else 1;

    // PixelSpacing is (row, column): rows step in Y, columns in X.
    var voxel_spacing = [3]f64{ 1.0, 1.0, 1.0 };
    if (ds.getStrs(tag.PIXEL_SPACING)) |parts| {
        var comps: [2][]const u8 = undefined;
        var count: usize = 0;
        for (parts) |p| {
            var it = std.mem.splitScalar(u8, p, '\\');
            while (it.next()) |q| : (count += 1) {
                if (count < 2) comps[count] = q;
            }
        }
        if (count >= 2) {
            if (parseF64(trimWs(comps[0]))) |v| voxel_spacing[1] = v;
            if (parseF64(trimWs(comps[1]))) |v| voxel_spacing[0] = v;
        }
    }
    if (ds.getString(tag.SLICE_THICKNESS)) |st| {
        if (parseF64(trimWs(st))) |v| voxel_spacing[2] = v;
    } else if (ds.getString(tag.SPACING_BETWEEN_SLICES)) |sbs| {
        if (parseF64(trimWs(sbs))) |v| voxel_spacing[2] = v;
    }

    // Sign-extend 8-bit signed samples so the viewer can treat stored bits
    // as i16 (0xFF becomes -1, not 255).
    if (signed_pixels and bits_allocated == 8) {
        for (samples) |*s| s.* = @bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(s.*))))));
    }

    const modality = try gpa.dupe(u8, ds.modality());
    errdefer gpa.free(modality);
    var threats = try parseThreats(gpa, ds, .{ cols, rows, dim_z });
    errdefer volume.freeThreats(gpa, &threats);

    var vol = volume.Volume{
        .data = samples,
        .dim_x = cols,
        .dim_y = rows,
        .dim_z = dim_z,
        .window_center = window_center,
        .window_width = window_width,
        .rescale_intercept = rescale_intercept,
        .rescale_slope = rescale_slope,
        .signed_pixels = signed_pixels,
        .modality = modality,
        .voxel_spacing = voxel_spacing,
        .threats = threats,
    };
    // Full-range window or several WC/WW presets: use a data-derived window.
    if (window_width >= 65000.0 or multi_window) try vol.computeWindowFromData(gpa);
    return vol;
}

// ---------------------------------------------------------------------------
// Slice stacking
// ---------------------------------------------------------------------------

/// The spatial tags that decide slice order.
pub const SliceMeta = struct {
    ipp: ?[3]f64 = null,
    iop: ?[6]f64 = null,
    slice_location: ?f64 = null,
    instance: ?f64 = null,
};

fn metaFromDataset(ds: *const Dataset) SliceMeta {
    return .{
        .ipp = dsNumbersFixed(ds, tag.IMAGE_POSITION_PATIENT, 3),
        .iop = dsNumbersFixed(ds, tag.IMAGE_ORIENTATION_PATIENT, 6),
        .slice_location = if (ds.getString(tag.SLICE_LOCATION)) |s| parseF64(trimWs(s)) else null,
        .instance = if (ds.getU16(tag.INSTANCE_NUMBER)) |v| @as(f64, @floatFromInt(v)) else null,
    };
}

/// Spatial sort keys for a whole stack (port of `slice_sort_keys`). One
/// strategy is chosen for the entire stack so keys never mix millimetres and
/// ordinals: all-IPP projected onto the slice normal (from the first IOP,
/// else +Z) > all SliceLocation > all InstanceNumber > input order.
/// Caller owns the result.
pub fn sliceSortKeys(gpa: Allocator, metas: []const SliceMeta) Allocator.Error![]f64 {
    const keys = try gpa.alloc(f64, metas.len);
    errdefer gpa.free(keys);

    const all_ipp = for (metas) |m| {
        if (m.ipp == null) break false;
    } else true;
    if (all_ipp) {
        var normal = [3]f64{ 0, 0, 1 };
        for (metas) |m| {
            if (m.iop) |o| {
                const n = [3]f64{
                    o[1] * o[5] - o[2] * o[4],
                    o[2] * o[3] - o[0] * o[5],
                    o[0] * o[4] - o[1] * o[3],
                };
                if (@abs(n[0]) > 1e-9 or @abs(n[1]) > 1e-9 or @abs(n[2]) > 1e-9) normal = n;
                break; // only the first slice that carries an orientation
            }
        }
        for (metas, keys) |m, *k| {
            const p = m.ipp.?;
            k.* = p[0] * normal[0] + p[1] * normal[1] + p[2] * normal[2];
        }
        return keys;
    }

    const all_loc = for (metas) |m| {
        if (m.slice_location == null) break false;
    } else true;
    if (all_loc) {
        for (metas, keys) |m, *k| k.* = m.slice_location.?;
        return keys;
    }

    const all_inst = for (metas) |m| {
        if (m.instance == null) break false;
    } else true;
    if (all_inst) {
        for (metas, keys) |m, *k| k.* = m.instance.?;
        return keys;
    }

    for (keys, 0..) |*k, i| k.* = @floatFromInt(i);
    return keys;
}

/// Failures that mean a slice is present but unusable (Rust `InvalidValue`):
/// they fail the whole stack instead of silently closing a spatial gap.
fn isInvalidValueClass(e: LoadError) bool {
    return switch (e) {
        error.ZeroRows,
        error.ZeroColumns,
        error.InvalidRescaleSlope,
        error.UnsupportedPixelRepresentation,
        error.UnsupportedBitsAllocated,
        error.UnsupportedBitsStored,
        => true,
        else => false,
    };
}

const StackSlice = struct {
    name: []const u8,
    meta: SliceMeta,
    key: f64 = 0,
    vol: volume.Volume,
};

fn sliceLess(_: void, a: StackSlice, b: StackSlice) bool {
    if (a.key < b.key) return true;
    if (a.key > b.key) return false;
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Stack per-slice files into one volume (port of `load_dicos_directory`).
/// `files` must already be sorted by name. See `stackSlicesDiag`.
pub fn stackSlices(gpa: Allocator, files: []const NamedBytes) LoadError!volume.Volume {
    return stackSlicesDiag(gpa, files, null);
}

/// As `stackSlices`; on a whole-load failure caused by one file, `diag`
/// (when given) names it.
///
/// Files that fail to parse, lack PixelData or fail for non-value reasons are
/// skipped; `InvalidValue`-class failures abort. Slices are ordered by
/// `sliceSortKeys` then name; slices whose Rows x Columns differ from the
/// first are skipped; mixed slope/intercept/signedness is rejected.
pub fn stackSlicesDiag(gpa: Allocator, files: []const NamedBytes, diag: ?*Diagnostic) LoadError!volume.Volume {
    var slices: std.ArrayList(StackSlice) = .empty;
    defer {
        for (slices.items) |*s| s.vol.deinit(gpa);
        slices.deinit(gpa);
    }

    for (files) |f| {
        var ds = dicos.reader.parseBytes(gpa, f.bytes) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            continue; // unparseable: skip
        };
        defer ds.deinit();
        // Non-image files (e.g. a TDR) carry no pixel data; skip them before
        // validation so their attributes cannot fail the load.
        if (ds.get(tag.PIXEL_DATA) == null) continue;

        var vol = volumeFromDataset(gpa, &ds) catch |e| {
            if (isInvalidValueClass(e)) {
                if (diag) |d| d.file_name = f.name;
                return e;
            }
            if (e == error.OutOfMemory) return e;
            continue;
        };
        slices.append(gpa, .{ .name = f.name, .meta = metaFromDataset(&ds), .vol = vol }) catch {
            vol.deinit(gpa);
            return error.OutOfMemory;
        };
    }
    if (slices.items.len == 0) return error.NoImageFiles;

    const metas = try gpa.alloc(SliceMeta, slices.items.len);
    defer gpa.free(metas);
    for (slices.items, metas) |s, *m| m.* = s.meta;
    const keys = try sliceSortKeys(gpa, metas);
    defer gpa.free(keys);
    for (slices.items, keys) |*s, k| s.key = k;
    std.mem.sort(StackSlice, slices.items, {}, sliceLess);

    // The first slice provides dimensions and shared metadata.
    const first = &slices.items[0];
    const cols = first.vol.dim_x;
    const rows = first.vol.dim_y;

    var included: std.ArrayList(usize) = .empty;
    defer included.deinit(gpa);
    var total_z: usize = 0;
    for (slices.items, 0..) |*s, i| {
        const v = &s.vol;
        if (v.dim_x != cols or v.dim_y != rows) continue; // skipped
        // One intensity transform applies to the whole volume.
        if (v.rescale_slope != first.vol.rescale_slope or
            v.rescale_intercept != first.vol.rescale_intercept or
            v.signed_pixels != first.vol.signed_pixels)
        {
            if (diag) |d| d.file_name = s.name;
            return error.MixedRescale;
        }
        total_z = std.math.add(usize, total_z, v.dim_z) catch return error.TooLarge;
        try included.append(gpa, i);
    }
    const total = std.math.mul(usize, cols * rows, total_z) catch return error.TooLarge;
    if (total > max_voxels) return error.TooLarge;

    const data = try gpa.alloc(u16, total);
    errdefer gpa.free(data);
    var at: usize = 0;
    for (included.items) |i| {
        const d = slices.items[i].vol.data;
        @memcpy(data[at..][0..d.len], d);
        at += d.len;
    }

    // Take the first slice's owned metadata; the rest is freed by the defer.
    var out = volume.Volume{
        .data = data,
        .dim_x = cols,
        .dim_y = rows,
        .dim_z = total_z,
        .window_center = first.vol.window_center,
        .window_width = first.vol.window_width,
        .rescale_intercept = first.vol.rescale_intercept,
        .rescale_slope = first.vol.rescale_slope,
        .signed_pixels = first.vol.signed_pixels,
        .modality = first.vol.modality,
        .voxel_spacing = first.vol.voxel_spacing,
        .threats = first.vol.threats,
    };
    first.vol.modality = &.{};
    first.vol.threats = .empty;
    // On failure below `out` still owns modality/threats; give them back.
    errdefer {
        first.vol.modality = out.modality;
        first.vol.threats = out.threats;
    }
    if (out.window_width >= 65000.0) try out.computeWindowFromData(gpa);
    return out;
}

// ---------------------------------------------------------------------------
// Threats
// ---------------------------------------------------------------------------

fn floatToUsize(f: f64) usize {
    const r = @round(f);
    if (std.math.isNan(r) or r <= 0) return 0;
    if (r >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return std.math.maxInt(usize);
    return @intFromFloat(r);
}

fn parseCorner(gpa: Allocator, item: *const Dataset, t: Tag, z_default: usize) Allocator.Error!?[3]usize {
    const elem = item.get(t) orelse return null;
    const nums = try parseNumbers(gpa, &elem.value);
    defer gpa.free(nums);
    if (nums.len < 2) return null;
    return .{
        floatToUsize(nums[0]),
        floatToUsize(nums[1]),
        if (nums.len >= 3) floatToUsize(nums[2]) else z_default,
    };
}

fn clampBbox(min_in: [3]usize, max_in: [3]usize, dims: [3]usize) struct { [3]usize, [3]usize } {
    var mn = min_in;
    var mx = max_in;
    for (0..3) |i| {
        const bound = dims[i] -| 1;
        mn[i] = @min(mn[i], bound);
        mx[i] = @min(mx[i], bound);
        if (mn[i] > mx[i]) std.mem.swap(usize, &mn[i], &mx[i]);
    }
    return .{ mn, mx };
}

fn firstNumber(gpa: Allocator, item: *const Dataset, t: Tag) Allocator.Error!?f64 {
    const elem = item.get(t) orelse return null;
    const nums = try parseNumbers(gpa, &elem.value);
    defer gpa.free(nums);
    return if (nums.len > 0) nums[0] else null;
}

/// Owned text of an attribute, or an owned empty string.
fn textOrEmpty(gpa: Allocator, item: *const Dataset, t: Tag) Allocator.Error![]u8 {
    if (item.get(t)) |elem| {
        if (try parseText(gpa, &elem.value)) |s| return s;
    }
    return gpa.alloc(u8, 0);
}

fn buildThreat(
    gpa: Allocator,
    item: *const Dataset,
    bbox_item: *const Dataset,
    dims: [3]usize,
    fallback_idx: usize,
) Allocator.Error!?volume.ThreatBox {
    const top_left = (try parseCorner(gpa, bbox_item, tag.BOUNDING_BOX_TOP_LEFT, 0)) orelse return null;
    const bottom_right = (try parseCorner(gpa, bbox_item, tag.BOUNDING_BOX_BOTTOM_RIGHT, dims[2] -| 1)) orelse return null;
    const mn, const mx = clampBbox(top_left, bottom_right, dims);

    const id = try textOrEmpty(gpa, item, tag.POTENTIAL_THREAT_OBJECT_ID);
    defer gpa.free(id);
    const category = try textOrEmpty(gpa, item, tag.THREAT_CATEGORY_DESCRIPTION);
    defer gpa.free(category);
    const name = if (id.len != 0 and category.len != 0)
        try std.fmt.allocPrint(gpa, "{s} ({s})", .{ id, category })
    else if (id.len != 0)
        try gpa.dupe(u8, id)
    else if (category.len != 0)
        try gpa.dupe(u8, category)
    else
        try std.fmt.allocPrint(gpa, "Threat {d}", .{fallback_idx + 1});
    errdefer gpa.free(name);

    const confidence = (try firstNumber(gpa, item, tag.THREAT_CONFIDENCE_SCORE)) orelse
        try firstNumber(gpa, item, tag.ATD_ASSESSMENT_PROBABILITY);

    return .{ .name = name, .confidence = confidence, .min = mn, .max = mx };
}

fn appendThreat(gpa: Allocator, list: *volume.ThreatList, t: volume.ThreatBox) Allocator.Error!void {
    var owned = t;
    list.append(gpa, owned) catch |e| {
        owned.deinit(gpa);
        return e;
    };
}

/// Threat ROIs of a dataset (port of `parse_threats`): ThreatROISequence
/// items, then PTOSequence items (via PTORepresentationSequence, falling back
/// to the item itself). Boxes are clamped to `dims` and recoloured.
pub fn parseThreats(gpa: Allocator, ds: *const Dataset, dims: [3]usize) Allocator.Error!volume.ThreatList {
    var list: volume.ThreatList = .empty;
    errdefer volume.freeThreats(gpa, &list);

    if (ds.get(tag.THREAT_ROI_SEQUENCE)) |elem| {
        if (elem.value == .sequence) {
            for (elem.value.sequence) |*item| {
                if (try buildThreat(gpa, item, item, dims, list.items.len)) |t| try appendThreat(gpa, &list, t);
            }
        }
    }

    // Threat detection reports commonly encode ROIs in PTOSequence /
    // PTORepresentationSequence instead of ThreatROISequence.
    if (ds.get(tag.PTO_SEQUENCE)) |elem| {
        if (elem.value == .sequence) {
            for (elem.value.sequence) |*item| {
                var parsed_representation = false;
                if (item.get(tag.PTO_REPRESENTATION_SEQUENCE)) |repr| {
                    if (repr.value == .sequence) {
                        for (repr.value.sequence) |*rep| {
                            if (try buildThreat(gpa, item, rep, dims, list.items.len)) |t| {
                                try appendThreat(gpa, &list, t);
                                parsed_representation = true;
                            }
                        }
                    }
                }
                if (!parsed_representation) {
                    if (try buildThreat(gpa, item, item, dims, list.items.len)) |t| try appendThreat(gpa, &list, t);
                }
            }
        }
    }

    volume.recolorThreats(list.items);
    return list;
}

/// Parse threat boxes from a sidecar (TDR) file; no pixel data is needed.
pub fn parseThreatsBytes(gpa: Allocator, bytes: []const u8, dims: [3]usize) LoadError!volume.ThreatList {
    var ds = dicos.reader.parseBytes(gpa, bytes) catch |e| return mapError(e);
    defer ds.deinit();
    return try parseThreats(gpa, &ds, dims);
}

fn hasExt(name: []const u8, comptime ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ext);
}

fn isDicosExt(name: []const u8) bool {
    return hasExt(name, ".dcs") or hasExt(name, ".dcm");
}

/// Directory rule of `load_threat_sidecars_from_dir`: extension dcs/dcm and a
/// stem containing "threat" (both case-insensitive).
pub fn isThreatSidecarName(name: []const u8) bool {
    if (!isDicosExt(name)) return false;
    return std.ascii.indexOfIgnoreCase(std.fs.path.stem(name), "threat") != null;
}

fn nameLess(_: void, a: NamedBytes, b: NamedBytes) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Port of `load_threat_sidecars_from_bytes`: every `.dcs`/`.dcm` file (by
/// extension, case-insensitive; names need not contain "threat") is parsed in
/// name order; unparseable files are skipped; the merged list is recoloured.
pub fn threatSidecarsFromBytes(gpa: Allocator, files: []const NamedBytes, dims: [3]usize) Allocator.Error!volume.ThreatList {
    var selected: std.ArrayList(NamedBytes) = .empty;
    defer selected.deinit(gpa);
    for (files) |f| if (isDicosExt(f.name)) try selected.append(gpa, f);
    std.mem.sort(NamedBytes, selected.items, {}, nameLess);

    var all: volume.ThreatList = .empty;
    errdefer volume.freeThreats(gpa, &all);
    for (selected.items) |f| {
        var ds = dicos.reader.parseBytes(gpa, f.bytes) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer ds.deinit();
        var found = try parseThreats(gpa, &ds, dims);
        defer found.deinit(gpa); // entries are moved below
        errdefer for (found.items) |*t| t.deinit(gpa);
        try all.ensureUnusedCapacity(gpa, found.items.len);
        all.appendSliceAssumeCapacity(found.items);
        found.clearRetainingCapacity();
    }
    volume.recolorThreats(all.items);
    return all;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Minimal explicit-VR little-endian Part-10 encoder. Used instead of
/// `dicos.writer` so file-level tests do not depend on the writer.
const Enc = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *Enc) void {
        self.buf.deinit(self.gpa);
    }

    fn u16le(self: *Enc, v: u16) !void {
        try self.buf.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }
    fn u32le(self: *Enc, v: u32) !void {
        try self.buf.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }

    /// Preamble, DICM and a TransferSyntaxUID of Explicit VR Little Endian.
    fn header(self: *Enc) !void {
        try self.buf.appendNTimes(self.gpa, 0, 128);
        try self.buf.appendSlice(self.gpa, "DICM");
        const ts = "1.2.840.10008.1.2.1\x00";
        try self.put(.{ 0x0002, 0x0010 }, "UI", ts);
    }

    fn isLong(vr: *const [2]u8) bool {
        const longs = [_][]const u8{ "OB", "OD", "OF", "OL", "OW", "SQ", "UC", "UN", "UR", "UT" };
        for (longs) |l| if (std.mem.eql(u8, l, vr)) return true;
        return false;
    }

    fn put(self: *Enc, t: [2]u16, vr: *const [2]u8, value: []const u8) !void {
        try self.u16le(t[0]);
        try self.u16le(t[1]);
        try self.buf.appendSlice(self.gpa, vr);
        if (isLong(vr)) {
            try self.u16le(0);
            try self.u32le(@intCast(value.len + (value.len & 1)));
        } else {
            try self.u16le(@intCast(value.len + (value.len & 1)));
        }
        try self.buf.appendSlice(self.gpa, value);
        if (value.len & 1 == 1) try self.buf.append(self.gpa, if (std.mem.eql(u8, vr, "UI")) 0 else ' ');
    }

    fn putTag(self: *Enc, t: Tag, vr: *const [2]u8, value: []const u8) !void {
        try self.put(.{ t.group, t.element }, vr, value);
    }
    fn putUs(self: *Enc, t: Tag, v: u16) !void {
        try self.putTag(t, "US", &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
    }
    fn putStr(self: *Enc, t: Tag, vr: *const [2]u8, s: []const u8) !void {
        try self.putTag(t, vr, s);
    }

    /// Undefined-length SQ whose items are the given encoded contents.
    fn putSeq(self: *Enc, t: Tag, items: []const []const u8) !void {
        try self.u16le(t.group);
        try self.u16le(t.element);
        try self.buf.appendSlice(self.gpa, "SQ");
        try self.u16le(0);
        try self.u32le(0xFFFF_FFFF);
        for (items) |it| {
            try self.u16le(0xFFFE);
            try self.u16le(0xE000);
            try self.u32le(@intCast(it.len));
            try self.buf.appendSlice(self.gpa, it);
        }
        try self.u16le(0xFFFE);
        try self.u16le(0xE0DD);
        try self.u32le(0);
    }

    fn putPixels16(self: *Enc, pixels: []const u16) !void {
        const bytes = try self.gpa.alloc(u8, pixels.len * 2);
        defer self.gpa.free(bytes);
        for (pixels, 0..) |p, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], p, .little);
        try self.putTag(tag.PIXEL_DATA, "OW", bytes);
    }
};

const Extra = struct { Tag, []const u8, []const u8 };

/// Encode a 1 x pixels.len image file with the given intensity attributes.
fn encodeSliceFile(
    gpa: Allocator,
    pixels: []const u16,
    signed: bool,
    slope: []const u8,
    intercept: []const u8,
    extra: []const Extra,
    bits_stored: ?u16,
) ![]u8 {
    var e = Enc{ .gpa = gpa };
    errdefer e.deinit();
    try e.header();
    try e.putStr(tag.MODALITY, "CS", "CT");
    try e.putUs(tag.BITS_ALLOCATED, 16);
    if (bits_stored) |b| try e.putUs(tag.BITS_STORED, b);
    try e.putUs(tag.PIXEL_REPRESENTATION, if (signed) 1 else 0);
    try e.putUs(tag.ROWS, 1);
    try e.putUs(tag.COLUMNS, @intCast(pixels.len));
    try e.putStr(tag.RESCALE_INTERCEPT, "DS", intercept);
    try e.putStr(tag.RESCALE_SLOPE, "DS", slope);
    for (extra) |x| try e.putStr(x[0], x[2][0..2], x[1]);
    try e.putPixels16(pixels);
    return e.buf.toOwnedSlice(gpa);
}

/// Encoded item content for a ThreatROI / PTO item.
fn encodeRoi(gpa: Allocator, tl: []const u8, br: []const u8, id: ?[]const u8) ![]u8 {
    var e = Enc{ .gpa = gpa };
    errdefer e.deinit();
    try e.putStr(tag.BOUNDING_BOX_TOP_LEFT, "DS", tl);
    try e.putStr(tag.BOUNDING_BOX_BOTTOM_RIGHT, "DS", br);
    if (id) |s| try e.putStr(tag.POTENTIAL_THREAT_OBJECT_ID, "LO", s);
    return e.buf.toOwnedSlice(gpa);
}

fn encodeThreatFile(gpa: Allocator, with_roi: bool) ![]u8 {
    var e = Enc{ .gpa = gpa };
    errdefer e.deinit();
    try e.header();
    try e.putStr(tag.MODALITY, "CS", "CT");
    try e.putUs(tag.BITS_ALLOCATED, 16);
    try e.putUs(tag.ROWS, 4);
    try e.putUs(tag.COLUMNS, 4);
    var px: [16]u16 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i + 1);
    try e.putPixels16(&px);
    if (with_roi) {
        const roi = try encodeRoi(gpa, "1\\1\\0", "3\\2\\0", null);
        defer gpa.free(roi);
        try e.putSeq(tag.THREAT_ROI_SEQUENCE, &.{roi});
    }
    return e.buf.toOwnedSlice(gpa);
}

// --- in-memory dataset helpers ---------------------------------------------

fn putBytes(ds: *Dataset, t: Tag, vr: dicos.Vr, bytes: []const u8) !void {
    const owned = try ds.allocator.dupe(u8, bytes);
    try ds.insert(dicos.Element.init(t, vr, .{ .bytes = owned }));
}

/// Moves `items` (already-built datasets) into a sequence element.
fn putSeqItems(ds: *Dataset, t: Tag, items: []const Dataset) !void {
    const owned = try ds.allocator.dupe(Dataset, items);
    try ds.insert(dicos.Element.init(t, .SQ, .{ .sequence = owned }));
}

fn f32Triplet(x: f32, y: f32, z: f32) [12]u8 {
    var out: [12]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @bitCast(x), .little);
    std.mem.writeInt(u32, out[4..8], @bitCast(y), .little);
    std.mem.writeInt(u32, out[8..12], @bitCast(z), .little);
    return out;
}

fn datasetWithPixels(gpa: Allocator, pixels: []const u16, bits: u16, signed: bool, slope: []const u8, intercept: []const u8) !Dataset {
    var ds = Dataset.init(gpa);
    errdefer ds.deinit();
    try ds.putU16(tag.ROWS, .US, 1);
    try ds.putU16(tag.COLUMNS, .US, @intCast(pixels.len));
    try ds.putU16(tag.BITS_ALLOCATED, .US, bits);
    try ds.putU16(tag.PIXEL_REPRESENTATION, .US, if (signed) 1 else 0);
    try ds.putString(tag.RESCALE_SLOPE, .DS, slope);
    try ds.putString(tag.RESCALE_INTERCEPT, .DS, intercept);
    try ds.putString(tag.MODALITY, .CS, "CT");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    if (bits == 8) {
        for (pixels) |p| try bytes.append(gpa, @truncate(p));
        if (bytes.items.len % 2 == 1) try bytes.append(gpa, 0);
    } else {
        for (pixels) |p| try bytes.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, p)));
    }
    try putBytes(&ds, tag.PIXEL_DATA, .OW, bytes.items);
    return ds;
}

fn dsWithZ(gpa: Allocator, z: f32) !Dataset {
    var ds = Dataset.init(gpa);
    errdefer ds.deinit();
    try ds.putU16(tag.ROWS, .US, 1);
    try ds.putU16(tag.COLUMNS, .US, 1);
    try ds.putString(tag.MODALITY, .CS, "CT");
    const s = try std.fmt.allocPrint(gpa, "0.0\\0.0\\{d}", .{z});
    defer gpa.free(s);
    try ds.putString(tag.IMAGE_POSITION_PATIENT, .DS, s);
    try putBytes(&ds, tag.PIXEL_DATA, .OW, &.{ 0, 0 });
    return ds;
}

fn expectKeys(metas: []const SliceMeta, expected: []const f64) !void {
    const keys = try sliceSortKeys(testing.allocator, metas);
    defer testing.allocator.free(keys);
    try testing.expectEqualSlices(f64, expected, keys);
}

// --- parseText / parseNumbers ------------------------------------------------

fn expectText(value: Value, expected: ?[]const u8) !void {
    const got = try parseText(testing.allocator, &value);
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(e, got.?);
    } else try testing.expect(got == null);
}

test "parseText: strings, bytes and numbers" {
    try expectText(.{ .str = "  TH-1\x00" }, "TH-1");
    try expectText(.{ .str = "   " }, null);
    try expectText(.{ .strings = &.{ " A ", "B" } }, "A");
    try expectText(.{ .bytes = "ltr_0 " }, "ltr_0");
    try expectText(.{ .bytes = &.{ 7, 0 } }, "7");
    try expectText(.{ .bytes = &.{ 1, 0, 0, 0 } }, "1");
    try expectText(.{ .bytes = &.{ 0x00, 0x01, 0x02 } }, null);
    try expectText(.{ .bytes = "" }, null);
    try expectText(.{ .u16_val = 9 }, "9");
    try expectText(.{ .i16_val = -3 }, "-3");
    try expectText(.{ .f32_val = 1.5 }, "1.5");
    try expectText(.{ .u16s = &.{1} }, null);
}

test "parseText: deliberate deviation, short non-printable str becomes a number" {
    // LO bytes `01 00` arrive as the one-byte string "\x01" (NUL stripped).
    try expectText(.{ .str = "\x01" }, "1");
    try expectText(.{ .str = "\x07\x01" }, "263");
    try expectText(.{ .str = "\x01\x00\x01" }, "65537");
}

fn expectNumbers(value: Value, expected: []const f64) !void {
    const got = try parseNumbers(testing.allocator, &value);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(f64, expected, got);
}

test "parseNumbers: value kinds" {
    try expectNumbers(.{ .str = " 1\\2.5\\x\\-3 " }, &.{ 1, 2.5, -3 });
    try expectNumbers(.{ .strings = &.{ "4", "bad", " 5" } }, &.{ 4, 5 });
    try expectNumbers(.{ .u16_val = 7 }, &.{7});
    try expectNumbers(.{ .u16s = &.{ 1, 2 } }, &.{ 1, 2 });
    try expectNumbers(.{ .f32s = &.{ 0.5, 2 } }, &.{ 0.5, 2 });
    try expectNumbers(.{ .f64_val = 2.25 }, &.{2.25});
    try expectNumbers(.{ .u32_val = 70000 }, &.{70000});
    try expectNumbers(.{ .sequence = &.{} }, &.{});
}

test "parseNumbers: bytes precedence text > f32 > u16" {
    try expectNumbers(.{ .bytes = "1\\2\\3" }, &.{ 1, 2, 3 });
    try expectNumbers(.{ .bytes = "1,2;3 4" }, &.{ 1, 2, 3, 4 });
    const f = f32Triplet(2, 3, 4);
    try expectNumbers(.{ .bytes = &f }, &.{ 2, 3, 4 });
    // f32 triplet that is also valid UTF-8 but not numeric text.
    const g = f32Triplet(8, 9, 10);
    try expectNumbers(.{ .bytes = &g }, &.{ 8, 9, 10 });
    // Non-finite f32 falls through to u16 pairs.
    try expectNumbers(.{ .bytes = &.{ 0, 0, 0x80, 0x7f } }, &.{ 0, 0x7f80 });
    try expectNumbers(.{ .bytes = &.{ 1, 0, 2 } }, &.{});
    try expectNumbers(.{ .bytes = "" }, &.{});
}

// --- slice sort keys ---------------------------------------------------------

test "sort key from ImagePositionPatient" {
    var ds = try dsWithZ(testing.allocator, -50.0);
    defer ds.deinit();
    try expectKeys(&.{metaFromDataset(&ds)}, &.{-50.0});
}

test "sort key falls back to SliceLocation" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putString(tag.SLICE_LOCATION, .DS, "12.5");
    try expectKeys(&.{metaFromDataset(&ds)}, &.{12.5});
}

test "sort key falls back to InstanceNumber" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putU16(tag.INSTANCE_NUMBER, .IS, 7);
    try expectKeys(&.{metaFromDataset(&ds)}, &.{7.0});
}

test "sort keys follow input order without spatial tags" {
    const m: SliceMeta = .{};
    try expectKeys(&.{ m, m, m }, &.{ 0, 1, 2 });
}

test "sort keys use the orientation normal for sagittal stacks" {
    const iop = [6]f64{ 0, 1, 0, 0, 0, -1 }; // normal (-1, 0, 0)
    const mk = struct {
        fn f(x: f64, o: ?[6]f64) SliceMeta {
            return .{ .ipp = .{ x, 0, 5 }, .iop = o };
        }
    }.f;
    try expectKeys(&.{ mk(2, iop), mk(1, iop), mk(0, iop) }, &.{ -2, -1, 0 });
    // The normal comes from the first slice that has an orientation.
    try expectKeys(&.{ mk(2, null), mk(1, iop), mk(0, iop) }, &.{ -2, -1, 0 });
}

test "sort keys: partial IPP falls back for the whole stack" {
    var a = try dsWithZ(testing.allocator, -300.0);
    defer a.deinit();
    try a.putU16(tag.INSTANCE_NUMBER, .IS, 1);
    var b = Dataset.init(testing.allocator);
    defer b.deinit();
    try b.putU16(tag.INSTANCE_NUMBER, .IS, 2);
    var c = try dsWithZ(testing.allocator, -100.0);
    defer c.deinit();
    try c.putU16(tag.INSTANCE_NUMBER, .IS, 3);
    try expectKeys(&.{ metaFromDataset(&a), metaFromDataset(&b), metaFromDataset(&c) }, &.{ 1, 2, 3 });
}

test "sort keys: degenerate orientation falls back to +Z" {
    const m: SliceMeta = .{ .ipp = .{ 1, 2, 3 }, .iop = .{ 0, 0, 0, 0, 0, 0 } };
    try expectKeys(&.{m}, &.{3});
}

test "slices sort by Z" {
    var neg = try dsWithZ(testing.allocator, -10.0);
    defer neg.deinit();
    var pos = try dsWithZ(testing.allocator, 10.0);
    defer pos.deinit();
    const keys = try sliceSortKeys(testing.allocator, &.{ metaFromDataset(&neg), metaFromDataset(&pos) });
    defer testing.allocator.free(keys);
    try testing.expect(keys[0] < keys[1]);
}

test "multi-valued parsed IPP is read from Strings" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    const parts = try testing.allocator.alloc([]const u8, 3);
    parts[0] = try testing.allocator.dupe(u8, "0.0");
    parts[1] = try testing.allocator.dupe(u8, "0.0");
    parts[2] = try testing.allocator.dupe(u8, "-10");
    try ds.insert(dicos.Element.init(tag.IMAGE_POSITION_PATIENT, .DS, .{ .strings = parts }));
    try expectKeys(&.{metaFromDataset(&ds)}, &.{-10});
}

// --- volumeFromDataset -------------------------------------------------------

test "zero rows and columns are distinct from missing" {
    const gpa = testing.allocator;
    var ds = Dataset.init(gpa);
    defer ds.deinit();
    try ds.putU16(tag.ROWS, .US, 0);
    try ds.putU16(tag.COLUMNS, .US, 4);
    try testing.expectError(error.ZeroRows, volumeFromDataset(gpa, &ds));
    try ds.putU16(tag.ROWS, .US, 4);
    try ds.putU16(tag.COLUMNS, .US, 0);
    try testing.expectError(error.ZeroColumns, volumeFromDataset(gpa, &ds));
}

test "missing rows / columns / pixel data" {
    const gpa = testing.allocator;
    var a = Dataset.init(gpa);
    defer a.deinit();
    try a.putU16(tag.COLUMNS, .US, 4);
    try testing.expectError(error.MissingRows, volumeFromDataset(gpa, &a));

    var b = Dataset.init(gpa);
    defer b.deinit();
    try b.putU16(tag.ROWS, .US, 4);
    try testing.expectError(error.MissingColumns, volumeFromDataset(gpa, &b));

    var c = Dataset.init(gpa);
    defer c.deinit();
    try c.putU16(tag.ROWS, .US, 4);
    try c.putU16(tag.COLUMNS, .US, 4);
    try testing.expectError(error.MissingPixelData, volumeFromDataset(gpa, &c));
}

test "signed 16-bit pixels are i16 and slope/intercept apply" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{0xFFFF}, 16, true, "1", "0");
    defer ds.deinit();
    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expect(vol.signed_pixels);
    try testing.expectEqual(@as(f64, 1.0), vol.rescale_slope);
    try testing.expectEqual(@as(f64, -1.0), vol.modalityValue(vol.data[0]));
    try testing.expectEqualStrings("CT", vol.modality);

    var ds2 = try datasetWithPixels(gpa, &.{1000}, 16, false, "2", "-1000");
    defer ds2.deinit();
    var v2 = try volumeFromDataset(gpa, &ds2);
    defer v2.deinit(gpa);
    try testing.expect(!v2.signed_pixels);
    try testing.expectEqual(@as(f64, 2.0), v2.rescale_slope);
    try testing.expectEqual(@as(f64, -1000.0), v2.rescale_intercept);
    try testing.expectEqual(@as(f64, 1000.0), v2.modalityValue(v2.data[0]));
}

test "signed 8-bit native frames are sign-extended" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{0x00FF}, 8, true, "1", "0");
    defer ds.deinit();
    const frames = try gpa.alloc([]u16, 1);
    frames[0] = gpa.dupe(u16, &.{255}) catch |e| {
        gpa.free(frames);
        return e;
    };
    try ds.insert(dicos.Element.init(tag.PIXEL_DATA, .OW, .{ .pixel_data = .{ .native = .{ .frames = frames } } }));
    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expect(vol.signed_pixels);
    try testing.expectEqual(@as(u16, 0xFFFF), vol.data[0]);
    try testing.expectEqual(@as(f64, -1.0), vol.modalityValue(vol.data[0]));
}

test "8-bit raw bytes are one sample per byte" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{ 1, 2, 0xFE }, 8, true, "1", "0");
    defer ds.deinit();
    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 0xFFFE }, vol.data);
}

test "unsupported pixel representation is rejected" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{1}, 16, false, "1", "0");
    defer ds.deinit();
    try ds.putU16(tag.PIXEL_REPRESENTATION, .US, 2);
    try testing.expectError(error.UnsupportedPixelRepresentation, volumeFromDataset(gpa, &ds));
}

test "signed data with BitsStored narrower than BitsAllocated is rejected" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{0x0FFF}, 16, true, "1", "0");
    defer ds.deinit();
    try ds.putU16(tag.BITS_STORED, .US, 12);
    try testing.expectError(error.UnsupportedBitsStored, volumeFromDataset(gpa, &ds));
    try ds.putU16(tag.BITS_STORED, .US, 16);
    var vol = try volumeFromDataset(gpa, &ds);
    vol.deinit(gpa);
}

test "signed data needs BitsAllocated 8 or 16; slope must be finite" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{1}, 16, true, "1", "0");
    defer ds.deinit();
    try ds.putU16(tag.BITS_ALLOCATED, .US, 32);
    try testing.expectError(error.UnsupportedBitsAllocated, volumeFromDataset(gpa, &ds));
    try ds.putU16(tag.BITS_ALLOCATED, .US, 16);
    try ds.putString(tag.RESCALE_SLOPE, .DS, "nan");
    try testing.expectError(error.InvalidRescaleSlope, volumeFromDataset(gpa, &ds));
}

test "odd raw pixel length and count mismatch" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{ 1, 2 }, 16, false, "1", "0");
    defer ds.deinit();
    try putBytes(&ds, tag.PIXEL_DATA, .OW, &.{ 1, 0, 2, 0, 3 });
    try testing.expectError(error.OddPixelLength, volumeFromDataset(gpa, &ds));
    try putBytes(&ds, tag.PIXEL_DATA, .OW, &.{ 1, 0, 2, 0, 3, 0 });
    try testing.expectError(error.PixelCountMismatch, volumeFromDataset(gpa, &ds));
}

test "native multi-frame pixel data, spacing and window" {
    const gpa = testing.allocator;
    var ds = Dataset.init(gpa);
    defer ds.deinit();
    try ds.putU16(tag.ROWS, .US, 2);
    try ds.putU16(tag.COLUMNS, .US, 2);
    try ds.putString(tag.NUMBER_OF_FRAMES, .IS, "2");
    try ds.putString(tag.PIXEL_SPACING, .DS, "0.5\\0.25"); // row, col
    try ds.putString(tag.SPACING_BETWEEN_SLICES, .DS, "3");
    try ds.putString(tag.WINDOW_CENTER, .DS, "40");
    try ds.putString(tag.WINDOW_WIDTH, .DS, "400");
    try ds.putString(tag.MODALITY, .CS, "CT");
    const frames = try gpa.alloc([]u16, 2);
    frames[0] = try gpa.dupe(u16, &.{ 1, 2, 3, 4 });
    frames[1] = gpa.dupe(u16, &.{ 5, 6, 7, 8 }) catch |e| {
        gpa.free(frames[0]);
        gpa.free(frames);
        return e;
    };
    try ds.insert(dicos.Element.init(tag.PIXEL_DATA, .OW, .{ .pixel_data = .{ .native = .{ .frames = frames } } }));
    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expectEqual([3]usize{ 2, 2, 2 }, [3]usize{ vol.dim_x, vol.dim_y, vol.dim_z });
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, vol.data);
    try testing.expectEqual([3]f64{ 0.25, 0.5, 3.0 }, vol.voxel_spacing);
    try testing.expectEqual(@as(f64, 40), vol.window_center);
    try testing.expectEqual(@as(f64, 400), vol.window_width);
}

test "multiple window presets recompute the window from data" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{ 0, 100, 200, 300, 400, 500, 600, 700, 800, 900 }, 16, false, "1", "0");
    defer ds.deinit();
    const wc = try gpa.alloc([]const u8, 2);
    wc[0] = try gpa.dupe(u8, "40");
    wc[1] = gpa.dupe(u8, "80") catch |e| {
        gpa.free(wc[0]);
        gpa.free(wc);
        return e;
    };
    try ds.insert(dicos.Element.init(tag.WINDOW_CENTER, .DS, .{ .strings = wc }));
    try ds.putString(tag.WINDOW_WIDTH, .DS, "400");
    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expect(vol.window_width != 400.0);
    try testing.expect(vol.window_width < 65000.0);
}

test "full-range default window is recomputed" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{ 10, 20, 30, 40 }, 16, false, "1", "0");
    defer ds.deinit();
    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expect(vol.window_width < 65000.0);
}

test "SAFETY: huge header with tiny pixel data allocates nothing" {
    const gpa = testing.allocator;
    var ds = try datasetWithPixels(gpa, &.{ 1, 2 }, 16, false, "1", "0");
    defer ds.deinit();

    // 65535 x 65535 x 1 exceeds the voxel cap: rejected from the header.
    try ds.putU16(tag.ROWS, .US, 65535);
    try ds.putU16(tag.COLUMNS, .US, 65535);
    try testing.expectError(error.TooLarge, volumeFromDataset(gpa, &ds));

    // Frames x Rows x Columns overflow of 32-bit math.
    try ds.putU16(tag.ROWS, .US, 1000);
    try ds.putU16(tag.COLUMNS, .US, 1000);
    try ds.putString(tag.NUMBER_OF_FRAMES, .IS, "4000000000");
    try testing.expectError(error.TooLarge, volumeFromDataset(gpa, &ds));

    // Under the cap but far more than the 4 pixel bytes present: the
    // allocator must never be touched (a failing allocator would turn any
    // attempt into OutOfMemory instead of PixelCountMismatch).
    try ds.putU16(tag.ROWS, .US, 20000);
    try ds.putU16(tag.COLUMNS, .US, 20000);
    try ds.putString(tag.NUMBER_OF_FRAMES, .IS, "1");
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.PixelCountMismatch, volumeFromDataset(failing.allocator(), &ds));

    // Encapsulated data with an unknown transfer syntax: no codec.
    const frames = try gpa.alloc([]u8, 1);
    frames[0] = try gpa.dupe(u8, "x");
    const offs = try gpa.alloc(u32, 0);
    try ds.insert(dicos.Element.init(tag.PIXEL_DATA, .OB, .{ .pixel_data = .{ .encapsulated = .{ .frames = frames, .offsets = offs } } }));
    try ds.putString(tag.TRANSFER_SYNTAX_UID, .UI, "1.2.3.4.999");
    try testing.expectError(error.UnsupportedCodec, volumeFromDataset(failing.allocator(), &ds));
}

// --- file-level loading ------------------------------------------------------

test "loadVolumeBytes parses a real encoded file" {
    const gpa = testing.allocator;
    const bytes = try encodeSliceFile(gpa, &.{ 7, 8, 9 }, false, "2", "-5", &.{}, null);
    defer gpa.free(bytes);
    var vol = try loadVolumeBytes(gpa, bytes);
    defer vol.deinit(gpa);
    try testing.expectEqualSlices(u16, &.{ 7, 8, 9 }, vol.data);
    try testing.expectEqual(@as(f64, 2), vol.rescale_slope);
    try testing.expectEqual(@as(f64, -5), vol.rescale_intercept);
    try testing.expectError(error.BadPreamble, loadVolumeBytes(gpa, "definitely not dicos"));
}

test "signed pixels after a real parse are i16" {
    const gpa = testing.allocator;
    const bytes = try encodeSliceFile(gpa, &.{0xFFFF}, true, "1", "0", &.{}, null);
    defer gpa.free(bytes);
    var vol = try loadVolumeBytes(gpa, bytes);
    defer vol.deinit(gpa);
    try testing.expect(vol.signed_pixels);
    try testing.expectEqual(@as(f64, -1.0), vol.modalityValue(vol.data[0]));
}

fn stackFile(gpa: Allocator, pixel: u16, slope: []const u8, ipp_z: ?[]const u8, instance: []const u8, bits_stored: ?u16, signed: bool) ![]u8 {
    var extra: [2]Extra = undefined;
    var n: usize = 0;
    extra[n] = .{ tag.INSTANCE_NUMBER, instance, "IS" };
    n += 1;
    if (ipp_z) |z| {
        extra[n] = .{ tag.IMAGE_POSITION_PATIENT, z, "DS" };
        n += 1;
    }
    return encodeSliceFile(gpa, &.{pixel}, signed, slope, "0", extra[0..n], bits_stored);
}

test "stack: mixed rescale slope is rejected" {
    const gpa = testing.allocator;
    var bufs: [3][]u8 = undefined;
    var files: [3]NamedBytes = undefined;
    const names = [_][]const u8{ "s0.dcm", "s1.dcm", "s2.dcm" };
    const slopes = [_][]const u8{ "1", "2", "3" };
    const inst = [_][]const u8{ "1", "2", "3" };
    for (0..3) |i| {
        bufs[i] = try stackFile(gpa, @intCast(10 * (i + 1)), slopes[i], null, inst[i], null, false);
        files[i] = .{ .name = names[i], .bytes = bufs[i] };
    }
    defer for (bufs) |b| gpa.free(b);
    var diag: Diagnostic = .{};
    try testing.expectError(error.MixedRescale, stackSlicesDiag(gpa, &files, &diag));
    try testing.expectEqualStrings("s1.dcm", diag.file_name);
}

test "stack: an unsupported middle slice fails the whole load" {
    const gpa = testing.allocator;
    var bufs: [3][]u8 = undefined;
    var files: [3]NamedBytes = undefined;
    const names = [_][]const u8{ "s0.dcm", "s1.dcm", "s2.dcm" };
    const inst = [_][]const u8{ "1", "2", "3" };
    const stored = [_]u16{ 16, 12, 16 };
    for (0..3) |i| {
        bufs[i] = try stackFile(gpa, 1, "1", null, inst[i], stored[i], true);
        files[i] = .{ .name = names[i], .bytes = bufs[i] };
    }
    defer for (bufs) |b| gpa.free(b);
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnsupportedBitsStored, stackSlicesDiag(gpa, &files, &diag));
    try testing.expectEqualStrings("s1.dcm", diag.file_name);
}

test "stack: a TDR next to the slices keeps IPP order" {
    const gpa = testing.allocator;
    // Files a, b, c at z = 2, 0, 1 with InstanceNumber reversed (3, 2, 1).
    const a = try stackFile(gpa, 102, "1", "0\\0\\2", "3", null, false);
    defer gpa.free(a);
    const b = try stackFile(gpa, 100, "1", "0\\0\\0", "2", null, false);
    defer gpa.free(b);
    const c = try stackFile(gpa, 101, "1", "0\\0\\1", "1", null, false);
    defer gpa.free(c);
    // TDR-like: parses but has no pixel data; Rows=0 would fail validation.
    var te = Enc{ .gpa = gpa };
    defer te.deinit();
    try te.header();
    try te.putStr(tag.MODALITY, "CS", "OT");
    try te.putUs(tag.ROWS, 0);

    const files = [_]NamedBytes{
        .{ .name = "000-tdr.dcs", .bytes = te.buf.items },
        .{ .name = "a.dcm", .bytes = a },
        .{ .name = "b.dcm", .bytes = b },
        .{ .name = "c.dcm", .bytes = c },
        .{ .name = "garbage.dcm", .bytes = "not dicos" },
    };
    var vol = try stackSlices(gpa, &files);
    defer vol.deinit(gpa);
    try testing.expectEqualSlices(u16, &.{ 100, 101, 102 }, vol.data);
    try testing.expectEqual(@as(usize, 3), vol.dim_z);
}

test "stack: dimension mismatch is skipped; nothing loadable is NoImageFiles" {
    const gpa = testing.allocator;
    const one = try stackFile(gpa, 5, "1", null, "1", null, false);
    defer gpa.free(one);
    const two = try encodeSliceFile(gpa, &.{ 1, 2 }, false, "1", "0", &.{.{ tag.INSTANCE_NUMBER, "2", "IS" }}, null);
    defer gpa.free(two);
    var vol = try stackSlices(gpa, &.{ .{ .name = "a.dcm", .bytes = one }, .{ .name = "b.dcm", .bytes = two } });
    defer vol.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), vol.data.len);

    try testing.expectError(error.NoImageFiles, stackSlices(gpa, &.{}));
    try testing.expectError(error.NoImageFiles, stackSlices(gpa, &.{.{ .name = "x.dcm", .bytes = "junk" }}));
}

// --- threats -----------------------------------------------------------------

fn threatsDataset(gpa: Allocator) !Dataset {
    var ds = Dataset.init(gpa);
    errdefer ds.deinit();
    try ds.putU16(tag.ROWS, .US, 4);
    try ds.putU16(tag.COLUMNS, .US, 4);
    try ds.putString(tag.MODALITY, .CS, "CT");
    var bytes: [32]u8 = undefined;
    for (0..16) |i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], @intCast(i), .little);
    try putBytes(&ds, tag.PIXEL_DATA, .OW, &bytes);
    return ds;
}

test "volume parses threat bounding boxes" {
    const gpa = testing.allocator;
    var ds = try threatsDataset(gpa);
    defer ds.deinit();
    var roi = Dataset.init(gpa);
    errdefer roi.deinit();
    try roi.putString(tag.BOUNDING_BOX_TOP_LEFT, .DS, "1\\1\\0");
    try roi.putString(tag.BOUNDING_BOX_BOTTOM_RIGHT, .DS, "3\\2\\0");
    try roi.putString(tag.POTENTIAL_THREAT_OBJECT_ID, .LO, "TH-1");
    try putSeqItems(&ds, tag.THREAT_ROI_SEQUENCE, &.{roi});

    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), vol.threats.items.len);
    try testing.expectEqual([3]usize{ 1, 1, 0 }, vol.threats.items[0].min);
    try testing.expectEqual([3]usize{ 3, 2, 0 }, vol.threats.items[0].max);
    try testing.expectEqualStrings("TH-1", vol.threats.items[0].name);
    try testing.expect(vol.threats.items[0].enabled);
    try testing.expectEqual(volume.threatColorForIndex(0), vol.threats.items[0].color);
}

test "volume parses PTOSequence threats from raw bytes" {
    const gpa = testing.allocator;
    var ds = Dataset.init(gpa);
    defer ds.deinit();
    try ds.putU16(tag.ROWS, .US, 16);
    try ds.putU16(tag.COLUMNS, .US, 16);
    try ds.putString(tag.NUMBER_OF_FRAMES, .IS, "16");
    try ds.putString(tag.MODALITY, .CS, "CT");
    const zeros = try gpa.alloc(u8, 16 * 16 * 16 * 2);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    try putBytes(&ds, tag.PIXEL_DATA, .OW, zeros);

    var rep = Dataset.init(gpa);
    errdefer rep.deinit();
    try putBytes(&rep, tag.BOUNDING_BOX_TOP_LEFT, .UN, &f32Triplet(2, 3, 4));
    try putBytes(&rep, tag.OOI_SIZE, .UN, &f32Triplet(8, 9, 10));

    var pto = Dataset.init(gpa);
    errdefer pto.deinit();
    try putBytes(&pto, tag.POTENTIAL_THREAT_OBJECT_ID, .UN, &.{ 7, 0 });
    try putBytes(&pto, tag.THREAT_CATEGORY_DESCRIPTION, .UN, "ltr_0 ");
    try putSeqItems(&pto, tag.PTO_REPRESENTATION_SEQUENCE, &.{rep});
    try putSeqItems(&ds, tag.PTO_SEQUENCE, &.{pto});

    var vol = try volumeFromDataset(gpa, &ds);
    defer vol.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), vol.threats.items.len);
    try testing.expectEqualStrings("7 (ltr_0)", vol.threats.items[0].name);
    try testing.expectEqual([3]usize{ 2, 3, 4 }, vol.threats.items[0].min);
    try testing.expectEqual([3]usize{ 8, 9, 10 }, vol.threats.items[0].max);
}

test "threat naming, confidence, clamping, swap and z defaults" {
    const gpa = testing.allocator;
    var ds = Dataset.init(gpa);
    defer ds.deinit();

    // 1: category only, ThreatConfidenceScore wins over ATD probability,
    //    corners reversed and beyond the volume, two-component corners.
    var r1 = Dataset.init(gpa);
    errdefer r1.deinit();
    try r1.putString(tag.BOUNDING_BOX_TOP_LEFT, .DS, "50.4\\2.6");
    try r1.putString(tag.BOUNDING_BOX_BOTTOM_RIGHT, .DS, "-4\\1");
    try r1.putString(tag.THREAT_CATEGORY_DESCRIPTION, .LO, "Knife");
    try r1.putString(tag.THREAT_CONFIDENCE_SCORE, .DS, "0.9");
    try r1.putString(tag.ATD_ASSESSMENT_PROBABILITY, .DS, "0.1");
    // 2: no name at all, ATD probability only.
    var r2 = Dataset.init(gpa);
    errdefer r2.deinit();
    try r2.putString(tag.BOUNDING_BOX_TOP_LEFT, .DS, "0\\0\\0");
    try r2.putString(tag.BOUNDING_BOX_BOTTOM_RIGHT, .DS, "1\\1\\1");
    try r2.putString(tag.ATD_ASSESSMENT_PROBABILITY, .DS, "0.25");
    // 3: missing corner -> dropped.
    var r3 = Dataset.init(gpa);
    errdefer r3.deinit();
    try r3.putString(tag.BOUNDING_BOX_TOP_LEFT, .DS, "0\\0\\0");
    try putSeqItems(&ds, tag.THREAT_ROI_SEQUENCE, &.{ r1, r2, r3 });

    var list = try parseThreats(gpa, &ds, .{ 10, 8, 4 });
    defer volume.freeThreats(gpa, &list);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    const a = list.items[0];
    try testing.expectEqualStrings("Knife", a.name);
    try testing.expectEqual(@as(?f64, 0.9), a.confidence);
    // x: 50 clamps to 9; "-4" -> 0. min > max swaps: [0, 9]. y: 3 vs 1 -> [1, 3].
    try testing.expectEqual([3]usize{ 0, 1, 0 }, a.min);
    try testing.expectEqual([3]usize{ 9, 3, 3 }, a.max); // z default 0 / dims[2]-1
    const b = list.items[1];
    try testing.expectEqualStrings("Threat 2", b.name);
    try testing.expectEqual(@as(?f64, 0.25), b.confidence);
    try testing.expectEqual(volume.threatColorForIndex(1), b.color);
}

test "sidecar name rule" {
    try testing.expect(isThreatSidecarName("TDR_Threat.DCS"));
    try testing.expect(isThreatSidecarName("threat_report.dcm"));
    try testing.expect(isThreatSidecarName("dir/my-THREATS.dcs"));
    try testing.expect(!isThreatSidecarName("scan.dcs"));
    try testing.expect(!isThreatSidecarName("tdr.dcs"));
    try testing.expect(!isThreatSidecarName("threat_report.txt"));
    try testing.expect(!isThreatSidecarName("threat"));
}

test "sidecars from bytes: selection, ordering and parsing" {
    const gpa = testing.allocator;
    const threat = try encodeThreatFile(gpa, true);
    defer gpa.free(threat);
    const plain = try encodeThreatFile(gpa, false);
    defer gpa.free(plain);

    const files = [_]NamedBytes{
        .{ .name = "ct.dcs", .bytes = plain },
        .{ .name = "TDR_Threat.DCS", .bytes = threat },
        .{ .name = "threat_notes.txt", .bytes = threat },
        .{ .name = "threat_garbage.dcs", .bytes = "not dicos" },
    };
    var list = try threatSidecarsFromBytes(gpa, &files, .{ 4, 4, 1 });
    defer volume.freeThreats(gpa, &list);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual([3]usize{ 1, 1, 0 }, list.items[0].min);
    try testing.expectEqual([3]usize{ 3, 2, 0 }, list.items[0].max);

    var none = try threatSidecarsFromBytes(gpa, files[0..1], .{ 4, 4, 1 });
    defer volume.freeThreats(gpa, &none);
    try testing.expectEqual(@as(usize, 0), none.items.len);

    // Two sidecars merge in name order and are recoloured.
    const two = [_]NamedBytes{
        .{ .name = "b.dcs", .bytes = threat },
        .{ .name = "a.dcm", .bytes = threat },
    };
    var both = try threatSidecarsFromBytes(gpa, &two, .{ 4, 4, 1 });
    defer volume.freeThreats(gpa, &both);
    try testing.expectEqual(@as(usize, 2), both.items.len);
    try testing.expectEqual(volume.threatColorForIndex(1), both.items[1].color);
}

test "parseThreatsBytes needs no pixel data" {
    const gpa = testing.allocator;
    const threat = try encodeThreatFile(gpa, true);
    defer gpa.free(threat);
    var list = try parseThreatsBytes(gpa, threat, .{ 4, 4, 1 });
    defer volume.freeThreats(gpa, &list);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectError(error.BadPreamble, parseThreatsBytes(gpa, "nope", .{ 4, 4, 1 }));
}

test "sample sidecar tdr.dcs yields one knife box" {
    const gpa = testing.allocator;
    const path = "/Users/jpfielding/projects/dicos.rs/testdata/" ++
        "backpack+purse_fishtank+goldfish_THREAT-knife_20260227-191512/tdr.dcs";
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.SkipZigTest;
    defer file.close();
    const bytes = file.readToEndAlloc(gpa, 1 << 20) catch return error.SkipZigTest;
    defer gpa.free(bytes);

    var list = try threatSidecarsFromBytes(gpa, &.{.{ .name = "tdr.dcs", .bytes = bytes }}, .{ 256, 256, 128 });
    defer volume.freeThreats(gpa, &list);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expect(std.ascii.indexOfIgnoreCase(list.items[0].name, "knife") != null);
    for (list.items[0].name) |c| try testing.expect(c >= 0x20 and c != 0x7f);
}

test "describe gives short messages" {
    try testing.expectEqualStrings("missing Rows attribute", describe(error.MissingRows));
    try testing.expectEqualStrings("volume dimensions are too large", describe(error.TooLarge));
    try testing.expectEqualStrings("FileNotFound", describe(error.FileNotFound));
}
