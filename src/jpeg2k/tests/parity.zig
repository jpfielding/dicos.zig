//! Byte-parity against the Rust `pure_jpeg2k` 2.1.0 encoder.
//!
//! `testdata/parity_rust.txt` was produced by running the Rust crate over a
//! deterministic matrix (dims x levels x code-block sizes x pixel patterns;
//! see the generator in the README). Each line is
//! `w h nl cbw cbh kind len fnv1a64` of the Rust encoder output. This test
//! regenerates every case with the Zig encoder and requires identical length
//! and FNV-1a-64 digest, i.e. byte-for-byte identical codestreams.

const std = @import("std");
const jpeg2k = @import("../root.zig");

const testing = std.testing;
const ta = testing.allocator;

const table = @embedFile("../testdata/parity_rust.txt");

fn fnv1a64(b: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (b) |x| {
        h ^= x;
        h *%= 0x100000001b3;
    }
    return h;
}

/// Pixel patterns, identical to the Rust generator.
fn pattern(kind: usize, w: u32, h: u32, v: []u16) void {
    const n = v.len;
    switch (kind) {
        0 => @memset(v, 40000),
        1 => for (v, 0..) |*p, i| {
            const iu: u32 = @intCast(i);
            p.* = @intCast(((iu % w) * 250 + (iu / w) * 70) % 65536);
        },
        2 => {
            var s: u64 = 0x9E37_79B9_7F4A_7C15 ^ (@as(u64, w) << 20) ^ @as(u64, h);
            for (v) |*p| {
                s = s *% 6364136223846793005 +% 1;
                p.* = @truncate(s >> 40);
            }
        },
        3 => {
            @memset(v, 0);
            v[0] = 65535;
            v[n / 2] = 32768;
            v[n - 1] = 1;
        },
        else => {
            var s: u64 = 0xABCDEF12;
            for (v) |*p| {
                s = s *% 6364136223846793005 +% 1442695040888963407;
                p.* = @truncate(s >> 33);
            }
        },
    }
}

/// Every case runs in optimized builds; Debug (the `zig build test` default)
/// checks every 5th case to keep the suite fast. Run
/// `zig build test -Doptimize=ReleaseSafe` for the full matrix.
const stride: usize = if (@import("builtin").mode == .Debug) 5 else 1;

test "encoder output is byte-identical to the rust crate" {
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(ta);
    var aw: std.Io.Writer.Allocating = .init(ta);
    defer aw.deinit();

    var cases: usize = 0;
    var index: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, table, '\n');
    while (lines.next()) |line| : (index += 1) {
        if (index % stride != 0) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const w = try std.fmt.parseInt(u32, it.next().?, 10);
        const h = try std.fmt.parseInt(u32, it.next().?, 10);
        const nl = try std.fmt.parseInt(u8, it.next().?, 10);
        const cbw = try std.fmt.parseInt(u8, it.next().?, 10);
        const cbh = try std.fmt.parseInt(u8, it.next().?, 10);
        const kind = try std.fmt.parseInt(usize, it.next().?, 10);
        const len = try std.fmt.parseInt(usize, it.next().?, 10);
        const digest = try std.fmt.parseInt(u64, it.next().?, 16);

        try buf.resize(ta, @as(usize, w) * h);
        pattern(kind, w, h, buf.items);
        aw.clearRetainingCapacity();
        try jpeg2k.encodeWithOptions(ta, buf.items, w, h, .{
            .num_decomp_levels = nl,
            .cb_width_exp = cbw,
            .cb_height_exp = cbh,
        }, &aw.writer);
        const got = aw.written();
        if (got.len != len or fnv1a64(got) != digest) {
            std.debug.print("parity mismatch: {s} (zig len {d} fnv {x:0>16})\n", .{ line, got.len, fnv1a64(got) });
            return error.TestUnexpectedResult;
        }
        cases += 1;
    }
    try testing.expect(cases * stride >= 6000);
}
