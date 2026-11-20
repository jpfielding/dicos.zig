//! Mutation / robustness tests (Rust `tests/mutation.rs`).
//!
//! Property under test: no matter how the encoded stream is corrupted, the
//! decoder must **never panic** and must **never return a wrong-sized
//! success**. Every decode of a mutated stream is either an error or exactly
//! `W * H` samples. The base stream comes from the default (T.87) encoder.

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");

const testing = std.testing;
const ta = testing.allocator;

const W = 16;
const H = 16;

fn baseStream() ![]u8 {
    var pixels: [W * H]u16 = undefined;
    for (0..H) |y| for (0..W) |x| {
        pixels[y * W + x] = @intCast((x * 7 + y * 13) & 0xFF);
    };
    var aw = std.Io.Writer.Allocating.init(ta);
    defer aw.deinit();
    try jpegls.encode(ta, &pixels, W, H, &aw.writer);
    return aw.toOwnedSlice();
}

fn expectWellformed(stream: []const u8) !void {
    const px = jpegls.decode(ta, stream, W, H) catch return;
    defer ta.free(px);
    try testing.expectEqual(@as(usize, W * H), px.len);
}

test "truncation prefixes never panic" {
    const base = try baseStream();
    defer ta.free(base);
    for (0..base.len) |len| try expectWellformed(base[0..len]);
}

test "bit flips never panic" {
    const base = try baseStream();
    defer ta.free(base);
    const m = try ta.dupe(u8, base);
    defer ta.free(m);
    const head = @min(64, base.len);
    const tail_start = base.len -| 16;
    for (0..base.len) |byte| {
        if (byte >= head and byte < tail_start) continue;
        for (0..8) |bit| {
            @memcpy(m, base);
            m[byte] ^= @as(u8, 1) << @intCast(bit);
            try expectWellformed(m);
        }
    }
}

test "chopped trailing marker is err" {
    const base = try baseStream();
    defer ta.free(base);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, base[base.len - 2 ..]);
    try testing.expect(util.decodeErr(base[0 .. base.len - 2], W, H) != null);
}
