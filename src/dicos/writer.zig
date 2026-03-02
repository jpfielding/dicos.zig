const std = @import("std");
const tag_mod = @import("tag.zig");
const transfer_mod = @import("transfer.zig");
const types = @import("types.zig");
const vr_mod = @import("vr.zig");

const Tag = tag_mod.Tag;
const Vr = vr_mod.Vr;
const Dataset = types.Dataset;
const Element = types.Element;
const Value = types.Value;
const PixelData = types.PixelData;
const ArrayList = std.array_list.AlignedManaged;

// ---------------------------------------------------------------------------
// Helper: append a little/big-endian integer to a managed ArrayList(u8)
// ---------------------------------------------------------------------------

fn appendInt(buf: *ArrayList(u8, null), comptime T: type, val: T, comptime endian: std.builtin.Endian) !void {
    const bytes = std.mem.toBytes(if (endian == .little) val else std.mem.nativeToBig(T, val));
    try buf.appendSlice(&bytes);
}

/// Writes a dataset in DICOM Part-10 file format into the given buffer.
pub fn write(allocator: std.mem.Allocator, ds: *const Dataset, out: *ArrayList(u8, null)) !u64 {
    return writePart10(allocator, ds, out);
}

/// Writes a dataset in DICOM Part-10 file format with normalized File Meta Information.
fn writePart10(allocator: std.mem.Allocator, ds: *const Dataset, out: *ArrayList(u8, null)) !u64 {
    var count: u64 = 0;

    // 1. Preamble (128 zeros)
    try out.appendNTimes(0, 128);
    count += 128;

    // 2. DICM magic
    try out.appendSlice("DICM");
    count += 4;

    // 3. Collect group-0002 elements (except group length)
    var meta_elements = ArrayList(Element, null).init(allocator);
    defer meta_elements.deinit();

    var has_ts = false;
    var iter = ds.elements.iterator();
    while (iter.next()) |entry| {
        const elem = entry.value_ptr;
        if (elem.tag_val.group == 0x0002) {
            if (@as(u32, @bitCast(elem.tag_val)) != @as(u32, @bitCast(tag_mod.FILE_META_INFORMATION_GROUP_LENGTH))) {
                try meta_elements.append(elem.*);
                if (@as(u32, @bitCast(elem.tag_val)) == @as(u32, @bitCast(tag_mod.TRANSFER_SYNTAX_UID))) {
                    has_ts = true;
                }
            }
        }
    }

    if (!has_ts) {
        // Insert default TS -- use a static string so no allocation needed
        try meta_elements.append(Element.init(
            tag_mod.TRANSFER_SYNTAX_UID,
            .UI,
            .{ .str = transfer_mod.EXPLICIT_VR_LITTLE_ENDIAN },
        ));
    }

    // Sort by tag
    std.mem.sort(Element, meta_elements.items, {}, struct {
        fn lessThan(_: void, a: Element, b: Element) bool {
            return @as(u32, @bitCast(a.tag_val)) < @as(u32, @bitCast(b.tag_val));
        }
    }.lessThan);

    // Encode meta elements to compute group length
    var meta_buf = ArrayList(u8, null).init(allocator);
    defer meta_buf.deinit();
    for (meta_elements.items) |elem| {
        try writeElement(allocator, &elem, &meta_buf);
    }

    // Write (0002,0000) group length
    const gl_elem = Element.init(tag_mod.FILE_META_INFORMATION_GROUP_LENGTH, .UL, .{ .u32_val = @intCast(meta_buf.items.len) });
    count += try writeElementCounted(allocator, &gl_elem, out);

    // Write meta elements
    try out.appendSlice(meta_buf.items);
    count += meta_buf.items.len;

    // 4. Write all non-group-0002 elements in tag order
    // Collect and sort keys
    var keys = ArrayList(u32, null).init(allocator);
    defer keys.deinit();

    var iter2 = ds.elements.iterator();
    while (iter2.next()) |entry| {
        const elem = entry.value_ptr;
        if (elem.tag_val.group != 0x0002) {
            try keys.append(@bitCast(elem.tag_val));
        }
    }
    std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));

    for (keys.items) |key| {
        if (ds.elements.getPtr(key)) |elem| {
            count += try writeElementCounted(allocator, elem, out);
        }
    }

    return count;
}

fn writeElement(allocator: std.mem.Allocator, elem: *const Element, out: *ArrayList(u8, null)) anyerror!void {
    _ = try writeElementCounted(allocator, elem, out);
}

fn writeElementCounted(allocator: std.mem.Allocator, elem: *const Element, out: *ArrayList(u8, null)) !u64 {
    var count: u64 = 0;

    // Tag
    try appendInt(out, u16, elem.tag_val.group, .little);
    try appendInt(out, u16, elem.tag_val.element, .little);
    count += 4;

    // VR
    const vr_bytes = elem.vr.asBytes();
    try out.appendSlice(&vr_bytes);
    count += 2;

    // Encode value
    var val_buf = ArrayList(u8, null).init(allocator);
    defer val_buf.deinit();
    const is_undefined_length = try encodeValue(allocator, &elem.value, elem.vr, &val_buf);

    // Length
    if (elem.vr.isLongVr()) {
        try out.appendSlice(&[_]u8{ 0, 0 });
        count += 2;
        const length: u32 = if (is_undefined_length) 0xFFFF_FFFF else @intCast(val_buf.items.len);
        try appendInt(out, u32, length, .little);
        count += 4;
    } else {
        try appendInt(out, u16, @intCast(val_buf.items.len), .little);
        count += 2;
    }

    // Value bytes
    try out.appendSlice(val_buf.items);
    count += val_buf.items.len;

    return count;
}

fn encodeValue(allocator: std.mem.Allocator, value: *const Value, vr: Vr, buf: *ArrayList(u8, null)) !bool {
    switch (value.*) {
        .str => |s| {
            try buf.appendSlice(s);
            if (s.len % 2 != 0) {
                if (vr == .UI) try buf.append(0) else try buf.append(' ');
            }
            return false;
        },
        .strings => |values| {
            for (values, 0..) |s, i| {
                if (i > 0) try buf.append('\\');
                try buf.appendSlice(s);
            }
            if (buf.items.len % 2 != 0) {
                if (vr == .UI) try buf.append(0) else try buf.append(' ');
            }
            return false;
        },
        .u16_val => |v| {
            try appendInt(buf, u16, v, .little);
            return false;
        },
        .u16s => |values| {
            for (values) |v| try appendInt(buf, u16, v, .little);
            return false;
        },
        .u32_val => |v| {
            try appendInt(buf, u32, v, .little);
            return false;
        },
        .i16_val => |v| {
            try appendInt(buf, i16, v, .little);
            return false;
        },
        .i32_val => |v| {
            try appendInt(buf, i32, v, .little);
            return false;
        },
        .f32_val => |v| {
            try appendInt(buf, u32, @bitCast(v), .little);
            return false;
        },
        .f64_val => |v| {
            try appendInt(buf, u64, @bitCast(v), .little);
            return false;
        },
        .f32s => |values| {
            for (values) |v| try appendInt(buf, u32, @bitCast(v), .little);
            return false;
        },
        .f64s => |values| {
            for (values) |v| try appendInt(buf, u64, @bitCast(v), .little);
            return false;
        },
        .bytes => |data| {
            try buf.appendSlice(data);
            return false;
        },
        .sequence => |datasets| {
            try encodeSequence(allocator, datasets, buf);
            return true; // Sequences use undefined length
        },
        .pixel_data => |pd| {
            if (pd.is_encapsulated) {
                try encodeEncapsulatedPixelData(&pd, buf);
                return true;
            } else {
                encodeNativePixelData(&pd, buf) catch {};
                return false;
            }
        },
    }
}

fn encodeSequence(allocator: std.mem.Allocator, datasets: []const Dataset, buf: *ArrayList(u8, null)) !void {
    for (datasets) |*ds| {
        // Item tag
        try appendInt(buf, u16, 0xFFFE, .little);
        try appendInt(buf, u16, 0xE000, .little);

        // Encode item body
        var item_buf = ArrayList(u8, null).init(allocator);
        defer item_buf.deinit();

        var iter = ds.elements.iterator();
        while (iter.next()) |entry| {
            try writeElement(allocator, entry.value_ptr, &item_buf);
        }

        // Item length
        try appendInt(buf, u32, @intCast(item_buf.items.len), .little);
        try buf.appendSlice(item_buf.items);
    }

    // Sequence Delimitation Item
    try appendInt(buf, u16, 0xFFFE, .little);
    try appendInt(buf, u16, 0xE0DD, .little);
    try appendInt(buf, u32, 0, .little);
}

fn encodeNativePixelData(pd: *const PixelData, buf: *ArrayList(u8, null)) !void {
    for (pd.frames) |frame| {
        for (frame.data) |pixel| {
            try appendInt(buf, u16, pixel, .little);
        }
    }
}

fn encodeEncapsulatedPixelData(pd: *const PixelData, buf: *ArrayList(u8, null)) !void {
    // Basic Offset Table item
    try appendInt(buf, u16, 0xFFFE, .little);
    try appendInt(buf, u16, 0xE000, .little);
    const bot_len: u32 = @intCast(pd.offsets.len * 4);
    try appendInt(buf, u32, bot_len, .little);
    for (pd.offsets) |offset| {
        try appendInt(buf, u32, offset, .little);
    }

    // Frame items
    for (pd.frames) |frame| {
        try appendInt(buf, u16, 0xFFFE, .little);
        try appendInt(buf, u16, 0xE000, .little);
        try appendInt(buf, u32, @intCast(frame.compressed_data.len), .little);
        try buf.appendSlice(frame.compressed_data);
    }

    // Sequence Delimitation Item
    try appendInt(buf, u16, 0xFFFE, .little);
    try appendInt(buf, u16, 0xE0DD, .little);
    try appendInt(buf, u32, 0, .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const reader = @import("reader.zig");

fn roundtrip(allocator: std.mem.Allocator, ds: *const Dataset) !Dataset {
    var buf = ArrayList(u8, null).init(allocator);
    defer buf.deinit();
    _ = try write(allocator, ds, &buf);
    return reader.parseBytes(allocator, buf.items);
}

test "write injects transfer syntax when missing" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "DOE^ALICE");

    var rt = try roundtrip(allocator, &ds);
    defer rt.deinit();
    try std.testing.expectEqualStrings(
        transfer_mod.EXPLICIT_VR_LITTLE_ENDIAN,
        rt.getString(tag_mod.TRANSFER_SYNTAX_UID).?,
    );
}

test "roundtrip string elements" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();

    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer_mod.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putString(tag_mod.PATIENT_NAME, .PN, "SMITH^ALICE");
    try ds.putString(tag_mod.PATIENT_ID, .LO, "12345");
    try ds.putString(tag_mod.MODALITY, .CS, "DX");

    var rt = try roundtrip(allocator, &ds);
    defer rt.deinit();

    try std.testing.expectEqualStrings("SMITH^ALICE", rt.getString(tag_mod.PATIENT_NAME).?);
    try std.testing.expectEqualStrings("12345", rt.getString(tag_mod.PATIENT_ID).?);
    try std.testing.expectEqualStrings("DX", rt.modality());
}

test "roundtrip numeric elements" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();

    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer_mod.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putU16(tag_mod.ROWS, .US, 512);
    try ds.putU16(tag_mod.COLUMNS, .US, 256);
    try ds.putU16(tag_mod.BITS_ALLOCATED, .US, 16);

    var rt = try roundtrip(allocator, &ds);
    defer rt.deinit();

    try std.testing.expectEqual(@as(u16, 512), rt.rows());
    try std.testing.expectEqual(@as(u16, 256), rt.columns());
    try std.testing.expectEqual(@as(u16, 16), rt.bitsAllocated());
}

test "write produces valid preamble and magic" {
    const allocator = std.testing.allocator;
    var ds = Dataset.init(allocator);
    defer ds.deinit();
    try ds.putString(tag_mod.TRANSFER_SYNTAX_UID, .UI, transfer_mod.EXPLICIT_VR_LITTLE_ENDIAN);

    var buf = ArrayList(u8, null).init(allocator);
    defer buf.deinit();
    _ = try write(allocator, &ds, &buf);

    // First 128 bytes should be zero
    for (buf.items[0..128]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
    // Followed by DICM
    try std.testing.expectEqualStrings("DICM", buf.items[128..132]);
}
