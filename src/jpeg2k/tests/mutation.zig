//! Mutation / robustness tests (port of Rust `tests/mutation.rs`).
//!
//! Property: however the encoded stream is corrupted, the decoder must
//! **never panic** and **never return a wrong-sized success**. Every decode
//! of a mutated stream is an error or exactly `W * H` samples with matching
//! dimensions. A panic (incl. safety-checked UB) fails the test run.

const std = @import("std");
const jpeg2k = @import("../root.zig");

const testing = std.testing;
const ta = testing.allocator;

const W: u32 = 16;
const H: u32 = 16;

fn baseStream() ![]u8 {
    var px: [W * H]u16 = undefined;
    for (0..H) |y| for (0..W) |x| {
        px[y * W + x] = @intCast((x + y) & 0xFF);
    };
    var aw: std.Io.Writer.Allocating = .init(ta);
    defer aw.deinit();
    try jpeg2k.encode(ta, &px, W, H, &aw.writer);
    return aw.toOwnedSlice();
}

fn expectWellFormed(data: []const u8) !void {
    var img = jpeg2k.decode(ta, data, W, H) catch return;
    defer img.deinit(ta);
    try testing.expectEqual(W, img.width);
    try testing.expectEqual(H, img.height);
    try testing.expectEqual(@as(usize, W * H), img.pixels.len);
}

test "truncation prefixes never panic" {
    const base = try baseStream();
    defer ta.free(base);
    for (0..base.len) |len| try expectWellFormed(base[0..len]);
}

test "bit flips never panic" {
    const base = try baseStream();
    defer ta.free(base);
    const m = try ta.dupe(u8, base);
    defer ta.free(m);
    const len = base.len;

    const head = @min(64, len);
    for (0..head) |byte| for (0..8) |bit| {
        @memcpy(m, base);
        m[byte] ^= @as(u8, 1) << @intCast(bit);
        try expectWellFormed(m);
    };

    for (len -| 16..len) |byte| for (0..8) |bit| {
        @memcpy(m, base);
        m[byte] ^= @as(u8, 1) << @intCast(bit);
        try expectWellFormed(m);
    };
}

test "chopped trailing marker is err" {
    const base = try baseStream();
    defer ta.free(base);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, base[base.len - 2 ..]);
    if (jpeg2k.decode(ta, base[0 .. base.len - 2], W, H)) |img| {
        var i = img;
        i.deinit(ta);
        return error.TestUnexpectedResult;
    } else |_| {}
}
