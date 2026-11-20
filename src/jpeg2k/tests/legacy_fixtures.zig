//! Legacy-format fixtures frozen from the 1.0.0 codec (port of Rust
//! `tests/legacy_fixtures.rs`).
//!
//! The 1.0.0 `encode` serialised raw DWT coefficients (not conformant T.800
//! packets). Files in that format exist in the wild (produced by the Rust
//! crate and the Go dicos codec); the fixtures in `testdata/legacy/` pin it
//! forever: the legacy decode path must keep decoding them to the exact
//! pixels produced by `testImages`. Do not edit the `.j2c` files or the
//! generator.

const std = @import("std");
const jpeg2k = @import("../root.zig");

const testing = std.testing;
const ta = testing.allocator;

const Fixture = struct { name: []const u8, w: u32, h: u32, bytes: []const u8 };

const fixtures = [_]Fixture{
    .{ .name = "gradient-16x16", .w = 16, .h = 16, .bytes = @embedFile("../testdata/legacy/gradient-16x16.j2c") },
    .{ .name = "random-32x32", .w = 32, .h = 32, .bytes = @embedFile("../testdata/legacy/random-32x32.j2c") },
    .{ .name = "odd-13x7", .w = 13, .h = 7, .bytes = @embedFile("../testdata/legacy/odd-13x7.j2c") },
    .{ .name = "flat-8x8", .w = 8, .h = 8, .bytes = @embedFile("../testdata/legacy/flat-8x8.j2c") },
    .{ .name = "tall-1x16", .w = 1, .h = 16, .bytes = @embedFile("../testdata/legacy/tall-1x16.j2c") },
};

/// Deterministic LCG pixels. Do not change.
fn lcgPixels(seed: u64, out: []u16, max: u16) void {
    var state = seed;
    // u16 saturating, exactly as Rust: `max.saturating_add(1).max(1)`.
    const modulus: u16 = @max(max +| 1, 1);
    for (out) |*p| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        p.* = @as(u16, @truncate(state >> 33)) % modulus;
    }
}

/// Expected pixels for fixture `name` (caller frees).
fn expectedPixels(name: []const u8, w: u32, h: u32) ![]u16 {
    const n: usize = @as(usize, w) * h;
    const px = try ta.alloc(u16, n);
    if (std.mem.eql(u8, name, "gradient-16x16")) {
        for (0..h) |y| for (0..w) |x| {
            px[y * w + x] = @truncate(@as(u32, @intCast(x)) * 65535 / @max(w, 1) + @as(u32, @intCast(y)) * 7);
        };
    } else if (std.mem.eql(u8, name, "random-32x32")) {
        lcgPixels(0xD1C05, px, std.math.maxInt(u16));
    } else if (std.mem.eql(u8, name, "odd-13x7")) {
        lcgPixels(0x0DD5, px, 4095);
    } else if (std.mem.eql(u8, name, "flat-8x8")) {
        @memset(px, 1234);
    } else if (std.mem.eql(u8, name, "tall-1x16")) {
        lcgPixels(0x7A11, px, std.math.maxInt(u16));
    } else unreachable;
    return px;
}

test "legacy fixtures decode" {
    for (fixtures) |f| {
        const want = try expectedPixels(f.name, f.w, f.h);
        defer ta.free(want);
        var img = try jpeg2k.decode(ta, f.bytes, f.w, f.h);
        defer img.deinit(ta);
        try testing.expectEqual(f.w, img.width);
        try testing.expectEqual(f.h, img.height);
        try testing.expectEqualSlices(u16, want, img.pixels);
    }
}

test "legacy fixtures decode with legacy only" {
    for (fixtures) |f| {
        const want = try expectedPixels(f.name, f.w, f.h);
        defer ta.free(want);
        var img = try jpeg2k.decodeWithOptions(ta, f.bytes, f.w, f.h, .{ .legacy = .legacy_only });
        defer img.deinit(ta);
        try testing.expectEqualSlices(u16, want, img.pixels);
    }
}

test "legacy fixtures rejected by standard only" {
    for (fixtures) |f| {
        if (jpeg2k.decodeWithOptions(ta, f.bytes, f.w, f.h, .{ .legacy = .standard_only })) |img| {
            var i = img;
            i.deinit(ta);
            std.debug.print("{s}: StandardOnly must reject the legacy fixture\n", .{f.name});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "legacy only rejects conformant stream" {
    const px: [64]u16 = @splat(500);
    var aw: std.Io.Writer.Allocating = .init(ta);
    defer aw.deinit();
    try jpeg2k.encode(ta, &px, 8, 8, &aw.writer);
    try testing.expectError(error.InvalidData, jpeg2k.decodeWithOptions(ta, aw.written(), 8, 8, .{ .legacy = .legacy_only }));
}
