//! LegacyGo-profile fixtures frozen from the 1.0.0 codec (Rust
//! `tests/legacy_fixtures.rs`).
//!
//! The 1.0.0 bitstream is NOT ITU-T T.87: it uses T.81-style 0xFF00 byte
//! stuffing, no run mode, and an uncapped Golomb coder -- byte-compatible
//! with the Go dicos codec. The fixtures under `testdata/legacy/` (copied
//! verbatim from the Rust crate) pin it forever: the `Profile.legacy_go`
//! encode/decode paths must stay byte-identical to them. There is
//! deliberately no regenerator.

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");

const testing = std.testing;
const ta = testing.allocator;

/// Deterministic pixel generator; do not change.
fn lcgPixels(seed: u64, n: usize, max: u16) ![]u16 {
    const out = try ta.alloc(u16, n);
    var state = seed;
    const modulus: u16 = @max(max +| 1, 1);
    for (out) |*v| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        v.* = @as(u16, @truncate(state >> 33)) % modulus;
    }
    return out;
}

fn gradient(w: u32, h: u32) ![]u16 {
    const out = try ta.alloc(u16, w * h);
    for (0..h) |y| for (0..w) |x| {
        out[y * w + x] = @truncate((x * 65535 / @max(w, 1)) + y * 7);
    };
    return out;
}

const Image = struct { name: []const u8, w: u32, h: u32, pixels: []u16, fixture: []const u8 };

fn testImages() ![5]Image {
    const flat = try ta.alloc(u16, 24 * 8);
    @memset(flat, 777);
    return .{
        .{ .name = "gradient-16x16", .w = 16, .h = 16, .pixels = try gradient(16, 16), .fixture = @embedFile("../testdata/legacy/gradient-16x16.jls") },
        .{ .name = "random-32x32", .w = 32, .h = 32, .pixels = try lcgPixels(0x15D1C05, 32 * 32, std.math.maxInt(u16)), .fixture = @embedFile("../testdata/legacy/random-32x32.jls") },
        .{ .name = "odd-13x7", .w = 13, .h = 7, .pixels = try lcgPixels(0x10DD5, 13 * 7, 4095), .fixture = @embedFile("../testdata/legacy/odd-13x7.jls") },
        // Flat image: exactly the case where conformant T.87 uses run mode
        // and the legacy format does not -- the highest-value freeze.
        .{ .name = "flat-24x8", .w = 24, .h = 8, .pixels = flat, .fixture = @embedFile("../testdata/legacy/flat-24x8.jls") },
        .{ .name = "tall-1x16", .w = 1, .h = 16, .pixels = try lcgPixels(0x17A11, 16, std.math.maxInt(u16)), .fixture = @embedFile("../testdata/legacy/tall-1x16.jls") },
    };
}

fn freeImages(images: [5]Image) void {
    for (images) |img| ta.free(img.pixels);
}

test "legacy fixtures decode" {
    const images = try testImages();
    defer freeImages(images);
    for (images) |img| {
        const decoded = jpegls.decodeWithOptions(ta, img.fixture, img.w, img.h, .{ .profile = .legacy_go }) catch |e| {
            std.debug.print("{s}: legacy decode failed\n", .{img.name});
            return e;
        };
        defer ta.free(decoded);
        try testing.expectEqualSlices(u16, img.pixels, decoded);
    }
}

test "legacy fixtures encode identity" {
    const images = try testImages();
    defer freeImages(images);
    for (images) |img| {
        const actual = try util.encodeOpts(img.pixels, img.w, img.h, .{ .profile = .legacy_go });
        defer ta.free(actual);
        testing.expectEqualSlices(u8, img.fixture, actual) catch |e| {
            std.debug.print("{s}: encoder output drifted from 1.0.0 fixture\n", .{img.name});
            return e;
        };
    }
}
