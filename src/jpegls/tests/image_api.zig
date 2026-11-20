//! `encodeImage` / `decodeImage` API tests (Rust `tests/image_api.rs`).

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");

const testing = std.testing;
const ta = testing.allocator;

const Rgb = struct {
    stream: []u8,
    pixels: [48]u16,

    fn deinit(self: Rgb) void {
        ta.free(self.stream);
    }
};

fn rgb() !Rgb {
    var pixels: [48]u16 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i * 5);
    return .{ .stream = try util.encodeImg(&pixels, 4, 4, 3, .{}), .pixels = pixels };
}

/// Offsets of every SOS marker.
fn scans(stream: []const u8, out: *[3]usize) usize {
    var n: usize = 0;
    for (0..stream.len - 1) |i| {
        if (stream[i] == 0xFF and stream[i + 1] == 0xDA) {
            if (n < out.len) out[n] = i;
            n += 1;
        }
    }
    return n;
}

fn expectImageSamples(stream: []const u8, expected: []const u16) !void {
    var img = try jpegls.decodeImage(ta, stream);
    defer img.deinit(ta);
    try testing.expectEqualSlices(u16, expected, img.samples);
}

test "rgb selectors are distinct and unknown or duplicate selectors fail" {
    const r = try rgb();
    defer r.deinit();
    var sos: [3]usize = undefined;
    try testing.expectEqual(@as(usize, 3), scans(r.stream, &sos));
    for (sos, 0..) |offset, i| try testing.expectEqual(@as(u8, @intCast(i + 1)), r.stream[offset + 5]);
    try expectImageSamples(r.stream, &r.pixels);
    for ([_]u8{ 1, 99 }) |selector| {
        const bad = try ta.dupe(u8, r.stream);
        defer ta.free(bad);
        bad[sos[1] + 5] = selector;
        try util.expectErr(error.InvalidData, util.decodeImageErr(bad));
    }
}

test "reordered scans are returned in frame component order" {
    const r = try rgb();
    defer r.deinit();
    const s = r.stream;
    var sos: [3]usize = undefined;
    _ = scans(s, &sos);
    const reordered = try util.concat(&.{
        s[0..sos[0]],
        s[sos[2] .. s.len - 2],
        s[sos[0]..sos[1]],
        s[sos[1]..sos[2]],
        &.{ 0xFF, 0xD9 },
    });
    defer ta.free(reordered);
    try expectImageSamples(reordered, &r.pixels);
}

test "component ids need not start at one but must be unique" {
    const r = try rgb();
    defer r.deinit();
    const s = r.stream;
    const sof = util.find(s, &.{ 0xFF, 0xF7 }).?;
    var sos: [3]usize = undefined;
    _ = scans(s, &sos);
    for ([_]u8{ 7, 0, 42 }, 0..) |id, i| {
        s[sof + 10 + 3 * i] = id;
        s[sos[i] + 5] = id;
    }
    try expectImageSamples(s, &r.pixels);
    s[sof + 13] = 7;
    try util.expectErr(error.InvalidData, util.decodeImageErr(s));
}

test "output budget counts every component and accepts exact boundary" {
    const r = try rgb();
    defer r.deinit();
    for ([_]usize{ 0, 32, 95 }) |limit| {
        var diag: jpegls.Diagnostic = .{};
        try util.expectErr(error.InvalidData, util.decodeImageErrOpts(r.stream, .{ .max_decoded_bytes = limit, .diagnostic = &diag }));
        try testing.expect(std.mem.indexOf(u8, diag.message(), "limit") != null);
    }
    var img = try jpegls.decodeImageWithOptions(ta, r.stream, .{ .max_decoded_bytes = 96 });
    defer img.deinit(ta);
    try testing.expectEqualSlices(u16, &r.pixels, img.samples);
}

test "tiny stream with large geometry hits budget before entropy decode" {
    const r = try rgb();
    defer r.deinit();
    const s = r.stream;
    const sof = util.find(s, &.{ 0xFF, 0xF7 }).?;
    std.mem.writeInt(u16, s[sof + 5 ..][0..2], 8192, .big);
    std.mem.writeInt(u16, s[sof + 7 ..][0..2], 8192, .big);
    try testing.expect(s.len < 512);
    var diag: jpegls.Diagnostic = .{};
    try util.expectErr(error.InvalidData, util.decodeImageErrOpts(s, .{ .diagnostic = &diag }));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "limit") != null);
}

test "unsupported component counts fail before writing" {
    for ([_]u8{ 0, 2, 4, 255 }) |count| {
        const samples = try ta.alloc(u16, count);
        defer ta.free(samples);
        @memset(samples, 0);
        var aw = std.Io.Writer.Allocating.init(ta);
        defer aw.deinit();
        var diag: jpegls.Diagnostic = .{};
        try testing.expectError(error.InvalidParameter, jpegls.encodeImage(ta, samples, 1, 1, count, .{ .diagnostic = &diag }, &aw.writer));
        try testing.expectEqualStrings("components", diag.name);
        try testing.expectEqual(@as(usize, 0), aw.written().len);
    }
}

test "malformed sof and sos lengths fail in both entry points" {
    const stream = try util.encodeImg(&([_]u16{0} ** 16), 4, 4, 1, .{});
    defer ta.free(stream);
    for ([_]u8{ 0xF7, 0xDA }) |marker| {
        const offset = util.find(stream, &.{ 0xFF, marker }).?;
        const valid = stream[offset + 3];
        for ([_]u8{ 2, 5, valid - 1, valid + 1 }) |length| {
            const bad = try ta.dupe(u8, stream);
            defer ta.free(bad);
            bad[offset + 3] = length;
            try util.expectErr(error.InvalidData, util.decodeImageErr(bad));
            try util.expectErr(error.InvalidData, util.decodeErr(bad, 4, 4));
        }
    }
}
