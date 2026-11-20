//! Core DICOS data types: Dataset, Element, Value, and PixelData.
//!
//! These types represent the in-memory structure of a DICOS file after
//! parsing, and serve as the input for writing DICOS files.
//!
//! Ownership: every slice inside a `Value` is owned by the `Dataset` that
//! holds the element and is freed with that dataset's allocator. Sequence
//! items are `Dataset`s that own their own elements.

const std = @import("std");
const tag_mod = @import("tag.zig");
const transfer = @import("transfer.zig");
const vr_mod = @import("vr.zig");

const Tag = tag_mod.Tag;
const Vr = vr_mod.Vr;
const TransferSyntax = transfer.TransferSyntax;
const Allocator = std.mem.Allocator;

/// A typed value stored in a DICOM/DICOS data element.
pub const Value = union(enum) {
    /// Single string value.
    str: []const u8,
    /// Multi-valued string (backslash-separated in DICOM).
    strings: []const []const u8,
    /// Unsigned 16-bit integer.
    u16_val: u16,
    /// Multiple unsigned 16-bit integers.
    u16s: []const u16,
    /// Unsigned 32-bit integer.
    u32_val: u32,
    /// Signed 16-bit integer.
    i16_val: i16,
    /// Signed 32-bit integer.
    i32_val: i32,
    /// 32-bit floating point.
    f32_val: f32,
    /// 64-bit floating point.
    f64_val: f64,
    /// Multiple 32-bit floating point values.
    f32s: []const f32,
    /// Multiple 64-bit floating point values.
    f64s: []const f64,
    /// Raw byte data (OB, OW, UN).
    bytes: []const u8,
    /// Sequence of nested datasets.
    sequence: []Dataset,
    /// Pixel data with frame structure.
    pixel_data: PixelData,

    /// Returns the value as a string if it is `str`, or the first of `strings`.
    pub fn asStr(self: *const Value) ?[]const u8 {
        return switch (self.*) {
            .str => |s| s,
            .strings => |values| if (values.len > 0) values[0] else null,
            else => null,
        };
    }

    /// Returns all string values when the value is `strings`.
    pub fn asStrings(self: *const Value) ?[]const []const u8 {
        return switch (self.*) {
            .strings => |values| values,
            else => null,
        };
    }

    /// Extracts the value as a `u16` from `u16_val` or a numeric string.
    pub fn asU16(self: *const Value) ?u16 {
        return switch (self.*) {
            .u16_val => |v| v,
            .str => |s| parseIntStrict(u16, trimWhitespace(s)),
            else => null,
        };
    }

    /// Extracts the value as a `u32`.
    pub fn asU32(self: *const Value) ?u32 {
        return switch (self.*) {
            .u32_val => |v| v,
            .u16_val => |v| v,
            .str => |s| parseIntStrict(u32, trimWhitespace(s)),
            else => null,
        };
    }

    /// Extracts the value as an `i32` from any integer variant or string.
    pub fn asI32(self: *const Value) ?i32 {
        return switch (self.*) {
            .i32_val => |v| v,
            .i16_val => |v| v,
            .u16_val => |v| v,
            .u32_val => |v| std.math.cast(i32, v),
            .str => |s| parseIntStrict(i32, trimWhitespace(s)),
            else => null,
        };
    }

    /// Extracts the value as an `f64`.
    pub fn asF64(self: *const Value) ?f64 {
        return switch (self.*) {
            .f64_val => |v| v,
            .f32_val => |v| v,
            .str => |s| parseFloatStrict(trimWhitespace(s)),
            else => null,
        };
    }

    /// Returns the slice of u16 values if this is `u16s`.
    pub fn asU16s(self: *const Value) ?[]const u16 {
        return switch (self.*) {
            .u16s => |v| v,
            else => null,
        };
    }

    /// Returns the slice of f32 values if this is `f32s`.
    pub fn asF32s(self: *const Value) ?[]const f32 {
        return switch (self.*) {
            .f32s => |v| v,
            else => null,
        };
    }

    /// Returns the slice of f64 values if this is `f64s`.
    pub fn asF64s(self: *const Value) ?[]const f64 {
        return switch (self.*) {
            .f64s => |v| v,
            else => null,
        };
    }

    /// Returns the raw bytes if this is `bytes`.
    pub fn asBytes(self: *const Value) ?[]const u8 {
        return switch (self.*) {
            .bytes => |v| v,
            else => null,
        };
    }

    /// Frees any memory owned by this value.
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .str => |s| allocator.free(s),
            .strings => |values| {
                for (values) |s| allocator.free(s);
                allocator.free(values);
            },
            .u16s => |s| allocator.free(s),
            .f32s => |s| allocator.free(s),
            .f64s => |s| allocator.free(s),
            .bytes => |b| allocator.free(b),
            .sequence => |datasets| {
                for (datasets) |*ds| ds.deinit();
                allocator.free(datasets);
            },
            .pixel_data => |*pd| pd.deinit(allocator),
            .u16_val, .u32_val, .i16_val, .i32_val, .f32_val, .f64_val => {},
        }
        self.* = .{ .bytes = &.{} };
    }

    /// Deep-copies the value using `allocator`.
    pub fn clone(self: *const Value, allocator: Allocator) Allocator.Error!Value {
        return switch (self.*) {
            .str => |s| .{ .str = try allocator.dupe(u8, s) },
            .strings => |values| blk: {
                const out = try allocator.alloc([]const u8, values.len);
                var n: usize = 0;
                errdefer {
                    for (out[0..n]) |s| allocator.free(s);
                    allocator.free(out);
                }
                for (values) |s| {
                    out[n] = try allocator.dupe(u8, s);
                    n += 1;
                }
                break :blk .{ .strings = out };
            },
            .u16s => |v| .{ .u16s = try allocator.dupe(u16, v) },
            .f32s => |v| .{ .f32s = try allocator.dupe(f32, v) },
            .f64s => |v| .{ .f64s = try allocator.dupe(f64, v) },
            .bytes => |v| .{ .bytes = try allocator.dupe(u8, v) },
            .sequence => |items| blk: {
                const out = try allocator.alloc(Dataset, items.len);
                var n: usize = 0;
                errdefer {
                    for (out[0..n]) |*d| d.deinit();
                    allocator.free(out);
                }
                for (items) |*item| {
                    out[n] = try item.cloneWith(allocator);
                    n += 1;
                }
                break :blk .{ .sequence = out };
            },
            .pixel_data => |*pd| .{ .pixel_data = try pd.clone(allocator) },
            .u16_val, .u32_val, .i16_val, .i32_val, .f32_val, .f64_val => self.*,
        };
    }

    /// Structural equality (Rust `PartialEq`; floats compare with `==`).
    pub fn eql(a: *const Value, b: *const Value) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .str => |s| std.mem.eql(u8, s, b.str),
            .strings => |sa| blk: {
                const sb = b.strings;
                if (sa.len != sb.len) break :blk false;
                for (sa, sb) |x, y| if (!std.mem.eql(u8, x, y)) break :blk false;
                break :blk true;
            },
            .u16_val => |v| v == b.u16_val,
            .u32_val => |v| v == b.u32_val,
            .i16_val => |v| v == b.i16_val,
            .i32_val => |v| v == b.i32_val,
            .f32_val => |v| v == b.f32_val,
            .f64_val => |v| v == b.f64_val,
            .u16s => |v| std.mem.eql(u16, v, b.u16s),
            .f32s => |v| floatSliceEql(f32, v, b.f32s),
            .f64s => |v| floatSliceEql(f64, v, b.f64s),
            .bytes => |v| std.mem.eql(u8, v, b.bytes),
            .sequence => |sa| blk: {
                const sb = b.sequence;
                if (sa.len != sb.len) break :blk false;
                for (sa, sb) |*x, *y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            .pixel_data => |*pd| pd.eql(&b.pixel_data),
        };
    }

    /// Debug-style rendering mirroring Rust's derived `Debug` output shape.
    pub fn format(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .str => |s| try w.print("Str(\"{s}\")", .{s}),
            .strings => |values| {
                try w.writeAll("Strings([");
                for (values, 0..) |s, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("\"{s}\"", .{s});
                }
                try w.writeAll("])");
            },
            .u16_val => |v| try w.print("U16({d})", .{v}),
            .u32_val => |v| try w.print("U32({d})", .{v}),
            .i16_val => |v| try w.print("I16({d})", .{v}),
            .i32_val => |v| try w.print("I32({d})", .{v}),
            .f32_val => |v| try w.print("F32({d})", .{v}),
            .f64_val => |v| try w.print("F64({d})", .{v}),
            .u16s => |v| try w.print("U16s({any})", .{v}),
            .f32s => |v| try w.print("F32s({any})", .{v}),
            .f64s => |v| try w.print("F64s({any})", .{v}),
            .bytes => |v| try w.print("Bytes(<{d} bytes>)", .{v.len}),
            .sequence => |items| try w.print("Sequence(<{d} items>)", .{items.len}),
            .pixel_data => |pd| switch (pd) {
                .native => |n| try w.print("PixelData(Native {{ frames: {d} }})", .{n.frames.len}),
                .encapsulated => |e| try w.print(
                    "PixelData(Encapsulated {{ frames: {d}, offsets: {any} }})",
                    .{ e.frames.len, e.offsets },
                ),
            },
        }
    }
};

fn floatSliceEql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// A single DICOM/DICOS data element.
///
/// A plain record. There is no enforced invariant between `vr` and `value`:
/// keeping the Value Representation coherent with the stored `Value` is the
/// caller's responsibility. The writer encodes `value` according to its own
/// variant, not `vr`.
pub const Element = struct {
    /// The tag identifying this element.
    tag: Tag,
    /// The Value Representation.
    vr: Vr,
    /// The typed value.
    value: Value,

    pub fn init(t: Tag, v: Vr, val: Value) Element {
        return .{ .tag = t, .vr = v, .value = val };
    }

    pub fn deinit(self: *Element, allocator: Allocator) void {
        self.value.deinit(allocator);
    }

    pub fn eql(a: *const Element, b: *const Element) bool {
        return a.tag.eql(b.tag) and a.vr == b.vr and a.value.eql(&b.value);
    }

    pub fn clone(self: *const Element, allocator: Allocator) Allocator.Error!Element {
        return .{ .tag = self.tag, .vr = self.vr, .value = try self.value.clone(allocator) };
    }
};

/// An ordered collection of DICOM data elements, keyed by Tag.
///
/// Elements are kept sorted by tag (Rust uses a `BTreeMap`), so iteration
/// yields ascending tag order, matching the required on-disk ordering.
pub const Dataset = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(Element) = .empty,

    /// Creates a new empty dataset whose values are owned by `allocator`.
    pub fn init(allocator: Allocator) Dataset {
        return .{ .allocator = allocator };
    }

    /// Frees every element and the dataset storage.
    pub fn deinit(self: *Dataset) void {
        for (self.items.items) |*e| e.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Deep-copies the dataset with the same allocator.
    pub fn clone(self: *const Dataset) Allocator.Error!Dataset {
        return self.cloneWith(self.allocator);
    }

    /// Deep-copies the dataset into `allocator`.
    pub fn cloneWith(self: *const Dataset, allocator: Allocator) Allocator.Error!Dataset {
        var out = Dataset.init(allocator);
        errdefer out.deinit();
        try out.items.ensureTotalCapacityPrecise(allocator, self.items.items.len);
        for (self.items.items) |*e| out.items.appendAssumeCapacity(try e.clone(allocator));
        return out;
    }

    fn search(self: *const Dataset, t: Tag) struct { found: bool, index: usize } {
        const key = t.toU32();
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = self.items.items[mid].tag.toU32();
            if (k == key) return .{ .found = true, .index = mid };
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return .{ .found = false, .index = lo };
    }

    /// Inserts an element, replacing (and freeing) any existing element with
    /// the same tag. Always takes ownership of `element`: on allocation
    /// failure the element is freed before the error is returned.
    pub fn insert(self: *Dataset, element: Element) Allocator.Error!void {
        const pos = self.search(element.tag);
        if (pos.found) {
            self.items.items[pos.index].deinit(self.allocator);
            self.items.items[pos.index] = element;
            return;
        }
        self.items.insert(self.allocator, pos.index, element) catch |e| {
            var owned = element;
            owned.deinit(self.allocator);
            return e;
        };
    }

    /// Returns the element with the given tag, if present.
    pub fn get(self: *const Dataset, t: Tag) ?*const Element {
        const pos = self.search(t);
        return if (pos.found) &self.items.items[pos.index] else null;
    }

    /// Returns a mutable pointer to the element with the given tag.
    pub fn getPtr(self: *Dataset, t: Tag) ?*Element {
        const pos = self.search(t);
        return if (pos.found) &self.items.items[pos.index] else null;
    }

    /// Removes and returns the element with the given tag. The caller owns
    /// the returned element and frees it with `elem.deinit(ds.allocator)`.
    pub fn remove(self: *Dataset, t: Tag) ?Element {
        const pos = self.search(t);
        if (!pos.found) return null;
        return self.items.orderedRemove(pos.index);
    }

    /// Returns `true` if the dataset contains an element with the given tag.
    pub fn contains(self: *const Dataset, t: Tag) bool {
        return self.search(t).found;
    }

    /// Returns the number of elements.
    pub fn len(self: *const Dataset) usize {
        return self.items.items.len;
    }

    /// Returns `true` if the dataset has no elements.
    pub fn isEmpty(self: *const Dataset) bool {
        return self.items.items.len == 0;
    }

    /// Returns all elements in ascending tag order.
    pub fn iter(self: *const Dataset) []const Element {
        return self.items.items;
    }

    /// Returns an iterator over all tags in ascending order.
    pub fn tags(self: *const Dataset) TagIterator {
        return .{ .elements = self.items.items };
    }

    pub const TagIterator = struct {
        elements: []const Element,
        index: usize = 0,

        pub fn next(it: *TagIterator) ?Tag {
            if (it.index >= it.elements.len) return null;
            defer it.index += 1;
            return it.elements[it.index].tag;
        }
    };

    /// Returns a string value for the given tag (first value when multi-valued).
    pub fn getString(self: *const Dataset, t: Tag) ?[]const u8 {
        const e = self.get(t) orelse return null;
        return e.value.asStr();
    }

    pub fn getU16(self: *const Dataset, t: Tag) ?u16 {
        const e = self.get(t) orelse return null;
        return e.value.asU16();
    }

    pub fn getU32(self: *const Dataset, t: Tag) ?u32 {
        const e = self.get(t) orelse return null;
        return e.value.asU32();
    }

    pub fn getI32(self: *const Dataset, t: Tag) ?i32 {
        const e = self.get(t) orelse return null;
        return e.value.asI32();
    }

    pub fn getF64(self: *const Dataset, t: Tag) ?f64 {
        const e = self.get(t) orelse return null;
        return e.value.asF64();
    }

    /// Returns all string values for the given tag. A single `str` value is
    /// returned as a one-item slice. The slice borrows the dataset.
    pub fn getStrs(self: *const Dataset, t: Tag) ?[]const []const u8 {
        const e = self.get(t) orelse return null;
        return switch (e.value) {
            .str => @as(*const [1][]const u8, &e.value.str),
            .strings => |values| values,
            else => null,
        };
    }

    /// Rows (0028,0010), or `null` if absent. No DICOM-defined default.
    pub fn rows(self: *const Dataset) ?u16 {
        return self.getU16(tag_mod.ROWS);
    }

    /// Columns (0028,0011), or `null` if absent.
    pub fn columns(self: *const Dataset) ?u16 {
        return self.getU16(tag_mod.COLUMNS);
    }

    /// BitsAllocated (0028,0100), or `null` if absent.
    pub fn bitsAllocated(self: *const Dataset) ?u16 {
        return self.getU16(tag_mod.BITS_ALLOCATED);
    }

    /// PixelRepresentation (0028,0103), or `null` if absent.
    pub fn pixelRepresentation(self: *const Dataset) ?u16 {
        return self.getU16(tag_mod.PIXEL_REPRESENTATION);
    }

    /// NumberOfFrames (0028,0008), defaulting to 1 (DICOM-defined: absent
    /// means a single-frame image).
    pub fn numberOfFrames(self: *const Dataset) u32 {
        const e = self.get(tag_mod.NUMBER_OF_FRAMES) orelse return 1;
        if (e.value.asU32()) |v| return v;
        if (e.value.asStr()) |s| {
            if (parseIntStrict(u32, trimWhitespace(s))) |v| return v;
        }
        return 1;
    }

    /// Returns the Modality value, or an empty string.
    pub fn modality(self: *const Dataset) []const u8 {
        return self.getString(tag_mod.MODALITY) orelse "";
    }

    /// Returns the Transfer Syntax, defaulting to Explicit VR Little Endian.
    /// The result borrows the dataset's UID string.
    pub fn transferSyntax(self: *const Dataset) TransferSyntax {
        if (self.getString(tag_mod.TRANSFER_SYNTAX_UID)) |s| {
            return TransferSyntax.init(trimWhitespace(s));
        }
        return TransferSyntax.init(transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    }

    /// Returns `true` if the dataset uses an encapsulated transfer syntax.
    pub fn isEncapsulated(self: *const Dataset) bool {
        return self.transferSyntax().isEncapsulated();
    }

    /// Returns the pixel data if present and already structured.
    pub fn pixelData(self: *const Dataset) ?*const PixelData {
        const e = self.get(tag_mod.PIXEL_DATA) orelse return null;
        return switch (e.value) {
            .pixel_data => |*pd| pd,
            else => null,
        };
    }

    /// Creates and inserts a string element (the value is copied).
    pub fn putString(self: *Dataset, t: Tag, vr: Vr, value: []const u8) Allocator.Error!void {
        const owned = try self.allocator.dupe(u8, value);
        try self.insert(Element.init(t, vr, .{ .str = owned }));
    }

    /// Creates and inserts a u16 element.
    pub fn putU16(self: *Dataset, t: Tag, vr: Vr, value: u16) Allocator.Error!void {
        try self.insert(Element.init(t, vr, .{ .u16_val = value }));
    }

    /// Creates and inserts a u32 element.
    pub fn putU32(self: *Dataset, t: Tag, vr: Vr, value: u32) Allocator.Error!void {
        try self.insert(Element.init(t, vr, .{ .u32_val = value }));
    }

    /// Structural equality (Rust `PartialEq`).
    pub fn eql(a: *const Dataset, b: *const Dataset) bool {
        if (a.items.items.len != b.items.items.len) return false;
        for (a.items.items, b.items.items) |*x, *y| if (!x.eql(y)) return false;
        return true;
    }

    /// Rust `Display`: a header line plus one line per element.
    pub fn format(self: Dataset, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Dataset ({d} elements)\n", .{self.len()});
        for (self.items.items) |e| {
            try w.print("  {f} {f}: {f}\n", .{ e.tag, e.vr, e.value });
        }
    }
};

/// Native (uncompressed) frames: decoded pixels per frame.
pub const NativeFrames = struct {
    frames: [][]u16,
};

/// Encapsulated (compressed) frames plus the Basic Offset Table.
pub const EncapsulatedFrames = struct {
    frames: [][]u8,
    offsets: []u32,
};

/// Pixel data with support for both native (uncompressed) and encapsulated
/// (compressed) formats.
pub const PixelData = union(enum) {
    native: NativeFrames,
    encapsulated: EncapsulatedFrames,

    /// Native pixel data from a single frame. Takes ownership of `data`
    /// (freed on error).
    pub fn initNativeSingle(allocator: Allocator, data: []u16) Allocator.Error!PixelData {
        const frames = allocator.alloc([]u16, 1) catch |e| {
            allocator.free(data);
            return e;
        };
        frames[0] = data;
        return .{ .native = .{ .frames = frames } };
    }

    /// Native pixel data from multiple frames. Takes ownership of `frames`
    /// and every frame slice.
    pub fn initNative(frames: [][]u16) PixelData {
        return .{ .native = .{ .frames = frames } };
    }

    /// Encapsulated pixel data from compressed frames and BOT offsets. Takes
    /// ownership of all slices.
    pub fn initEncapsulated(frames: [][]u8, bot: []u32) PixelData {
        return .{ .encapsulated = .{ .frames = frames, .offsets = bot } };
    }

    pub fn deinit(self: *PixelData, allocator: Allocator) void {
        switch (self.*) {
            .native => |n| {
                for (n.frames) |f| allocator.free(f);
                allocator.free(n.frames);
            },
            .encapsulated => |e| {
                for (e.frames) |f| allocator.free(f);
                allocator.free(e.frames);
                allocator.free(e.offsets);
            },
        }
        self.* = .{ .native = .{ .frames = &.{} } };
    }

    pub fn clone(self: *const PixelData, allocator: Allocator) Allocator.Error!PixelData {
        switch (self.*) {
            .native => |n| return .{ .native = .{ .frames = try dupeFrames(u16, allocator, n.frames) } },
            .encapsulated => |e| {
                const frames = try dupeFrames(u8, allocator, e.frames);
                errdefer freeFrames(u8, allocator, frames);
                const offs = try allocator.dupe(u32, e.offsets);
                return .{ .encapsulated = .{ .frames = frames, .offsets = offs } };
            },
        }
    }

    pub fn eql(a: *const PixelData, b: *const PixelData) bool {
        switch (a.*) {
            .native => |n| {
                if (b.* != .native) return false;
                return framesEql(u16, n.frames, b.native.frames);
            },
            .encapsulated => |e| {
                if (b.* != .encapsulated) return false;
                return framesEql(u8, e.frames, b.encapsulated.frames) and
                    std.mem.eql(u32, e.offsets, b.encapsulated.offsets);
            },
        }
    }

    /// All native frames concatenated into a newly allocated slice, or
    /// `null` for encapsulated data.
    pub fn flatData(self: *const PixelData, allocator: Allocator) Allocator.Error!?[]u16 {
        var out: std.ArrayListUnmanaged(u16) = .empty;
        errdefer out.deinit(allocator);
        if ((try self.flatDataInto(allocator, &out)) == null) return null;
        return try out.toOwnedSlice(allocator);
    }

    /// Writes all native frame data into `out` (cleared first). Returns
    /// `null` for encapsulated data.
    pub fn flatDataInto(self: *const PixelData, allocator: Allocator, out: *std.ArrayListUnmanaged(u16)) Allocator.Error!?void {
        const frames = self.nativeFrames() orelse return null;
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(allocator, self.totalPixels());
        for (frames) |f| out.appendSliceAssumeCapacity(f);
    }

    /// The native frame at `index`, or `null` if not native or out of bounds.
    pub fn nativeFrame(self: *const PixelData, index: usize) ?[]const u16 {
        const frames = self.nativeFrames() orelse return null;
        return if (index < frames.len) frames[index] else null;
    }

    /// The encapsulated frame at `index`, or `null` if not encapsulated or
    /// out of bounds.
    pub fn encapsulatedFrame(self: *const PixelData, index: usize) ?[]const u8 {
        const frames = self.encapsulatedFrames() orelse return null;
        return if (index < frames.len) frames[index] else null;
    }

    pub fn nativeFrames(self: *const PixelData) ?[]const []u16 {
        return switch (self.*) {
            .native => |n| n.frames,
            .encapsulated => null,
        };
    }

    pub fn encapsulatedFrames(self: *const PixelData) ?[]const []u8 {
        return switch (self.*) {
            .encapsulated => |e| e.frames,
            .native => null,
        };
    }

    /// The Basic Offset Table entries, or an empty slice for native data.
    pub fn offsets(self: *const PixelData) []const u32 {
        return switch (self.*) {
            .encapsulated => |e| e.offsets,
            .native => &.{},
        };
    }

    /// Iterates all native pixels across all frames (empty for encapsulated).
    pub fn iterNativePixels(self: *const PixelData) NativePixelIterator {
        return .{ .frames = self.nativeFrames() orelse &.{} };
    }

    pub const NativePixelIterator = struct {
        frames: []const []u16,
        frame: usize = 0,
        index: usize = 0,

        pub fn next(it: *NativePixelIterator) ?u16 {
            while (it.frame < it.frames.len) {
                const f = it.frames[it.frame];
                if (it.index < f.len) {
                    defer it.index += 1;
                    return f[it.index];
                }
                it.frame += 1;
                it.index = 0;
            }
            return null;
        }
    };

    pub fn numFrames(self: *const PixelData) usize {
        return switch (self.*) {
            .native => |n| n.frames.len,
            .encapsulated => |e| e.frames.len,
        };
    }

    pub fn isCompressed(self: *const PixelData) bool {
        return self.* == .encapsulated;
    }

    pub fn hasFrames(self: *const PixelData) bool {
        return self.numFrames() > 0;
    }

    /// Pixels in the first frame (native only), or 0.
    pub fn frameSize(self: *const PixelData) usize {
        return switch (self.*) {
            .native => |n| if (n.frames.len > 0) n.frames[0].len else 0,
            .encapsulated => 0,
        };
    }

    /// Total pixels across all frames (native only), or 0.
    pub fn totalPixels(self: *const PixelData) usize {
        return switch (self.*) {
            .native => |n| blk: {
                var total: usize = 0;
                for (n.frames) |f| total += f.len;
                break :blk total;
            },
            .encapsulated => 0,
        };
    }
};

fn dupeFrames(comptime T: type, allocator: Allocator, frames: []const []T) Allocator.Error![][]T {
    const out = try allocator.alloc([]T, frames.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |f| allocator.free(f);
        allocator.free(out);
    }
    for (frames) |f| {
        out[n] = try allocator.dupe(T, f);
        n += 1;
    }
    return out;
}

fn freeFrames(comptime T: type, allocator: Allocator, frames: [][]T) void {
    for (frames) |f| allocator.free(f);
    allocator.free(frames);
}

fn framesEql(comptime T: type, a: []const []T, b: []const []T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(T, x, y)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Rust-compatible string helpers
// ---------------------------------------------------------------------------

/// Trims leading and trailing Unicode `White_Space` (Rust `str::trim`).
/// NUL is not whitespace.
pub fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const n = whitespaceLenAt(s, start);
        if (n == 0) break;
        start += n;
    }
    var end: usize = s.len;
    while (end > start) {
        const n = whitespaceLenBefore(s[start..end]);
        if (n == 0) break;
        end -= n;
    }
    return s[start..end];
}

fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn whitespaceLenAt(s: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return 0;
    if (i + n > s.len) return 0;
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return 0;
    return if (isUnicodeWhitespace(cp)) n else 0;
}

fn whitespaceLenBefore(s: []const u8) usize {
    // Walk back over at most 3 continuation bytes to the lead byte.
    var i: usize = s.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        if (s[i] & 0xC0 != 0x80) break;
    }
    const n = whitespaceLenAt(s, i);
    return if (n == s.len - i) n else 0;
}

/// Strict decimal integer parse matching Rust `str::parse::<T>()`: optional
/// sign (`-` only for signed types), at least one ASCII digit, nothing else.
pub fn parseIntStrict(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        if (neg and @typeInfo(T).int.signedness == .unsigned) return null;
        i = 1;
    }
    if (i == s.len) return null;
    for (s[i..]) |c| if (c < '0' or c > '9') return null;
    if (neg) {
        // Parse with the sign so T's minimum is representable.
        return std.fmt.parseInt(T, s, 10) catch null;
    }
    return std.fmt.parseInt(T, s[i..], 10) catch null;
}

/// Float parse aligned with Rust `str::parse::<f64>()`: rejects the Zig-only
/// extensions (digit-separator underscores and hexadecimal floats).
pub fn parseFloatStrict(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    if (std.mem.indexOfScalar(u8, s, '_') != null) return null;
    var body = s;
    if (body[0] == '+' or body[0] == '-') body = body[1..];
    if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "dataset insert and get" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "DOE^JOHN");
    try ds.putU16(tag_mod.ROWS, .US, 512);

    try testing.expectEqual(@as(usize, 2), ds.len());
    try testing.expect(!ds.isEmpty());
    try testing.expectEqualStrings("DOE^JOHN", ds.getString(tag_mod.PATIENT_NAME).?);
    try testing.expectEqual(@as(?u16, 512), ds.rows());
}

test "dataset remove" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putU16(tag_mod.ROWS, .US, 256);
    try testing.expect(ds.contains(tag_mod.ROWS));
    var removed = ds.remove(tag_mod.ROWS) orelse return error.TestUnexpectedResult;
    removed.deinit(ds.allocator);
    try testing.expect(!ds.contains(tag_mod.ROWS));
    try testing.expect(ds.isEmpty());
}

test "dataset defaults" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try testing.expectEqual(@as(?u16, null), ds.rows());
    try testing.expectEqual(@as(?u16, null), ds.columns());
    try testing.expectEqual(@as(?u16, null), ds.bitsAllocated());
    try testing.expectEqual(@as(?u16, null), ds.pixelRepresentation());
    try testing.expectEqual(@as(u32, 1), ds.numberOfFrames());
    try testing.expectEqualStrings("", ds.modality());
}

test "dataset transfer syntax" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try testing.expectEqualStrings(transfer.EXPLICIT_VR_LITTLE_ENDIAN, ds.transferSyntax().uid);
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer.JPEG_LS_LOSSLESS);
    try testing.expect(ds.isEncapsulated());
    try testing.expect(ds.transferSyntax().isJpegLs());
}

test "dataset ordering" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putU16(tag_mod.PIXEL_REPRESENTATION, .US, 0);
    try ds.putU16(tag_mod.ROWS, .US, 128);
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "TEST");
    try ds.putU16(tag_mod.COLUMNS, .US, 256);

    var it = ds.tags();
    var prev: ?Tag = null;
    while (it.next()) |t| {
        if (prev) |p| try testing.expect(p.lessThan(t));
        prev = t;
    }
}

test "insert replaces and frees the previous value" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "A");
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "B");
    try testing.expectEqual(@as(usize, 1), ds.len());
    try testing.expectEqualStrings("B", ds.getString(tag_mod.PATIENT_NAME).?);
}

test "value conversions" {
    try testing.expectEqual(@as(?u16, 42), (Value{ .u16_val = 42 }).asU16());
    try testing.expectEqual(@as(?u32, 42), (Value{ .u16_val = 42 }).asU32());
    try testing.expectEqual(@as(?u32, 100_000), (Value{ .u32_val = 100_000 }).asU32());
    try testing.expectEqual(@as(?i32, -5), (Value{ .i32_val = -5 }).asI32());
    try testing.expectEqual(@as(?i32, -3), (Value{ .i16_val = -3 }).asI32());
    try testing.expectEqual(@as(?f64, 2.5), (Value{ .f64_val = 2.5 }).asF64());
    try testing.expectEqual(@as(?u16, 123), (Value{ .str = "123" }).asU16());
    try testing.expectEqual(@as(?f64, 2.5), (Value{ .str = "2.5" }).asF64());
    try testing.expectEqualStrings("hello", (Value{ .str = "hello" }).asStr().?);
}

test "value string helpers" {
    const values = [_][]const u8{ "A", "B" };
    const v = Value{ .strings = &values };
    try testing.expectEqualStrings("A", v.asStr().?);
    try testing.expectEqual(@as(usize, 2), v.asStrings().?.len);
    try testing.expectEqualStrings("B", v.asStrings().?[1]);
}

test "value conversion failures" {
    try testing.expectEqual(@as(?[]const u8, null), (Value{ .bytes = &.{ 1, 2 } }).asStr());
    try testing.expectEqual(@as(?u16, null), (Value{ .str = "abc" }).asU16());
    try testing.expectEqual(@as(?[]const u8, null), (Value{ .u16_val = 5 }).asStr());
}

test "rust-compatible numeric parsing" {
    try testing.expectEqual(@as(?u16, 7), (Value{ .str = " +7\t" }).asU16());
    try testing.expectEqual(@as(?u16, null), (Value{ .str = "-0" }).asU16());
    try testing.expectEqual(@as(?u16, null), (Value{ .str = "1_0" }).asU16());
    try testing.expectEqual(@as(?i32, -2147483648), (Value{ .str = "-2147483648" }).asI32());
    try testing.expectEqual(@as(?f64, null), (Value{ .str = "0x10" }).asF64());
    try testing.expectEqual(@as(?f64, -1024.0), (Value{ .str = "-1024" }).asF64());
    try testing.expectEqual(@as(?u16, null), (Value{ .u32_val = 1 }).asU16());
    try testing.expectEqual(@as(?i32, null), (Value{ .u32_val = 0xFFFF_FFFF }).asI32());
}

test "unicode trim" {
    try testing.expectEqualStrings("x", trimWhitespace("\u{00A0} x\u{3000}\n"));
    try testing.expectEqualStrings("x\x00", trimWhitespace("x\x00"));
    try testing.expectEqualStrings("", trimWhitespace("   "));
}

fn makeFrames(comptime T: type, allocator: Allocator, frames: []const []const T) ![][]T {
    const out = try allocator.alloc([]T, frames.len);
    for (frames, 0..) |f, i| out[i] = try allocator.dupe(T, f);
    return out;
}

test "pixel data native" {
    const a = testing.allocator;
    var pd = try PixelData.initNativeSingle(a, try a.dupe(u16, &.{ 100, 200, 300, 400 }));
    defer pd.deinit(a);
    try testing.expect(!pd.isCompressed());
    try testing.expect(pd.hasFrames());
    try testing.expectEqual(@as(usize, 1), pd.numFrames());
    try testing.expectEqual(@as(usize, 4), pd.frameSize());
    try testing.expectEqual(@as(usize, 4), pd.totalPixels());
    const flat = (try pd.flatData(a)).?;
    defer a.free(flat);
    try testing.expectEqualSlices(u16, &.{ 100, 200, 300, 400 }, flat);
}

test "pixel data native helpers" {
    const a = testing.allocator;
    var pd = PixelData.initNative(try makeFrames(u16, a, &.{ &.{ 1, 2 }, &.{ 3, 4 } }));
    defer pd.deinit(a);

    var out: std.ArrayListUnmanaged(u16) = .empty;
    defer out.deinit(a);
    try testing.expect((try pd.flatDataInto(a, &out)) != null);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4 }, out.items);
    try testing.expectEqual(@as(usize, 2), pd.nativeFrames().?.len);

    var it = pd.iterNativePixels();
    var collected: [4]u16 = undefined;
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) collected[n] = p;
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4 }, &collected);
}

test "pixel data encapsulated" {
    const a = testing.allocator;
    var pd = PixelData.initEncapsulated(
        try makeFrames(u8, a, &.{&.{ 0xFF, 0xD8, 0x01, 0x02 }}),
        try a.dupe(u32, &.{0}),
    );
    defer pd.deinit(a);
    try testing.expect(pd.isCompressed());
    try testing.expect(pd.hasFrames());
    try testing.expectEqual(@as(usize, 0), pd.frameSize());
    try testing.expectEqual(@as(usize, 0), pd.totalPixels());
    try testing.expectEqual(@as(?[]u16, null), try pd.flatData(a));
}

test "pixel data multi frame" {
    const a = testing.allocator;
    var pd = PixelData.initNative(try makeFrames(u16, a, &.{ &.{ 1, 2, 3, 4 }, &.{ 5, 6, 7, 8 } }));
    defer pd.deinit(a);
    try testing.expectEqual(@as(usize, 2), pd.numFrames());
    try testing.expectEqual(@as(usize, 8), pd.totalPixels());
    const flat = (try pd.flatData(a)).?;
    defer a.free(flat);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, flat);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4 }, pd.nativeFrame(0).?);
    try testing.expectEqualSlices(u16, &.{ 5, 6, 7, 8 }, pd.nativeFrame(1).?);
    try testing.expect(pd.nativeFrame(2) == null);
}

test "dataset with pixel data" {
    const a = testing.allocator;
    var ds = Dataset.init(a);
    defer ds.deinit();
    const pd = try PixelData.initNativeSingle(a, try a.dupe(u16, &.{ 10, 20, 30, 40 }));
    try ds.insert(Element.init(tag_mod.PIXEL_DATA, .OW, .{ .pixel_data = pd }));
    const got = ds.pixelData() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), got.numFrames());
    const flat = (try got.flatData(a)).?;
    defer a.free(flat);
    try testing.expectEqualSlices(u16, &.{ 10, 20, 30, 40 }, flat);
}

test "dataset display" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "TEST");
    var buf: [256]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{ds});
    try testing.expect(std.mem.indexOf(u8, s, "Dataset") != null);
    try testing.expect(std.mem.indexOf(u8, s, "1 elements") != null);
}

test "number of frames from string" {
    var ds = Dataset.init(testing.allocator);
    defer ds.deinit();
    try ds.putString(tag_mod.NUMBER_OF_FRAMES, .IS, "10");
    try testing.expectEqual(@as(u32, 10), ds.numberOfFrames());
}

test "dataset get strs for multi value" {
    const a = testing.allocator;
    var ds = Dataset.init(a);
    defer ds.deinit();
    const vals = try a.alloc([]const u8, 2);
    vals[0] = try a.dupe(u8, "ORIGINAL");
    vals[1] = try a.dupe(u8, "PRIMARY");
    try ds.insert(Element.init(tag_mod.IMAGE_TYPE, .CS, .{ .strings = vals }));

    const strs = ds.getStrs(tag_mod.IMAGE_TYPE).?;
    try testing.expectEqual(@as(usize, 2), strs.len);
    try testing.expectEqualStrings("ORIGINAL", strs[0]);
    try testing.expectEqualStrings("PRIMARY", strs[1]);
    try testing.expectEqualStrings("ORIGINAL", ds.getString(tag_mod.IMAGE_TYPE).?);

    try ds.putString(tag_mod.MODALITY, .CS, "CT");
    const single = ds.getStrs(tag_mod.MODALITY).?;
    try testing.expectEqual(@as(usize, 1), single.len);
    try testing.expectEqualStrings("CT", single[0]);
}

test "dataset sequence value" {
    const a = testing.allocator;
    var inner = Dataset.init(a);
    try inner.putString(tag_mod.SOP_CLASS_UID, .UI, "1.2.3");
    const items = try a.alloc(Dataset, 1);
    items[0] = inner;

    var ds = Dataset.init(a);
    defer ds.deinit();
    try ds.insert(Element.init(tag_mod.REFERENCED_IMAGE_SEQUENCE, .SQ, .{ .sequence = items }));

    const elem = ds.get(tag_mod.REFERENCED_IMAGE_SEQUENCE) orelse return error.TestUnexpectedResult;
    switch (elem.value) {
        .sequence => |seq| {
            try testing.expectEqual(@as(usize, 1), seq.len);
            try testing.expectEqualStrings("1.2.3", seq[0].getString(tag_mod.SOP_CLASS_UID).?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "clone and eql are deep" {
    const a = testing.allocator;
    var ds = Dataset.init(a);
    defer ds.deinit();
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "X");
    const items = try a.alloc(Dataset, 1);
    items[0] = Dataset.init(a);
    try items[0].putU16(tag_mod.ROWS, .US, 3);
    try ds.insert(Element.init(tag_mod.REFERENCED_IMAGE_SEQUENCE, .SQ, .{ .sequence = items }));

    var copy = try ds.clone();
    defer copy.deinit();
    try testing.expect(ds.eql(&copy));
    try copy.putString(tag_mod.PATIENT_NAME, .PN, "Y");
    try testing.expect(!ds.eql(&copy));
}
