//! Port of Rust `tests/synthetic_luggage_example.rs`: checks against the
//! curated `testdata/bag_ct.dcs` sample. Every test skips when the file is
//! absent.

const std = @import("std");
const dicos = @import("../root.zig");
const tu = @import("../reader/test_util.zig");

const tag = dicos.tag;
const testing = std.testing;
const a = testing.allocator;

fn parseDs() !?dicos.Dataset {
    const data = (try tu.readTestdata(a, "bag_ct.dcs")) orelse return null;
    defer a.free(data);
    return try dicos.parseBytes(a, data);
}

fn firstString(ds: *const dicos.Dataset, t: dicos.Tag) []const u8 {
    return ds.getString(t) orelse "";
}

test "bag ct sample is ct" {
    var ds = (try parseDs()) orelse return;
    defer ds.deinit();
    try testing.expectEqualStrings("1.2.840.10008.5.1.4.1.1.2", firstString(&ds, tag.SOP_CLASS_UID));
    try testing.expectEqualStrings("CT", firstString(&ds, tag.MODALITY));
    try testing.expectEqualStrings("1.2.840.10008.1.2.1", firstString(&ds, tag.TRANSFER_SYNTAX_UID));
    try testing.expect((ds.rows() orelse 0) > 0);
    try testing.expect((ds.columns() orelse 0) > 0);
    try testing.expect(ds.numberOfFrames() >= 1);
}

test "bag ct sample is public safe" {
    var ds = (try parseDs()) orelse return;
    defer ds.deinit();
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(a);
    for (ds.iter(), 0..) |*e, i| {
        const s = e.value.asStr() orelse continue;
        if (i > 0) try joined.append(a, ' ');
        for (s) |c| try joined.append(a, std.ascii.toLower(c));
    }
    try testing.expect(std.mem.indexOf(u8, joined.items, "clearscan") == null);
    try testing.expect(std.mem.indexOf(u8, joined.items, "cct1218") == null);
    try testing.expectEqualStrings("BAG-CT-001", firstString(&ds, tag.PATIENT_ID));
}

test "bag ct sample has non uniform pixel data" {
    var ds = (try parseDs()) orelse return;
    defer ds.deinit();
    const rows: usize = ds.rows() orelse return error.TestUnexpectedResult;
    const cols: usize = ds.columns() orelse return error.TestUnexpectedResult;
    const frames: usize = ds.numberOfFrames();

    const pd = ds.pixelData() orelse return error.TestUnexpectedResult;
    const native_frames = pd.nativeFrames() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(rows * cols * frames, pd.totalPixels());

    var min: u16 = std.math.maxInt(u16);
    var max: u16 = 0;
    for (native_frames) |f| for (f) |v| {
        min = @min(min, v);
        max = @max(max, v);
    };
    try testing.expect(max > min);
}
