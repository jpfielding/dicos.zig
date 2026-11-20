//! Wire-format builders shared across the dicos unit tests.
//!
//! These helpers assemble DICOS/DICOM byte streams by hand so parser and
//! writer tests can construct precise on-disk layouts (explicit/implicit VR,
//! fixed- and undefined-length sequences, deliberately malformed inputs).
//! Port of Rust `reader/test_util.rs`. All builders append to a caller-owned
//! `std.ArrayListUnmanaged(u8)` or return slices owned by the allocator.

const std = @import("std");
const tag_mod = @import("../tag.zig");
const transfer = @import("../transfer.zig");
const types = @import("../types.zig");
const reader = @import("../reader.zig");

const Tag = tag_mod.Tag;
const Element = types.Element;
const Value = types.Value;
const Allocator = std.mem.Allocator;
pub const Bytes = std.ArrayListUnmanaged(u8);

const UNDEFINED_LENGTH = reader.UNDEFINED_LENGTH;

fn putU16(a: Allocator, buf: *Bytes, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try buf.appendSlice(a, &b);
}

fn putU32(a: Allocator, buf: *Bytes, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(a, &b);
}

/// Preamble, magic, (0002,0000) group length and (0002,0010) = `ts_uid`.
fn pushMeta(a: Allocator, buf: *Bytes, ts_uid: []const u8) !void {
    try buf.appendNTimes(a, 0, 128);
    try buf.appendSlice(a, "DICM");
    const padded: usize = ts_uid.len + ts_uid.len % 2;
    const meta_len: u32 = @intCast(8 + padded);
    // (0002,0000) UL 4 <meta_len>
    try putU16(a, buf, 0x0002);
    try putU16(a, buf, 0x0000);
    try buf.appendSlice(a, "UL");
    try putU16(a, buf, 4);
    try putU32(a, buf, meta_len);
    // (0002,0010) UI <len> <value>
    try putU16(a, buf, 0x0002);
    try putU16(a, buf, 0x0010);
    try buf.appendSlice(a, "UI");
    try putU16(a, buf, @intCast(padded));
    try buf.appendSlice(a, ts_uid);
    if (ts_uid.len % 2 != 0) try buf.append(a, ' ');
}

/// Builds a minimal valid DICOS file in memory with explicit VR LE.
pub fn buildMinimalExplicitVrLe(a: Allocator, elements: []const Element) !Bytes {
    var buf: Bytes = .empty;
    errdefer buf.deinit(a);
    try pushMeta(a, &buf, transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    for (elements) |*e| try writeElementExplicit(a, &buf, e);
    return buf;
}

fn encodeValueBytes(a: Allocator, value: *const Value) ![]u8 {
    var b: Bytes = .empty;
    errdefer b.deinit(a);
    switch (value.*) {
        .str => |s| {
            try b.appendSlice(a, s);
            if (s.len % 2 != 0) try b.append(a, ' ');
        },
        .u16_val => |v| try putU16(a, &b, v),
        .u32_val => |v| try putU32(a, &b, v),
        .i16_val => |v| try putU16(a, &b, @bitCast(v)),
        .i32_val => |v| try putU32(a, &b, @bitCast(v)),
        .f32_val => |v| try putU32(a, &b, @bitCast(v)),
        .f64_val => |v| {
            var x: [8]u8 = undefined;
            std.mem.writeInt(u64, &x, @bitCast(v), .little);
            try b.appendSlice(a, &x);
        },
        .bytes => |bytes| try b.appendSlice(a, bytes),
        else => {},
    }
    return b.toOwnedSlice(a);
}

fn writeElementExplicit(a: Allocator, buf: *Bytes, e: *const Element) !void {
    const val = try encodeValueBytes(a, &e.value);
    defer a.free(val);
    try putU16(a, buf, e.tag.group);
    try putU16(a, buf, e.tag.element);
    try buf.appendSlice(a, &e.vr.asBytes());
    if (e.vr.isLongVr()) {
        try buf.appendSlice(a, &.{ 0, 0 });
        try putU32(a, buf, @intCast(val.len));
    } else {
        try putU16(a, buf, @intCast(val.len));
    }
    try buf.appendSlice(a, val);
}

/// Minimal file with an arbitrary TS UID followed by (0008,0060) CS "CT"
/// encoded explicit VR LE, so the reader crosses the meta boundary.
pub fn buildMinimalDicosWithTs(a: Allocator, ts_uid: []const u8) !Bytes {
    var buf: Bytes = .empty;
    errdefer buf.deinit(a);
    try pushMeta(a, &buf, ts_uid);
    try putU16(a, &buf, 0x0008);
    try putU16(a, &buf, 0x0060);
    try buf.appendSlice(a, "CS");
    try putU16(a, &buf, 2);
    try buf.appendSlice(a, "CT");
    return buf;
}

/// A file with no TransferSyntaxUID: (0002,0000)=0 then Rows=64 encoded as
/// Implicit VR LE.
pub fn buildDicosWithoutTransferSyntax(a: Allocator) !Bytes {
    var buf: Bytes = .empty;
    errdefer buf.deinit(a);
    try buf.appendNTimes(a, 0, 128);
    try buf.appendSlice(a, "DICM");
    try putU16(a, &buf, 0x0002);
    try putU16(a, &buf, 0x0000);
    try buf.appendSlice(a, "UL");
    try putU16(a, &buf, 4);
    try putU32(a, &buf, 0);
    try putU16(a, &buf, 0x0028);
    try putU16(a, &buf, 0x0010);
    try putU32(a, &buf, 2);
    try putU16(a, &buf, 64);
    return buf;
}

/// Encodes a single element in explicit-VR wire format.
pub fn encodeExplicitElem(a: Allocator, e: Element) ![]u8 {
    var buf: Bytes = .empty;
    errdefer buf.deinit(a);
    try writeElementExplicit(a, &buf, &e);
    return buf.toOwnedSlice(a);
}

/// Wraps `content` in a fixed-length SQ item.
pub fn buildSqItem(a: Allocator, content: []const u8) ![]u8 {
    var buf: Bytes = .empty;
    errdefer buf.deinit(a);
    try putU16(a, &buf, 0xFFFE);
    try putU16(a, &buf, 0xE000);
    try putU32(a, &buf, @intCast(content.len));
    try buf.appendSlice(a, content);
    return buf.toOwnedSlice(a);
}

/// Wraps `items_bytes` in a fixed-length SQ element (long VR encoding).
pub fn buildFixedSq(a: Allocator, sq_tag: Tag, items_bytes: []const u8) ![]u8 {
    var buf: Bytes = .empty;
    errdefer buf.deinit(a);
    try putU16(a, &buf, sq_tag.group);
    try putU16(a, &buf, sq_tag.element);
    try buf.appendSlice(a, "SQ");
    try buf.appendSlice(a, &.{ 0, 0 });
    try putU32(a, &buf, @intCast(items_bytes.len));
    try buf.appendSlice(a, items_bytes);
    return buf.toOwnedSlice(a);
}

/// Wraps `inner` in one undefined-length SQ holding one undefined-length item.
pub fn wrapUndefinedLengthSq(a: Allocator, inner: []const u8) ![]u8 {
    var sq: Bytes = .empty;
    errdefer sq.deinit(a);
    const t = tag_mod.REFERENCED_IMAGE_SEQUENCE;
    try putU16(a, &sq, t.group);
    try putU16(a, &sq, t.element);
    try sq.appendSlice(a, "SQ");
    try sq.appendSlice(a, &.{ 0, 0 });
    try putU32(a, &sq, UNDEFINED_LENGTH);
    try putU16(a, &sq, 0xFFFE); // Item
    try putU16(a, &sq, 0xE000);
    try putU32(a, &sq, UNDEFINED_LENGTH);
    try sq.appendSlice(a, inner);
    try putU16(a, &sq, 0xFFFE); // Item Delimitation
    try putU16(a, &sq, 0xE00D);
    try putU32(a, &sq, 0);
    try putU16(a, &sq, 0xFFFE); // Sequence Delimitation
    try putU16(a, &sq, 0xE0DD);
    try putU32(a, &sq, 0);
    return sq.toOwnedSlice(a);
}

/// (7FE0,0010) OB with undefined length: the encapsulated pixel data header.
pub fn pushEncapsulatedPixelDataHeader(a: Allocator, buf: *Bytes) !void {
    try putU16(a, buf, 0x7FE0);
    try putU16(a, buf, 0x0010);
    try buf.appendSlice(a, "OB");
    try buf.appendSlice(a, &.{ 0, 0 });
    try putU32(a, buf, UNDEFINED_LENGTH);
}

/// A Basic Offset Table item.
pub fn pushBasicOffsetTable(a: Allocator, buf: *Bytes, offsets: []const u32) !void {
    try putU16(a, buf, 0xFFFE);
    try putU16(a, buf, 0xE000);
    try putU32(a, buf, @intCast(offsets.len * 4));
    for (offsets) |o| try putU32(a, buf, o);
}

/// An encapsulated fragment item.
pub fn pushPixelFragment(a: Allocator, buf: *Bytes, data: []const u8) !void {
    try putU16(a, buf, 0xFFFE);
    try putU16(a, buf, 0xE000);
    try putU32(a, buf, @intCast(data.len));
    try buf.appendSlice(a, data);
}

/// The Sequence Delimitation Item.
pub fn pushSequenceDelimitation(a: Allocator, buf: *Bytes) !void {
    try putU16(a, buf, 0xFFFE);
    try putU16(a, buf, 0xE0DD);
    try putU32(a, buf, 0);
}

/// Appends a raw little-endian u16/u32 (for hand-built malformed streams).
pub const appendU16 = putU16;
pub const appendU32 = putU32;

/// Reads `<repo-root>/testdata/<name>` if present. Tests run from the
/// build root (`zig build test` sets the cwd), and `DICOS_TESTDATA`
/// overrides the directory. Returns `null` (caller skips) when the file is
/// absent or is an un-fetched Git LFS pointer.
pub fn readTestdata(a: Allocator, name: []const u8) !?[]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.process.getEnvVarOwned(a, "DICOS_TESTDATA") catch null;
    defer if (dir) |d| a.free(d);
    const base = if (dir) |d| std.fmt.bufPrint(&dir_buf, "{s}", .{d}) catch "testdata" else "testdata";
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base, name });
    const data = std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |e| switch (e) {
        error.FileNotFound => {
            std.debug.print("skipping: {s} not found\n", .{path});
            return null;
        },
        else => return e,
    };
    if (std.mem.startsWith(u8, data, "version https://git-lfs")) {
        std.debug.print("skipping: {s} is a Git LFS pointer (run `git lfs pull`)\n", .{path});
        a.free(data);
        return null;
    }
    return data;
}
