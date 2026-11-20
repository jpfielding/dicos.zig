//! DICOS/DICOM file reader.
//!
//! Reads the standard DICOM Part-10 file format:
//!
//! 1. 128-byte preamble (ignored)
//! 2. 4-byte "DICM" magic
//! 3. Group 0002 (File Meta Information) -- always Explicit VR Little Endian
//! 4. Remaining dataset elements using the transfer syntax from (0002,0010)
//!
//! Supports Implicit VR Little Endian, Explicit VR Little Endian, and
//! encapsulated pixel data.
//!
//! Hostile-input guarantees: every declared length is checked against the
//! per-element limit, element bodies are read incrementally (a length that
//! lies about the remaining stream fails with `Truncated` after allocating at
//! most ~2x the bytes actually present), nesting is bounded by
//! `MAX_NESTING_DEPTH`, and encapsulated frame assembly can never produce
//! more bytes than the fragments it was given.

const std = @import("std");
const err_mod = @import("error.zig");
const tag_mod = @import("tag.zig");
const transfer = @import("transfer.zig");
const types = @import("types.zig");
const vr_mod = @import("vr.zig");

const Tag = tag_mod.Tag;
const Vr = vr_mod.Vr;
const Dataset = types.Dataset;
const Element = types.Element;
const Value = types.Value;
const PixelData = types.PixelData;
const Allocator = std.mem.Allocator;
const Diagnostic = err_mod.Diagnostic;
pub const DicosError = err_mod.DicosError;

const log = std.log.scoped(.dicos);

/// The 4-byte DICOM magic number.
const DICM_MAGIC = "DICM";

/// Sentinel for undefined length.
pub const UNDEFINED_LENGTH: u32 = 0xFFFF_FFFF;

/// Default per-element allocation limit (1 GB).
pub const DEFAULT_MAX_ELEMENT_LENGTH: usize = 1024 * 1024 * 1024;

/// Maximum sequence/item nesting depth. Bounds recursion on
/// attacker-controlled nesting so a crafted file cannot overflow the stack.
pub const MAX_NESTING_DEPTH: usize = 64;

/// Upper bound on Basic Offset Table entries reserved speculatively; the
/// declared BOT length is attacker-controlled.
const BOT_RESERVE_CAP: u32 = 4096;

/// Initial chunk for incremental element-body reads.
const READ_CHUNK: usize = 64 * 1024;

/// A non-fatal issue detected while parsing.
pub const ParseWarning = union(enum) {
    /// Native pixel data had an odd byte length; the trailing byte was ignored.
    odd_pixel_data_length: struct { length: usize },
    /// Native pixel count did not match `rows * columns * frames`.
    pixel_count_mismatch: struct { actual: usize, expected: usize },
    /// BitsAllocated (0028,0100) was absent; native pixel data was decoded
    /// assuming 16-bit little-endian samples.
    bits_allocated_missing,

    pub fn format(self: ParseWarning, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .odd_pixel_data_length => |o| try w.print(
                "native pixel data has an odd byte length ({d}); trailing byte ignored",
                .{o.length},
            ),
            .pixel_count_mismatch => |p| try w.print(
                "native pixel data size ({d} pixels) does not match rows*cols*frames ({d}); storing as a single frame",
                .{ p.actual, p.expected },
            ),
            .bits_allocated_missing => try w.writeAll(
                "BitsAllocated (0028,0100) is absent; native pixel data decoded as 16-bit little-endian samples",
            ),
        }
    }

    pub fn eql(a: ParseWarning, b: ParseWarning) bool {
        return std.meta.eql(a, b);
    }
};

/// A parsed dataset plus the non-fatal warnings collected while parsing.
pub const ParseResult = struct {
    dataset: Dataset,
    warnings: []ParseWarning,

    pub fn deinit(self: *ParseResult) void {
        const a = self.dataset.allocator;
        a.free(self.warnings);
        self.dataset.deinit();
    }
};

/// Parse options.
pub const Options = struct {
    /// Any element whose on-disk length exceeds this is rejected with
    /// `error.LengthExceedsLimit`.
    max_element_bytes: usize = DEFAULT_MAX_ELEMENT_LENGTH,
    /// Filled with structured error details on failure.
    diagnostic: ?*Diagnostic = null,
};

/// Parses a DICOS/DICOM file with the default 1 GB per-element limit.
/// Warnings are logged via `std.log` (scope `.dicos`).
pub fn parse(allocator: Allocator, reader: *std.Io.Reader) DicosError!Dataset {
    return parseWithLimit(allocator, reader, DEFAULT_MAX_ELEMENT_LENGTH);
}

/// Parses with a custom per-element allocation limit; warnings are logged.
pub fn parseWithLimit(allocator: Allocator, reader: *std.Io.Reader, max_element_bytes: usize) DicosError!Dataset {
    const res = try parseWithOptions(allocator, reader, .{ .max_element_bytes = max_element_bytes });
    for (res.warnings) |w| log.warn("{f}", .{w});
    allocator.free(res.warnings);
    return res.dataset;
}

/// Parses, returning the dataset alongside any warnings (not logged).
pub fn parseWithWarnings(allocator: Allocator, reader: *std.Io.Reader) DicosError!ParseResult {
    return parseWithOptions(allocator, reader, .{});
}

/// Parses with a custom limit, returning the dataset alongside any warnings.
pub fn parseWithWarningsAndLimit(allocator: Allocator, reader: *std.Io.Reader, max_element_bytes: usize) DicosError!ParseResult {
    return parseWithOptions(allocator, reader, .{ .max_element_bytes = max_element_bytes });
}

/// The general entry point: limit and optional diagnostic.
pub fn parseWithOptions(allocator: Allocator, reader: *std.Io.Reader, options: Options) DicosError!ParseResult {
    var r: DicosReader = .{
        .allocator = allocator,
        .src = reader,
        .max_element_bytes = options.max_element_bytes,
        .diag = options.diagnostic,
    };
    defer if (r.transfer_syntax_uid) |uid| allocator.free(uid);
    return r.readDataset();
}

/// Convenience: parse an in-memory file (warnings are logged).
pub fn parseBytes(allocator: Allocator, data: []const u8) DicosError!Dataset {
    var fr = std.Io.Reader.fixed(data);
    return parse(allocator, &fr);
}

/// Low-level DICOS/DICOM reader that tracks transfer syntax state.
const DicosReader = struct {
    allocator: Allocator,
    src: *std.Io.Reader,
    explicit_vr: bool = true, // group 0002 is always explicit
    /// Owned copy of the transfer syntax UID (top-level reader only).
    transfer_syntax_uid: ?[]u8 = null,
    /// Still inside group 0002 (File Meta Information).
    in_meta: bool = true,
    max_element_bytes: usize,
    /// Bytes consumed from `src`, used for truncation offsets.
    bytes_read: u64 = 0,
    diag: ?*Diagnostic,

    fn fail(self: *DicosReader, e: DicosError, detail: Diagnostic.Detail) DicosError {
        Diagnostic.set(self.diag, detail);
        return e;
    }

    fn truncated(self: *DicosReader, offset: u64, context: []const u8) DicosError {
        return self.fail(error.Truncated, .{ .truncated = .{ .offset = offset, .context = context } });
    }

    /// Reads into `buf`, returning how many bytes were read; short only at EOF.
    fn fill(self: *DicosReader, buf: []u8) DicosError!usize {
        const n = self.src.readSliceShort(buf) catch |e|
            return self.fail(error.IoError, .{ .io = e });
        self.bytes_read += n;
        return n;
    }

    fn readExactCtx(self: *DicosReader, buf: []u8, context: []const u8) DicosError!void {
        const offset = self.bytes_read;
        if (try self.fill(buf) < buf.len) return self.truncated(offset, context);
    }

    fn readU16Ctx(self: *DicosReader, context: []const u8) DicosError!u16 {
        var b: [2]u8 = undefined;
        try self.readExactCtx(&b, context);
        return std.mem.readInt(u16, &b, .little);
    }

    fn readU32Ctx(self: *DicosReader, context: []const u8) DicosError!u32 {
        var b: [4]u8 = undefined;
        try self.readExactCtx(&b, context);
        return std.mem.readInt(u32, &b, .little);
    }

    /// Reads a tag at an element boundary: `null` on clean EOF, `Truncated`
    /// when only part of a tag is present.
    fn readBoundaryTag(self: *DicosReader, context: []const u8) DicosError!?Tag {
        const offset = self.bytes_read;
        var buf: [4]u8 = undefined;
        const n = try self.fill(&buf);
        if (n == 0) return null;
        if (n < 4) return self.truncated(offset, context);
        return Tag.init(std.mem.readInt(u16, buf[0..2], .little), std.mem.readInt(u16, buf[2..4], .little));
    }

    fn readTagRequired(self: *DicosReader, context: []const u8) DicosError!Tag {
        return (try self.readBoundaryTag(context)) orelse self.truncated(self.bytes_read, context);
    }

    /// Validates `len` against the limit, then reads it incrementally so the
    /// allocation tracks bytes actually present in the stream.
    fn readBody(self: *DicosReader, len: u32, context: []const u8) DicosError![]u8 {
        const n: usize = len;
        if (n > self.max_element_bytes) {
            return self.fail(error.LengthExceedsLimit, .{ .length_exceeds_limit = .{ .length = n, .limit = self.max_element_bytes } });
        }
        const offset = self.bytes_read;
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(self.allocator);
        while (list.items.len < n) {
            const have = list.items.len;
            const target = @min(n, have + @max(have, READ_CHUNK));
            try list.ensureTotalCapacityPrecise(self.allocator, target);
            const dst = list.allocatedSlice()[have..target];
            const got = try self.fill(dst);
            list.items.len += got;
            if (got < dst.len) return self.truncated(offset, context);
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Skips `len` bytes, verifying the full count was consumed.
    fn skipBytes(self: *DicosReader, len: u32) DicosError!void {
        const offset = self.bytes_read;
        const copied = self.src.discardShort(len) catch |e|
            return self.fail(error.IoError, .{ .io = e });
        self.bytes_read += copied;
        if (copied != len) return self.truncated(offset, "skipped element body");
    }

    /// Applies the dataset transfer syntax when crossing out of group 0002.
    fn enterDatasetIfNeeded(self: *DicosReader, t: Tag) DicosError!void {
        if (t.group == 0x0002 or !self.in_meta) return;
        self.in_meta = false;
        if (self.transfer_syntax_uid == null) {
            // No TransferSyntaxUID: default to Implicit VR LE (PS3.5 §10.1).
            self.transfer_syntax_uid = try self.allocator.dupe(u8, transfer.IMPLICIT_VR_LITTLE_ENDIAN);
        }
        const uid = self.transfer_syntax_uid.?;
        self.explicit_vr = !std.mem.eql(u8, uid, transfer.IMPLICIT_VR_LITTLE_ENDIAN);
        if (!transfer.TransferSyntax.init(uid).isLittleEndian()) {
            return self.fail(error.UnsupportedTransferSyntax, .{ .unsupported_transfer_syntax = err_mod.Message.init("{s}", .{uid}) });
        }
    }

    /// Reads elements into `ds` until a clean EOF or a group-0xFFFE tag.
    /// Returns the delimiter tag (its length left unconsumed), or `null` on
    /// clean EOF. `capture_ts` records (0002,0010) for the top-level reader.
    fn parseElementsUntil(self: *DicosReader, depth: usize, ds: *Dataset, capture_ts: bool) DicosError!?Tag {
        while (true) {
            const t = (try self.readBoundaryTag("element tag")) orelse return null;
            if (t.group == 0xFFFE) return t;
            try self.enterDatasetIfNeeded(t);
            const elem = try self.readElementWithTag(t, depth);
            if (capture_ts and elem.tag.eql(tag_mod.TRANSFER_SYNTAX_UID)) {
                if (elem.value == .str) {
                    const trimmed = types.trimWhitespace(elem.value.str);
                    const copy = self.allocator.dupe(u8, trimmed) catch |e| {
                        var owned = elem;
                        owned.deinit(self.allocator);
                        return e;
                    };
                    if (self.transfer_syntax_uid) |old| self.allocator.free(old);
                    self.transfer_syntax_uid = copy;
                    // Do NOT switch VR mode yet -- still reading group 0002.
                }
            }
            try ds.insert(elem);
        }
    }

    fn readDataset(self: *DicosReader) DicosError!ParseResult {
        var ds = Dataset.init(self.allocator);
        errdefer ds.deinit();

        var preamble: [128]u8 = undefined;
        if (try self.fill(&preamble) != preamble.len) {
            return self.fail(error.BadPreamble, .{ .bad_preamble = .{ .reason = "preamble too short" } });
        }
        var magic: [4]u8 = undefined;
        if (try self.fill(&magic) != magic.len or !std.mem.eql(u8, &magic, DICM_MAGIC)) {
            return self.fail(error.BadPreamble, .{ .bad_preamble = .{ .reason = "missing DICM magic number" } });
        }

        self.explicit_vr = true;
        self.in_meta = true;

        _ = try self.parseElementsUntil(0, &ds, true);

        // Materialize the inferred default TS so Dataset.transferSyntax()
        // agrees with the VR mode the reader actually used.
        if (!ds.contains(tag_mod.TRANSFER_SYNTAX_UID)) {
            if (self.transfer_syntax_uid) |uid| try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, uid);
        }

        var warnings: std.ArrayListUnmanaged(ParseWarning) = .empty;
        errdefer warnings.deinit(self.allocator);
        try normalizeNativePixelData(self.allocator, &ds, &warnings);
        return .{ .dataset = ds, .warnings = try warnings.toOwnedSlice(self.allocator) };
    }

    /// Reads an element after its tag has been consumed.
    fn readElementWithTag(self: *DicosReader, t: Tag, depth: usize) DicosError!Element {
        // Delimiters always have implicit structure: 4-byte length, no VR.
        if (t.group == 0xFFFE) {
            const len = try self.readU32Ctx("delimiter length");
            const body: []u8 = if (len > 0 and len != UNDEFINED_LENGTH)
                try self.readBody(len, "delimiter body")
            else
                &.{};
            return Element.init(t, .UN, .{ .bytes = body });
        }

        const vr: Vr, const vl: u32 = if (self.explicit_vr)
            try self.readExplicitVrHeader()
        else
            .{ implicitVrForTag(t), try self.readU32Ctx("implicit VR length") };

        return Element.init(t, vr, try self.readValue(t, vr, vl, depth));
    }

    fn readExplicitVrHeader(self: *DicosReader) DicosError!struct { Vr, u32 } {
        var vr_buf: [2]u8 = undefined;
        try self.readExactCtx(&vr_buf, "explicit VR header");
        const vr = Vr.fromBytes(&vr_buf) orelse .UN;
        if (vr.isLongVr()) {
            var reserved: [2]u8 = undefined;
            try self.readExactCtx(&reserved, "explicit VR header");
            return .{ vr, try self.readU32Ctx("explicit VR length") };
        }
        return .{ vr, try self.readU16Ctx("explicit VR length") };
    }

    fn readValue(self: *DicosReader, t: Tag, vr: Vr, vl: u32, depth: usize) DicosError!Value {
        if (vl == UNDEFINED_LENGTH) return self.readUndefinedLengthValue(t, vr, depth);
        const data = try self.readBody(vl, "element value");
        return parseValue(self.allocator, vr, data, self.explicit_vr, self.max_element_bytes, depth, self.diag);
    }

    fn readUndefinedLengthValue(self: *DicosReader, t: Tag, vr: Vr, depth: usize) DicosError!Value {
        if (t.eql(tag_mod.PIXEL_DATA)) return .{ .pixel_data = try self.readEncapsulatedPixelData() };
        if (vr == .SQ) return .{ .sequence = try self.readSequenceItems(depth) };
        // Unknown undefined-length element: skip to the sequence delimiter.
        try self.skipUndefinedLength(depth);
        return .{ .bytes = &.{} };
    }

    fn readSequenceItems(self: *DicosReader, depth: usize) DicosError![]Dataset {
        if (depth >= MAX_NESTING_DEPTH) {
            return self.fail(error.NestingTooDeep, .{ .nesting_too_deep = .{ .max = MAX_NESTING_DEPTH } });
        }
        var items: std.ArrayListUnmanaged(Dataset) = .empty;
        errdefer freeItems(self.allocator, &items);

        while (true) {
            const item_tag = try self.readTagRequired("sequence item");
            const item_len = try self.readU32Ctx("sequence item length");
            if (item_tag.eql(tag_mod.SEQUENCE_DELIMITATION_ITEM)) break;
            if (!item_tag.eql(tag_mod.ITEM)) {
                return self.fail(error.UnexpectedTag, .{ .unexpected_tag = .{ .expected = tag_mod.ITEM, .got = item_tag, .context = "sequence item" } });
            }
            var item = if (item_len == UNDEFINED_LENGTH)
                try self.readItemUndefinedLength(depth)
            else
                try self.readItemFixedLength(item_len, depth);
            items.append(self.allocator, item) catch |e| {
                item.deinit();
                return e;
            };
        }
        return items.toOwnedSlice(self.allocator);
    }

    fn readItemUndefinedLength(self: *DicosReader, depth: usize) DicosError!Dataset {
        var ds = Dataset.init(self.allocator);
        errdefer ds.deinit();
        while (true) {
            const elem_tag = try self.readTagRequired("sequence item element");
            if (elem_tag.eql(tag_mod.ITEM_DELIMITATION_ITEM)) {
                _ = try self.readU32Ctx("item delimiter length");
                break;
            }
            try ds.insert(try self.readElementWithTag(elem_tag, depth + 1));
        }
        return ds;
    }

    fn readItemFixedLength(self: *DicosReader, len: u32, depth: usize) DicosError!Dataset {
        const buf = try self.readBody(len, "fixed-length item body");
        defer self.allocator.free(buf);
        var fr = std.Io.Reader.fixed(buf);
        var sub: DicosReader = .{
            .allocator = self.allocator,
            .src = &fr,
            .explicit_vr = self.explicit_vr,
            .in_meta = false,
            .max_element_bytes = self.max_element_bytes,
            .diag = self.diag,
        };
        var ds = Dataset.init(self.allocator);
        errdefer ds.deinit();
        _ = try sub.parseElementsUntil(depth + 1, &ds, false);
        return ds;
    }

    fn readEncapsulatedPixelData(self: *DicosReader) DicosError!PixelData {
        const a = self.allocator;
        var offsets: std.ArrayListUnmanaged(u32) = .empty;
        errdefer offsets.deinit(a);

        const bot_tag = try self.readTagRequired("basic offset table");
        if (!bot_tag.eql(tag_mod.ITEM)) {
            return self.fail(error.UnexpectedTag, .{ .unexpected_tag = .{ .expected = tag_mod.ITEM, .got = bot_tag, .context = "basic offset table" } });
        }
        const bot_len = try self.readU32Ctx("basic offset table length");
        if (bot_len > 0) {
            const num_offsets = bot_len / 4;
            // Never reserve on the attacker-controlled count; each entry read
            // fails fast (Truncated) once the stream runs out.
            try offsets.ensureTotalCapacity(a, @min(num_offsets, BOT_RESERVE_CAP));
            var i: u32 = 0;
            while (i < num_offsets) : (i += 1) {
                try offsets.append(a, try self.readU32Ctx("basic offset table entry"));
            }
        }

        var fragments: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (fragments.items) |f| a.free(f);
            fragments.deinit(a);
        }
        var fragment_offsets: std.ArrayListUnmanaged(u32) = .empty;
        defer fragment_offsets.deinit(a);
        var running_offset: u32 = 0;
        while (true) {
            const item_tag = try self.readTagRequired("encapsulated pixel data");
            if (item_tag.eql(tag_mod.SEQUENCE_DELIMITATION_ITEM)) {
                _ = try self.readU32Ctx("pixel data delimiter length");
                break;
            }
            if (!item_tag.eql(tag_mod.ITEM)) {
                return self.fail(error.UnexpectedTag, .{ .unexpected_tag = .{ .expected = tag_mod.ITEM, .got = item_tag, .context = "encapsulated pixel data" } });
            }
            const item_len = try self.readU32Ctx("encapsulated frame length");
            const frame = try self.readBody(item_len, "encapsulated frame");
            fragments.append(a, frame) catch |e| {
                a.free(frame);
                return e;
            };
            try fragment_offsets.append(a, running_offset);
            // 8-byte item header plus body; saturate so hostile input can't wrap.
            running_offset = running_offset +| 8 +| item_len;
        }

        const frames = try assembleEncapsulatedFrames(a, &fragments, fragment_offsets.items, offsets.items, self.diag);
        errdefer freeByteFrames(a, frames);
        const owned_offsets = try offsets.toOwnedSlice(a);
        return PixelData.initEncapsulated(frames, owned_offsets);
    }

    /// Skips an undefined-length element up to its Sequence Delimitation Item.
    fn skipUndefinedLength(self: *DicosReader, depth: usize) DicosError!void {
        if (depth >= MAX_NESTING_DEPTH) {
            return self.fail(error.NestingTooDeep, .{ .nesting_too_deep = .{ .max = MAX_NESTING_DEPTH } });
        }
        while (true) {
            const item_tag = try self.readTagRequired("skipped sequence");
            if (item_tag.group == 0xFFFE) {
                const len = try self.readU32Ctx("skipped item length");
                if (item_tag.eql(tag_mod.SEQUENCE_DELIMITATION_ITEM)) return;
                if (item_tag.eql(tag_mod.ITEM_DELIMITATION_ITEM)) continue;
                if (len == UNDEFINED_LENGTH) {
                    try self.skipUndefinedLength(depth + 1);
                } else if (len > 0) {
                    try self.skipBytes(len);
                }
                continue;
            }
            const vl: u32 = if (self.explicit_vr)
                (try self.readExplicitVrHeader())[1]
            else
                try self.readU32Ctx("implicit VR length");
            if (vl == UNDEFINED_LENGTH) {
                try self.skipUndefinedLength(depth + 1);
            } else if (vl > 0) {
                try self.skipBytes(vl);
            }
        }
    }
};

fn freeItems(a: Allocator, items: *std.ArrayListUnmanaged(Dataset)) void {
    for (items.items) |*d| d.deinit();
    items.deinit(a);
}

fn freeByteFrames(a: Allocator, frames: [][]u8) void {
    for (frames) |f| a.free(f);
    a.free(frames);
}

/// Infers a VR for a tag when reading Implicit VR transfer syntax.
pub fn implicitVrForTag(t: Tag) Vr {
    if (t.group == 0x0002) return .UL;
    const T = tag_mod;
    const eq = struct {
        fn any(x: Tag, comptime list: []const Tag) bool {
            inline for (list) |c| if (x.eql(c)) return true;
            return false;
        }
    }.any;
    if (t.eql(T.PIXEL_DATA)) return .OW;
    if (eq(t, &.{ T.ROWS, T.COLUMNS, T.BITS_ALLOCATED, T.BITS_STORED, T.HIGH_BIT, T.PIXEL_REPRESENTATION, T.SAMPLES_PER_PIXEL })) return .US;
    if (t.eql(T.NUMBER_OF_FRAMES)) return .IS;
    if (eq(t, &.{ T.PIXEL_SPACING, T.WINDOW_CENTER, T.WINDOW_WIDTH, T.RESCALE_INTERCEPT, T.RESCALE_SLOPE })) return .DS;
    if (eq(t, &.{ T.RESCALE_TYPE, T.PHOTOMETRIC_INTERPRETATION })) return .CS;
    if (eq(t, &.{ T.SOP_CLASS_UID, T.SOP_INSTANCE_UID, T.STUDY_INSTANCE_UID, T.SERIES_INSTANCE_UID })) return .UI;
    if (eq(t, &.{ T.MODALITY, T.IMAGE_TYPE })) return .CS;
    return .UN;
}

/// Parses raw element bytes into a typed `Value` according to `vr`.
/// Takes ownership of `data` (it either becomes the value or is freed).
fn parseValue(
    a: Allocator,
    vr: Vr,
    data: []u8,
    explicit_vr: bool,
    max_element_bytes: usize,
    depth: usize,
    diag: ?*Diagnostic,
) DicosError!Value {
    var keep = false;
    defer if (!keep) a.free(data);
    switch (vr) {
        .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC, .UI, .UR, .UT => {
            return parseStringValue(a, data);
        },
        .US => {
            if (data.len == 2) return .{ .u16_val = std.mem.readInt(u16, data[0..2], .little) };
            if (data.len >= 4 and data.len % 2 == 0) return .{ .u16s = try decodeLe(u16, a, data) };
        },
        .UL => if (data.len == 4) return .{ .u32_val = std.mem.readInt(u32, data[0..4], .little) },
        .SS => if (data.len == 2) return .{ .i16_val = std.mem.readInt(i16, data[0..2], .little) },
        .SL => if (data.len == 4) return .{ .i32_val = std.mem.readInt(i32, data[0..4], .little) },
        .FL => {
            if (data.len == 4) return .{ .f32_val = @bitCast(std.mem.readInt(u32, data[0..4], .little)) };
            if (data.len >= 8 and data.len % 4 == 0) return .{ .f32s = try decodeLe(f32, a, data) };
        },
        .FD => {
            if (data.len == 8) return .{ .f64_val = @bitCast(std.mem.readInt(u64, data[0..8], .little)) };
            if (data.len >= 16 and data.len % 8 == 0) return .{ .f64s = try decodeLe(f64, a, data) };
        },
        .SQ => {
            if (data.len == 0) return .{ .sequence = &.{} };
            return .{ .sequence = try parseSequenceItems(a, data, explicit_vr, max_element_bytes, depth, diag) };
        },
        .AT, .OB, .OD, .OF, .OL, .OW, .UN => {},
    }
    keep = true;
    return .{ .bytes = data };
}

fn decodeLe(comptime T: type, a: Allocator, data: []const u8) Allocator.Error![]T {
    const size = @sizeOf(T);
    const Int = std.meta.Int(.unsigned, size * 8);
    const out = try a.alloc(T, data.len / size);
    for (out, 0..) |*o, i| o.* = @bitCast(std.mem.readInt(Int, data[i * size ..][0..size], .little));
    return out;
}

/// String VRs: lossy UTF-8, trailing NUL/space trimmed, split on backslash.
fn parseStringValue(a: Allocator, data: []const u8) DicosError!Value {
    const text = try utf8Lossy(a, data);
    defer a.free(text);
    const trimmed = std.mem.trimEnd(u8, text, "\x00 ");
    if (std.mem.indexOfScalar(u8, trimmed, '\\') == null) {
        return .{ .str = try a.dupe(u8, trimmed) };
    }
    const count = std.mem.count(u8, trimmed, "\\") + 1;
    const values = try a.alloc([]const u8, count);
    var n: usize = 0;
    errdefer {
        for (values[0..n]) |s| a.free(s);
        a.free(values);
    }
    var it = std.mem.splitScalar(u8, trimmed, '\\');
    while (it.next()) |part| {
        values[n] = try a.dupe(u8, part);
        n += 1;
    }
    return .{ .strings = values };
}

/// Decodes bytes as UTF-8, replacing each maximal invalid subpart with
/// U+FFFD (the same policy as Rust `String::from_utf8_lossy`).
pub fn utf8Lossy(a: Allocator, data: []const u8) Allocator.Error![]u8 {
    if (std.unicode.utf8ValidateSlice(data)) return a.dupe(u8, data);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.ensureTotalCapacity(a, data.len + 8);
    const replacement = "\u{FFFD}";
    var i: usize = 0;
    while (i < data.len) {
        const b0 = data[i];
        if (b0 < 0x80) {
            try out.append(a, b0);
            i += 1;
            continue;
        }
        // Expected length and the valid range of the second byte (Unicode
        // Table 3-7, well-formed UTF-8 byte sequences).
        const need: usize, const lo: u8, const hi: u8 = switch (b0) {
            0xC2...0xDF => .{ 2, 0x80, 0xBF },
            0xE0 => .{ 3, 0xA0, 0xBF },
            0xE1...0xEC, 0xEE...0xEF => .{ 3, 0x80, 0xBF },
            0xED => .{ 3, 0x80, 0x9F },
            0xF0 => .{ 4, 0x90, 0xBF },
            0xF1...0xF3 => .{ 4, 0x80, 0xBF },
            0xF4 => .{ 4, 0x80, 0x8F },
            else => {
                try out.appendSlice(a, replacement);
                i += 1;
                continue;
            },
        };
        var j: usize = 1;
        while (j < need) : (j += 1) {
            if (i + j >= data.len) break;
            const c = data[i + j];
            const ok = if (j == 1) (c >= lo and c <= hi) else (c >= 0x80 and c <= 0xBF);
            if (!ok) break;
        }
        if (j == need) {
            try out.appendSlice(a, data[i .. i + need]);
        } else {
            try out.appendSlice(a, replacement);
        }
        i += j;
    }
    return out.toOwnedSlice(a);
}

/// Parses items from a fixed-length SQ body.
fn parseSequenceItems(
    a: Allocator,
    data: []const u8,
    explicit_vr: bool,
    max_element_bytes: usize,
    depth: usize,
    diag: ?*Diagnostic,
) DicosError![]Dataset {
    if (depth >= MAX_NESTING_DEPTH) {
        Diagnostic.set(diag, .{ .nesting_too_deep = .{ .max = MAX_NESTING_DEPTH } });
        return error.NestingTooDeep;
    }
    var items: std.ArrayListUnmanaged(Dataset) = .empty;
    errdefer freeItems(a, &items);

    var pos: usize = 0;
    const Cursor = struct {
        fn readU16(d: []const u8, p: *usize) ?u16 {
            if (d.len - p.* < 2) return null;
            defer p.* += 2;
            return std.mem.readInt(u16, d[p.*..][0..2], .little);
        }
        fn readU32(d: []const u8, p: *usize) ?u32 {
            if (d.len - p.* < 4) return null;
            defer p.* += 4;
            return std.mem.readInt(u32, d[p.*..][0..4], .little);
        }
    };
    const eof = struct {
        fn f(dg: ?*Diagnostic) DicosError {
            // Rust surfaces this as `DicosError::Io(UnexpectedEof)`.
            Diagnostic.set(dg, .{ .io = error.UnexpectedEof });
            return error.IoError;
        }
    }.f;

    while (true) {
        const group = Cursor.readU16(data, &pos) orelse break; // clean end
        const element = Cursor.readU16(data, &pos) orelse return eof(diag);
        const item_tag = Tag.init(group, element);

        if (item_tag.eql(tag_mod.SEQUENCE_DELIMITATION_ITEM)) {
            _ = Cursor.readU32(data, &pos) orelse return eof(diag);
            break;
        }
        if (!item_tag.eql(tag_mod.ITEM)) {
            Diagnostic.set(diag, .{ .unexpected_tag = .{ .expected = tag_mod.ITEM, .got = item_tag, .context = "fixed-length SQ item" } });
            return error.UnexpectedTag;
        }
        const item_len = Cursor.readU32(data, &pos) orelse return eof(diag);
        if (item_len == UNDEFINED_LENGTH) {
            Diagnostic.set(diag, .undefined_length_in_fixed_sq);
            return error.UndefinedLengthInFixedSq;
        }
        const remaining = data.len - pos;
        if (item_len > remaining) {
            Diagnostic.set(diag, .{ .length_exceeds_buffer = .{ .length = item_len, .remaining = remaining } });
            return error.LengthExceedsBuffer;
        }
        const item_bytes = data[pos .. pos + item_len];
        pos += item_len;

        var fr = std.Io.Reader.fixed(item_bytes);
        var sub: DicosReader = .{
            .allocator = a,
            .src = &fr,
            .explicit_vr = explicit_vr,
            .in_meta = false,
            .max_element_bytes = max_element_bytes,
            .diag = diag,
        };
        var ds = Dataset.init(a);
        _ = sub.parseElementsUntil(depth + 1, &ds, false) catch |e| {
            ds.deinit();
            return e;
        };
        items.append(a, ds) catch |e| {
            ds.deinit();
            return e;
        };
    }
    return items.toOwnedSlice(a);
}

/// Groups encapsulated fragments into frames using the Basic Offset Table.
///
/// Per PS3.5 A.4 each BOT entry is the byte offset (relative to the first
/// fragment's Item tag) of a frame's first fragment; fragments whose offset
/// falls in `[bot[i], bot[i+1])` are concatenated into frame `i` (the last
/// window is open-ended). An empty BOT means one fragment per frame.
///
/// Divergence from Rust (hostile-input hardening): fragment offsets are
/// monotonic, so each window is located by binary search (O(n log n) rather
/// than O(frames x fragments)), and a BOT whose windows overlap so that the
/// assembled frames would exceed the fragment bytes is rejected with
/// `error.InvalidFile` instead of duplicating data (a memory-amplification
/// vector).
fn assembleEncapsulatedFrames(
    a: Allocator,
    fragments: *std.ArrayListUnmanaged([]u8),
    fragment_offsets: []const u32,
    bot: []const u32,
    diag: ?*Diagnostic,
) DicosError![][]u8 {
    if (bot.len == 0) {
        // Transfer the fragments as-is.
        const out = try fragments.toOwnedSlice(a);
        return out;
    }

    const frags = fragments.items;
    var total_input: usize = 0;
    for (frags) |f| total_input += f.len;

    // Prefix sums of fragment sizes so each window's size is O(1).
    const prefix = try a.alloc(usize, frags.len + 1);
    defer a.free(prefix);
    prefix[0] = 0;
    for (frags, 0..) |f, i| prefix[i + 1] = prefix[i] + f.len;

    const Range = struct { lo: usize, hi: usize };
    const ranges = try a.alloc(Range, bot.len);
    defer a.free(ranges);
    var total_out: usize = 0;
    for (bot, 0..) |start, i| {
        const end: u32 = if (i + 1 < bot.len) bot[i + 1] else std.math.maxInt(u32);
        const lo = lowerBound(fragment_offsets, start);
        const hi = if (end > start) lowerBound(fragment_offsets, end) else lo;
        ranges[i] = .{ .lo = lo, .hi = @max(lo, hi) };
        total_out += prefix[ranges[i].hi] - prefix[ranges[i].lo];
        if (total_out > total_input) {
            Diagnostic.set(diag, .{ .invalid_file = err_mod.Message.init(
                "Basic Offset Table windows overlap: assembled frames exceed the {d} fragment bytes",
                .{total_input},
            ) });
            return error.InvalidFile;
        }
    }

    const frames = try a.alloc([]u8, bot.len);
    var n: usize = 0;
    errdefer {
        for (frames[0..n]) |f| a.free(f);
        a.free(frames);
    }
    for (ranges) |r| {
        const buf = try a.alloc(u8, prefix[r.hi] - prefix[r.lo]);
        var off: usize = 0;
        for (frags[r.lo..r.hi]) |f| {
            @memcpy(buf[off..][0..f.len], f);
            off += f.len;
        }
        frames[n] = buf;
        n += 1;
    }
    return frames;
}

/// First index whose value is `>= key` in a non-decreasing slice.
fn lowerBound(xs: []const u32, key: u32) usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (xs[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Converts raw fixed-length (7FE0,0010) bytes into `PixelData.native` using
/// the image geometry and BitsAllocated.
fn normalizeNativePixelData(a: Allocator, ds: *Dataset, warnings: *std.ArrayListUnmanaged(ParseWarning)) DicosError!void {
    const rows: usize = ds.rows() orelse 0;
    const cols: usize = ds.columns() orelse 0;
    const num_frames: usize = ds.numberOfFrames();
    const bits_allocated = ds.bitsAllocated();

    if (rows == 0 or cols == 0) return;
    const frame_pixels = rows * cols;

    const existing = ds.get(tag_mod.PIXEL_DATA) orelse return;
    if (existing.value != .bytes) return;

    var removed = ds.remove(tag_mod.PIXEL_DATA).?;
    defer removed.deinit(a);
    const raw = removed.value.bytes;

    // 8-bit: one sample per byte. Otherwise (incl. absent): 16-bit LE pairs.
    var count: usize = undefined;
    const all = blk: {
        if (bits_allocated == 8) {
            const px = try a.alloc(u16, raw.len);
            for (px, raw) |*p, b| p.* = b;
            count = px.len;
            break :blk px;
        }
        if (bits_allocated == null) try warnings.append(a, .bits_allocated_missing);
        if (raw.len % 2 != 0) try warnings.append(a, .{ .odd_pixel_data_length = .{ .length = raw.len } });
        const px = try decodeLe(u16, a, raw[0 .. raw.len - raw.len % 2]);
        count = px.len;
        break :blk px;
    };
    var all_owned = true;
    defer if (all_owned) a.free(all);

    const expected = std.math.mul(usize, frame_pixels, @max(num_frames, 1)) catch std.math.maxInt(usize);

    // A single trailing pad byte on an odd-sized 8-bit image is not a voxel.
    if (bits_allocated == 8 and expected % 2 == 1 and count == expected + 1) count -= 1;

    var frames: [][]u16 = undefined;
    if (num_frames > 1 and count == frame_pixels * num_frames) {
        frames = try a.alloc([]u16, num_frames);
        var made: usize = 0;
        errdefer {
            for (frames[0..made]) |f| a.free(f);
            a.free(frames);
        }
        while (made < num_frames) : (made += 1) {
            frames[made] = try a.dupe(u16, all[made * frame_pixels ..][0..frame_pixels]);
        }
    } else {
        if (count != expected) {
            try warnings.append(a, .{ .pixel_count_mismatch = .{ .actual = count, .expected = expected } });
        }
        frames = try a.alloc([]u16, 1);
        errdefer a.free(frames);
        frames[0] = if (count == all.len) all else try a.realloc(all, count);
        all_owned = false;
    }
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .pixel_data = PixelData.initNative(frames) }));
}

test {
    _ = @import("reader/tests.zig");
}
