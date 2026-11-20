//! DICOS/DICOM file writer.
//!
//! Writes datasets in the standard DICOM Part-10 file format using
//! Explicit VR Little Endian encoding:
//!
//! 1. 128-byte preamble (all zeros)
//! 2. 4-byte "DICM" magic
//! 3. Group 0002 (File Meta Information) -- Explicit VR Little Endian
//! 4. Remaining dataset elements in tag order
//!
//! The writer does not allocate: a sizing pass validates each element and
//! computes its encoded length (sequence items and encapsulated pixel data
//! need their lengths up front), then a second pass streams the bytes. As in
//! the Rust crate, an element that fails validation writes nothing.

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
const Diagnostic = err_mod.Diagnostic;
const Message = err_mod.Message;
pub const DicosError = err_mod.DicosError;

pub const Options = struct {
    /// Filled with structured error details on failure.
    diagnostic: ?*Diagnostic = null,
};

/// Writes a dataset in DICOM Part-10 format. Returns the bytes written.
pub fn write(w: *std.Io.Writer, ds: *const Dataset) DicosError!u64 {
    return writePart10(w, ds, .{});
}

/// Writes a dataset in DICOM Part-10 format.
///
/// Always emits a normalized File Meta Information group with a recomputed
/// (0002,0000) group length and a default Transfer Syntax UID when absent.
/// An Implicit VR Little Endian UID is rewritten to Explicit VR Little Endian
/// because the body is always written explicit; compressed UIDs are kept.
pub fn writePart10(w: *std.Io.Writer, ds: *const Dataset, options: Options) DicosError!u64 {
    var ctx: Ctx = .{ .w = w, .diag = options.diagnostic };

    try ctx.writeAll(&([_]u8{0} ** 128));
    try ctx.writeAll("DICM");

    // Encode-size all metadata (except group length) to compute (0002,0000).
    var meta_len: usize = 0;
    {
        var it = MetaIter.init(ds);
        while (it.next()) |e| meta_len += try ctx.elementLen(e, null);
    }
    const group_length = std.math.cast(u32, meta_len) orelse
        return ctx.validation("group 0002 is too large", .{});

    const gl = Element.init(tag_mod.FILE_META_INFORMATION_GROUP_LENGTH, .UL, .{ .u32_val = group_length });
    try ctx.writeElement(&gl, null);
    {
        var it = MetaIter.init(ds);
        while (it.next()) |e| try ctx.writeElement(e, null);
    }

    // Write all non-group-0002 elements in tag order.
    const bits = ds.bitsAllocated();
    for (ds.iter()) |*e| {
        if (e.tag.group == 0x0002) continue;
        try ctx.writeElement(e, if (e.tag.eql(tag_mod.PIXEL_DATA)) bits else null);
    }
    return ctx.count;
}

/// Convenience: encodes `ds` into a newly allocated buffer.
pub fn writeToBytes(allocator: std.mem.Allocator, ds: *const Dataset, options: Options) DicosError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    _ = writePart10(&out.writer, ds, options) catch |e| switch (e) {
        // The allocating writer only fails on OOM.
        error.IoError => return error.OutOfMemory,
        else => return e,
    };
    return out.toOwnedSlice();
}

const explicit_ts_element = Element.init(tag_mod.TRANSFER_SYNTAX_UID, .UI, .{ .str = transfer.EXPLICIT_VR_LITTLE_ENDIAN });

/// Yields the normalized group-0002 elements in tag order: drops
/// (0002,0000), injects or normalizes (0002,0010).
const MetaIter = struct {
    elems: []const Element,
    index: usize = 0,
    ts_done: bool,

    fn init(ds: *const Dataset) MetaIter {
        return .{ .elems = ds.iter(), .ts_done = ds.contains(tag_mod.TRANSFER_SYNTAX_UID) };
    }

    fn next(it: *MetaIter) ?*const Element {
        while (it.index < it.elems.len) {
            const e = &it.elems[it.index];
            if (e.tag.group < 0x0002) {
                it.index += 1;
                continue;
            }
            if (e.tag.group > 0x0002) {
                it.index = it.elems.len;
                break;
            }
            if (!it.ts_done and tag_mod.TRANSFER_SYNTAX_UID.lessThan(e.tag)) {
                it.ts_done = true;
                return &explicit_ts_element;
            }
            it.index += 1;
            if (e.tag.eql(tag_mod.FILE_META_INFORMATION_GROUP_LENGTH)) continue;
            if (e.tag.eql(tag_mod.TRANSFER_SYNTAX_UID) and isImplicitUid(&e.value)) return &explicit_ts_element;
            return e;
        }
        if (!it.ts_done) {
            it.ts_done = true;
            return &explicit_ts_element;
        }
        return null;
    }
};

fn isImplicitUid(v: *const Value) bool {
    const uid = v.asStr() orelse return false;
    return std.mem.eql(u8, trimNulAndWhitespace(uid), transfer.IMPLICIT_VR_LITTLE_ENDIAN);
}

/// Rust `trim_matches(|c| c == '\0' || c.is_whitespace())`.
fn trimNulAndWhitespace(s: []const u8) []const u8 {
    var cur = s;
    while (true) {
        const before = cur.len;
        cur = std.mem.trim(u8, cur, "\x00");
        cur = types.trimWhitespace(cur);
        if (cur.len == before) return cur;
    }
}

const ValueLen = struct { len: usize, undefined_length: bool };

const Ctx = struct {
    w: *std.Io.Writer,
    count: u64 = 0,
    diag: ?*Diagnostic,

    fn validation(self: *Ctx, comptime fmt: []const u8, args: anytype) DicosError {
        Diagnostic.set(self.diag, .{ .validation = Message.init(fmt, args) });
        return error.Validation;
    }

    fn writeAll(self: *Ctx, bytes: []const u8) DicosError!void {
        self.w.writeAll(bytes) catch |e| {
            Diagnostic.set(self.diag, .{ .io = e });
            return error.IoError;
        };
        self.count += bytes.len;
    }

    fn writeInt(self: *Ctx, comptime T: type, v: T) DicosError!void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.writeAll(&b);
    }

    // ---- sizing pass (also performs every validation) ----

    /// Encoded size of one element, header included.
    fn elementLen(self: *Ctx, e: *const Element, bits: ?u16) DicosError!usize {
        return self.checkedElementLen(e, try self.valueLen(&e.value, e.vr, bits));
    }

    /// Validates the header length field for a sized value.
    fn checkedElementLen(self: *Ctx, e: *const Element, v: ValueLen) DicosError!usize {
        if (e.vr.isLongVr()) {
            if (!v.undefined_length and v.len > std.math.maxInt(u32)) {
                return self.validation("value too large for element {f} ({d} bytes, max {d})", .{ e.tag, v.len, std.math.maxInt(u32) });
            }
            return 12 + v.len;
        }
        if (v.undefined_length) {
            return self.validation("undefined length not supported for short VR {f}", .{e.vr});
        }
        if (v.len > std.math.maxInt(u16)) {
            return self.validation("value too large for short-VR element {f} ({d} bytes, max 65535)", .{ e.tag, v.len });
        }
        return 8 + v.len;
    }

    fn valueLen(self: *Ctx, value: *const Value, vr: Vr, bits: ?u16) DicosError!ValueLen {
        _ = vr; // the value variant, not the VR, drives the encoding (as in Rust)
        const len: usize = switch (value.*) {
            .str => |s| s.len + s.len % 2,
            .strings => |ss| blk: {
                var n: usize = 0;
                for (ss, 0..) |s, i| n += s.len + @intFromBool(i > 0);
                break :blk n + n % 2;
            },
            .u16_val, .i16_val => 2,
            .u32_val, .i32_val, .f32_val => 4,
            .f64_val => 8,
            .u16s => |v| v.len * 2,
            .f32s => |v| v.len * 4,
            .f64s => |v| v.len * 8,
            .bytes => |v| v.len,
            .sequence => |items| return .{ .len = try self.sequenceLen(items), .undefined_length = true },
            .pixel_data => |*pd| switch (pd.*) {
                .native => |n| try self.nativeLen(n.frames, bits),
                .encapsulated => |e| return .{ .len = try self.encapsulatedLen(e.frames, e.offsets.len != 0), .undefined_length = true },
            },
        };
        return .{ .len = len, .undefined_length = false };
    }

    fn itemBodyLen(self: *Ctx, item: *const Dataset) DicosError!usize {
        var n: usize = 0;
        for (item.iter()) |*e| n += try self.elementLen(e, null);
        if (n > std.math.maxInt(u32)) {
            return self.validation("sequence item too large ({d} bytes, max {d})", .{ n, std.math.maxInt(u32) });
        }
        return n;
    }

    fn sequenceLen(self: *Ctx, items: []const Dataset) DicosError!usize {
        var n: usize = 8; // Sequence Delimitation Item
        for (items) |*item| n += 8 + try self.itemBodyLen(item);
        return n;
    }

    fn nativeLen(self: *Ctx, frames: []const []u16, bits: ?u16) DicosError!usize {
        var total: usize = 0;
        for (frames) |f| total += f.len;
        if (bits != 8) return total * 2;
        for (frames) |f| for (f) |p| {
            if (p > 0xFF) return self.validation("native sample {d} does not fit in 8-bit pixel data", .{p});
        };
        return total + total % 2;
    }

    fn encapsulatedLen(self: *Ctx, frames: []const []u8, with_bot: bool) DicosError!usize {
        var offset: u32 = 0;
        for (frames) |f| {
            const body_len = f.len + f.len % 2;
            const body32 = std.math.cast(u32, body_len) orelse
                return self.validation("compressed frame too large ({d} bytes, max {d})", .{ body_len, std.math.maxInt(u32) });
            const item_size = std.math.add(u32, body32, 8) catch
                return self.validation("compressed frame too large", .{});
            offset = std.math.add(u32, offset, item_size) catch
                return self.validation("encapsulated pixel data offsets overflow u32", .{});
        }
        const bot_bytes: usize = if (with_bot) frames.len * 4 else 0;
        if (bot_bytes > std.math.maxInt(u32)) return self.validation("Basic Offset Table too large", .{});
        return 8 + bot_bytes + @as(usize, offset) + 8;
    }

    // ---- streaming pass ----

    fn writeElement(self: *Ctx, e: *const Element, bits: ?u16) DicosError!void {
        // Validate and size before emitting anything for this element.
        const v = try self.valueLen(&e.value, e.vr, bits);
        _ = try self.checkedElementLen(e, v);

        try self.writeInt(u16, e.tag.group);
        try self.writeInt(u16, e.tag.element);
        try self.writeAll(&e.vr.asBytes());
        if (e.vr.isLongVr()) {
            try self.writeAll(&.{ 0, 0 });
            try self.writeInt(u32, if (v.undefined_length) 0xFFFF_FFFF else @intCast(v.len));
        } else {
            try self.writeInt(u16, @intCast(v.len));
        }
        try self.writeValue(&e.value, e.vr, bits);
    }

    fn writeValue(self: *Ctx, value: *const Value, vr: Vr, bits: ?u16) DicosError!void {
        const pad: u8 = if (vr == .UI) 0 else ' ';
        switch (value.*) {
            .str => |s| {
                try self.writeAll(s);
                if (s.len % 2 != 0) try self.writeAll(&.{pad});
            },
            .strings => |ss| {
                var n: usize = 0;
                for (ss, 0..) |s, i| {
                    if (i > 0) try self.writeAll("\\");
                    try self.writeAll(s);
                    n += s.len + @intFromBool(i > 0);
                }
                if (n % 2 != 0) try self.writeAll(&.{pad});
            },
            .u16_val => |v| try self.writeInt(u16, v),
            .u32_val => |v| try self.writeInt(u32, v),
            .i16_val => |v| try self.writeInt(i16, v),
            .i32_val => |v| try self.writeInt(i32, v),
            .f32_val => |v| try self.writeInt(u32, @bitCast(v)),
            .f64_val => |v| try self.writeInt(u64, @bitCast(v)),
            .u16s => |vs| for (vs) |v| try self.writeInt(u16, v),
            .f32s => |vs| for (vs) |v| try self.writeInt(u32, @bitCast(v)),
            .f64s => |vs| for (vs) |v| try self.writeInt(u64, @bitCast(v)),
            .bytes => |b| try self.writeAll(b),
            .sequence => |items| {
                for (items) |*item| {
                    try self.writeInt(u16, 0xFFFE);
                    try self.writeInt(u16, 0xE000);
                    try self.writeInt(u32, @intCast(try self.itemBodyLen(item)));
                    for (item.iter()) |*e| try self.writeElement(e, null);
                }
                try self.writeDelimiter();
            },
            .pixel_data => |*pd| switch (pd.*) {
                .native => |n| try self.writeNative(n.frames, bits),
                .encapsulated => |e| try self.writeEncapsulated(e.frames, e.offsets.len != 0),
            },
        }
    }

    fn writeDelimiter(self: *Ctx) DicosError!void {
        try self.writeInt(u16, 0xFFFE);
        try self.writeInt(u16, 0xE0DD);
        try self.writeInt(u32, 0);
    }

    fn writeNative(self: *Ctx, frames: []const []u16, bits: ?u16) DicosError!void {
        if (bits == 8) {
            var total: usize = 0;
            for (frames) |f| {
                for (f) |p| try self.writeAll(&.{@as(u8, @intCast(p))});
                total += f.len;
            }
            if (total % 2 == 1) try self.writeAll(&.{0});
            return;
        }
        for (frames) |f| {
            if (@import("builtin").cpu.arch.endian() == .little) {
                try self.writeAll(std.mem.sliceAsBytes(f));
            } else {
                for (f) |p| try self.writeInt(u16, p);
            }
        }
    }

    /// One item per frame; when `with_bot` the BOT is rebuilt from the items
    /// actually written (including padding), otherwise it is left empty.
    fn writeEncapsulated(self: *Ctx, frames: []const []u8, with_bot: bool) DicosError!void {
        try self.writeInt(u16, 0xFFFE);
        try self.writeInt(u16, 0xE000);
        try self.writeInt(u32, @intCast(if (with_bot) frames.len * 4 else 0));
        if (with_bot) {
            var offset: u32 = 0;
            for (frames) |f| {
                try self.writeInt(u32, offset);
                offset += @intCast(8 + f.len + f.len % 2);
            }
        }
        for (frames) |f| {
            try self.writeInt(u16, 0xFFFE);
            try self.writeInt(u16, 0xE000);
            try self.writeInt(u32, @intCast(f.len + f.len % 2));
            try self.writeAll(f);
            if (f.len % 2 == 1) try self.writeAll(&.{0});
        }
        try self.writeDelimiter();
    }
};

// ---------------------------------------------------------------------------
// Tests (port of Rust writer.rs tests)
// ---------------------------------------------------------------------------
const testing = std.testing;
const reader = @import("reader.zig");
const ta = testing.allocator;

fn roundtrip(ds: *const Dataset) !Dataset {
    const bytes = try writeToBytes(ta, ds, .{});
    defer ta.free(bytes);
    return reader.parseBytes(ta, bytes);
}

fn nativePd(frames: []const []const u16) !PixelData {
    const out = try ta.alloc([]u16, frames.len);
    for (frames, 0..) |f, i| out[i] = try ta.dupe(u16, f);
    return PixelData.initNative(out);
}

fn encapPd(frames: []const []const u8, offsets: []const u32) !PixelData {
    const out = try ta.alloc([]u8, frames.len);
    for (frames, 0..) |f, i| out[i] = try ta.dupe(u8, f);
    return PixelData.initEncapsulated(out, try ta.dupe(u32, offsets));
}

fn expectPd(expected: PixelData, actual: ?*const PixelData) !void {
    var e = expected;
    defer e.deinit(ta);
    const got = actual orelse return error.TestUnexpectedResult;
    try testing.expect(e.eql(got));
}

test "write injects transfer syntax when missing" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "DOE^ALICE");
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqualStrings(transfer.EXPLICIT_VR_LITTLE_ENDIAN, rt.getString(tag_mod.TRANSFER_SYNTAX_UID).?);
}

test "write recomputes meta group length" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putString(tag_mod.SOP_CLASS_UID, .UI, "1.2.3.4");
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "META^TEST");
    try ds.putU32(tag_mod.FILE_META_INFORMATION_GROUP_LENGTH, .UL, 9999); // stale
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    const e = rt.get(tag_mod.FILE_META_INFORMATION_GROUP_LENGTH) orelse return error.TestUnexpectedResult;
    // Only (0002,0010) "1.2.840.10008.1.2.1" + pad: 8 + 20 bytes.
    try testing.expectEqual(@as(u32, 28), e.value.u32_val);
}

test "roundtrip string elements" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "SMITH^ALICE");
    try ds.putString(tag_mod.PATIENT_ID, .LO, "12345");
    try ds.putString(tag_mod.MODALITY, .CS, "DX");
    try ds.putString(tag_mod.STUDY_DESCRIPTION, .LO, "Baggage Scan");
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqualStrings("SMITH^ALICE", rt.getString(tag_mod.PATIENT_NAME).?);
    try testing.expectEqualStrings("12345", rt.getString(tag_mod.PATIENT_ID).?);
    try testing.expectEqualStrings("DX", rt.modality());
    try testing.expectEqualStrings("Baggage Scan", rt.getString(tag_mod.STUDY_DESCRIPTION).?);
}

test "roundtrip numeric elements" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putU16(tag_mod.ROWS, .US, 512);
    try ds.putU16(tag_mod.COLUMNS, .US, 256);
    try ds.putU16(tag_mod.BITS_ALLOCATED, .US, 16);
    try ds.putU16(tag_mod.BITS_STORED, .US, 12);
    try ds.putU16(tag_mod.HIGH_BIT, .US, 11);
    try ds.putU16(tag_mod.PIXEL_REPRESENTATION, .US, 0);
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqual(@as(?u16, 512), rt.rows());
    try testing.expectEqual(@as(?u16, 256), rt.columns());
    try testing.expectEqual(@as(?u16, 16), rt.bitsAllocated());
    try testing.expectEqual(@as(?u16, 12), rt.getU16(tag_mod.BITS_STORED));
    try testing.expectEqual(@as(?u16, 0), rt.pixelRepresentation());
}

test "roundtrip native pixel data" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putU16(tag_mod.ROWS, .US, 2);
    try ds.putU16(tag_mod.COLUMNS, .US, 2);
    try ds.putU16(tag_mod.BITS_ALLOCATED, .US, 16);
    const px = [_]u16{ 100, 200, 300, 400 };
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .bytes = try ta.dupe(u8, std.mem.sliceAsBytes(&px)) }));
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqual(@as(?u16, 2), rt.rows());
    const frames = rt.pixelData().?.nativeFrames().?;
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqualSlices(u16, &px, frames[0]);
}

test "roundtrip encapsulated pixel data" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putU16(tag_mod.ROWS, .US, 4);
    try ds.putU16(tag_mod.COLUMNS, .US, 4);
    const frame = [_]u8{ 0xFF, 0xD8, 0x00, 0x01, 0x02, 0x03 };
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .pixel_data = try encapPd(&.{&frame}, &.{0}) }));
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    const pd = rt.pixelData().?;
    try testing.expect(pd.isCompressed());
    try testing.expectEqual(@as(usize, 1), pd.numFrames());
    try testing.expectEqualSlices(u8, &frame, pd.encapsulatedFrame(0).?);
    try testing.expectEqualSlices(u32, &.{0}, pd.offsets());
}

test "roundtrip signed values" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putString(tag_mod.RESCALE_INTERCEPT, .DS, "-1024");
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqual(@as(?f64, -1024.0), rt.getF64(tag_mod.RESCALE_INTERCEPT));
}

test "write produces valid preamble and magic" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    const n = try write(&out.writer, &ds);
    const buf = out.written();
    try testing.expectEqual(@as(u64, buf.len), n);
    for (buf[0..128]) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqualStrings("DICM", buf[128..132]);
}

test "roundtrip multiple frames" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .pixel_data = try encapPd(&.{ &.{ 1, 2, 3, 4 }, &.{ 5, 6, 7, 8 } }, &.{ 0, 12 }) }));
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    const pd = rt.pixelData().?;
    try testing.expectEqual(@as(usize, 2), pd.numFrames());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, pd.encapsulatedFrame(0).?);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, pd.encapsulatedFrame(1).?);
}

test "roundtrip 8bit native pixels" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putU16(tag_mod.ROWS, .US, 1);
    try ds.putU16(tag_mod.COLUMNS, .US, 2);
    try ds.putU16(tag_mod.BITS_ALLOCATED, .US, 8);
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OB, .{ .bytes = try ta.dupe(u8, &.{ 10, 20 }) }));

    var first = try roundtrip(&ds);
    defer first.deinit();
    try expectPd(try nativePd(&.{&.{ 10, 20 }}), first.pixelData());
    try testing.expectEqual(@as(?u16, 8), first.bitsAllocated());

    var second = try roundtrip(&first);
    defer second.deinit();
    try testing.expect(first.pixelData().?.eql(second.pixelData().?));
    try testing.expectEqual(@as(?u16, 8), second.bitsAllocated());
}

test "roundtrip 16bit native pixel data enum" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putU16(tag_mod.ROWS, .US, 2);
    try ds.putU16(tag_mod.COLUMNS, .US, 2);
    try ds.putU16(tag_mod.BITS_ALLOCATED, .US, 16);
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .pixel_data = try nativePd(&.{&.{ 100, 200, 300, 400 }}) }));
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try expectPd(try nativePd(&.{&.{ 100, 200, 300, 400 }}), rt.pixelData());
}

test "roundtrip 8bit odd length strips padding" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putU16(tag_mod.ROWS, .US, 1);
    try ds.putU16(tag_mod.COLUMNS, .US, 1);
    try ds.putU16(tag_mod.BITS_ALLOCATED, .US, 8);
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OB, .{ .bytes = try ta.dupe(u8, &.{ 10, 0 }) }));
    var first = try roundtrip(&ds);
    defer first.deinit();
    try expectPd(try nativePd(&.{&.{10}}), first.pixelData());
    var second = try roundtrip(&first);
    defer second.deinit();
    try testing.expect(first.pixelData().?.eql(second.pixelData().?));
}

test "write 8bit rejects samples that do not fit" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putU16(tag_mod.ROWS, .US, 1);
    try ds.putU16(tag_mod.COLUMNS, .US, 1);
    try ds.putU16(tag_mod.BITS_ALLOCATED, .US, 8);
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .pixel_data = try nativePd(&.{&.{256}}) }));
    var diag: Diagnostic = .{};
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    try testing.expectError(error.Validation, writePart10(&out.writer, &ds, .{ .diagnostic = &diag }));
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try testing.expect(std.mem.indexOf(u8, msg, "256") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "8-bit") != null);
}

test "implicit vr write normalizes to explicit and roundtrips" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.IMPLICIT_VR_LITTLE_ENDIAN);
    try ds.putU16(tag_mod.ROWS, .US, 1);
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqualStrings(transfer.EXPLICIT_VR_LITTLE_ENDIAN, rt.getString(tag_mod.TRANSFER_SYNTAX_UID).?);
    try testing.expectEqual(@as(?u16, 1), rt.rows());
}

test "compressed transfer syntax is preserved" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.JPEG_LS_LOSSLESS);
    try ds.putU16(tag_mod.ROWS, .US, 1);
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqualStrings(transfer.JPEG_LS_LOSSLESS, rt.getString(tag_mod.TRANSFER_SYNTAX_UID).?);
    try testing.expectEqual(@as(?u16, 1), rt.rows());
}

test "multi fragment roundtrip recomputes bot" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.JPEG_LS_LOSSLESS);
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OB, .{ .pixel_data = try encapPd(&.{ &.{ 1, 2, 3, 4 }, &.{ 5, 6 } }, &.{ 0, 20 }) }));
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try expectPd(try encapPd(&.{ &.{ 1, 2, 3, 4 }, &.{ 5, 6 } }, &.{ 0, 12 }), rt.pixelData());
    var again = try roundtrip(&rt);
    defer again.deinit();
    try testing.expect(rt.pixelData().?.eql(again.pixelData().?));
}

test "encapsulated odd length frame pads and keeps boundaries" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.JPEG_LS_LOSSLESS);
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OB, .{ .pixel_data = try encapPd(&.{ &.{ 1, 2, 3 }, &.{ 4, 5 } }, &.{ 0, 99 }) }));
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try expectPd(try encapPd(&.{ &.{ 1, 2, 3, 0 }, &.{ 4, 5 } }, &.{ 0, 12 }), rt.pixelData());
}

test "empty bot is preserved on rewrite" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.JPEG_LS_LOSSLESS);
    try ds.putString(tag_mod.NUMBER_OF_FRAMES, .IS, "1");
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OB, .{ .pixel_data = try encapPd(&.{ &.{ 1, 2 }, &.{ 3, 4 } }, &.{}) }));
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try expectPd(try encapPd(&.{ &.{ 1, 2 }, &.{ 3, 4 } }, &.{}), rt.pixelData());
    var again = try roundtrip(&rt);
    defer again.deinit();
    try testing.expect(rt.pixelData().?.eql(again.pixelData().?));
}

test "roundtrip native pixels with 32bit allocation" {
    for ([_]u16{ 1, 32 }) |bits| {
        var ds = Dataset.init(ta);
        defer ds.deinit();
        try ds.putU16(tag_mod.ROWS, .US, 1);
        try ds.putU16(tag_mod.COLUMNS, .US, 1);
        try ds.putU16(tag_mod.BITS_ALLOCATED, .US, bits);
        try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .pixel_data = try nativePd(&.{&.{ 513, 1027 }}) }));

        const first = try writeToBytes(ta, &ds, .{});
        defer ta.free(first);
        var rt = try reader.parseBytes(ta, first);
        defer rt.deinit();
        try expectPd(try nativePd(&.{&.{ 513, 1027 }}), rt.pixelData());
        const second = try writeToBytes(ta, &rt, .{});
        defer ta.free(second);
        try testing.expectEqualSlices(u8, first, second);
    }
}

test "implicit vr uid with nul padding is normalized" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.IMPLICIT_VR_LITTLE_ENDIAN ++ "\x00");
    try ds.putU16(tag_mod.ROWS, .US, 1);
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqualStrings(transfer.EXPLICIT_VR_LITTLE_ENDIAN, rt.getString(tag_mod.TRANSFER_SYNTAX_UID).?);
    try testing.expectEqual(@as(?u16, 1), rt.rows());
}

// ---- Zig-port specific checks ----

test "short vr overflow is a validation error and writes nothing for it" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    const big = try ta.alloc(u8, 70_000);
    @memset(big, 'A');
    try ds.insert(Element.init(tag_mod.PATIENT_NAME, .PN, .{ .str = big }));
    var diag: Diagnostic = .{};
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    try testing.expectError(error.Validation, writePart10(&out.writer, &ds, .{ .diagnostic = &diag }));
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try testing.expect(std.mem.indexOf(u8, msg, "max 65535") != null);
}

test "sequence on a short vr is rejected" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.insert(Element.init(tag_mod.REFERENCED_IMAGE_SEQUENCE, .LO, .{ .sequence = try ta.alloc(Dataset, 0) }));
    try testing.expectError(error.Validation, writeToBytes(ta, &ds, .{}));
}

test "group 0000 elements do not hide the meta group" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    try ds.putU32(Tag.init(0x0000, 0x0000), .UL, 0);
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.JPEG_LS_LOSSLESS);
    var rt = try roundtrip(&ds);
    defer rt.deinit();
    try testing.expectEqualStrings(transfer.JPEG_LS_LOSSLESS, rt.getString(tag_mod.TRANSFER_SYNTAX_UID).?);
}

test "byte count matches encoded length with sequences" {
    var ds = Dataset.init(ta);
    defer ds.deinit();
    const items = try ta.alloc(Dataset, 2);
    items[0] = Dataset.init(ta);
    items[1] = Dataset.init(ta);
    try ds.insert(Element.init(tag_mod.REFERENCED_IMAGE_SEQUENCE, .SQ, .{ .sequence = items }));
    try items[0].putString(tag_mod.SOP_CLASS_UID, .UI, "1.2.3");
    try items[1].putU16(tag_mod.ROWS, .US, 7);
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    const n = try write(&out.writer, &ds);
    try testing.expectEqual(@as(u64, out.written().len), n);
    var rt = try reader.parseBytes(ta, out.written());
    defer rt.deinit();
    const seq = rt.get(tag_mod.REFERENCED_IMAGE_SEQUENCE).?.value.sequence;
    try testing.expectEqual(@as(usize, 2), seq.len);
    try testing.expectEqualStrings("1.2.3", seq[0].getString(tag_mod.SOP_CLASS_UID).?);
    try testing.expectEqual(@as(?u16, 7), seq[1].rows());
}
