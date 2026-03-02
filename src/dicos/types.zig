const std = @import("std");
const tag = @import("tag.zig");
const transfer = @import("transfer.zig");
const vr_mod = @import("vr.zig");

const Tag = tag.Tag;
const Vr = vr_mod.Vr;
const TransferSyntax = transfer.TransferSyntax;

/// A typed value stored in a DICOM/DICOS data element.
pub const Value = union(enum) {
    str: []const u8,
    strings: []const []const u8,
    u16_val: u16,
    u16s: []const u16,
    u32_val: u32,
    i16_val: i16,
    i32_val: i32,
    f32_val: f32,
    f64_val: f64,
    f32s: []const f32,
    f64s: []const f64,
    bytes: []const u8,
    sequence: []const Dataset,
    pixel_data: PixelData,

    /// Returns the value as a string if it is `str`.
    pub fn asStr(self: Value) ?[]const u8 {
        return switch (self) {
            .str => |s| s,
            .strings => |values| if (values.len > 0) values[0] else null,
            else => null,
        };
    }

    /// Extracts the value as a u16.
    pub fn asU16(self: Value) ?u16 {
        return switch (self) {
            .u16_val => |v| v,
            .str => |s| std.fmt.parseInt(u16, std.mem.trim(u8, s, " \x00"), 10) catch null,
            else => null,
        };
    }

    /// Extracts the value as a u32.
    pub fn asU32(self: Value) ?u32 {
        return switch (self) {
            .u32_val => |v| v,
            .u16_val => |v| @as(u32, v),
            .str => |s| std.fmt.parseInt(u32, std.mem.trim(u8, s, " \x00"), 10) catch null,
            else => null,
        };
    }

    /// Extracts the value as an i32.
    pub fn asI32(self: Value) ?i32 {
        return switch (self) {
            .i32_val => |v| v,
            .i16_val => |v| @as(i32, v),
            .u16_val => |v| @as(i32, v),
            .u32_val => |v| if (v <= std.math.maxInt(i32)) @as(i32, @intCast(v)) else null,
            .str => |s| std.fmt.parseInt(i32, std.mem.trim(u8, s, " \x00"), 10) catch null,
            else => null,
        };
    }

    /// Extracts the value as an f64.
    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .f64_val => |v| v,
            .f32_val => |v| @as(f64, v),
            .str => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \x00")) catch null,
            else => null,
        };
    }

    /// Free any allocated memory owned by this value.
    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
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
                for (datasets) |*ds| {
                    @constCast(ds).deinit();
                }
                allocator.free(datasets);
            },
            .pixel_data => |*pd| @constCast(pd).deinit(allocator),
            else => {},
        }
    }
};

/// A single DICOM/DICOS data element.
pub const Element = struct {
    tag_val: Tag,
    vr: Vr,
    value: Value,

    pub fn init(t: Tag, v: Vr, val: Value) Element {
        return .{ .tag_val = t, .vr = v, .value = val };
    }
};

/// An ordered collection of DICOM data elements, keyed by Tag.
pub const Dataset = struct {
    const TagMap = std.ArrayHashMap(u32, Element, struct {
        pub fn hash(_: @This(), key: u32) u32 {
            return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)));
        }
        pub fn eql(_: @This(), a: u32, b: u32, _: usize) bool {
            return a == b;
        }
    }, true);

    elements: TagMap,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Dataset {
        return .{
            .elements = TagMap.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Dataset) void {
        var it = self.elements.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.value.deinit(self.allocator);
        }
        self.elements.deinit();
    }

    /// Inserts an element. Replaces any existing element with the same tag.
    pub fn insert(self: *Dataset, elem: Element) !void {
        const key: u32 = @bitCast(elem.tag_val);
        const gop = try self.elements.getOrPut(key);
        if (gop.found_existing) {
            gop.value_ptr.value.deinit(self.allocator);
        }
        gop.value_ptr.* = elem;
    }

    /// Returns a reference to the element with the given tag.
    pub fn get(self: *const Dataset, t: Tag) ?*const Element {
        const key: u32 = @bitCast(t);
        return if (self.elements.getPtr(key)) |ptr| ptr else null;
    }

    /// Removes the element with the given tag.
    pub fn remove(self: *Dataset, t: Tag) bool {
        const key: u32 = @bitCast(t);
        if (self.elements.fetchSwapRemove(key)) |entry| {
            var val = entry.value.value;
            val.deinit(self.allocator);
            return true;
        }
        return false;
    }

    /// Returns `true` if the dataset contains an element with the given tag.
    pub fn contains(self: *const Dataset, t: Tag) bool {
        return self.get(t) != null;
    }

    /// Returns the number of elements.
    pub fn len(self: *const Dataset) usize {
        return self.elements.count();
    }

    /// Returns `true` if the dataset has no elements.
    pub fn isEmpty(self: *const Dataset) bool {
        return self.elements.count() == 0;
    }

    /// Returns a string value for the given tag.
    pub fn getString(self: *const Dataset, t: Tag) ?[]const u8 {
        const elem = self.get(t) orelse return null;
        return elem.value.asStr();
    }

    /// Returns a u16 value for the given tag.
    pub fn getU16(self: *const Dataset, t: Tag) ?u16 {
        const elem = self.get(t) orelse return null;
        return elem.value.asU16();
    }

    /// Returns a u32 value for the given tag.
    pub fn getU32(self: *const Dataset, t: Tag) ?u32 {
        const elem = self.get(t) orelse return null;
        return elem.value.asU32();
    }

    /// Returns an i32 value for the given tag.
    pub fn getI32(self: *const Dataset, t: Tag) ?i32 {
        const elem = self.get(t) orelse return null;
        return elem.value.asI32();
    }

    /// Returns an f64 value for the given tag.
    pub fn getF64(self: *const Dataset, t: Tag) ?f64 {
        const elem = self.get(t) orelse return null;
        return elem.value.asF64();
    }

    // Convenience helpers
    pub fn rows(self: *const Dataset) u16 {
        return self.getU16(tag.ROWS) orelse 0;
    }

    pub fn columns(self: *const Dataset) u16 {
        return self.getU16(tag.COLUMNS) orelse 0;
    }

    pub fn bitsAllocated(self: *const Dataset) u16 {
        return self.getU16(tag.BITS_ALLOCATED) orelse 16;
    }

    pub fn pixelRepresentation(self: *const Dataset) u16 {
        return self.getU16(tag.PIXEL_REPRESENTATION) orelse 0;
    }

    pub fn numberOfFrames(self: *const Dataset) u32 {
        if (self.get(tag.NUMBER_OF_FRAMES)) |elem| {
            if (elem.value.asU32()) |v| return v;
            if (elem.value.asStr()) |s| {
                return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \x00"), 10) catch 1;
            }
        }
        return 1;
    }

    pub fn modality(self: *const Dataset) []const u8 {
        return self.getString(tag.MODALITY) orelse "";
    }

    pub fn transferSyntax(self: *const Dataset) TransferSyntax {
        if (self.getString(tag.TRANSFER_SYNTAX_UID)) |s| {
            return TransferSyntax.init(std.mem.trim(u8, s, " \x00"));
        }
        return TransferSyntax.init(transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    }

    pub fn isEncapsulated(self: *const Dataset) bool {
        return self.transferSyntax().isEncapsulated();
    }

    pub fn pixelData(self: *const Dataset) ?*const PixelData {
        const elem = self.get(tag.PIXEL_DATA) orelse return null;
        return switch (elem.value) {
            .pixel_data => |*pd| pd,
            else => null,
        };
    }

    /// Convenience: insert a string element.
    pub fn putString(self: *Dataset, t: Tag, vr: Vr, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        try self.insert(Element.init(t, vr, .{ .str = owned }));
    }

    /// Convenience: insert a u16 element.
    pub fn putU16(self: *Dataset, t: Tag, vr: Vr, value: u16) !void {
        try self.insert(Element.init(t, vr, .{ .u16_val = value }));
    }

    /// Convenience: insert a u32 element.
    pub fn putU32(self: *Dataset, t: Tag, vr: Vr, value: u32) !void {
        try self.insert(Element.init(t, vr, .{ .u32_val = value }));
    }
};

/// Pixel data with support for both native and encapsulated formats.
pub const PixelData = struct {
    is_encapsulated: bool,
    frames: []Frame,
    offsets: []u32,
    allocator: std.mem.Allocator,

    pub fn nativeSingle(allocator: std.mem.Allocator, data: []u16) !PixelData {
        const frames = try allocator.alloc(Frame, 1);
        frames[0] = .{
            .data = data,
            .compressed_data = &.{},
        };
        return .{
            .is_encapsulated = false,
            .frames = frames,
            .offsets = &.{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PixelData, allocator: std.mem.Allocator) void {
        for (self.frames) |frame| {
            if (frame.data.len > 0) allocator.free(frame.data);
            if (frame.compressed_data.len > 0) allocator.free(frame.compressed_data);
        }
        if (self.frames.len > 0) allocator.free(self.frames);
        if (self.offsets.len > 0) allocator.free(self.offsets);
    }

    pub fn numFrames(self: PixelData) usize {
        return self.frames.len;
    }

    pub fn isCompressed(self: PixelData) bool {
        return self.is_encapsulated;
    }

    pub fn hasFrames(self: PixelData) bool {
        return self.frames.len > 0;
    }

    pub fn totalPixels(self: PixelData) usize {
        if (self.is_encapsulated) return 0;
        var total: usize = 0;
        for (self.frames) |frame| {
            total += frame.data.len;
        }
        return total;
    }

    /// Returns all native frames concatenated.
    pub fn flatData(self: PixelData, allocator: std.mem.Allocator) !?[]u16 {
        if (self.is_encapsulated) return null;
        const total = self.totalPixels();
        const result = try allocator.alloc(u16, total);
        var offset: usize = 0;
        for (self.frames) |frame| {
            @memcpy(result[offset .. offset + frame.data.len], frame.data);
            offset += frame.data.len;
        }
        return result;
    }
};

/// A single frame of pixel data.
pub const Frame = struct {
    data: []u16,
    compressed_data: []const u8,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "dataset insert and get" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();

    try ds.putString(tag.PATIENT_NAME, .PN, "DOE^JOHN");
    try ds.putU16(tag.ROWS, .US, 512);

    try std.testing.expectEqual(@as(usize, 2), ds.len());
    try std.testing.expect(!ds.isEmpty());
    try std.testing.expectEqualStrings("DOE^JOHN", ds.getString(tag.PATIENT_NAME).?);
    try std.testing.expectEqual(@as(u16, 512), ds.rows());
}

test "dataset remove" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();

    try ds.putU16(tag.ROWS, .US, 256);
    try std.testing.expect(ds.contains(tag.ROWS));
    try std.testing.expect(ds.remove(tag.ROWS));
    try std.testing.expect(!ds.contains(tag.ROWS));
    try std.testing.expect(ds.isEmpty());
}

test "dataset defaults" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();

    try std.testing.expectEqual(@as(u16, 0), ds.rows());
    try std.testing.expectEqual(@as(u16, 0), ds.columns());
    try std.testing.expectEqual(@as(u16, 16), ds.bitsAllocated());
    try std.testing.expectEqual(@as(u16, 0), ds.pixelRepresentation());
    try std.testing.expectEqual(@as(u32, 1), ds.numberOfFrames());
    try std.testing.expectEqualStrings("", ds.modality());
}

test "dataset transfer syntax" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();

    try std.testing.expectEqualStrings(
        transfer.EXPLICIT_VR_LITTLE_ENDIAN,
        ds.transferSyntax().getUid(),
    );

    try ds.putString(tag.TRANSFER_SYNTAX_UID, .UI, transfer.JPEG_LS_LOSSLESS);
    try std.testing.expect(ds.isEncapsulated());
    try std.testing.expect(ds.transferSyntax().isJpegLs());
}

test "value conversions" {
    try std.testing.expectEqual(@as(?u16, 42), (Value{ .u16_val = 42 }).asU16());
    try std.testing.expectEqual(@as(?u32, 42), (Value{ .u16_val = 42 }).asU32());
    try std.testing.expectEqual(@as(?u32, 100_000), (Value{ .u32_val = 100_000 }).asU32());
    try std.testing.expectEqual(@as(?i32, -5), (Value{ .i32_val = -5 }).asI32());
    try std.testing.expectEqual(@as(?i32, -3), (Value{ .i16_val = -3 }).asI32());
}
