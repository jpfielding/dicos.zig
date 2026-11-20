//! Inputs found by the Rust `decode` fuzz target, pinned so they stay fixed
//! (Rust `tests/fuzz_crash_regressions.rs`).
//!
//! Each fixture is a raw libFuzzer input: the first 4 bytes are two
//! little-endian `u16` dimensions (clamped to `1..=512`), the rest is the
//! JPEG-LS body. Debug builds have overflow checks on, so a regression panics.

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");

const testing = std.testing;
const ta = testing.allocator;

/// `i32` overflow in the run-context A accumulator (`updateRunStats`).
const CRASH_0AC3D3B = @embedFile("../testdata/fuzz/decode-crash-0ac3d3b29c36ae16b19af9329dd3bc2ffa0b3484");

const Split = struct { body: []const u8, w: u32, h: u32 };

fn split(data: []const u8) Split {
    const dim = struct {
        fn f(lo: u8, hi: u8) u32 {
            return std.math.clamp(@as(u32, std.mem.readInt(u16, &.{ lo, hi }, .little)), 1, 512);
        }
    }.f;
    return .{ .body = data[4..], .w = dim(data[0], data[1]), .h = dim(data[2], data[3]) };
}

test "crash 0ac3d3b is rejected" {
    const s = split(CRASH_0AC3D3B);
    // Its SOF55 declares Ls = 5, too short for any frame header.
    try util.expectErr(error.InvalidData, util.decodeErr(s.body, s.w, s.h));
}

test "crash 0ac3d3b with valid sof is rejected without overflow" {
    // Repair the SOF55 so the scan is actually decoded: this reaches the
    // corrupt Golomb codes that overflowed A before the Errval bound.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ta);
    try data.appendSlice(ta, CRASH_0AC3D3B);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xF7, 0x00, 0x05 }, data.items[6..10]);
    data.items[9] = 11; // Ls = 8 + 3*Nf
    try data.insertSlice(ta, 16, &.{ 1, 0x11, 0x00 }); // Ci, 1:1 sampling, Tq 0
    // Repair the minimized SOS length and selector as well, so header
    // validation cannot mask the entropy-code regression.
    const sos = util.find(data.items, &.{ 0xFF, 0xDA }).?;
    std.mem.writeInt(u16, data.items[sos + 2 ..][0..2], 8, .big);
    data.items[sos + 5] = 1;
    const s = split(data.items);
    try util.expectErr(error.Truncated, util.decodeErr(s.body, s.w, s.h));
}
