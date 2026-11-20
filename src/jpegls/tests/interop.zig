//! Interop tests against a third-party JPEG-LS codec (CharLS / pillow-jpls),
//! ported from Rust `tests/interop.rs`.
//!
//! Fixture-driven and self-skipping: decodes every `*.jls` in the interop
//! directory and compares against a same-stem `.pgm` expectation (binary P5,
//! 8- or 16-bit big-endian). A stream may declare a near-lossless bound in its
//! file name as `...-nearN.jls`. When the directory holds no `.jls` files (the
//! checked-in state), the test returns `error.SkipZigTest`.
//!
//! The directory defaults to `src/jpegls/testdata/interop` relative to the
//! working directory (`zig build test` runs from the repository root) and can
//! be overridden with `JPEGLS_INTEROP_DIR`. See `testdata/interop/README.md`.

const std = @import("std");
const jpegls = @import("../root.zig");

const testing = std.testing;
const ta = testing.allocator;

const Pgm = struct { w: u32, h: u32, px: []u16 };

fn readPgm(d: []const u8) !Pgm {
    if (d.len < 2 or !std.mem.eql(u8, d[0..2], "P5")) return error.NotP5;
    var i: usize = 2;
    var toks: [3]u32 = undefined;
    var n: usize = 0;
    while (n < 3) {
        while (i < d.len and std.ascii.isWhitespace(d[i])) i += 1;
        if (i >= d.len) return error.ShortPgm;
        if (d[i] == '#') {
            while (i < d.len and d[i] != '\n') i += 1;
            continue;
        }
        const s = i;
        while (i < d.len and !std.ascii.isWhitespace(d[i])) i += 1;
        toks[n] = try std.fmt.parseInt(u32, d[s..i], 10);
        n += 1;
    }
    i += 1;
    const body = d[@min(i, d.len)..];
    const px = if (toks[2] > 255) blk: {
        const out = try ta.alloc(u16, body.len / 2);
        for (out, 0..) |*v, j| v.* = std.mem.readInt(u16, body[2 * j ..][0..2], .big);
        break :blk out;
    } else blk: {
        const out = try ta.alloc(u16, body.len);
        for (out, body) |*v, b| v.* = b;
        break :blk out;
    };
    return .{ .w = toks[0], .h = toks[1], .px = px };
}

/// Parse an optional `-nearN` suffix from a stream stem.
fn nearBound(stem: []const u8) i32 {
    const idx = std.mem.lastIndexOf(u8, stem, "-near") orelse return 0;
    return std.fmt.parseInt(i32, stem[idx + 5 ..], 10) catch 0;
}

test "decode charls fixtures" {
    const owned_env = std.process.getEnvVarOwned(ta, "JPEGLS_INTEROP_DIR") catch null;
    defer if (owned_env) |e| ta.free(e);
    const dir_path = owned_env orelse "src/jpegls/testdata/interop";

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close();

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |s| ta.free(s);
        names.deinit(ta);
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jls")) continue;
        try names.append(ta, try ta.dupe(u8, entry.name));
    }
    if (names.items.len == 0) return error.SkipZigTest;
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    for (names.items) |name| {
        const stem = name[0 .. name.len - 4];
        const pgm_name = try std.fmt.allocPrint(ta, "{s}.pgm", .{stem});
        defer ta.free(pgm_name);
        const pgm_bytes = try dir.readFileAlloc(ta, pgm_name, 1 << 28);
        defer ta.free(pgm_bytes);
        const pgm = try readPgm(pgm_bytes);
        defer ta.free(pgm.px);
        const near = nearBound(stem);

        const bytes = try dir.readFileAlloc(ta, name, 1 << 28);
        defer ta.free(bytes);
        const decoded = jpegls.decode(ta, bytes, pgm.w, pgm.h) catch |e| {
            std.debug.print("{s}: decode failed\n", .{stem});
            return e;
        };
        defer ta.free(decoded);
        try testing.expectEqual(pgm.px.len, decoded.len);
        for (decoded, pgm.px, 0..) |a, b, idx| {
            const diff = @abs(@as(i32, a) - @as(i32, b));
            if (diff > near) {
                std.debug.print("{s}: sample {d} diff {d} exceeds near bound {d}\n", .{ stem, idx, diff, near });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "near bound parsing" {
    try testing.expectEqual(@as(i32, 3), nearBound("foo-near3"));
    try testing.expectEqual(@as(i32, 0), nearBound("foo"));
}
