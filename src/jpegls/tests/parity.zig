//! Byte-for-byte parity with the Rust `pure_jpegls` 2.1.0 encoder.
//!
//! `testdata/parity_manifest.txt` holds `<sha256> <label>` for 849 streams the
//! Rust encoder produced (T.87 single-component across precisions 2..=16 and
//! NEAR 0/1/3, default-options `encode`, LegacyGo with derived and explicit
//! precision, and 3-component planar `encode_image`). This test regenerates
//! the same inputs with the same generators, in the same order, and requires
//! every Zig stream to hash identically.
//!
//! The manifest was produced by a scratch-only Rust test (not part of either
//! repository) that mirrors `enumerate` below; any change here must be
//! mirrored there and the manifest regenerated from the Rust crate.

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");
const t87 = @import("t87_roundtrip.zig");

const testing = std.testing;
const ta = testing.allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const manifest = @embedFile("../testdata/parity_manifest.txt");

const Checker = struct {
    lines: std.mem.TokenIterator(u8, .scalar),
    count: usize = 0,
    failures: usize = 0,

    fn check(self: *Checker, label: []const u8, bytes: []const u8) !void {
        const line = self.lines.next() orelse return error.ManifestTooShort;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadManifest;
        const want_hex = line[0..space];
        const want_label = line[space + 1 ..];
        if (!std.mem.eql(u8, want_label, label)) {
            std.debug.print("parity: case order diverged: manifest {s}, zig {s}\n", .{ want_label, label });
            return error.ManifestOrder;
        }
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        const got_hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.mem.eql(u8, want_hex, &got_hex)) {
            std.debug.print("parity: {s}: zig bytes differ from rust ({d} bytes)\n", .{ label, bytes.len });
            self.failures += 1;
        }
        self.count += 1;
    }
};

fn maxFor(p: u8) u16 {
    return @intCast((@as(u32, 1) << @intCast(p)) - 1);
}

fn nearOk(near: u8, m: u16) bool {
    return near <= @min(m / 2, 255);
}

fn enumerate(c: *Checker) !void {
    var label_buf: [96]u8 = undefined;
    const dims = [_][2]u32{ .{ 1, 1 }, .{ 1, 16 }, .{ 16, 1 }, .{ 7, 5 }, .{ 16, 16 }, .{ 33, 9 }, .{ 64, 48 } };

    // T87 single component, explicit precision.
    for (dims) |d| {
        for ([_]u8{ 2, 5, 8, 12, 16 }) |p| {
            const m = maxFor(p);
            const ps = try t87.patterns(d[0], d[1], m);
            defer t87.freePatterns(ps);
            for (ps) |pat| {
                for ([_]u8{ 0, 1, 3 }) |near| {
                    if (!nearOk(near, m)) continue;
                    const out = try util.encodeOpts(pat.pixels, d[0], d[1], .{ .near = near, .precision = p });
                    defer ta.free(out);
                    try c.check(try std.fmt.bufPrint(&label_buf, "t87_{s}_{d}x{d}_p{d}_n{d}", .{ pat.name, d[0], d[1], p, near }), out);
                }
            }
        }
    }

    // Default encode (derived precision) and LegacyGo.
    for (dims) |d| {
        for ([_]u8{ 8, 12, 16 }) |p| {
            const m = maxFor(p);
            const ps = try t87.patterns(d[0], d[1], m);
            defer t87.freePatterns(ps);
            for (ps) |pat| {
                {
                    var aw = std.Io.Writer.Allocating.init(ta);
                    defer aw.deinit();
                    try jpegls.encode(ta, pat.pixels, d[0], d[1], &aw.writer);
                    try c.check(try std.fmt.bufPrint(&label_buf, "default_{s}_{d}x{d}_m{d}", .{ pat.name, d[0], d[1], p }), aw.written());
                }
                {
                    const out = try util.encodeOpts(pat.pixels, d[0], d[1], .{ .profile = .legacy_go });
                    defer ta.free(out);
                    try c.check(try std.fmt.bufPrint(&label_buf, "legacy_{s}_{d}x{d}_m{d}", .{ pat.name, d[0], d[1], p }), out);
                }
                {
                    const out = try util.encodeOpts(pat.pixels, d[0], d[1], .{ .profile = .legacy_go, .precision = p });
                    defer ta.free(out);
                    try c.check(try std.fmt.bufPrint(&label_buf, "legacyp_{s}_{d}x{d}_p{d}", .{ pat.name, d[0], d[1], p }), out);
                }
            }
        }
    }

    // encodeImage, 3-component planar (gradient, random, randflat planes).
    for ([_][2]u32{ .{ 1, 1 }, .{ 7, 5 }, .{ 16, 16 }, .{ 33, 9 } }) |d| {
        for ([_]u8{ 2, 8, 12, 16 }) |p| {
            const m = maxFor(p);
            const ps = try t87.patterns(d[0], d[1], m);
            defer t87.freePatterns(ps);
            const planar = try std.mem.concat(ta, u16, &.{ ps[1].pixels, ps[3].pixels, ps[4].pixels });
            defer ta.free(planar);
            for ([_]u8{ 0, 1, 3 }) |near| {
                if (!nearOk(near, m)) continue;
                const out = try util.encodeImg(planar, d[0], d[1], 3, .{ .near = near, .precision = p });
                defer ta.free(out);
                try c.check(try std.fmt.bufPrint(&label_buf, "rgb_{d}x{d}_p{d}_n{d}", .{ d[0], d[1], p, near }), out);
            }
        }
    }
}

test "encoder output is byte-identical to the rust crate" {
    var c = Checker{ .lines = std.mem.tokenizeScalar(u8, manifest, '\n') };
    try enumerate(&c);
    if (c.lines.next() != null) return error.ManifestTooLong;
    try testing.expectEqual(@as(usize, 849), c.count);
    try testing.expectEqual(@as(usize, 0), c.failures);
}
