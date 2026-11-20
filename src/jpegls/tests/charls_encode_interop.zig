//! CharLS decodes our planar RGB output (Rust `tests/charls_encode_interop.rs`).
//!
//! Opt-in: set `DICOS_CHARLS_INTEROP=1` with a C++ compiler (`c++`) and
//! libcharls installed; otherwise the test returns `error.SkipZigTest`.
//! Extra compiler flags (e.g. `-I/opt/homebrew/include -L/opt/homebrew/lib`)
//! may be supplied via `CHARLS_CXXFLAGS` (space separated).

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");

const testing = std.testing;
const ta = testing.allocator;

const charls_decode_cpp = @embedFile("../testdata/charls_decode.cpp");

fn run(argv: []const []const u8, cwd: std.fs.Dir) !bool {
    var child = std.process.Child.init(argv, ta);
    child.cwd_dir = cwd;
    const term = try child.spawnAndWait();
    return term == .Exited and term.Exited == 0;
}

test "charls decodes our planar rgb output" {
    if (!std.process.hasEnvVarConstant("DICOS_CHARLS_INTEROP")) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "charls_decode.cpp", .data = charls_decode_cpp });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ta);
    try argv.appendSlice(ta, &.{ "c++", "-std=c++14", "-Wall", "-Wextra", "-Werror", "charls_decode.cpp" });
    const extra = std.process.getEnvVarOwned(ta, "CHARLS_CXXFLAGS") catch null;
    defer if (extra) |e| ta.free(e);
    if (extra) |e| {
        var it = std.mem.tokenizeScalar(u8, e, ' ');
        while (it.next()) |flag| try argv.append(ta, flag);
    }
    try argv.appendSlice(ta, &.{ "-lcharls", "-o", "charls-decode" });
    try testing.expect(try run(argv.items, tmp.dir));

    for ([_]u8{ 8, 12, 16 }) |precision| {
        for ([_]u8{ 0, 3 }) |near| {
            const max: u32 = (@as(u32, 1) << @intCast(precision)) - 1;
            var pixels: [3 * 35]u16 = undefined;
            for (&pixels, 0..) |*p, i| p.* = @intCast((i * 619 + i / 35 * 71) & max);
            const stream = try util.encodeImg(&pixels, 7, 5, 3, .{ .precision = precision, .near = near });
            defer ta.free(stream);
            try tmp.dir.writeFile(.{ .sub_path = "input.jls", .data = stream });
            if (!try run(&.{ "./charls-decode", "input.jls", "output.raw" }, tmp.dir)) {
                std.debug.print("charls failed: precision {d}, near {d}\n", .{ precision, near });
                return error.TestUnexpectedResult;
            }
            const bytes = try tmp.dir.readFileAlloc(ta, "output.raw", 1 << 20);
            defer ta.free(bytes);
            const decoded = try ta.alloc(u16, if (precision == 8) bytes.len else bytes.len / 2);
            defer ta.free(decoded);
            if (precision == 8) {
                for (decoded, bytes) |*d, b| d.* = b;
            } else {
                for (decoded, 0..) |*d, j| d.* = std.mem.readInt(u16, bytes[2 * j ..][0..2], @import("builtin").cpu.arch.endian());
            }
            try testing.expectEqual(pixels.len, decoded.len);
            for (decoded, pixels) |a, e| try testing.expect(@abs(@as(i32, a) - @as(i32, e)) <= near);
            var img = try jpegls.decodeImage(ta, stream);
            defer img.deinit(ta);
            try testing.expectEqualSlices(u16, decoded, img.samples);
        }
    }
}
