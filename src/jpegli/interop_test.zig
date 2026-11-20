//! Interop tests against libjpeg-turbo (`cjpeg`/`djpeg`, >= 3.0 for lossless).
//!
//! * Decode (`decode cjpeg fixtures`): always runs. Decodes the checked-in
//!   `testdata/*.jpg` streams (produced by `cjpeg -lossless`, see
//!   `testdata/README.md`) and asserts the output equals the source PGM samples,
//!   with the point transform applied for the `_pt1` fixture.
//! * Encode (`encode roundtrip via djpeg`) and `decode cjpeg streams generated
//!   on the fly`: shell out to `djpeg`/`cjpeg` and skip with
//!   `error.SkipZigTest` when the tool is missing or too old for lossless.

const std = @import("std");
const jpegli = @import("root.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const Pgm = struct {
    w: u32,
    h: u32,
    px: []u16,

    fn deinit(self: Pgm, allocator: Allocator) void {
        allocator.free(self.px);
    }
};

/// Parse a binary PGM (P5), 8- or 16-bit (big-endian per the netpbm spec).
fn readPgm(allocator: Allocator, d: []const u8) !Pgm {
    try testing.expectEqualSlices(u8, "P5", d[0..2]);
    var i: usize = 2;
    var toks: [3]u32 = undefined;
    var n: usize = 0;
    while (n < 3) {
        while (std.ascii.isWhitespace(d[i])) i += 1;
        if (d[i] == '#') {
            while (d[i] != '\n') i += 1;
            continue;
        }
        const s = i;
        while (!std.ascii.isWhitespace(d[i])) i += 1;
        toks[n] = try std.fmt.parseInt(u32, d[s..i], 10);
        n += 1;
    }
    i += 1; // single whitespace after maxval
    const body = d[i..];
    const wide = toks[2] > 255;
    const count = if (wide) body.len / 2 else body.len;
    const px = try allocator.alloc(u16, count);
    errdefer allocator.free(px);
    for (px, 0..) |*p, k| {
        p.* = if (wide) std.mem.readInt(u16, body[k * 2 ..][0..2], .big) else body[k];
    }
    return .{ .w = toks[0], .h = toks[1], .px = px };
}

fn writePgm16(allocator: Allocator, w: u32, h: u32, px: []const u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "P5\n{d} {d}\n65535\n", .{ w, h });
    for (px) |p| {
        try out.append(allocator, @intCast(p >> 8));
        try out.append(allocator, @intCast(p & 0xFF));
    }
    return out.toOwnedSlice(allocator);
}

const Fixture = struct {
    name: []const u8,
    jpg: []const u8,
    src: []const u8,
    point_transform: u4 = 0,
};

const g16 = @embedFile("testdata/g16.pgm");
const r16 = @embedFile("testdata/r16.pgm");
const g8 = @embedFile("testdata/g8.pgm");

const fixtures = [_]Fixture{
    .{ .name = "g16_psv1", .jpg = @embedFile("testdata/g16_psv1.jpg"), .src = g16 },
    .{ .name = "g16_psv2", .jpg = @embedFile("testdata/g16_psv2.jpg"), .src = g16 },
    .{ .name = "g16_psv3", .jpg = @embedFile("testdata/g16_psv3.jpg"), .src = g16 },
    .{ .name = "g16_psv4", .jpg = @embedFile("testdata/g16_psv4.jpg"), .src = g16 },
    .{ .name = "g16_psv5", .jpg = @embedFile("testdata/g16_psv5.jpg"), .src = g16 },
    .{ .name = "g16_psv6", .jpg = @embedFile("testdata/g16_psv6.jpg"), .src = g16 },
    .{ .name = "g16_psv7", .jpg = @embedFile("testdata/g16_psv7.jpg"), .src = g16 },
    .{ .name = "g16_restart", .jpg = @embedFile("testdata/g16_restart.jpg"), .src = g16 },
    // Point transform Pt=1: cjpeg stores (sample >> 1) << 1.
    .{ .name = "g16_psv1_pt1", .jpg = @embedFile("testdata/g16_psv1_pt1.jpg"), .src = g16, .point_transform = 1 },
    // Random 16-bit: exercises large modular differences, including SSSS=16 (32768).
    .{ .name = "r16_psv1", .jpg = @embedFile("testdata/r16_psv1.jpg"), .src = r16 },
    // 8-bit precision.
    .{ .name = "g8_psv1", .jpg = @embedFile("testdata/g8_psv1.jpg"), .src = g8 },
};

// Decode direction: always runs against the checked-in fixtures.
test "decode cjpeg fixtures" {
    for (fixtures) |f| {
        const src = try readPgm(testing.allocator, f.src);
        defer src.deinit(testing.allocator);
        if (f.point_transform > 0) {
            for (src.px) |*s| s.* = (s.* >> f.point_transform) << f.point_transform;
        }
        const res = jpegli.decode(testing.allocator, f.jpg, src.w, src.h) catch |e| {
            std.debug.print("{s}: decode failed: {s}\n", .{ f.name, @errorName(e) });
            return e;
        };
        defer res.deinit(testing.allocator);
        try testing.expectEqual(src.w, res.width);
        try testing.expectEqual(src.h, res.height);
        testing.expectEqualSlices(u16, src.px, res.pixels) catch |e| {
            std.debug.print("{s}: pixel mismatch vs cjpeg source\n", .{f.name});
            return e;
        };
    }
}

// ---------------------------------------------------------------------------
// External-tool interop (skips when libjpeg-turbo binaries are unavailable)
// ---------------------------------------------------------------------------

const tool_dirs = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" };

/// Absolute path of `tool` in a well-known directory, or `error.SkipZigTest`.
fn findTool(allocator: Allocator, tool: []const u8) ![]u8 {
    for (tool_dirs) |dir| {
        const p = try std.fs.path.join(allocator, &.{ dir, tool });
        if (std.fs.accessAbsolute(p, .{})) |_| return p else |_| allocator.free(p);
    }
    return error.SkipZigTest;
}

/// Run `argv`, returning true on exit code 0. Skips if stderr says the tool
/// lacks lossless support (libjpeg-turbo < 3.0).
fn runTool(allocator: Allocator, argv: []const []const u8) !bool {
    const r = try std.process.Child.run(.{ .allocator = allocator, .argv = argv, .max_output_bytes = 1 << 20 });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    const ok = switch (r.term) {
        .Exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        if (std.mem.indexOf(u8, r.stderr, "Unsupported JPEG process") != null or
            std.mem.indexOf(u8, r.stderr, "invalid option") != null or
            std.mem.indexOf(u8, r.stderr, "Unrecognized option") != null)
            return error.SkipZigTest;
        std.debug.print("{s} failed: {s}\n", .{ argv[0], r.stderr });
    }
    return ok;
}

fn hashImage(w: u32, h: u32) [32 * 24]u16 {
    std.debug.assert(w * h == 32 * 24);
    var src: [32 * 24]u16 = undefined;
    for (&src, 0..) |*p, i| {
        const v: u32 = @as(u32, @intCast(i)) *% 2654435761;
        p.* = @intCast((v >> 8) & 0xFFFF);
    }
    return src;
}

// Encode direction: our encoder's output must be decodable by `djpeg`.
test "encode roundtrip via djpeg" {
    const a = testing.allocator;
    const djpeg = try findTool(a, "djpeg");
    defer a.free(djpeg);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const w: u32 = 32;
    const h: u32 = 24;
    const src = hashImage(w, h);

    // (predictor, restart rows): predictors 1..7 plus restart-bearing configs.
    const cases = [_][2]u8{ .{ 1, 0 }, .{ 2, 0 }, .{ 3, 0 }, .{ 4, 0 }, .{ 5, 0 }, .{ 6, 0 }, .{ 7, 0 }, .{ 1, 2 }, .{ 4, 1 } };
    for (cases) |c| {
        const buf = try jpegli.encodeWithOptions(a, &src, w, h, .{ .predictor = c[0], .restart_interval_rows = c[1] });
        defer a.free(buf);
        try tmp.dir.writeFile(.{ .sub_path = "in.jpg", .data = buf });

        const jpg_path = try std.fs.path.join(a, &.{ dir, "in.jpg" });
        defer a.free(jpg_path);
        const out_path = try std.fs.path.join(a, &.{ dir, "out.pgm" });
        defer a.free(out_path);
        const argv = [_][]const u8{ djpeg, "-pnm", "-outfile", out_path, jpg_path };
        if (!try runTool(a, &argv)) {
            std.debug.print("djpeg rejected our psv{d} output\n", .{c[0]});
            return error.TestUnexpectedResult;
        }

        const out = try tmp.dir.readFileAlloc(a, "out.pgm", 1 << 20);
        defer a.free(out);
        const pgm = try readPgm(a, out);
        defer pgm.deinit(a);
        try testing.expectEqual(w, pgm.w);
        try testing.expectEqual(h, pgm.h);
        testing.expectEqualSlices(u16, &src, pgm.px) catch |e| {
            std.debug.print("psv{d} restart_rows={d}: djpeg pixel mismatch\n", .{ c[0], c[1] });
            return e;
        };
    }
}

// Decode direction against live `cjpeg` output across every predictor and the
// point transform, using a descending image so negative Rb-Rc / Ra-Rc
// differences (where `>> 1` and truncating `/ 2` disagree) are exercised.
test "decode cjpeg streams generated on the fly" {
    const a = testing.allocator;
    const cjpeg = try findTool(a, "cjpeg");
    defer a.free(cjpeg);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);

    const w: u32 = 32;
    const h: u32 = 24;
    var src = hashImage(w, h);
    // Blend in a descending ramp.
    for (&src, 0..) |*p, i| p.* = p.* / 2 +% @as(u16, @intCast(40000 - (i % w) * 300 - (i / w) * 517));
    const pgm = try writePgm16(a, w, h, &src);
    defer a.free(pgm);
    try tmp.dir.writeFile(.{ .sub_path = "in.pgm", .data = pgm });
    const in_path = try std.fs.path.join(a, &.{ dir, "in.pgm" });
    defer a.free(in_path);
    const out_path = try std.fs.path.join(a, &.{ dir, "out.jpg" });
    defer a.free(out_path);

    var psv: u8 = 1;
    while (psv <= 7) : (psv += 1) {
        for ([_]u4{ 0, 3 }) |pt| {
            var sel_buf: [8]u8 = undefined;
            const sel = try std.fmt.bufPrint(&sel_buf, "{d},{d}", .{ psv, pt });
            const argv = [_][]const u8{ cjpeg, "-precision", "16", "-lossless", sel, "-outfile", out_path, in_path };
            if (!try runTool(a, &argv)) return error.TestUnexpectedResult;

            const jpg = try tmp.dir.readFileAlloc(a, "out.jpg", 1 << 20);
            defer a.free(jpg);
            const res = try jpegli.decode(a, jpg, w, h);
            defer res.deinit(a);
            for (src, res.pixels, 0..) |s, d, i| {
                if ((s >> pt) << pt != d) {
                    std.debug.print("psv{d} pt{d}: mismatch at {d}: want {d} got {d}\n", .{ psv, pt, i, (s >> pt) << pt, d });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
