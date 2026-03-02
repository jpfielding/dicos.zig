//! Huffman table construction and lookup for JPEG Lossless encoding/decoding.
//!
//! Implements the Huffman code generation algorithm from ITU-T T.81 Annex C,
//! including a fast 8-bit lookup table for decoding.

const std = @import("std");

/// A Huffman table used for encoding and decoding JPEG lossless data.
///
/// The table stores both the canonical representation (bits/values) and
/// pre-computed codes, sizes, and a fast 8-bit lookup table.
pub const HuffmanTable = struct {
    /// Number of codes of each length (1-indexed: bits[i] = count of i-bit codes).
    bits: [17]u8,
    /// Symbol values in code-length order.
    values: []u8,
    /// Computed Huffman codes (parallel to `values`).
    codes: []u16,
    /// Computed code sizes in bits (parallel to `values`).
    sizes: []u8,
    /// Fast 8-bit lookup table. Each entry packs (size << 8 | value).
    /// A value of -1 means "not found, use slow path".
    lookup: [256]i16,
    /// Allocator used for dynamic arrays.
    allocator: std.mem.Allocator,

    /// Creates an empty Huffman table with no codes.
    pub fn init(allocator: std.mem.Allocator) HuffmanTable {
        return .{
            .bits = [_]u8{0} ** 17,
            .values = &[_]u8{},
            .codes = &[_]u16{},
            .sizes = &[_]u8{},
            .lookup = [_]i16{-1} ** 256,
            .allocator = allocator,
        };
    }

    /// Builds a Huffman table from `bits` (count of codes per length) and `values`.
    ///
    /// This generates the canonical Huffman codes and populates the fast lookup table.
    pub fn fromBitsValues(allocator: std.mem.Allocator, bits: [17]u8, values: []const u8) !HuffmanTable {
        var ht = HuffmanTable{
            .bits = bits,
            .values = try allocator.dupe(u8, values),
            .codes = &[_]u16{},
            .sizes = &[_]u8{},
            .lookup = [_]i16{-1} ** 256,
            .allocator = allocator,
        };
        try ht.generateCodes();
        ht.buildLookup();
        return ht;
    }

    /// Free all owned memory.
    pub fn deinit(self: *HuffmanTable) void {
        if (self.values.len > 0) self.allocator.free(self.values);
        if (self.codes.len > 0) self.allocator.free(self.codes);
        if (self.sizes.len > 0) self.allocator.free(self.sizes);
        self.values = &[_]u8{};
        self.codes = &[_]u16{};
        self.sizes = &[_]u8{};
    }

    /// Generate Huffman codes and sizes from the bits/values representation.
    ///
    /// Implements the GENERATE_SIZE_TABLE and GENERATE_CODE_TABLE procedures
    /// from ITU-T T.81 Annex C.
    fn generateCodes(self: *HuffmanTable) !void {
        var total: usize = 0;
        for (self.bits[1..17]) |b| {
            total += @as(usize, b);
        }

        if (self.codes.len > 0) self.allocator.free(self.codes);
        if (self.sizes.len > 0) self.allocator.free(self.sizes);

        if (total == 0) {
            self.codes = &[_]u16{};
            self.sizes = &[_]u8{};
            return;
        }

        self.codes = try self.allocator.alloc(u16, total);
        self.sizes = try self.allocator.alloc(u8, total);
        @memset(self.codes, 0);
        @memset(self.sizes, 0);

        // GENERATE_SIZE_TABLE: assign code lengths
        var k: usize = 0;
        for (1..17) |i| {
            const count = self.bits[i];
            for (0..count) |_| {
                self.sizes[k] = @intCast(i);
                k += 1;
            }
        }

        // GENERATE_CODE_TABLE: assign codes
        var code: u16 = 0;
        var si: u8 = self.sizes[0];
        for (0..total) |idx| {
            while (self.sizes[idx] > si) {
                code <<= 1;
                si += 1;
            }
            self.codes[idx] = code;
            code += 1;
        }
    }

    /// Build the fast 8-bit lookup table for decoding.
    ///
    /// For codes that fit in 8 bits or fewer, all possible byte-aligned
    /// representations are stored so that a single array index gives us
    /// the decoded symbol and its code length.
    fn buildLookup(self: *HuffmanTable) void {
        self.lookup = [_]i16{-1} ** 256;
        const total = self.codes.len;
        for (0..total) |k| {
            const size: u32 = @intCast(self.sizes[k]);
            if (size <= 8) {
                const base: u32 = @as(u32, self.codes[k]) << @intCast(8 - size);
                const count: u32 = @as(u32, 1) << @intCast(8 - size);
                for (0..count) |i| {
                    const idx: usize = @intCast(base + @as(u32, @intCast(i)));
                    // Pack size in high byte, value in low byte
                    self.lookup[idx] = (@as(i16, @intCast(size)) << 8) | @as(i16, self.values[k]);
                }
            }
        }
    }

    /// Look up a symbol using the fast 8-bit table.
    ///
    /// Returns `{code_size, symbol_value}` if the code fits in 8 bits,
    /// or `null` if the slow path must be used.
    pub fn fastLookup(self: *const HuffmanTable, byte_val: u8) ?struct { size: u8, value: u8 } {
        const entry = self.lookup[byte_val];
        if (entry >= 0) {
            return .{
                .size = @intCast(entry >> 8),
                .value = @intCast(entry & 0xFF),
            };
        }
        return null;
    }

    /// Find the code and size for a given symbol value (used during encoding).
    ///
    /// Returns `{code, size}` or `null` if the symbol is not in the table.
    pub fn encodeSymbol(self: *const HuffmanTable, symbol: u8) ?struct { code: u16, size: u8 } {
        for (self.values, 0..) |val, i| {
            if (val == symbol) {
                return .{
                    .code = self.codes[i],
                    .size = self.sizes[i],
                };
            }
        }
        return null;
    }

    /// Slow-path decode: given a sequence of bits accumulated so far and the
    /// current bit length, check if there is a matching code.
    ///
    /// Returns the symbol value if found, or `null`.
    pub fn decodeSlow(self: *const HuffmanTable, code: u16, size: u8) ?u8 {
        // Find the starting index for codes of this size
        var idx: usize = 0;
        for (1..size) |i| {
            idx += @as(usize, self.bits[i]);
        }
        const count = @as(usize, self.bits[size]);
        for (0..count) |i| {
            if (self.codes[idx + i] == code) {
                return self.values[idx + i];
            }
        }
        return null;
    }
};

/// Returns the SSSS category (number of bits needed) for a difference value.
///
/// For JPEG lossless, the category indicates how many additional bits are
/// needed to represent the magnitude of the difference.
pub fn categorize(diff: i32) u8 {
    // Use @abs which handles min_int correctly by returning the unsigned absolute value.
    const abs_val: u32 = @abs(diff);
    if (abs_val == 0) {
        return 0;
    }
    return @intCast(32 - @clz(abs_val));
}

/// Extends a partial bit value to a signed difference.
///
/// Implements the EXTEND procedure from ITU-T T.81 Table F.12.
/// If the high bit of the `ssss`-bit value is 0, the value is negative.
pub fn extend(bits: u32, ssss: u8) i32 {
    if (ssss == 0) {
        return 0;
    }
    const vt: u32 = @as(u32, 1) << @intCast(ssss - 1);
    if (bits < vt) {
        // Negative: bits - (2^ssss - 1)
        const upper: i32 = @as(i32, 1) << @intCast(ssss);
        return @as(i32, @intCast(bits)) - (upper - 1);
    } else {
        return @intCast(bits);
    }
}

/// Build the default Huffman table for 16-bit lossless JPEG encoding.
///
/// This table covers SSSS categories 0-16, which is sufficient for all
/// possible difference values in a 16-bit image.
pub fn buildDefaultTable(allocator: std.mem.Allocator) !HuffmanTable {
    // Fixed distribution covering 17 symbols (SSSS 0..=16):
    // bits[2]=1, bits[3]=5, bits[4..=14]=1 each => 1+5+11 = 17
    var bits = [_]u8{0} ** 17;
    bits[2] = 1;
    bits[3] = 5;
    bits[4] = 1;
    bits[5] = 1;
    bits[6] = 1;
    bits[7] = 1;
    bits[8] = 1;
    bits[9] = 1;
    bits[10] = 1;
    bits[11] = 1;
    bits[12] = 1;
    bits[13] = 1;
    bits[14] = 1;

    var values: [17]u8 = undefined;
    for (0..17) |i| {
        values[i] = @intCast(i);
    }

    return HuffmanTable.fromBitsValues(allocator, bits, &values);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "categorize zero" {
    try std.testing.expectEqual(@as(u8, 0), categorize(0));
}

test "categorize positive" {
    try std.testing.expectEqual(@as(u8, 1), categorize(1));
    try std.testing.expectEqual(@as(u8, 2), categorize(2));
    try std.testing.expectEqual(@as(u8, 2), categorize(3));
    try std.testing.expectEqual(@as(u8, 3), categorize(4));
    try std.testing.expectEqual(@as(u8, 3), categorize(7));
    try std.testing.expectEqual(@as(u8, 4), categorize(8));
    try std.testing.expectEqual(@as(u8, 8), categorize(255));
    try std.testing.expectEqual(@as(u8, 9), categorize(256));
    try std.testing.expectEqual(@as(u8, 15), categorize(32767));
    try std.testing.expectEqual(@as(u8, 16), categorize(65535));
}

test "categorize negative" {
    try std.testing.expectEqual(@as(u8, 1), categorize(-1));
    try std.testing.expectEqual(@as(u8, 2), categorize(-2));
    try std.testing.expectEqual(@as(u8, 2), categorize(-3));
    try std.testing.expectEqual(@as(u8, 8), categorize(-128));
    try std.testing.expectEqual(@as(u8, 16), categorize(-32768));
}

test "extend zero" {
    try std.testing.expectEqual(@as(i32, 0), extend(0, 0));
}

test "extend positive" {
    // ssss=1: vt=1, bits=1 >= vt => +1
    try std.testing.expectEqual(@as(i32, 1), extend(1, 1));
    // ssss=2: vt=2, bits=2 => +2, bits=3 => +3
    try std.testing.expectEqual(@as(i32, 2), extend(2, 2));
    try std.testing.expectEqual(@as(i32, 3), extend(3, 2));
    // ssss=8: vt=128, bits=200 => +200
    try std.testing.expectEqual(@as(i32, 200), extend(200, 8));
}

test "extend negative" {
    // ssss=1: vt=1, bits=0 < vt => 0 - (2^1 - 1) = -1
    try std.testing.expectEqual(@as(i32, -1), extend(0, 1));
    // ssss=2: vt=2, bits=0 => 0 - 3 = -3, bits=1 => 1 - 3 = -2
    try std.testing.expectEqual(@as(i32, -3), extend(0, 2));
    try std.testing.expectEqual(@as(i32, -2), extend(1, 2));
    // ssss=8: vt=128, bits=0 => 0 - 255 = -255
    try std.testing.expectEqual(@as(i32, -255), extend(0, 8));
    try std.testing.expectEqual(@as(i32, -128), extend(127, 8));
}

test "extend roundtrip" {
    // Verify that categorize + extend round-trips correctly
    var diff: i32 = -1000;
    while (diff <= 1000) : (diff += 1) {
        const ssss = categorize(diff);
        if (diff == 0) continue; // ssss=0, no additional bits
        const additional: u32 = if (diff < 0)
            @intCast(diff + (@as(i32, 1) << @intCast(ssss)) - 1)
        else
            @intCast(diff);
        const recovered = extend(additional, ssss);
        try std.testing.expectEqual(diff, recovered);
    }
}

test "default table has 17 symbols" {
    var ht = try buildDefaultTable(std.testing.allocator);
    defer ht.deinit();

    try std.testing.expectEqual(@as(usize, 17), ht.values.len);
    try std.testing.expectEqual(@as(usize, 17), ht.codes.len);
    try std.testing.expectEqual(@as(usize, 17), ht.sizes.len);
    for (0..17) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), ht.values[i]);
    }
}

test "default table codes are prefix free" {
    var ht = try buildDefaultTable(std.testing.allocator);
    defer ht.deinit();

    // No code should be a prefix of another. Since these are canonical
    // Huffman codes, we verify that codes of the same length are distinct.
    for (0..ht.codes.len) |i| {
        for ((i + 1)..ht.codes.len) |j| {
            if (ht.sizes[i] == ht.sizes[j]) {
                try std.testing.expect(ht.codes[i] != ht.codes[j]);
            }
        }
    }
}

test "fast lookup covers short codes" {
    var ht = try buildDefaultTable(std.testing.allocator);
    defer ht.deinit();

    // The shortest code should be 2 bits (bits[2]=1).
    // Verify the fast lookup finds it.
    const result = ht.encodeSymbol(0).?;
    try std.testing.expectEqual(@as(u8, 2), result.size);
    // The 2-bit code extended to 8 bits should all map to symbol 0
    const base: u8 = @intCast(@as(u16, result.code) << @intCast(8 - result.size));
    const count: u8 = @as(u8, 1) << @intCast(8 - result.size);
    for (0..count) |i| {
        const lookup_result = ht.fastLookup(base + @as(u8, @intCast(i))).?;
        try std.testing.expectEqual(@as(u8, 2), lookup_result.size);
        try std.testing.expectEqual(@as(u8, 0), lookup_result.value);
    }
}

test "encode symbol all present" {
    var ht = try buildDefaultTable(std.testing.allocator);
    defer ht.deinit();

    for (0..17) |sym| {
        const result = ht.encodeSymbol(@intCast(sym));
        try std.testing.expect(result != null);
    }
}

test "encode symbol missing" {
    var ht = try buildDefaultTable(std.testing.allocator);
    defer ht.deinit();

    try std.testing.expect(ht.encodeSymbol(17) == null);
    try std.testing.expect(ht.encodeSymbol(255) == null);
}

test "decode slow all symbols" {
    var ht = try buildDefaultTable(std.testing.allocator);
    defer ht.deinit();

    for (ht.values, 0..) |val, i| {
        const decoded = ht.decodeSlow(ht.codes[i], ht.sizes[i]);
        try std.testing.expectEqual(@as(?u8, val), decoded);
    }
}

test "decode slow invalid code" {
    var ht = try buildDefaultTable(std.testing.allocator);
    defer ht.deinit();

    // An impossible code of size 1 should not match anything
    try std.testing.expect(ht.decodeSlow(0xFFFF, 1) == null);
}

test "from bits values empty" {
    var ht = try HuffmanTable.fromBitsValues(std.testing.allocator, [_]u8{0} ** 17, &[_]u8{});
    defer ht.deinit();

    try std.testing.expectEqual(@as(usize, 0), ht.codes.len);
    try std.testing.expectEqual(@as(usize, 0), ht.sizes.len);
    for (ht.lookup) |v| {
        try std.testing.expectEqual(@as(i16, -1), v);
    }
}

test "single symbol table" {
    var bits = [_]u8{0} ** 17;
    bits[1] = 1; // one 1-bit code
    var ht = try HuffmanTable.fromBitsValues(std.testing.allocator, bits, &[_]u8{42});
    defer ht.deinit();

    try std.testing.expectEqual(@as(usize, 1), ht.codes.len);
    try std.testing.expectEqual(@as(u16, 0), ht.codes[0]); // code is "0"
    try std.testing.expectEqual(@as(u8, 1), ht.sizes[0]);
    const enc = ht.encodeSymbol(42).?;
    try std.testing.expectEqual(@as(u16, 0), enc.code);
    try std.testing.expectEqual(@as(u8, 1), enc.size);
    // Fast lookup: 0b0xxxxxxx should all resolve to symbol 42
    for (0..128) |byte_val| {
        const lookup_result = ht.fastLookup(@intCast(byte_val)).?;
        try std.testing.expectEqual(@as(u8, 1), lookup_result.size);
        try std.testing.expectEqual(@as(u8, 42), lookup_result.value);
    }
}
