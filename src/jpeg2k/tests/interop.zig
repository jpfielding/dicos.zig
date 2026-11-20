//! Interop tests against OpenJPEG (`opj_compress` / `opj_decompress`, 2.5.x).
//! Port of Rust `tests/interop.rs`.
//!
//! * **Decode** (`decode openjpeg fixtures`): decodes the checked-in
//!   `testdata/interop/*.j2k` streams (produced by `opj_compress` in its
//!   default reversible mode) and asserts exact equality with the source PGMs.
//! * **Encode** (`encode roundtrip via opj_decompress`): encodes with this
//!   codec, hands the stream to `opj_decompress`, and compares pixels.
//! * **Live decode** (`decode live opj_compress output`): runs
//!   `opj_compress` on the source PGMs and decodes the result.
//!
//! The tool-driven tests return `error.SkipZigTest` when the OpenJPEG tools
//! are not found on `PATH`, `/opt/homebrew/bin` or `/usr/local/bin`.

const std = @import("std");
const jpeg2k = @import("../root.zig");

const testing = std.testing;
const ta = testing.allocator;

const Pgm = struct {
    w: u32,
    h: u32,
    px: []u16,

    fn deinit(self: *Pgm) void {
        ta.free(self.px);
    }
};

/// Parse a binary 16-bit PGM (P5, big-endian samples).
fn parsePgm(d: []const u8) !Pgm {
    if (d.len < 2 or !std.mem.eql(u8, d[0..2], "P5")) return error.NotP5;
    var i: usize = 2;
    var toks: [3]u32 = undefined;
    var nt: usize = 0;
    while (nt < 3) {
        while (i < d.len and std.ascii.isWhitespace(d[i])) i += 1;
        if (i >= d.len) return error.Truncated;
        if (d[i] == '#') {
            while (i < d.len and d[i] != '\n') i += 1;
            continue;
        }
        const s = i;
        while (i < d.len and !std.ascii.isWhitespace(d[i])) i += 1;
        toks[nt] = try std.fmt.parseInt(u32, d[s..i], 10);
        nt += 1;
    }
    i += 1;
    const w = toks[0];
    const h = toks[1];
    if (toks[2] <= 255) return error.Not16Bit;
    const n = @as(usize, w) * h;
    if (d.len - i < n * 2) return error.Truncated;
    const px = try ta.alloc(u16, n);
    for (px, 0..) |*p, k| p.* = std.mem.readInt(u16, d[i + 2 * k ..][0..2], .big);
    return .{ .w = w, .h = h, .px = px };
}

const Fx = struct { j2k_name: []const u8, j2k: []const u8, pgm_name: []const u8, pgm: []const u8 };

const random_pgm = @embedFile("../testdata/interop/random-32x32.pgm");

/// (stream, source PGM) pairs. `-cb32` shares the random source.
const fixtures = [_]Fx{
    .{ .j2k_name = "gradient-64x64.j2k", .j2k = @embedFile("../testdata/interop/gradient-64x64.j2k"), .pgm_name = "gradient-64x64.pgm", .pgm = @embedFile("../testdata/interop/gradient-64x64.pgm") },
    .{ .j2k_name = "odd-61x47.j2k", .j2k = @embedFile("../testdata/interop/odd-61x47.j2k"), .pgm_name = "odd-61x47.pgm", .pgm = @embedFile("../testdata/interop/odd-61x47.pgm") },
    .{ .j2k_name = "random-32x32.j2k", .j2k = @embedFile("../testdata/interop/random-32x32.j2k"), .pgm_name = "random-32x32.pgm", .pgm = random_pgm },
    .{ .j2k_name = "random-32x32-cb32.j2k", .j2k = @embedFile("../testdata/interop/random-32x32-cb32.j2k"), .pgm_name = "random-32x32.pgm", .pgm = random_pgm },
};

test "decode openjpeg fixtures" {
    for (fixtures) |f| {
        var src = try parsePgm(f.pgm);
        defer src.deinit();
        var img = try jpeg2k.decode(ta, f.j2k, src.w, src.h);
        defer img.deinit(ta);
        try testing.expectEqual(src.w, img.width);
        try testing.expectEqual(src.h, img.height);
        try testing.expectEqualSlices(u16, src.px, img.pixels);
    }
}

/// Locate an OpenJPEG tool, or `null` when absent.
fn findTool(name: []const u8, buf: []u8) ?[]const u8 {
    if (runOk(&.{ name, "-h" })) return name;
    for ([_][]const u8{ "/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/" }) |dir| {
        const p = std.fmt.bufPrint(buf, "{s}{s}", .{ dir, name }) catch continue;
        std.fs.accessAbsolute(p, .{}) catch continue;
        return p;
    }
    return null;
}

fn runOk(argv: []const []const u8) bool {
    const r = std.process.Child.run(.{ .allocator = ta, .argv = argv, .max_output_bytes = 1 << 20 }) catch return false;
    ta.free(r.stdout);
    ta.free(r.stderr);
    return true;
}

fn runTool(argv: []const []const u8, cwd: []const u8) !void {
    const r = try std.process.Child.run(.{ .allocator = ta, .argv = argv, .cwd = cwd, .max_output_bytes = 1 << 20 });
    defer ta.free(r.stdout);
    defer ta.free(r.stderr);
    switch (r.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("{s} failed ({d}): {s}\n", .{ argv[0], code, r.stderr });
            return error.ToolFailed;
        },
        else => return error.ToolFailed,
    }
}

test "encode roundtrip via opj_decompress" {
    var tool_buf: [256]u8 = undefined;
    const tool = findTool("opj_decompress", &tool_buf) orelse return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(ta, ".");
    defer ta.free(dir);

    for (fixtures[0..3]) |f| {
        var src = try parsePgm(f.pgm);
        defer src.deinit();

        var aw: std.Io.Writer.Allocating = .init(ta);
        defer aw.deinit();
        try jpeg2k.encode(ta, src.px, src.w, src.h, &aw.writer);
        try tmp.dir.writeFile(.{ .sub_path = "ours.j2k", .data = aw.written() });

        try runTool(&.{ tool, "-i", "ours.j2k", "-o", "ours.pgm" }, dir);

        const out = try tmp.dir.readFileAlloc(ta, "ours.pgm", 1 << 24);
        defer ta.free(out);
        var got = try parsePgm(out);
        defer got.deinit();
        try testing.expectEqual(src.w, got.w);
        try testing.expectEqual(src.h, got.h);
        try testing.expectEqualSlices(u16, src.px, got.px);
    }
}

test "decode live opj_compress output" {
    var tool_buf: [256]u8 = undefined;
    const tool = findTool("opj_compress", &tool_buf) orelse return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(ta, ".");
    defer ta.free(dir);

    const variants = [_][]const []const u8{
        &.{},
        &.{ "-b", "32,32" },
        &.{ "-n", "1" },
        &.{ "-n", "3", "-b", "16,8" },
    };
    for (fixtures[0..3]) |f| for (variants) |extra| {
        var src = try parsePgm(f.pgm);
        defer src.deinit();
        try tmp.dir.writeFile(.{ .sub_path = "src.pgm", .data = f.pgm });

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(ta);
        try argv.appendSlice(ta, &.{ tool, "-i", "src.pgm", "-o", "opj.j2k" });
        try argv.appendSlice(ta, extra);
        try runTool(argv.items, dir);

        const stream = try tmp.dir.readFileAlloc(ta, "opj.j2k", 1 << 24);
        defer ta.free(stream);
        var img = try jpeg2k.decodeWithOptions(ta, stream, src.w, src.h, .{ .legacy = .standard_only });
        defer img.deinit(ta);
        try testing.expectEqualSlices(u16, src.px, img.pixels);
    };
}
