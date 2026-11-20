//! Mutation / robustness tests.
//!
//! Property under test: no matter how the encoded stream is corrupted, the
//! decoder must never crash and must never return a wrong-sized `Ok`. Every
//! decode of a mutated stream is either an error (a well-typed rejection) or an
//! `Ok` holding exactly `W * H` samples with matching dimensions. Leaks are
//! caught by `std.testing.allocator`.
//!
//! DICOM RLE has no trailing end-of-stream marker, so the "chop the trailing
//! marker" case does not apply and is intentionally omitted.

const std = @import("std");
const jpegrle = @import("root.zig");

const testing = std.testing;

const W: u32 = 16;
const H: u32 = 16;

fn sampleImage() [W * H]u16 {
    var px: [W * H]u16 = undefined;
    for (0..H) |y| {
        for (0..W) |x| px[y * W + x] = @intCast((x * 7 + y * 13) & 0xFF);
    }
    return px;
}

fn baseStream() ![]u8 {
    const px = sampleImage();
    return jpegrle.encode(testing.allocator, &px, W, H);
}

fn assertWellformed(data: []const u8) !void {
    if (jpegrle.decode(testing.allocator, data, W, H)) |res| {
        defer res.deinit(testing.allocator);
        try testing.expectEqual(W, res.width);
        try testing.expectEqual(H, res.height);
        try testing.expectEqual(@as(usize, W * H), res.pixels.len);
    } else |_| {}
}

// (a) Every truncation prefix decodes to an error or a correctly-sized Ok.
test "truncation prefixes never panic" {
    const base = try baseStream();
    defer testing.allocator.free(base);
    for (0..base.len) |len| try assertWellformed(base[0..len]);
}

// (b) Every single-bit flip in the first 64 and last 16 bytes is safe.
test "bit flips never panic" {
    const base = try baseStream();
    defer testing.allocator.free(base);
    const m = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(m);

    const head = @min(64, base.len);
    const tail_start = base.len -| 16;
    const ranges = [_][2]usize{ .{ 0, head }, .{ tail_start, base.len } };
    for (ranges) |r| {
        for (r[0]..r[1]) |byte| {
            for (0..8) |bit| {
                @memcpy(m, base);
                m[byte] ^= @as(u8, 1) << @intCast(bit);
                try assertWellformed(m);
            }
        }
    }
}
