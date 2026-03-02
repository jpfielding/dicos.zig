//! PackBits run-length encoding algorithm.
//!
//! PackBits is a simple RLE scheme used by DICOM RLE Lossless:
//! - Header byte n >= 0: literal run of (n + 1) bytes follows
//! - Header byte n < 0 (and n != -128): repeat next byte (-n + 1) times
//! - Header byte -128 (0x80): no-op (reserved)

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Errors from PackBits decoding.
pub const PackBitsError = error{
    /// Compressed data truncated in a literal run.
    TruncatedLiteral,
    /// Compressed data truncated in a replicate run.
    TruncatedRun,
};

/// Encode data using the PackBits algorithm.
///
/// Returns an allocated buffer that the caller must free with `allocator.free()`.
pub fn encodePackbits(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    if (data.len == 0) {
        return allocator.alloc(u8, 0);
    }

    var out = std.array_list.AlignedManaged(u8, null).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;

    while (i < data.len) {
        // Try to find a run of identical bytes
        var run_len: usize = 1;
        while (i + run_len < data.len and run_len < 128 and data[i + run_len] == data[i]) {
            run_len += 1;
        }

        if (run_len > 1) {
            // Write run: header = -(run_len - 1), then the repeated byte
            const header: i8 = -@as(i8, @intCast(run_len - 1));
            try out.append(@bitCast(header));
            try out.append(data[i]);
            i += run_len;
        } else {
            // Literal run: consume bytes until we hit a run of 3+ identical bytes
            const lit_start = i;
            var lit_len: usize = 1;

            while (i + lit_len < data.len and lit_len < 128) {
                // Check if the next 3 bytes are identical (trigger run break)
                if (i + lit_len + 2 < data.len and
                    data[i + lit_len] == data[i + lit_len + 1] and
                    data[i + lit_len] == data[i + lit_len + 2])
                {
                    break;
                }
                lit_len += 1;
            }

            // Write literal: header = (lit_len - 1), then the literal bytes
            const header: u8 = @intCast(lit_len - 1);
            try out.append(header);
            try out.appendSlice(data[lit_start .. lit_start + lit_len]);
            i += lit_len;
        }
    }

    return out.toOwnedSlice();
}

/// Decode PackBits compressed data.
///
/// `expected_len` is the expected decompressed size. If nonzero, decoding
/// stops once that many bytes have been produced.
/// Returns an allocated buffer that the caller must free with `allocator.free()`.
pub fn decodePackbits(allocator: Allocator, data: []const u8, expected_len: usize) (PackBitsError || Allocator.Error)![]u8 {
    var out = if (expected_len > 0)
        try std.array_list.AlignedManaged(u8, null).initCapacity(allocator, expected_len)
    else
        std.array_list.AlignedManaged(u8, null).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;

    while (i < data.len) {
        // Stop if we've reached the expected output length
        if (expected_len > 0 and out.items.len >= expected_len) {
            break;
        }

        const n: i8 = @bitCast(data[i]);
        i += 1;

        if (n == -128) {
            // No-op
            continue;
        }

        if (n >= 0) {
            // Literal run: read (n + 1) bytes
            const count: usize = @as(usize, @intCast(n)) + 1;
            if (i + count > data.len) {
                return PackBitsError.TruncatedLiteral;
            }
            try out.appendSlice(data[i .. i + count]);
            i += count;
        } else {
            // Replicate run: repeat next byte (-n + 1) times
            const count: usize = @as(usize, @intCast(-@as(i16, n))) + 1;
            if (i >= data.len) {
                return PackBitsError.TruncatedRun;
            }
            const val = data[i];
            i += 1;
            try out.appendNTimes(val, count);
        }
    }

    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty data" {
    const encoded = try encodePackbits(testing.allocator, &.{});
    defer testing.allocator.free(encoded);
    try testing.expectEqual(@as(usize, 0), encoded.len);

    const decoded = try decodePackbits(testing.allocator, &.{}, 0);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "single byte" {
    const encoded = try encodePackbits(testing.allocator, &.{42});
    defer testing.allocator.free(encoded);

    const decoded = try decodePackbits(testing.allocator, encoded, 1);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &.{42}, decoded);
}

test "all identical" {
    const data = [_]u8{0xAB} ** 50;
    const encoded = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(encoded);

    const decoded = try decodePackbits(testing.allocator, encoded, data.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &data, decoded);
    // A run of 50 should compress significantly
    try testing.expect(encoded.len < data.len);
}

test "all different" {
    var data: [50]u8 = undefined;
    for (0..50) |i| {
        data[i] = @intCast(i);
    }
    const encoded = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(encoded);

    const decoded = try decodePackbits(testing.allocator, encoded, data.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &data, decoded);
}

test "mixed runs and literals" {
    // Pattern: 3 identical, 5 different, 4 identical
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 1, 2, 3, 4, 5, 0x42, 0x42, 0x42, 0x42 };
    const encoded = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(encoded);

    const decoded = try decodePackbits(testing.allocator, encoded, data.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &data, decoded);
}

test "max run length" {
    // 128 is the max run length in PackBits
    const data = [_]u8{0xBB} ** 128;
    const encoded = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(encoded);

    const decoded = try decodePackbits(testing.allocator, encoded, data.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &data, decoded);
    // Should be encoded as a single run: 2 bytes
    try testing.expectEqual(@as(usize, 2), encoded.len);
}

test "run exceeds max" {
    // 200 identical bytes should split into 128 + 72
    const data = [_]u8{0xCC} ** 200;
    const encoded = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(encoded);

    const decoded = try decodePackbits(testing.allocator, encoded, data.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &data, decoded);
}

test "max literal length" {
    // 128 different bytes at max literal
    var data: [128]u8 = undefined;
    for (0..128) |i| {
        data[i] = @truncate(i *% 7 +% 13);
    }
    const encoded = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(encoded);

    const decoded = try decodePackbits(testing.allocator, encoded, data.len);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &data, decoded);
}

test "truncated literal error" {
    // header byte 0x02 means 3 literal bytes follow, but we only provide 1
    const bad_data = [_]u8{ 0x02, 0xFF };
    const result = decodePackbits(testing.allocator, &bad_data, 0);
    try testing.expectError(PackBitsError.TruncatedLiteral, result);
}

test "truncated run error" {
    // header byte 0xFE (-2) means repeat 3 times, but no data byte follows
    const bad_data = [_]u8{0xFE};
    const result = decodePackbits(testing.allocator, &bad_data, 0);
    try testing.expectError(PackBitsError.TruncatedRun, result);
}

test "noop byte skipped" {
    // -128 (0x80) is a no-op in PackBits
    const encoded = [_]u8{ 0x80, 0x00, 0x42 }; // noop, then literal 1 byte (0x42)
    const decoded = try decodePackbits(testing.allocator, &encoded, 0);
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &.{0x42}, decoded);
}

test "roundtrip random patterns" {
    const Pattern = struct {
        data: []const u8,
    };

    // Pattern 0: single zero
    const p0 = [_]u8{0};
    // Pattern 1: two zeros
    const p1 = [_]u8{ 0, 0 };
    // Pattern 2: 0, 1
    const p2 = [_]u8{ 0, 1 };
    // Pattern 3: three zeros
    const p3 = [_]u8{ 0, 0, 0 };
    // Pattern 4: 0,0,1,1,1
    const p4 = [_]u8{ 0, 0, 1, 1, 1 };
    // Pattern 5: 1,2,3,3,3,4,5
    const p5 = [_]u8{ 1, 2, 3, 3, 3, 4, 5 };
    // Pattern 6: 0..255
    const p6 = comptime blk: {
        var arr: [255]u8 = undefined;
        for (0..255) |idx| {
            arr[idx] = @intCast(idx);
        }
        break :blk arr;
    };
    // Pattern 7: 1000 zeros
    const p7 = [_]u8{0} ** 1000;
    // Pattern 8: alternating runs and literals
    const p8 = comptime blk: {
        var arr: [200]u8 = undefined;
        var pos: usize = 0;
        for (0..20) |ii| {
            const i: u8 = @intCast(ii);
            if (i % 2 == 0) {
                for (0..10) |_| {
                    arr[pos] = i;
                    pos += 1;
                }
            } else {
                for (0..10) |jj| {
                    const j: u8 = @intCast(jj);
                    arr[pos] = i *% 10 +% j;
                    pos += 1;
                }
            }
        }
        break :blk arr;
    };

    const patterns = [_]Pattern{
        .{ .data = &p0 },
        .{ .data = &p1 },
        .{ .data = &p2 },
        .{ .data = &p3 },
        .{ .data = &p4 },
        .{ .data = &p5 },
        .{ .data = &p6 },
        .{ .data = &p7 },
        .{ .data = &p8 },
    };

    for (patterns, 0..) |pattern, idx| {
        _ = idx;
        const encoded = try encodePackbits(testing.allocator, pattern.data);
        defer testing.allocator.free(encoded);

        const decoded = try decodePackbits(testing.allocator, encoded, pattern.data.len);
        defer testing.allocator.free(decoded);

        try testing.expectEqualSlices(u8, pattern.data, decoded);
    }
}

test "expected len stops early" {
    const data = [_]u8{0xAA} ** 100;
    const encoded = try encodePackbits(testing.allocator, &data);
    defer testing.allocator.free(encoded);

    // Decode but request only 50 bytes
    const decoded = try decodePackbits(testing.allocator, encoded, 50);
    defer testing.allocator.free(decoded);
    try testing.expect(decoded.len >= 50);
}
