//! Port of Rust `reader/tests.rs`.

const std = @import("std");
const reader = @import("../reader.zig");
const tag = @import("../tag.zig");
const transfer = @import("../transfer.zig");
const types = @import("../types.zig");
const err_mod = @import("../error.zig");
const tu = @import("test_util.zig");

const testing = std.testing;
const Element = types.Element;
const Dataset = types.Dataset;
const Diagnostic = err_mod.Diagnostic;
const a = testing.allocator;

fn parseSlice(data: []const u8) !Dataset {
    var fr = std.Io.Reader.fixed(data);
    return reader.parse(a, &fr);
}

fn parseWarn(data: []const u8) !reader.ParseResult {
    var fr = std.Io.Reader.fixed(data);
    return reader.parseWithWarnings(a, &fr);
}

fn parseDiag(data: []const u8, diag: *Diagnostic) !Dataset {
    var fr = std.Io.Reader.fixed(data);
    const res = try reader.parseWithOptions(a, &fr, .{ .diagnostic = diag });
    a.free(res.warnings);
    return res.dataset;
}

fn el(t: tag.Tag, vr: @import("../vr.zig").Vr, v: types.Value) Element {
    return Element.init(t, vr, v);
}

test "parse minimal explicit vr le" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.PATIENT_NAME, .PN, .{ .str = "DOE^JOHN" }),
        el(tag.ROWS, .US, .{ .u16_val = 512 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 256 }),
        el(tag.BITS_ALLOCATED, .US, .{ .u16_val = 16 }),
    });
    defer file.deinit(a);
    var ds = try parseSlice(file.items);
    defer ds.deinit();

    try testing.expectEqualStrings("DOE^JOHN", ds.getString(tag.PATIENT_NAME).?);
    try testing.expectEqual(@as(?u16, 512), ds.rows());
    try testing.expectEqual(@as(?u16, 256), ds.columns());
    try testing.expectEqual(@as(?u16, 16), ds.bitsAllocated());
    try testing.expectEqualStrings(transfer.EXPLICIT_VR_LITTLE_ENDIAN, ds.transferSyntax().uid);
}

test "parse detects missing magic" {
    var buf = [_]u8{0} ** 132;
    @memcpy(buf[128..], "XXXX");
    var diag: Diagnostic = .{};
    try testing.expectError(error.BadPreamble, parseDiag(&buf, &diag));
    try testing.expect(diag.detail == .bad_preamble);
}

test "parse too short" {
    const buf = [_]u8{0} ** 50;
    try testing.expectError(error.BadPreamble, parseSlice(&buf));
}

test "parse numeric types" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 1024 }),
        el(tag.RESCALE_INTERCEPT, .DS, .{ .str = "-1024" }),
        el(tag.RESCALE_SLOPE, .DS, .{ .str = "1.0" }),
    });
    defer file.deinit(a);
    var ds = try parseSlice(file.items);
    defer ds.deinit();
    try testing.expectEqual(@as(?u16, 1024), ds.rows());
    try testing.expectEqual(@as(?f64, -1024.0), ds.getF64(tag.RESCALE_INTERCEPT));
}

test "parse multivalue string vr" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.IMAGE_TYPE, .CS, .{ .str = "ORIGINAL\\PRIMARY" }),
    });
    defer file.deinit(a);
    var ds = try parseSlice(file.items);
    defer ds.deinit();
    const e = ds.get(tag.IMAGE_TYPE) orelse return error.TestUnexpectedResult;
    switch (e.value) {
        .strings => |values| {
            try testing.expectEqual(@as(usize, 2), values.len);
            try testing.expectEqualStrings("ORIGINAL", values[0]);
            try testing.expectEqualStrings("PRIMARY", values[1]);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqualStrings("ORIGINAL", ds.getString(tag.IMAGE_TYPE).?);
}

test "parse rejects big endian transfer syntax" {
    var file = try tu.buildMinimalDicosWithTs(a, transfer.EXPLICIT_VR_BIG_ENDIAN);
    defer file.deinit(a);
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnsupportedTransferSyntax, parseDiag(file.items, &diag));
    try testing.expectEqualStrings(transfer.EXPLICIT_VR_BIG_ENDIAN, diag.detail.unsupported_transfer_syntax.slice());
}

test "parse without transfer syntax defaults to implicit vr le" {
    var file = try tu.buildDicosWithoutTransferSyntax(a);
    defer file.deinit(a);
    var ds = try parseSlice(file.items);
    defer ds.deinit();
    try testing.expectEqualStrings(transfer.IMPLICIT_VR_LITTLE_ENDIAN, ds.transferSyntax().uid);
    try testing.expectEqual(@as(?u16, 64), ds.rows());
}

// -- Integration tests against real DICOS files --

test "parse real bag ct sample" {
    const data = (try tu.readTestdata(a, "bag_ct.dcs")) orelse return;
    defer a.free(data);
    var ds = try parseSlice(data);
    defer ds.deinit();

    try testing.expect((ds.rows() orelse 0) > 0);
    try testing.expect((ds.columns() orelse 0) > 0);
    try testing.expect((ds.bitsAllocated() orelse 0) > 0);
    try testing.expect(ds.get(tag.PIXEL_DATA) != null);
    try testing.expectEqualStrings("CT", ds.modality());
    try testing.expectEqualStrings("1.2.840.10008.5.1.4.1.1.2", ds.getString(tag.SOP_CLASS_UID).?);
    try testing.expect(ds.numberOfFrames() >= 1);
    try testing.expect(ds.transferSyntax().uid.len > 0);
}

test "parse with native pixel data" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
        el(tag.BITS_ALLOCATED, .US, .{ .u16_val = 16 }),
        el(tag.PIXEL_DATA, .OW, .{ .bytes = &.{ 100, 0, 200, 0, 0x2C, 1, 0x90, 1 } }),
    });
    defer file.deinit(a);
    var ds = try parseSlice(file.items);
    defer ds.deinit();
    try testing.expectEqual(@as(?u16, 2), ds.rows());
    try testing.expectEqual(@as(?u16, 2), ds.columns());
    const pd = ds.pixelData() orelse return error.TestUnexpectedResult;
    const frames = pd.nativeFrames() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), frames.len);
    try testing.expectEqualSlices(u16, &.{ 100, 200, 300, 400 }, frames[0]);
}

// -----------------------------------------------------------------------
// Fixed-length SQ parsing tests (issue #3)
// -----------------------------------------------------------------------

test "parse fixed length sq valid item" {
    const inner = try tu.encodeExplicitElem(a, el(tag.ROWS, .US, .{ .u16_val = 128 }));
    defer a.free(inner);
    const item = try tu.buildSqItem(a, inner);
    defer a.free(item);
    const sq = try tu.buildFixedSq(a, tag.REFERENCED_IMAGE_SEQUENCE, item);
    defer a.free(sq);

    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    try file.appendSlice(a, sq);

    var ds = try parseSlice(file.items);
    defer ds.deinit();
    const e = ds.get(tag.REFERENCED_IMAGE_SEQUENCE) orelse return error.TestUnexpectedResult;
    const items = e.value.sequence;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqual(@as(?u16, 128), items[0].rows());
}

test "parse fixed length sq item length exceeds buffer returns error" {
    var items: tu.Bytes = .empty;
    defer items.deinit(a);
    try tu.appendU16(a, &items, 0xFFFE);
    try tu.appendU16(a, &items, 0xE000);
    try tu.appendU32(a, &items, 64); // claims 64 bytes
    try items.appendSlice(a, &.{ 0x00, 0x08, 0x60, 0x00 }); // only 4 present
    const sq = try tu.buildFixedSq(a, tag.REFERENCED_IMAGE_SEQUENCE, items.items);
    defer a.free(sq);

    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    try file.appendSlice(a, sq);
    var diag: Diagnostic = .{};
    try testing.expectError(error.LengthExceedsBuffer, parseDiag(file.items, &diag));
    try testing.expectEqual(@as(usize, 64), diag.detail.length_exceeds_buffer.length);
    try testing.expectEqual(@as(usize, 4), diag.detail.length_exceeds_buffer.remaining);
}

test "parse fixed length sq empty item is valid" {
    const item = try tu.buildSqItem(a, &.{});
    defer a.free(item);
    const sq = try tu.buildFixedSq(a, tag.REFERENCED_IMAGE_SEQUENCE, item);
    defer a.free(sq);
    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    try file.appendSlice(a, sq);

    var ds = try parseSlice(file.items);
    defer ds.deinit();
    const items = ds.get(tag.REFERENCED_IMAGE_SEQUENCE).?.value.sequence;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expect(items[0].isEmpty());
}

// -----------------------------------------------------------------------
// Nesting-depth guard (stack-overflow DoS protection)
// -----------------------------------------------------------------------

fn nestedPayload(levels: usize) ![]u8 {
    var payload: []u8 = try a.alloc(u8, 0);
    for (0..levels) |_| {
        const next = try tu.wrapUndefinedLengthSq(a, payload);
        a.free(payload);
        payload = next;
    }
    return payload;
}

test "parse rejects excessive sequence nesting" {
    const payload = try nestedPayload(reader.MAX_NESTING_DEPTH + 16);
    defer a.free(payload);
    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    try file.appendSlice(a, payload);
    var diag: Diagnostic = .{};
    try testing.expectError(error.NestingTooDeep, parseDiag(file.items, &diag));
    try testing.expectEqual(reader.MAX_NESTING_DEPTH, diag.detail.nesting_too_deep.max);
}

test "parse accepts nesting within limit" {
    const payload = try nestedPayload(reader.MAX_NESTING_DEPTH - 1);
    defer a.free(payload);
    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    try file.appendSlice(a, payload);
    var ds = try parseSlice(file.items);
    defer ds.deinit();
    try testing.expect(ds.get(tag.REFERENCED_IMAGE_SEQUENCE) != null);
}

// -----------------------------------------------------------------------
// Truncation semantics
// -----------------------------------------------------------------------

test "clean eof at boundary vs partial header" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
    });
    defer file.deinit(a);

    var at_magic = try parseSlice(file.items[0..132]);
    defer at_magic.deinit();
    try testing.expect(at_magic.isEmpty());

    var diag: Diagnostic = .{};
    try testing.expectError(error.Truncated, parseDiag(file.items[0..133], &diag));
    try testing.expectEqual(@as(u64, 132), diag.detail.truncated.offset);
}

test "truncation at every prefix never panics or silently matches" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.PATIENT_NAME, .PN, .{ .str = "DOE^JOHN" }),
        el(tag.ROWS, .US, .{ .u16_val = 4 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 4 }),
        el(tag.BITS_ALLOCATED, .US, .{ .u16_val = 16 }),
    });
    defer file.deinit(a);
    const full_len = blk: {
        var ds = try parseSlice(file.items);
        defer ds.deinit();
        break :blk ds.len();
    };

    for (0..file.items.len) |i| {
        if (parseSlice(file.items[0..i])) |ds_const| {
            var ds = ds_const;
            defer ds.deinit();
            try testing.expect(ds.len() < full_len);
        } else |e| switch (e) {
            error.Truncated, error.IoError, error.BadPreamble => {},
            else => return e,
        }
    }
    var ds = try parseSlice(file.items);
    defer ds.deinit();
    try testing.expectEqual(full_len, ds.len());
}

// -----------------------------------------------------------------------
// Parse warnings
// -----------------------------------------------------------------------

fn hasWarning(ws: []const reader.ParseWarning, w: reader.ParseWarning) bool {
    for (ws) |x| if (x.eql(w)) return true;
    return false;
}

test "parse with warnings reports odd pixel length" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
        el(tag.PIXEL_DATA, .OW, .{ .bytes = &.{ 1, 0, 2, 0, 3 } }),
    });
    defer file.deinit(a);
    var res = try parseWarn(file.items);
    defer res.deinit();
    try testing.expect(res.dataset.pixelData() != null);
    try testing.expect(hasWarning(res.warnings, .{ .odd_pixel_data_length = .{ .length = 5 } }));
}

test "parse with warnings reports pixel count mismatch" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
        el(tag.PIXEL_DATA, .OW, .{ .bytes = &.{ 1, 0, 2, 0 } }),
    });
    defer file.deinit(a);
    var res = try parseWarn(file.items);
    defer res.deinit();
    try testing.expect(hasWarning(res.warnings, .{ .pixel_count_mismatch = .{ .actual = 2, .expected = 4 } }));
}

test "parse without warnings still succeeds on clean file" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
        el(tag.BITS_ALLOCATED, .US, .{ .u16_val = 16 }),
        el(tag.PIXEL_DATA, .OW, .{ .bytes = &.{ 1, 0, 2, 0, 3, 0, 4, 0 } }),
    });
    defer file.deinit(a);
    var res = try parseWarn(file.items);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), res.warnings.len);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4 }, res.dataset.pixelData().?.nativeFrames().?[0]);
}

// ---------------------------------------------------------------------------
// Adversarial-review robustness / correctness regression tests
// ---------------------------------------------------------------------------

test "encapsulated bot length bomb is rejected without huge alloc" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
    });
    defer file.deinit(a);
    try tu.pushEncapsulatedPixelDataHeader(a, &file);
    try tu.appendU16(a, &file, 0xFFFE);
    try tu.appendU16(a, &file, 0xE000);
    try tu.appendU32(a, &file, 0xFFFF_FFFC); // ~4 GB BOT, no body

    // std.testing.allocator would surface a huge allocation as a failure in
    // a capped environment; the reservation is capped at BOT_RESERVE_CAP.
    try testing.expectError(error.Truncated, parseSlice(file.items));
}

test "encapsulated multi fragment frame uses offset table" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
    });
    defer file.deinit(a);
    const frag0 = [_]u8{ 0xAA, 0xBB };
    const frag1 = [_]u8{ 0xCC, 0xDD, 0xEE, 0xFF };
    const frag2 = [_]u8{ 0x11, 0x22 };
    const frame1_offset: u32 = (8 + frag0.len) + (8 + frag1.len);

    try tu.pushEncapsulatedPixelDataHeader(a, &file);
    try tu.pushBasicOffsetTable(a, &file, &.{ 0, frame1_offset });
    try tu.pushPixelFragment(a, &file, &frag0);
    try tu.pushPixelFragment(a, &file, &frag1);
    try tu.pushPixelFragment(a, &file, &frag2);
    try tu.pushSequenceDelimitation(a, &file);

    var ds = try parseSlice(file.items);
    defer ds.deinit();
    const pd = ds.pixelData().?;
    try testing.expectEqual(@as(usize, 2), pd.numFrames());
    try testing.expectEqualSlices(u8, &(frag0 ++ frag1), pd.encapsulatedFrame(0).?);
    try testing.expectEqualSlices(u8, &frag2, pd.encapsulatedFrame(1).?);
    try testing.expectEqualSlices(u32, &.{ 0, frame1_offset }, pd.offsets());
}

test "encapsulated empty bot is one fragment per frame" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
    });
    defer file.deinit(a);
    try tu.pushEncapsulatedPixelDataHeader(a, &file);
    try tu.pushBasicOffsetTable(a, &file, &.{});
    try tu.pushPixelFragment(a, &file, &.{ 0x01, 0x02 });
    try tu.pushPixelFragment(a, &file, &.{ 0x03, 0x04 });
    try tu.pushSequenceDelimitation(a, &file);

    var ds = try parseSlice(file.items);
    defer ds.deinit();
    const pd = ds.pixelData().?;
    try testing.expectEqual(@as(usize, 2), pd.numFrames());
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, pd.encapsulatedFrame(0).?);
    try testing.expectEqualSlices(u8, &.{ 0x03, 0x04 }, pd.encapsulatedFrame(1).?);
}

test "native 8bit pixel data is one sample per byte" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
        el(tag.BITS_ALLOCATED, .US, .{ .u16_val = 8 }),
        el(tag.PIXEL_DATA, .OB, .{ .bytes = &.{ 10, 20, 30, 40 } }),
    });
    defer file.deinit(a);
    var res = try parseWarn(file.items);
    defer res.deinit();
    try testing.expectEqual(@as(usize, 0), res.warnings.len);
    try testing.expectEqualSlices(u16, &.{ 10, 20, 30, 40 }, res.dataset.pixelData().?.nativeFrame(0).?);
}

test "native missing bits allocated warns" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
        el(tag.PIXEL_DATA, .OW, .{ .bytes = &.{ 1, 0, 2, 0, 3, 0, 4, 0 } }),
    });
    defer file.deinit(a);
    var res = try parseWarn(file.items);
    defer res.deinit();
    try testing.expect(hasWarning(res.warnings, .bits_allocated_missing));
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4 }, res.dataset.pixelData().?.nativeFrame(0).?);
}

// ---------------------------------------------------------------------------
// Zig-port hardening tests (no Rust counterpart)
// ---------------------------------------------------------------------------

test "element length above the limit is rejected before allocating" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    // (0009,0010) OB with a 0xFFFF_FFF0 length and no body.
    try tu.appendU16(a, &file, 0x0009);
    try tu.appendU16(a, &file, 0x0010);
    try file.appendSlice(a, "OB\x00\x00");
    try tu.appendU32(a, &file, 0xFFFF_FFF0);
    var fr = std.Io.Reader.fixed(file.items);
    var diag: Diagnostic = .{};
    try testing.expectError(error.LengthExceedsLimit, reader.parseWithOptions(a, &fr, .{
        .max_element_bytes = 1 << 20,
        .diagnostic = &diag,
    }));
    try testing.expectEqual(@as(usize, 0xFFFF_FFF0), diag.detail.length_exceeds_limit.length);
}

test "lying element length within the limit fails as truncated" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    try tu.appendU16(a, &file, 0x0009);
    try tu.appendU16(a, &file, 0x0010);
    try file.appendSlice(a, "OB\x00\x00");
    try tu.appendU32(a, &file, 0x3FFF_FFF0); // ~1 GB claimed, 3 bytes present
    try file.appendSlice(a, "abc");
    try testing.expectError(error.Truncated, parseSlice(file.items));
}

test "overlapping bot windows cannot amplify memory" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    try tu.pushEncapsulatedPixelDataHeader(a, &file);
    // Alternating [0, 100) windows would duplicate fragment 0 repeatedly.
    try tu.pushBasicOffsetTable(a, &file, &.{ 0, 100, 0, 100, 0, 100 });
    try tu.pushPixelFragment(a, &file, &.{ 1, 2, 3, 4 });
    try tu.pushSequenceDelimitation(a, &file);
    try testing.expectError(error.InvalidFile, parseSlice(file.items));
}

test "invalid utf8 is decoded lossily" {
    const out = try reader.utf8Lossy(a, "a\xffb\xe2\x82");
    defer a.free(out);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}", out);
}

test "unexpected item tag in undefined length sequence" {
    var file = try tu.buildMinimalExplicitVrLe(a, &.{});
    defer file.deinit(a);
    const t = tag.REFERENCED_IMAGE_SEQUENCE;
    try tu.appendU16(a, &file, t.group);
    try tu.appendU16(a, &file, t.element);
    try file.appendSlice(a, "SQ\x00\x00");
    try tu.appendU32(a, &file, reader.UNDEFINED_LENGTH);
    try tu.appendU16(a, &file, 0x0008); // not an Item tag
    try tu.appendU16(a, &file, 0x0060);
    try tu.appendU32(a, &file, 0);
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnexpectedTag, parseDiag(file.items, &diag));
    try testing.expectEqualStrings("sequence item", diag.detail.unexpected_tag.context);
}

test "fuzz-style random inputs never leak or crash" {
    var prng = std.Random.DefaultPrng.init(0xD1C05);
    const rnd = prng.random();
    var base = try tu.buildMinimalExplicitVrLe(a, &.{
        el(tag.PATIENT_NAME, .PN, .{ .str = "DOE^JOHN" }),
        el(tag.ROWS, .US, .{ .u16_val = 2 }),
        el(tag.COLUMNS, .US, .{ .u16_val = 2 }),
        el(tag.PIXEL_DATA, .OW, .{ .bytes = &.{ 1, 0, 2, 0, 3, 0, 4, 0 } }),
    });
    defer base.deinit(a);
    const buf = try a.dupe(u8, base.items);
    defer a.free(buf);
    for (0..2000) |_| {
        @memcpy(buf, base.items);
        const flips = rnd.intRangeAtMost(usize, 1, 8);
        for (0..flips) |_| buf[rnd.intRangeLessThan(usize, 132, buf.len)] = rnd.int(u8);
        const cut = rnd.intRangeAtMost(usize, 0, buf.len);
        var fr = std.Io.Reader.fixed(buf[0..cut]);
        if (reader.parseWithWarningsAndLimit(a, &fr, 1 << 20)) |res_const| {
            var res = res_const;
            res.deinit();
        } else |_| {}
    }
}
