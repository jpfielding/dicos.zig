//! Property-based round-trip tests for the DICOS writer/reader pair.
//!
//! Port of Rust `tests/roundtrip_prop.rs`, with deterministic `std.Random`
//! generators (fixed seeds) in place of proptest. Each property runs 100
//! cases.
//!
//! A naive `parse(write(ds)) == ds` does not hold: the writer injects a
//! TransferSyntaxUID and (re)writes the group length; the reader trims string
//! padding, splits backslash strings, decodes US/UL, and rebuilds native
//! pixel frames from geometry. The properties asserted are therefore:
//!
//! 1. every element of an already-normalized dataset survives one cycle;
//! 2. `parse(write(.))` is a fixed point at the dataset level;
//! 3. re-encoding a normalized dataset is byte-stable;
//! 4. multi-frame native pixel values are preserved exactly.

const std = @import("std");
const dicos = @import("../root.zig");

const tag = dicos.tag;
const Dataset = dicos.Dataset;
const Element = dicos.Element;
const PixelData = dicos.PixelData;
const testing = std.testing;
const a = testing.allocator;
const Random = std.Random;

const CASES = 100;

fn toBytes(ds: *const Dataset) ![]u8 {
    return dicos.writer.writeToBytes(a, ds, .{});
}

fn roundtrip(ds: *const Dataset) !Dataset {
    const bytes = try toBytes(ds);
    defer a.free(bytes);
    return dicos.parseBytes(a, bytes);
}

// --- Value generators, all producing already-normalized forms ---------------

fn genFromCharset(r: Random, buf: *std.ArrayListUnmanaged(u8), charset: []const u8, min: usize, max: usize) !void {
    const n = r.intRangeAtMost(usize, min, max);
    for (0..n) |_| try buf.append(a, charset[r.uintLessThan(usize, charset.len)]);
}

const text_charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789^._-";
const digits = "0123456789";

/// `[A-Za-z0-9^._-]{1,8}`
fn arbText(r: Random) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try genFromCharset(r, &buf, text_charset, 1, 8);
    return buf.toOwnedSlice(a);
}

/// `[0-9]{1,3}(\.[0-9]{1,3}){1,4}`
fn arbUid(r: Random) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    try genFromCharset(r, &buf, digits, 1, 3);
    for (0..r.intRangeAtMost(usize, 1, 4)) |_| {
        try buf.append(a, '.');
        try genFromCharset(r, &buf, digits, 1, 3);
    }
    return buf.toOwnedSlice(a);
}

/// `-?[0-9]{1,4}(\.[0-9]{1,3})?`
fn arbDecimal(r: Random) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    if (r.boolean()) try buf.append(a, '-');
    try genFromCharset(r, &buf, digits, 1, 4);
    if (r.boolean()) {
        try buf.append(a, '.');
        try genFromCharset(r, &buf, digits, 1, 3);
    }
    return buf.toOwnedSlice(a);
}

// --- Element and dataset generators -----------------------------------------

/// Scalar elements on distinct known tags, each independently present.
fn arbScalars(r: Random, ds: *Dataset) !void {
    if (r.boolean()) try ds.insert(Element.init(tag.PATIENT_NAME, .PN, .{ .str = try arbText(r) }));
    if (r.boolean()) try ds.insert(Element.init(tag.PATIENT_ID, .LO, .{ .str = try arbText(r) }));
    if (r.boolean()) try ds.insert(Element.init(tag.STUDY_DESCRIPTION, .LO, .{ .str = try arbText(r) }));
    if (r.boolean()) try ds.insert(Element.init(tag.SOP_CLASS_UID, .UI, .{ .str = try arbUid(r) }));
    if (r.boolean()) try ds.insert(Element.init(tag.RESCALE_INTERCEPT, .DS, .{ .str = try arbDecimal(r) }));
    if (r.boolean()) try ds.insert(Element.init(tag.RESCALE_SLOPE, .DS, .{ .str = try arbDecimal(r) }));
    if (r.boolean()) try ds.putU16(tag.BITS_ALLOCATED, .US, r.int(u16));
    if (r.boolean()) try ds.putU32(tag.NUMBER_OF_ALARM_OBJECTS, .UL, r.int(u32));
    if (r.boolean()) {
        // 2+ values guarantee a backslash so the reader keeps `strings`.
        const n = r.intRangeAtMost(usize, 2, 3);
        const items = try a.alloc([]const u8, n);
        var made: usize = 0;
        errdefer {
            for (items[0..made]) |s| a.free(s);
            a.free(items);
        }
        while (made < n) : (made += 1) items[made] = try arbText(r);
        try ds.insert(Element.init(tag.IMAGE_TYPE, .CS, .{ .strings = items }));
    }
}

const Pixels = struct { rows: u16, cols: u16, frames: usize };

fn arbGeometry(r: Random) Pixels {
    return .{
        .rows = r.intRangeAtMost(u16, 1, 4),
        .cols = r.intRangeAtMost(u16, 1, 4),
        .frames = r.intRangeAtMost(usize, 1, 2),
    };
}

/// Self-consistent native pixel frames for `g`.
fn arbFrames(r: Random, g: Pixels) ![][]u16 {
    const fp = @as(usize, g.rows) * g.cols;
    const frames = try a.alloc([]u16, g.frames);
    var made: usize = 0;
    errdefer {
        for (frames[0..made]) |f| a.free(f);
        a.free(frames);
    }
    while (made < g.frames) : (made += 1) {
        frames[made] = try a.alloc(u16, fp);
        for (frames[made]) |*p| p.* = r.int(u16);
    }
    return frames;
}

fn putGeometry(ds: *Dataset, g: Pixels) !void {
    try ds.putU16(tag.ROWS, .US, g.rows);
    try ds.putU16(tag.COLUMNS, .US, g.cols);
    if (g.frames > 1) {
        var buf: [20]u8 = undefined;
        try ds.putString(tag.NUMBER_OF_FRAMES, .IS, try std.fmt.bufPrint(&buf, "{d}", .{g.frames}));
    }
}

/// A full dataset: scalars, optional native pixels, optional one-level
/// sequence of 1-2 scalar-only items.
fn arbDataset(r: Random) !Dataset {
    var ds = Dataset.init(a);
    errdefer ds.deinit();
    try arbScalars(r, &ds);

    if (r.boolean()) {
        const g = arbGeometry(r);
        try putGeometry(&ds, g);
        // Pin 16 so a random scalar BitsAllocated cannot disagree with the
        // 16-bit samples.
        try ds.putU16(tag.BITS_ALLOCATED, .US, 16);
        try ds.insert(Element.init(tag.PIXEL_DATA, .OW, .{ .pixel_data = PixelData.initNative(try arbFrames(r, g)) }));
    }

    if (r.boolean()) {
        const n = r.intRangeAtMost(usize, 1, 2);
        const items = try a.alloc(Dataset, n);
        var made: usize = 0;
        errdefer {
            for (items[0..made]) |*d| d.deinit();
            a.free(items);
        }
        while (made < n) : (made += 1) {
            items[made] = Dataset.init(a);
            arbScalars(r, &items[made]) catch |e| {
                items[made].deinit();
                return e;
            };
        }
        try ds.insert(Element.init(tag.REFERENCED_IMAGE_SEQUENCE, .SQ, .{ .sequence = items }));
    }
    return ds;
}

fn printCase(case: usize, ds: *const Dataset) void {
    std.debug.print("failing case {d}:\n{f}", .{ case, ds.* });
}

test "roundtrip preserves every element" {
    var prng = Random.DefaultPrng.init(0x5EED_0001);
    for (0..CASES) |case| {
        var ds = try arbDataset(prng.random());
        defer ds.deinit();
        var rt = try roundtrip(&ds);
        defer rt.deinit();
        for (ds.iter()) |*e| {
            const got = rt.get(e.tag) orelse {
                printCase(case, &ds);
                return error.TestUnexpectedResult;
            };
            if (!got.eql(e)) {
                printCase(case, &ds);
                std.debug.print("element {f} did not survive the round trip\n", .{e.tag});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "parsed dataset is a fixed point" {
    var prng = Random.DefaultPrng.init(0x5EED_0002);
    for (0..CASES) |case| {
        var ds = try arbDataset(prng.random());
        defer ds.deinit();
        var once = try roundtrip(&ds);
        defer once.deinit();
        var twice = try roundtrip(&once);
        defer twice.deinit();
        if (!once.eql(&twice)) {
            printCase(case, &ds);
            return error.TestUnexpectedResult;
        }
    }
}

test "rewrite is byte stable" {
    var prng = Random.DefaultPrng.init(0x5EED_0003);
    for (0..CASES) |case| {
        var ds = try arbDataset(prng.random());
        defer ds.deinit();
        var normalized = try roundtrip(&ds);
        defer normalized.deinit();
        const bytes_a = try toBytes(&normalized);
        defer a.free(bytes_a);
        var reparsed = try dicos.parseBytes(a, bytes_a);
        defer reparsed.deinit();
        const bytes_b = try toBytes(&reparsed);
        defer a.free(bytes_b);
        if (!std.mem.eql(u8, bytes_a, bytes_b)) {
            printCase(case, &ds);
            return error.TestUnexpectedResult;
        }
    }
}

test "native pixel values are preserved" {
    var prng = Random.DefaultPrng.init(0x5EED_0004);
    for (0..CASES) |_| {
        const r = prng.random();
        const g = arbGeometry(r);
        var ds = Dataset.init(a);
        defer ds.deinit();
        try putGeometry(&ds, g);
        const frames = try arbFrames(r, g);
        var expected = PixelData.initNative(frames);
        var copy = try expected.clone(a);
        defer copy.deinit(a);
        try ds.insert(Element.init(tag.PIXEL_DATA, .OW, .{ .pixel_data = expected }));

        var rt = try roundtrip(&ds);
        defer rt.deinit();
        const pd = rt.pixelData() orelse return error.TestUnexpectedResult;
        try testing.expect(pd.* == .native);
        try testing.expect(pd.eql(&copy));
    }
}
