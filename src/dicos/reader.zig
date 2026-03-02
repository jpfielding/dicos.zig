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
const Frame = types.Frame;
const PixelData = types.PixelData;
const ArrayList = std.array_list.AlignedManaged;

const DICM_MAGIC = "DICM";
const UNDEFINED_LENGTH: u32 = 0xFFFF_FFFF;

// ---------------------------------------------------------------------------
// SliceReader -- replacement for std.io.fixedBufferStream(...).reader()
// ---------------------------------------------------------------------------

/// A simple reader over a byte slice, providing the interface expected by
/// DicosReader (readNoEof, readInt, skipBytes).
const SliceReader = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) SliceReader {
        return .{ .data = data, .pos = 0 };
    }

    fn readNoEof(self: *SliceReader, buf: []u8) !void {
        if (self.pos + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.pos .. self.pos + buf.len]);
        self.pos += buf.len;
    }

    fn readInt(self: *SliceReader, comptime T: type, comptime endian: std.builtin.Endian) !T {
        const byte_count = @divExact(@typeInfo(T).int.bits, 8);
        if (self.pos + byte_count > self.data.len) return error.EndOfStream;
        const bytes = self.data[self.pos..][0..byte_count];
        self.pos += byte_count;
        return std.mem.readInt(T, bytes, endian);
    }

    fn skipBytes(self: *SliceReader, n: anytype, _: anytype) !void {
        const count: usize = @intCast(n);
        if (self.pos + count > self.data.len) return error.EndOfStream;
        self.pos += count;
    }
};

/// Parses a DICOS/DICOM file from any reader.
pub fn parse(allocator: std.mem.Allocator, source: anytype) !Dataset {
    var rdr = DicosReader(@TypeOf(source)){
        .inner = source,
        .explicit_vr = true,
        .transfer_syntax_uid = null,
        .in_meta = true,
        .allocator = allocator,
    };
    return rdr.readDataset();
}

/// Parses a DICOS file from a byte slice.
pub fn parseBytes(allocator: std.mem.Allocator, data: []const u8) !Dataset {
    var sr = SliceReader.init(data);
    return parse(allocator, &sr);
}

fn DicosReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        inner: ReaderType,
        explicit_vr: bool,
        transfer_syntax_uid: ?[]const u8,
        in_meta: bool,
        allocator: std.mem.Allocator,

        fn readDataset(self: *Self) !Dataset {
            var ds = Dataset.init(self.allocator);
            errdefer ds.deinit();

            // 1. Read 128-byte preamble
            var preamble: [128]u8 = undefined;
            self.inner.readNoEof(&preamble) catch return error.InvalidFile;

            // 2. Read "DICM" magic
            var magic: [4]u8 = undefined;
            self.inner.readNoEof(&magic) catch return error.InvalidFile;
            if (!std.mem.eql(u8, &magic, DICM_MAGIC)) return error.InvalidFile;

            // 3. Group 0002 is always Explicit VR LE
            self.explicit_vr = true;
            self.in_meta = true;

            // 4. Read elements
            while (true) {
                const t = self.readTag() catch break;

                // Transition out of group 0002
                if (t.group != 0x0002 and self.in_meta) {
                    self.in_meta = false;
                    if (self.transfer_syntax_uid == null) {
                        self.transfer_syntax_uid = transfer_mod.IMPLICIT_VR_LITTLE_ENDIAN;
                    }
                    self.updateTransferSyntax();
                }

                const elem = try self.readElementWithTag(t);

                // Capture TransferSyntaxUID
                if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.TRANSFER_SYNTAX_UID))) {
                    if (elem.value.asStr()) |s| {
                        self.transfer_syntax_uid = std.mem.trim(u8, s, " \x00");
                    }
                }

                try ds.insert(elem);
            }

            return ds;
        }

        fn readTag(self: *Self) !Tag {
            const group = try self.inner.readInt(u16, .little);
            const element = try self.inner.readInt(u16, .little);
            return Tag.init(group, element);
        }

        fn readElementWithTag(self: *Self, t: Tag) anyerror!Element {
            // Sequence delimiters always have implicit structure
            if (t.group == 0xFFFE) {
                const len = try self.inner.readInt(u32, .little);
                const value = if (len > 0 and len != UNDEFINED_LENGTH) blk: {
                    const buf = try self.allocator.alloc(u8, len);
                    errdefer self.allocator.free(buf);
                    try self.inner.readNoEof(buf);
                    break :blk Value{ .bytes = buf };
                } else Value{ .bytes = &.{} };
                return Element.init(t, .UN, value);
            }

            const vr_vl = if (self.explicit_vr)
                try self.readExplicitVrHeader()
            else
                try self.readImplicitVrHeader(t);

            const vr = vr_vl.vr;
            const vl = vr_vl.vl;

            const value = try self.readValue(t, vr, vl);
            return Element.init(t, vr, value);
        }

        const VrHeader = struct { vr: Vr, vl: u32 };

        fn readExplicitVrHeader(self: *Self) !VrHeader {
            var vr_buf: [2]u8 = undefined;
            try self.inner.readNoEof(&vr_buf);
            const vr = Vr.fromBytes(&vr_buf) orelse .UN;

            const vl = if (vr.isLongVr()) blk: {
                var reserved: [2]u8 = undefined;
                try self.inner.readNoEof(&reserved);
                break :blk try self.inner.readInt(u32, .little);
            } else @as(u32, try self.inner.readInt(u16, .little));

            return .{ .vr = vr, .vl = vl };
        }

        fn readImplicitVrHeader(self: *Self, t: Tag) !VrHeader {
            const vl = try self.inner.readInt(u32, .little);
            const vr = implicitVrForTag(t);
            return .{ .vr = vr, .vl = vl };
        }

        fn readValue(self: *Self, t: Tag, vr: Vr, vl: u32) !Value {
            if (vl == UNDEFINED_LENGTH) {
                return self.readUndefinedLengthValue(t, vr);
            }

            const data = try self.allocator.alloc(u8, vl);
            errdefer self.allocator.free(data);
            try self.inner.readNoEof(data);

            return parseValue(self.allocator, vr, data);
        }

        fn readUndefinedLengthValue(self: *Self, t: Tag, vr: Vr) !Value {
            if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.PIXEL_DATA))) {
                const pd = try self.readEncapsulatedPixelData();
                return Value{ .pixel_data = pd };
            }

            if (vr == .SQ) {
                const items = try self.readSequenceItems();
                return Value{ .sequence = items };
            }

            try self.skipUndefinedLength();
            return Value{ .bytes = &.{} };
        }

        fn readSequenceItems(self: *Self) ![]const Dataset {
            var items = ArrayList(Dataset, null).init(self.allocator);
            errdefer {
                for (items.items) |*item| item.deinit();
                items.deinit();
            }

            while (true) {
                const item_tag = try self.readTag();
                const item_len = try self.inner.readInt(u32, .little);

                if (@as(u32, @bitCast(item_tag)) == @as(u32, @bitCast(tag_mod.SEQUENCE_DELIMITATION_ITEM))) break;
                if (@as(u32, @bitCast(item_tag)) != @as(u32, @bitCast(tag_mod.ITEM))) return error.InvalidFile;

                const item_ds = if (item_len == UNDEFINED_LENGTH)
                    try self.readItemUndefinedLength()
                else
                    try self.readItemFixedLength(item_len);

                try items.append(item_ds);
            }

            return items.toOwnedSlice();
        }

        fn readItemUndefinedLength(self: *Self) !Dataset {
            var ds = Dataset.init(self.allocator);
            errdefer ds.deinit();

            while (true) {
                const elem_tag = try self.readTag();
                if (@as(u32, @bitCast(elem_tag)) == @as(u32, @bitCast(tag_mod.ITEM_DELIMITATION_ITEM))) {
                    _ = try self.inner.readInt(u32, .little);
                    break;
                }
                const elem = try self.readElementWithTag(elem_tag);
                try ds.insert(elem);
            }

            return ds;
        }

        fn readItemFixedLength(self: *Self, len: u32) !Dataset {
            const buf = try self.allocator.alloc(u8, len);
            defer self.allocator.free(buf);
            try self.inner.readNoEof(buf);

            var sr = SliceReader.init(buf);
            var sub_reader = DicosReader(*SliceReader){
                .inner = &sr,
                .explicit_vr = self.explicit_vr,
                .transfer_syntax_uid = self.transfer_syntax_uid,
                .in_meta = false,
                .allocator = self.allocator,
            };

            var ds = Dataset.init(self.allocator);
            errdefer ds.deinit();

            while (true) {
                const t = sub_reader.readTag() catch break;
                const elem = try sub_reader.readElementWithTag(t);
                try ds.insert(elem);
            }

            return ds;
        }

        fn readEncapsulatedPixelData(self: *Self) !PixelData {
            var frames_list = ArrayList(Frame, null).init(self.allocator);
            errdefer {
                for (frames_list.items) |frame| {
                    if (frame.compressed_data.len > 0) self.allocator.free(frame.compressed_data);
                }
                frames_list.deinit();
            }
            var offsets_list = ArrayList(u32, null).init(self.allocator);
            errdefer offsets_list.deinit();

            // Read Basic Offset Table
            const bot_tag = try self.readTag();
            if (@as(u32, @bitCast(bot_tag)) != @as(u32, @bitCast(tag_mod.ITEM))) return error.InvalidFile;

            const bot_len = try self.inner.readInt(u32, .little);
            if (bot_len > 0) {
                const num_offsets = bot_len / 4;
                var i: u32 = 0;
                while (i < num_offsets) : (i += 1) {
                    try offsets_list.append(try self.inner.readInt(u32, .little));
                }
            }

            // Read frames
            while (true) {
                const item_tag = try self.readTag();

                if (@as(u32, @bitCast(item_tag)) == @as(u32, @bitCast(tag_mod.SEQUENCE_DELIMITATION_ITEM))) {
                    _ = try self.inner.readInt(u32, .little);
                    break;
                }

                if (@as(u32, @bitCast(item_tag)) != @as(u32, @bitCast(tag_mod.ITEM))) return error.InvalidFile;

                const item_len = try self.inner.readInt(u32, .little);
                const frame_data = try self.allocator.alloc(u8, item_len);
                errdefer self.allocator.free(frame_data);
                try self.inner.readNoEof(frame_data);

                try frames_list.append(.{
                    .data = &.{},
                    .compressed_data = frame_data,
                });
            }

            return PixelData{
                .is_encapsulated = true,
                .frames = try frames_list.toOwnedSlice(),
                .offsets = try offsets_list.toOwnedSlice(),
                .allocator = self.allocator,
            };
        }

        fn skipUndefinedLength(self: *Self) !void {
            while (true) {
                const item_tag = try self.readTag();

                if (item_tag.group == 0xFFFE) {
                    const len = try self.inner.readInt(u32, .little);
                    if (@as(u32, @bitCast(item_tag)) == @as(u32, @bitCast(tag_mod.SEQUENCE_DELIMITATION_ITEM))) return;
                    if (@as(u32, @bitCast(item_tag)) == @as(u32, @bitCast(tag_mod.ITEM_DELIMITATION_ITEM))) continue;
                    if (len != UNDEFINED_LENGTH and len > 0) {
                        try self.inner.skipBytes(len, .{});
                    } else if (len == UNDEFINED_LENGTH) {
                        try self.skipUndefinedLength();
                    }
                    continue;
                }

                // Regular element -- skip it
                if (self.explicit_vr) {
                    var vr_buf: [2]u8 = undefined;
                    try self.inner.readNoEof(&vr_buf);
                    const vr = Vr.fromBytes(&vr_buf) orelse .UN;
                    const vl = if (vr.isLongVr()) blk: {
                        try self.inner.skipBytes(2, .{});
                        break :blk try self.inner.readInt(u32, .little);
                    } else @as(u32, try self.inner.readInt(u16, .little));

                    if (vl != UNDEFINED_LENGTH and vl > 0) {
                        try self.inner.skipBytes(vl, .{});
                    } else if (vl == UNDEFINED_LENGTH) {
                        try self.skipUndefinedLength();
                    }
                } else {
                    const vl = try self.inner.readInt(u32, .little);
                    if (vl != UNDEFINED_LENGTH and vl > 0) {
                        try self.inner.skipBytes(vl, .{});
                    } else if (vl == UNDEFINED_LENGTH) {
                        try self.skipUndefinedLength();
                    }
                }
            }
        }

        fn updateTransferSyntax(self: *Self) void {
            if (self.transfer_syntax_uid) |uid| {
                self.explicit_vr = !std.mem.eql(u8, uid, transfer_mod.IMPLICIT_VR_LITTLE_ENDIAN);
            }
        }
    };
}

/// Infers a VR for a tag when reading Implicit VR transfer syntax.
fn implicitVrForTag(t: Tag) Vr {
    if (t.group == 0x0002) return .UL;
    if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.PIXEL_DATA))) return .OW;
    if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.ROWS)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.COLUMNS)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.BITS_ALLOCATED)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.BITS_STORED)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.HIGH_BIT)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.PIXEL_REPRESENTATION)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.SAMPLES_PER_PIXEL)))
        return .US;
    if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.NUMBER_OF_FRAMES))) return .IS;
    if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.PIXEL_SPACING)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.WINDOW_CENTER)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.WINDOW_WIDTH)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.RESCALE_INTERCEPT)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.RESCALE_SLOPE)))
        return .DS;
    if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.RESCALE_TYPE)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.PHOTOMETRIC_INTERPRETATION)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.MODALITY)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.IMAGE_TYPE)))
        return .CS;
    if (@as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.SOP_CLASS_UID)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.SOP_INSTANCE_UID)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.STUDY_INSTANCE_UID)) or
        @as(u32, @bitCast(t)) == @as(u32, @bitCast(tag_mod.SERIES_INSTANCE_UID)))
        return .UI;
    return .UN;
}

/// Parses raw bytes into a typed Value based on VR.
fn parseValue(allocator: std.mem.Allocator, vr: Vr, data: []const u8) !Value {
    switch (vr) {
        .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC, .UI, .UR, .UT => {
            // String types -- trim trailing nulls and spaces
            var end: usize = data.len;
            while (end > 0 and (data[end - 1] == 0 or data[end - 1] == ' ')) end -= 1;
            const trimmed = data[0..end];

            // Check for multi-valued string (backslash-separated)
            if (std.mem.indexOfScalar(u8, trimmed, '\\') != null) {
                var parts = ArrayList([]const u8, null).init(allocator);
                errdefer {
                    for (parts.items) |s| allocator.free(s);
                    parts.deinit();
                }
                var it = std.mem.splitScalar(u8, trimmed, '\\');
                while (it.next()) |part| {
                    try parts.append(try allocator.dupe(u8, part));
                }
                allocator.free(data);
                return Value{ .strings = try parts.toOwnedSlice() };
            }

            // Copy the trimmed string, then free the original
            const owned = try allocator.dupe(u8, trimmed);
            allocator.free(data);
            return Value{ .str = owned };
        },
        .US => {
            defer allocator.free(data);
            if (data.len == 2) {
                return Value{ .u16_val = std.mem.readInt(u16, data[0..2], .little) };
            } else if (data.len >= 4 and data.len % 2 == 0) {
                const count = data.len / 2;
                const values = try allocator.alloc(u16, count);
                for (0..count) |i| {
                    values[i] = std.mem.readInt(u16, data[i * 2 ..][0..2], .little);
                }
                return Value{ .u16s = values };
            }
            return Value{ .bytes = try allocator.dupe(u8, data) };
        },
        .UL => {
            defer allocator.free(data);
            if (data.len == 4) {
                return Value{ .u32_val = std.mem.readInt(u32, data[0..4], .little) };
            }
            return Value{ .bytes = try allocator.dupe(u8, data) };
        },
        .SS => {
            defer allocator.free(data);
            if (data.len == 2) {
                return Value{ .i16_val = @bitCast(std.mem.readInt(u16, data[0..2], .little)) };
            }
            return Value{ .bytes = try allocator.dupe(u8, data) };
        },
        .SL => {
            defer allocator.free(data);
            if (data.len == 4) {
                return Value{ .i32_val = @bitCast(std.mem.readInt(u32, data[0..4], .little)) };
            }
            return Value{ .bytes = try allocator.dupe(u8, data) };
        },
        .FL => {
            defer allocator.free(data);
            if (data.len == 4) {
                return Value{ .f32_val = @bitCast(std.mem.readInt(u32, data[0..4], .little)) };
            } else if (data.len >= 8 and data.len % 4 == 0) {
                const count = data.len / 4;
                const values = try allocator.alloc(f32, count);
                for (0..count) |i| {
                    values[i] = @bitCast(std.mem.readInt(u32, data[i * 4 ..][0..4], .little));
                }
                return Value{ .f32s = values };
            }
            return Value{ .bytes = try allocator.dupe(u8, data) };
        },
        .FD => {
            defer allocator.free(data);
            if (data.len == 8) {
                return Value{ .f64_val = @bitCast(std.mem.readInt(u64, data[0..8], .little)) };
            } else if (data.len >= 16 and data.len % 8 == 0) {
                const count = data.len / 8;
                const values = try allocator.alloc(f64, count);
                for (0..count) |i| {
                    values[i] = @bitCast(std.mem.readInt(u64, data[i * 8 ..][0..8], .little));
                }
                return Value{ .f64s = values };
            }
            return Value{ .bytes = try allocator.dupe(u8, data) };
        },
        .SQ => {
            defer allocator.free(data);
            if (data.len == 0) return Value{ .sequence = &.{} };
            // Fixed-length SQ parsing could be done here but for simplicity
            // treat as empty sequence
            return Value{ .sequence = &.{} };
        },
        else => {
            // Binary / Unknown -- keep raw bytes (already allocated)
            return Value{ .bytes = data };
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
/// Append a little-endian or big-endian integer to a Managed ArrayList(u8).
fn appendInt(buf: *ArrayList(u8, null), comptime T: type, val: T, comptime endian: std.builtin.Endian) !void {
    const bytes = std.mem.toBytes(if (endian == .little) val else std.mem.nativeToBig(T, val));
    try buf.appendSlice(&bytes);
}

fn buildMinimalExplicitVrLe(allocator: std.mem.Allocator, elements: []const Element) ![]u8 {
    var buf = ArrayList(u8, null).init(allocator);
    errdefer buf.deinit();

    // Preamble
    try buf.appendNTimes(0, 128);
    // DICM magic
    try buf.appendSlice("DICM");

    // TransferSyntaxUID
    const ts = transfer_mod.EXPLICIT_VR_LITTLE_ENDIAN;
    const ts_padded_len: u16 = if (ts.len % 2 == 0) @intCast(ts.len) else @intCast(ts.len + 1);

    // Compute meta length (TS element size)
    const meta_len: u32 = 4 + 2 + 2 + ts_padded_len; // tag + VR + len + value

    // (0002,0000) UL 4 <meta_len>
    try appendInt(&buf, u16, 0x0002, .little);
    try appendInt(&buf, u16, 0x0000, .little);
    try buf.appendSlice("UL");
    try appendInt(&buf, u16, 4, .little);
    try appendInt(&buf, u32, meta_len, .little);

    // (0002,0010) UI <len> <value>
    try appendInt(&buf, u16, 0x0002, .little);
    try appendInt(&buf, u16, 0x0010, .little);
    try buf.appendSlice("UI");
    try appendInt(&buf, u16, ts_padded_len, .little);
    try buf.appendSlice(ts);
    if (ts.len % 2 != 0) try buf.append(' ');

    // Dataset elements
    for (elements) |elem| {
        try writeTestElement(&buf, &elem);
    }

    return buf.toOwnedSlice();
}

fn writeTestElement(buf: *ArrayList(u8, null), elem: *const Element) !void {
    try appendInt(buf, u16, elem.tag_val.group, .little);
    try appendInt(buf, u16, elem.tag_val.element, .little);
    const vr_bytes = elem.vr.asBytes();
    try buf.appendSlice(&vr_bytes);

    const val_bytes = try encodeTestValue(buf.allocator, &elem.value);
    defer buf.allocator.free(val_bytes);

    if (elem.vr.isLongVr()) {
        try buf.appendSlice(&[_]u8{ 0, 0 });
        try appendInt(buf, u32, @intCast(val_bytes.len), .little);
    } else {
        try appendInt(buf, u16, @intCast(val_bytes.len), .little);
    }
    try buf.appendSlice(val_bytes);
}

fn encodeTestValue(allocator: std.mem.Allocator, value: *const Value) ![]u8 {
    switch (value.*) {
        .str => |s| {
            var b = try allocator.alloc(u8, if (s.len % 2 != 0) s.len + 1 else s.len);
            @memcpy(b[0..s.len], s);
            if (s.len % 2 != 0) b[s.len] = ' ';
            return b;
        },
        .u16_val => |v| {
            const b = try allocator.alloc(u8, 2);
            std.mem.writeInt(u16, b[0..2], v, .little);
            return b;
        },
        .u32_val => |v| {
            const b = try allocator.alloc(u8, 4);
            std.mem.writeInt(u32, b[0..4], v, .little);
            return b;
        },
        .bytes => |b| return allocator.dupe(u8, b),
        else => return allocator.alloc(u8, 0),
    }
}

test "parse minimal explicit vr le" {
    const allocator = std.testing.allocator;
    const elements = [_]Element{
        Element.init(tag_mod.PATIENT_NAME, .PN, .{ .str = "DOE^JOHN" }),
        Element.init(tag_mod.ROWS, .US, .{ .u16_val = 512 }),
        Element.init(tag_mod.COLUMNS, .US, .{ .u16_val = 256 }),
        Element.init(tag_mod.BITS_ALLOCATED, .US, .{ .u16_val = 16 }),
    };

    const file_data = try buildMinimalExplicitVrLe(allocator, &elements);
    defer allocator.free(file_data);

    var ds = try parseBytes(allocator, file_data);
    defer ds.deinit();

    try std.testing.expectEqualStrings("DOE^JOHN", ds.getString(tag_mod.PATIENT_NAME).?);
    try std.testing.expectEqual(@as(u16, 512), ds.rows());
    try std.testing.expectEqual(@as(u16, 256), ds.columns());
    try std.testing.expectEqual(@as(u16, 16), ds.bitsAllocated());
}

test "parse detects missing magic" {
    const allocator = std.testing.allocator;
    var buf: [132]u8 = undefined;
    @memset(&buf, 0);
    buf[128] = 'X';
    buf[129] = 'X';
    buf[130] = 'X';
    buf[131] = 'X';
    const result = parseBytes(allocator, &buf);
    try std.testing.expectError(error.InvalidFile, result);
}

test "parse too short" {
    const allocator = std.testing.allocator;
    var buf: [50]u8 = undefined;
    @memset(&buf, 0);
    const result = parseBytes(allocator, &buf);
    try std.testing.expectError(error.InvalidFile, result);
}
