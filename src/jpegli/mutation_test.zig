//! Mutation / robustness tests.
//!
//! Property under test: no matter how the encoded stream is corrupted, the
//! decoder must never crash and must never return a wrong-sized `Ok`. Every
//! decode of a mutated stream is either an error (a well-typed rejection) or an
//! `Ok` holding exactly `W * H` samples with matching dimensions. Leaks are
//! caught by `std.testing.allocator`.
//!
//! The base stream is produced with `restart_interval_rows = 1` so RST markers
//! are present in the entropy-coded scan (exercises the restart machinery).

const std = @import("std");
const jpegli = @import("root.zig");

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
    return jpegli.encodeWithOptions(testing.allocator, &px, W, H, .{
        .precision = 8, // matches the <= 255 sample values
        .restart_interval_rows = 1, // one restart per MCU row -> RST markers exist
    });
}

fn assertWellformed(data: []const u8) !void {
    if (jpegli.decode(testing.allocator, data, W, H)) |res| {
        defer res.deinit(testing.allocator);
        try testing.expectEqual(W, res.width);
        try testing.expectEqual(H, res.height);
        try testing.expectEqual(@as(usize, W * H), res.pixels.len);
    } else |_| {}
}

/// Byte offsets of the low byte of each `RST0..RST7` marker. Entropy `0xFF`
/// bytes are always stuffed as `0xFF 0x00`, so `0xFF Dn` is unambiguous.
fn restartMarkerPositions(allocator: std.mem.Allocator, buf: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i + 1 < buf.len) {
        if (buf[i] == 0xFF and buf[i + 1] >= 0xD0 and buf[i + 1] <= 0xD7) {
            try out.append(allocator, i + 1);
            i += 2;
        } else i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// (a) Every truncation prefix decodes to an error or a correctly-sized Ok.
test "truncation prefixes never panic" {
    const base = try baseStream();
    defer testing.allocator.free(base);
    for (0..base.len) |len| try assertWellformed(base[0..len]);
}

// (b) Every single-bit flip in the first 64 and last 16 bytes is safe.
//
// Regression coverage for a bug this suite originally found in the Rust port: a
// single-bit flip in the DHT symbol-value table could make the Huffman decoder
// return an SSSS category outside 0..=16, which was passed unchecked to the bit
// reader. The scan loop now rejects SSSS > 16 before reading appended bits.
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

// (c) Chop the trailing EOI marker. The entropy-coded scan stays intact, so every
// sample is still decoded from real bits; the decode stays well-formed.
test "chopped trailing marker still wellformed" {
    const base = try baseStream();
    defer testing.allocator.free(base);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, base[base.len - 2 ..]);
    try assertWellformed(base[0 .. base.len - 2]);
}

// (e) Truncating a valid stream mid-entropy must be rejected as Truncated, not
// silently completed with fabricated zero-valued samples.
test "mid entropy truncation is err" {
    const base = try baseStream();
    defer testing.allocator.free(base);
    const sos = std.mem.indexOf(u8, base, &.{ 0xFF, 0xDA }).?;
    // Entropy begins right after the SOS segment (2 marker bytes + 8 segment bytes).
    const entropy_start = sos + 2 + 8;
    for ([_]usize{ 0, 1, 2, 4, 8 }) |extra| {
        const res = jpegli.decode(testing.allocator, base[0 .. entropy_start + extra], W, H);
        if (res) |r| {
            r.deinit(testing.allocator);
            return error.TestExpectedError;
        } else |e| try testing.expectEqual(error.Truncated, e);
    }
}

// (d) Restart markers must appear in strictly increasing mod-8 order. Swapping the
// first two (RST0 <-> RST1) violates the sequence and must produce an error.
test "swapped restart markers is err" {
    const base = try baseStream();
    defer testing.allocator.free(base);
    const positions = try restartMarkerPositions(testing.allocator, base);
    defer testing.allocator.free(positions);
    try testing.expect(positions.len >= 2);

    const m = try testing.allocator.dupe(u8, base);
    defer testing.allocator.free(m);
    std.mem.swap(u8, &m[positions[0]], &m[positions[1]]);
    try testing.expect(std.meta.isError(jpegli.decode(testing.allocator, m, W, H)));
}
