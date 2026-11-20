//! Shared helpers for the JPEG-LS tests.

const std = @import("std");
const jpegls = @import("../root.zig");

pub const allocator = std.testing.allocator;

/// Encode with `encodeWithOptions` into a freshly allocated slice.
pub fn encodeOpts(pixels: []const u16, w: u32, h: u32, opts: jpegls.EncodeOptions) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try jpegls.encodeWithOptions(allocator, pixels, w, h, opts, &aw.writer);
    return aw.toOwnedSlice();
}

/// Encode with `encodeImage` into a freshly allocated slice.
pub fn encodeImg(samples: []const u16, w: u32, h: u32, components: u8, opts: jpegls.EncodeOptions) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try jpegls.encodeImage(allocator, samples, w, h, components, opts, &aw.writer);
    return aw.toOwnedSlice();
}

/// Position of the first occurrence of `needle`.
pub fn find(hay: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, hay, needle);
}

/// Deterministic LCG samples in `0..=maxval` (the generator used by the Rust
/// t87_roundtrip tests).
pub fn lcg(seed: u64, n: usize, maxval: u16) ![]u16 {
    const out = try allocator.alloc(u16, n);
    var s = seed;
    for (out) |*v| {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        v.* = @intCast(@as(u32, @truncate(s >> 33)) % (@as(u32, maxval) + 1));
    }
    return out;
}

/// Concatenate slices into a new allocation.
pub fn concat(parts: []const []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, parts);
}

/// Decode and assert the result equals `expected`.
pub fn expectDecodes(stream: []const u8, w: u32, h: u32, expected: []const u16) !void {
    const got = try jpegls.decode(allocator, stream, w, h);
    defer allocator.free(got);
    try std.testing.expectEqualSlices(u16, expected, got);
}

/// Run `decode`, freeing any successful result, and return only the error
/// (or `null` on success).
pub fn decodeErr(stream: []const u8, w: u32, h: u32) ?anyerror {
    return decodeErrOpts(stream, w, h, .{});
}

pub fn decodeErrOpts(stream: []const u8, w: u32, h: u32, opts: jpegls.DecodeOptions) ?anyerror {
    const got = jpegls.decodeWithOptions(allocator, stream, w, h, opts) catch |e| return e;
    allocator.free(got);
    return null;
}

/// Run `decodeImage`, freeing any successful result, and return only the
/// error (or `null` on success).
pub fn decodeImageErr(stream: []const u8) ?anyerror {
    return decodeImageErrOpts(stream, .{});
}

pub fn decodeImageErrOpts(stream: []const u8, opts: jpegls.DecodeImageOptions) ?anyerror {
    var img = jpegls.decodeImageWithOptions(allocator, stream, opts) catch |e| return e;
    img.deinit(allocator);
    return null;
}

pub fn expectErr(expected: anyerror, actual: ?anyerror) !void {
    try std.testing.expectEqual(@as(?anyerror, expected), actual);
}
