//! PackBits run-length encoding algorithm.
//!
//! PackBits is a simple RLE scheme used by DICOM RLE Lossless:
//! - Header byte n >= 0: literal run of (n + 1) bytes follows
//! - Header byte n < 0 (and n != -128): repeat next byte (-n + 1) times
//! - Header byte -128 (0x80): no-op (reserved)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from PackBits decoding.
pub const PackBitsError = error{
    /// Compressed data truncated in a literal run.
    TruncatedLiteral,
    /// Compressed data truncated in a replicate run.
    TruncatedRun,
    OutOfMemory,
};

/// Detail for a PackBits decode failure (mirrors the Rust error payloads).
pub const PackBitsDiagnostics = struct {
    /// Offset into the compressed data where the truncation was detected.
    offset: usize = 0,
    /// `TruncatedLiteral` only: bytes the literal run needs.
    count: usize = 0,
    /// `TruncatedLiteral` only: bytes remaining in the input.
    remaining: usize = 0,
};

/// Encode data using the PackBits algorithm.
///
/// Returns an allocated buffer that the caller must free with `allocator.free()`.
pub fn encodePackbits(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    if (data.len == 0) return allocator.alloc(u8, 0);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, data.len);

    var i: usize = 0;
    while (i < data.len) {
        // Try to find a run of identical bytes
        var run_len: usize = 1;
        while (i + run_len < data.len and run_len < 128 and data[i + run_len] == data[i]) {
            run_len += 1;
        }

        if (run_len > 1) {
            // Run: header = -(run_len - 1), then the repeated byte
            const header: i8 = -@as(i8, @intCast(run_len - 1));
            try out.append(allocator, @bitCast(header));
            try out.append(allocator, data[i]);
            i += run_len;
        } else {
            // Literal run: consume bytes until we hit a run of 3+ identical bytes
            const lit_start = i;
            var lit_len: usize = 1;

            while (i + lit_len < data.len and lit_len < 128) {
                if (i + lit_len + 2 < data.len and
                    data[i + lit_len] == data[i + lit_len + 1] and
                    data[i + lit_len] == data[i + lit_len + 2])
                {
                    break;
                }
                lit_len += 1;
            }

            // Literal: header = (lit_len - 1), then the literal bytes
            try out.append(allocator, @intCast(lit_len - 1));
            try out.appendSlice(allocator, data[lit_start .. lit_start + lit_len]);
            i += lit_len;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Decode PackBits compressed data. Returns an owned buffer.
///
/// `expected_len` is the expected decompressed size. If nonzero, decoding stops
/// once that many bytes have been produced (a final replicate run may overshoot
/// by up to 127 bytes). On a truncation error `diag` (when non-null) receives the
/// failing offset.
pub fn decodePackbits(
    allocator: Allocator,
    data: []const u8,
    expected_len: usize,
    diag: ?*PackBitsDiagnostics,
) PackBitsError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Pre-size from the expectation, but never beyond what the input can expand
    // to (a run expands at most 64x), so a malformed header cannot force a huge
    // allocation from a tiny stream.
    if (expected_len > 0) try out.ensureTotalCapacity(allocator, @min(expected_len, data.len *| 64));

    var i: usize = 0;
    while (i < data.len) {
        // Stop if we've reached the expected output length
        if (expected_len > 0 and out.items.len >= expected_len) break;

        const n: i8 = @bitCast(data[i]);
        i += 1;

        if (n == -128) continue; // no-op

        if (n >= 0) {
            // Literal run: read (n + 1) bytes
            const count = @as(usize, @intCast(n)) + 1;
            if (count > data.len - i) {
                if (diag) |d| d.* = .{ .offset = i, .count = count, .remaining = data.len - i };
                return error.TruncatedLiteral;
            }
            try out.appendSlice(allocator, data[i .. i + count]);
            i += count;
        } else {
            // Replicate run: repeat next byte (-n + 1) times
            const count = @as(usize, @intCast(-@as(i16, n))) + 1;
            if (i >= data.len) {
                if (diag) |d| d.* = .{ .offset = i };
                return error.TruncatedRun;
            }
            const val = data[i];
            i += 1;
            try out.appendNTimes(allocator, val, count);
        }
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectRoundtrip(data: []const u8) ![]u8 {
    const encoded = try encodePackbits(testing.allocator, data);
    errdefer testing.allocator.free(encoded);
    const decoded = try decodePackbits(testing.allocator, encoded, data.len, null);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, data, decoded);
    return encoded;
}

test "empty data" {
    const enc = try encodePackbits(testing.allocator, &.{});
    defer testing.allocator.free(enc);
    try testing.expectEqual(@as(usize, 0), enc.len);
    const dec = try decodePackbits(testing.allocator, &.{}, 0, null);
    defer testing.allocator.free(dec);
    try testing.expectEqual(@as(usize, 0), dec.len);
}

test "single byte" {
    const enc = try expectRoundtrip(&.{42});
    testing.allocator.free(enc);
}

test "all identical" {
    const data = [_]u8{0xAB} ** 50;
    const enc = try expectRoundtrip(&data);
    defer testing.allocator.free(enc);
    // A run of 50 should compress significantly
    try testing.expect(enc.len < data.len);
}

test "all different" {
    var data: [50]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    testing.allocator.free(try expectRoundtrip(&data));
}

test "mixed runs and literals" {
    // 3 identical, 5 different, 4 identical
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 1, 2, 3, 4, 5, 0x42, 0x42, 0x42, 0x42 };
    testing.allocator.free(try expectRoundtrip(&data));
}

test "max run length" {
    // 128 is the max run length in PackBits
    const data = [_]u8{0xBB} ** 128;
    const enc = try expectRoundtrip(&data);
    defer testing.allocator.free(enc);
    // Should be encoded as a single run: 2 bytes
    try testing.expectEqual(@as(usize, 2), enc.len);
}

test "run exceeds max" {
    // 200 identical bytes should split into 128 + 72
    const data = [_]u8{0xCC} ** 200;
    testing.allocator.free(try expectRoundtrip(&data));
}

test "max literal length" {
    var data: [128]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i * 7 + 13);
    testing.allocator.free(try expectRoundtrip(&data));
}

test "truncated literal error" {
    // header byte 0x02 means 3 literal bytes follow, but we only provide 1
    var diag: PackBitsDiagnostics = .{};
    try testing.expectError(error.TruncatedLiteral, decodePackbits(testing.allocator, &.{ 0x02, 0xFF }, 0, &diag));
    try testing.expectEqual(@as(usize, 1), diag.offset);
    try testing.expectEqual(@as(usize, 3), diag.count);
    try testing.expectEqual(@as(usize, 1), diag.remaining);
}

test "truncated run error" {
    // header byte 0xFE (-2) means repeat 3 times, but no data byte follows
    var diag: PackBitsDiagnostics = .{};
    try testing.expectError(error.TruncatedRun, decodePackbits(testing.allocator, &.{0xFE}, 0, &diag));
    try testing.expectEqual(@as(usize, 1), diag.offset);
}

test "noop byte skipped" {
    // -128 (0x80) is a no-op in PackBits
    const dec = try decodePackbits(testing.allocator, &.{ 0x80, 0x00, 0x42 }, 0, null);
    defer testing.allocator.free(dec);
    try testing.expectEqualSlices(u8, &.{0x42}, dec);
}

test "roundtrip random patterns" {
    var big: [255]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast(i);
    const zeros = [_]u8{0} ** 1000;
    var alt: [200]u8 = undefined;
    {
        var n: usize = 0;
        var i: u8 = 0;
        while (i < 20) : (i += 1) {
            if (i % 2 == 0) {
                for (0..10) |_| {
                    alt[n] = i;
                    n += 1;
                }
            } else {
                for (0..10) |j| {
                    alt[n] = i *% 10 +% @as(u8, @intCast(j));
                    n += 1;
                }
            }
        }
    }
    const patterns = [_][]const u8{
        &.{0},
        &.{ 0, 0 },
        &.{ 0, 1 },
        &.{ 0, 0, 0 },
        &.{ 0, 0, 1, 1, 1 },
        &.{ 1, 2, 3, 3, 3, 4, 5 },
        &big,
        &zeros,
        &alt,
    };
    for (patterns) |p| testing.allocator.free(try expectRoundtrip(p));
}

test "expected len stops early" {
    const data = [_]u8{0xAA} ** 100;
    const enc = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(enc);
    // Decode but request only 50 bytes
    const dec = try decodePackbits(testing.allocator, enc, 50, null);
    defer testing.allocator.free(dec);
    try testing.expect(dec.len >= 50);
}

test "decode does not preallocate beyond input expansion" {
    // A huge expected_len with a 2-byte stream must not allocate gigabytes.
    const dec = try decodePackbits(testing.allocator, &.{ 0x00, 0x07 }, 1 << 40, null);
    defer testing.allocator.free(dec);
    try testing.expectEqualSlices(u8, &.{0x07}, dec);
}
