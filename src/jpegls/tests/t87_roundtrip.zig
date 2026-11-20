//! T.87 conformant encode/decode round-trip matrix and run-mode specifics.
//!
//! Exercises the default `Profile.t87` path across dimensions, near-lossless
//! bounds, precisions, and pixel patterns (including ones that force run
//! mode, the end-of-line rule, and run interruptions). The Rust proptest
//! properties are ported as seeded random loops with the same case counts.

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");

const testing = std.testing;
const ta = testing.allocator;

fn encode(pixels: []const u16, w: u32, h: u32, near: u8, precision: u8) ![]u8 {
    return util.encodeOpts(pixels, w, h, .{ .near = near, .precision = precision });
}

/// Assert the near-lossless property: exact when near==0, else |delta| <= near.
fn expectWithinNear(orig: []const u16, decoded: []const u16, near: u8) !void {
    try testing.expectEqual(orig.len, decoded.len);
    for (orig, decoded, 0..) |o, d, i| {
        const diff = @abs(@as(i32, o) - @as(i32, d));
        if (diff > near) {
            std.debug.print("pixel {d} orig={d} decoded={d} diff={d} > near={d}\n", .{ i, o, d, diff, near });
            return error.TestExpectedEqual;
        }
    }
}

// --- pattern generators (all values clamped to maxval) ---------------------

pub fn constant(w: usize, h: usize, maxval: u16) ![]u16 {
    const out = try ta.alloc(u16, w * h);
    @memset(out, maxval / 2);
    return out;
}

pub fn gradient(w: usize, h: usize, maxval: u16) ![]u16 {
    const out = try ta.alloc(u16, w * h);
    for (0..h) |y| for (0..w) |x| {
        out[y * w + x] = @intCast((@as(u64, x + y) * maxval) / @max(w + h, 1));
    };
    return out;
}

pub fn checkerboard(w: usize, h: usize, maxval: u16) ![]u16 {
    const out = try ta.alloc(u16, w * h);
    for (0..h) |y| for (0..w) |x| {
        out[y * w + x] = if ((x + y) % 2 == 0) maxval else maxval / 4;
    };
    return out;
}

/// Random with flat runs interspersed -- forces run mode AND interruptions.
pub fn randomFlat(seed: u64, w: usize, h: usize, maxval: u16) ![]u16 {
    const base = try util.lcg(seed, w * h, maxval);
    for (0..h) |y| {
        for (w / 3..2 * w / 3) |x| base[y * w + x] = maxval / 3;
    }
    return base;
}

pub const Pattern = struct { name: []const u8, pixels: []u16 };

/// The five Rust test patterns, in order. Caller frees with `freePatterns`.
pub fn patterns(w: usize, h: usize, maxval: u16) ![5]Pattern {
    return .{
        .{ .name = "constant", .pixels = try constant(w, h, maxval) },
        .{ .name = "gradient", .pixels = try gradient(w, h, maxval) },
        .{ .name = "checker", .pixels = try checkerboard(w, h, maxval) },
        .{ .name = "random", .pixels = try util.lcg(0x1234_5678 ^ @as(u64, w * 131 + h), w * h, maxval) },
        .{ .name = "randflat", .pixels = try randomFlat(0xC0FFEE, w, h, maxval) },
    };
}

pub fn freePatterns(ps: [5]Pattern) void {
    for (ps) |p| ta.free(p.pixels);
}

test "roundtrip matrix" {
    const dims = [_][2]u32{ .{ 1, 1 }, .{ 1, 16 }, .{ 16, 1 }, .{ 7, 5 }, .{ 16, 16 }, .{ 33, 9 } };
    for (dims) |d| {
        const w = d[0];
        const h = d[1];
        for ([_]u8{ 8, 12, 16 }) |precision| {
            const maxval: u16 = @intCast((@as(u32, 1) << @intCast(precision)) - 1);
            // Rust seeds "random" with (w * 131 + h) as u32 widened; same value.
            const ps = try patterns(w, h, maxval);
            defer freePatterns(ps);
            for ([_]u8{ 0, 1, 3 }) |near| {
                for (ps) |p| {
                    const bytes = try encode(p.pixels, w, h, near, precision);
                    defer ta.free(bytes);
                    const decoded = jpegls.decode(ta, bytes, w, h) catch |e| {
                        std.debug.print("{s} {d}x{d} p{d} near{d}: decode failed\n", .{ p.name, w, h, precision, near });
                        return e;
                    };
                    defer ta.free(decoded);
                    try expectWithinNear(p.pixels, decoded, near);
                }
            }
        }
    }
}

test "run spanning multiple lines is exact" {
    const pixels = [_]u16{1234} ** (20 * 10);
    const bytes = try encode(&pixels, 20, 10, 0, 12);
    defer ta.free(bytes);
    try util.expectDecodes(bytes, 20, 10, &pixels);
}

test "run interruption at first column" {
    const w = 8;
    const h = 6;
    var pixels = [_]u16{100} ** (w * h);
    for (0..h) |y| pixels[y * w] = if (y % 2 == 0) 100 else 160;
    const bytes = try encode(&pixels, w, h, 0, 8);
    defer ta.free(bytes);
    try util.expectDecodes(bytes, w, h, &pixels);
}

test "run ending exactly at eol" {
    for ([_]u32{ 1, 2, 3, 7, 16, 31 }) |w| {
        const h = 4;
        const pixels = try ta.alloc(u16, w * h);
        defer ta.free(pixels);
        @memset(pixels, 50);
        const bytes = try encode(pixels, w, h, 0, 8);
        defer ta.free(bytes);
        try util.expectDecodes(bytes, w, h, pixels);
    }
}

test "near lossless various bounds" {
    const w = 24;
    const h = 16;
    const pixels = try util.lcg(0xABCDEF, w * h, 4095);
    defer ta.free(pixels);
    for ([_]u8{ 1, 2, 5, 10 }) |near| {
        const bytes = try encode(pixels, w, h, near, 12);
        defer ta.free(bytes);
        const decoded = try jpegls.decode(ta, bytes, w, h);
        defer ta.free(decoded);
        try expectWithinNear(pixels, decoded, near);
    }
}

test "encode rejects invalid precision" {
    for ([_]u8{ 0, 1, 17 }) |bad| {
        try testing.expectError(error.InvalidParameter, util.encodeOpts(&.{ 0, 0, 0, 0 }, 2, 2, .{ .precision = bad }));
    }
}

test "encode rejects near over half maxval" {
    try testing.expectError(error.InvalidParameter, util.encodeOpts(&.{ 10, 10, 10, 10 }, 2, 2, .{ .near = 200, .precision = 8 }));
}

test "prop roundtrip within near" {
    var prng = std.Random.DefaultPrng.init(0x7E57_0001);
    const r = prng.random();
    for (0..200) |_| {
        const w = r.intRangeAtMost(u32, 1, 40);
        const h = r.intRangeAtMost(u32, 1, 25);
        const precision = ([_]u8{ 8, 10, 12, 16 })[r.uintLessThan(usize, 4)];
        const near = r.intRangeAtMost(u8, 0, 4);
        const maxval: u16 = @intCast((@as(u32, 1) << @intCast(precision)) - 1);
        const pixels = try util.lcg(r.int(u64), w * h, maxval);
        defer ta.free(pixels);
        const bytes = try encode(pixels, w, h, near, precision);
        defer ta.free(bytes);
        const decoded = try jpegls.decode(ta, bytes, w, h);
        defer ta.free(decoded);
        try expectWithinNear(pixels, decoded, near);
    }
}

test "prop decode arbitrary no panic" {
    var prng = std.Random.DefaultPrng.init(0x7E57_0002);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..200) |_| {
        const n = r.uintLessThan(usize, 512);
        r.bytes(buf[0..n]);
        _ = util.decodeErr(buf[0..n], 8, 8);
    }
}

test "prop decode bitflip no panic" {
    var prng = std.Random.DefaultPrng.init(0x7E57_0003);
    const r = prng.random();
    for (0..200) |_| {
        const pixels = try util.lcg(r.int(u64), 64, 255);
        defer ta.free(pixels);
        const bytes = try encode(pixels, 8, 8, 0, 8);
        defer ta.free(bytes);
        const flip = r.uintLessThan(usize, 400);
        if (flip < bytes.len) {
            bytes[flip] ^= 0x40;
            _ = util.decodeErr(bytes, 8, 8);
        }
    }
}

test "encode rejects zero and oversize dims" {
    const pixels = [_]u16{0} ** 4;
    try testing.expect(std.meta.isError(util.encodeOpts(&pixels, 0, 2, .{})));
    try testing.expect(std.meta.isError(util.encodeOpts(&pixels, 2, 0, .{})));
    try testing.expect(std.meta.isError(util.encodeOpts(&.{}, 65536, 1, .{})));
}
