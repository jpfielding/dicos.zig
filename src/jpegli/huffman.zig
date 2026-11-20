//! Huffman table construction and lookup for JPEG Lossless encoding/decoding.
//!
//! Implements the Huffman code generation algorithm from ITU-T T.81 Annex C,
//! including a fast 8-bit lookup table for decoding.

const std = @import("std");
const Allocator = std.mem.Allocator;

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
    allocator: Allocator,

    /// Creates an empty Huffman table with no codes.
    pub fn init(allocator: Allocator) HuffmanTable {
        return .{
            .bits = [_]u8{0} ** 17,
            .values = &.{},
            .codes = &.{},
            .sizes = &.{},
            .lookup = [_]i16{-1} ** 256,
            .allocator = allocator,
        };
    }

    /// Builds a Huffman table from `bits` (count of codes per length) and `values`
    /// (copied). `values.len` must be at least the sum of `bits[1..=16]`, and `bits`
    /// must satisfy `bitsValid`; otherwise `error.InvalidTable` is returned.
    ///
    /// Generates the canonical Huffman codes and populates the fast lookup table.
    pub fn fromBitsValues(allocator: Allocator, bits: [17]u8, values: []const u8) !HuffmanTable {
        var total: usize = 0;
        for (bits[1..17]) |b| total += b;
        if (values.len < total or !bitsValid(&bits)) return error.InvalidTable;

        var ht = HuffmanTable.init(allocator);
        errdefer ht.deinit();
        ht.bits = bits;
        ht.values = try allocator.dupe(u8, values);
        try ht.generateCodes();
        ht.buildLookup();
        return ht;
    }

    pub fn deinit(self: *HuffmanTable) void {
        if (self.values.len > 0) self.allocator.free(self.values);
        if (self.codes.len > 0) self.allocator.free(self.codes);
        if (self.sizes.len > 0) self.allocator.free(self.sizes);
        self.values = &.{};
        self.codes = &.{};
        self.sizes = &.{};
    }

    /// GENERATE_SIZE_TABLE and GENERATE_CODE_TABLE from ITU-T T.81 Annex C.
    fn generateCodes(self: *HuffmanTable) !void {
        var total: usize = 0;
        for (self.bits[1..17]) |b| total += b;
        if (total == 0) return;

        self.codes = try self.allocator.alloc(u16, total);
        errdefer {
            self.allocator.free(self.codes);
            self.codes = &.{};
        }
        self.sizes = try self.allocator.alloc(u8, total);

        var k: usize = 0;
        var len: u8 = 1;
        while (len <= 16) : (len += 1) {
            var n = self.bits[len];
            while (n > 0) : (n -= 1) {
                self.sizes[k] = len;
                k += 1;
            }
        }

        var code: u16 = 0;
        var si = self.sizes[0];
        for (0..total) |i| {
            while (self.sizes[i] > si) {
                code <<= 1;
                si += 1;
            }
            self.codes[i] = code;
            // A complete length-16 code assigns 0xFFFF to its last symbol; the
            // trailing increment past it is unused but must not overflow.
            code +%= 1;
        }
    }

    /// Build the fast 8-bit lookup table for decoding.
    ///
    /// For codes of at most 8 bits, every byte-aligned extension is stored so a
    /// single array index yields the symbol and its code length.
    fn buildLookup(self: *HuffmanTable) void {
        self.lookup = [_]i16{-1} ** 256;
        for (0..self.codes.len) |k| {
            const size: u5 = @intCast(self.sizes[k]);
            if (size <= 8) {
                const shift: u5 = 8 - size;
                const base: u32 = @as(u32, self.codes[k]) << shift;
                const count: u32 = @as(u32, 1) << shift;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const idx: usize = @intCast(base + i);
                    self.lookup[idx] = (@as(i16, size) << 8) | @as(i16, self.values[k]);
                }
            }
        }
    }

    pub const FastEntry = struct { size: u8, value: u8 };

    /// Look up a symbol using the fast 8-bit table. Returns null when the code is
    /// longer than 8 bits (the slow path must be used).
    pub fn fastLookup(self: *const HuffmanTable, byte_val: u8) ?FastEntry {
        const entry = self.lookup[byte_val];
        if (entry < 0) return null;
        return .{ .size = @intCast(entry >> 8), .value = @intCast(entry & 0xFF) };
    }

    pub const CodeSize = struct { code: u16, size: u8 };

    /// Find the code and size for a symbol (used during encoding).
    pub fn encodeSymbol(self: *const HuffmanTable, symbol: u8) ?CodeSize {
        for (self.values[0..self.codes.len], 0..) |v, i| {
            if (v == symbol) return .{ .code = self.codes[i], .size = self.sizes[i] };
        }
        return null;
    }

    /// Slow-path decode: check whether `code` of length `size` matches a symbol.
    pub fn decodeSlow(self: *const HuffmanTable, code: u16, size: u8) ?u8 {
        var idx: usize = 0;
        var i: usize = 1;
        while (i < size) : (i += 1) idx += self.bits[i];
        const count: usize = self.bits[size];
        for (0..count) |j| {
            if (self.codes[idx + j] == code) return self.values[idx + j];
        }
        return null;
    }
};

/// Returns true if `bits` (count of Huffman codes per length 1..=16) forms a
/// valid, non-oversubscribed code assignment (ITU-T T.81 Annex C / Kraft).
///
/// An oversubscribed table would make canonical code generation emit aliasing
/// codes that overflow the 8-bit lookup index, so it must be rejected before
/// `HuffmanTable.fromBitsValues` builds the table.
pub fn bitsValid(bits: *const [17]u8) bool {
    var code: u32 = 0;
    for (1..17) |len| {
        code += bits[len];
        if (code > (@as(u32, 1) << @intCast(len))) return false;
        code <<= 1;
    }
    return true;
}

/// Returns the SSSS category (number of bits needed) for a difference value.
pub fn categorize(diff: i32) u8 {
    const abs = @abs(diff);
    if (abs == 0) return 0;
    return @intCast(32 - @clz(abs));
}

/// EXTEND procedure from ITU-T T.81 Table F.12: if the high bit of the
/// `ssss`-bit value is 0, the value is negative.
pub fn extend(bits: u32, ssss: u8) i32 {
    if (ssss == 0) return 0;
    const vt = @as(u32, 1) << @intCast(ssss - 1);
    if (bits < vt) {
        return @as(i32, @intCast(bits)) - ((@as(i32, 1) << @intCast(ssss)) - 1);
    }
    return @intCast(bits);
}

/// Default Huffman table covering SSSS categories 0-16 (all 16-bit differences).
pub fn buildDefaultTable(allocator: Allocator) !HuffmanTable {
    // bits[2]=1, bits[3]=5, bits[4..=14]=1 each => 1+5+11 = 17 symbols.
    var bits = [_]u8{0} ** 17;
    bits[2] = 1;
    bits[3] = 5;
    for (4..15) |i| bits[i] = 1;

    var values: [17]u8 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i);
    return HuffmanTable.fromBitsValues(allocator, bits, &values);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "categorize zero" {
    try testing.expectEqual(@as(u8, 0), categorize(0));
}

test "categorize positive" {
    try testing.expectEqual(@as(u8, 1), categorize(1));
    try testing.expectEqual(@as(u8, 2), categorize(2));
    try testing.expectEqual(@as(u8, 2), categorize(3));
    try testing.expectEqual(@as(u8, 3), categorize(4));
    try testing.expectEqual(@as(u8, 3), categorize(7));
    try testing.expectEqual(@as(u8, 4), categorize(8));
    try testing.expectEqual(@as(u8, 8), categorize(255));
    try testing.expectEqual(@as(u8, 9), categorize(256));
    try testing.expectEqual(@as(u8, 15), categorize(32767));
    try testing.expectEqual(@as(u8, 16), categorize(65535));
}

test "categorize negative" {
    try testing.expectEqual(@as(u8, 1), categorize(-1));
    try testing.expectEqual(@as(u8, 2), categorize(-2));
    try testing.expectEqual(@as(u8, 2), categorize(-3));
    try testing.expectEqual(@as(u8, 8), categorize(-128));
    try testing.expectEqual(@as(u8, 16), categorize(-32768));
}

test "extend zero" {
    try testing.expectEqual(@as(i32, 0), extend(0, 0));
}

test "extend positive" {
    try testing.expectEqual(@as(i32, 1), extend(1, 1));
    try testing.expectEqual(@as(i32, 2), extend(2, 2));
    try testing.expectEqual(@as(i32, 3), extend(3, 2));
    try testing.expectEqual(@as(i32, 200), extend(200, 8));
}

test "extend negative" {
    try testing.expectEqual(@as(i32, -1), extend(0, 1));
    try testing.expectEqual(@as(i32, -3), extend(0, 2));
    try testing.expectEqual(@as(i32, -2), extend(1, 2));
    try testing.expectEqual(@as(i32, -255), extend(0, 8));
    try testing.expectEqual(@as(i32, -128), extend(127, 8));
}

test "extend roundtrip" {
    var diff: i32 = -1000;
    while (diff <= 1000) : (diff += 1) {
        const ssss = categorize(diff);
        const additional: u32 = if (diff < 0)
            @intCast(diff + (@as(i32, 1) << @intCast(ssss)) - 1)
        else if (diff > 0)
            @intCast(diff)
        else
            continue;
        try testing.expectEqual(diff, extend(additional, ssss));
    }
}

test "default table has 17 symbols" {
    var ht = try buildDefaultTable(testing.allocator);
    defer ht.deinit();
    try testing.expectEqual(@as(usize, 17), ht.values.len);
    try testing.expectEqual(@as(usize, 17), ht.codes.len);
    try testing.expectEqual(@as(usize, 17), ht.sizes.len);
    for (0..17) |i| try testing.expectEqual(@as(u8, @intCast(i)), ht.values[i]);
}

test "default table codes are prefix free" {
    var ht = try buildDefaultTable(testing.allocator);
    defer ht.deinit();
    for (0..ht.codes.len) |i| {
        for (i + 1..ht.codes.len) |j| {
            if (ht.sizes[i] == ht.sizes[j]) {
                try testing.expect(ht.codes[i] != ht.codes[j]);
            }
        }
    }
}

test "fast lookup covers short codes" {
    var ht = try buildDefaultTable(testing.allocator);
    defer ht.deinit();
    const cs = ht.encodeSymbol(0).?;
    try testing.expectEqual(@as(u8, 2), cs.size);
    const base: u8 = @as(u8, @intCast(cs.code)) << @intCast(8 - cs.size);
    var i: u8 = 0;
    while (i < (@as(u8, 1) << @intCast(8 - cs.size))) : (i += 1) {
        const e = ht.fastLookup(base + i).?;
        try testing.expectEqual(@as(u8, 2), e.size);
        try testing.expectEqual(@as(u8, 0), e.value);
    }
}

test "encode symbol all present" {
    var ht = try buildDefaultTable(testing.allocator);
    defer ht.deinit();
    for (0..17) |sym| try testing.expect(ht.encodeSymbol(@intCast(sym)) != null);
}

test "encode symbol missing" {
    var ht = try buildDefaultTable(testing.allocator);
    defer ht.deinit();
    try testing.expect(ht.encodeSymbol(17) == null);
    try testing.expect(ht.encodeSymbol(255) == null);
}

test "decode slow all symbols" {
    var ht = try buildDefaultTable(testing.allocator);
    defer ht.deinit();
    for (ht.values, 0..) |val, i| {
        try testing.expectEqual(@as(?u8, val), ht.decodeSlow(ht.codes[i], ht.sizes[i]));
    }
}

test "decode slow invalid code" {
    var ht = try buildDefaultTable(testing.allocator);
    defer ht.deinit();
    try testing.expect(ht.decodeSlow(0xFFFF, 1) == null);
}

test "from bits values empty" {
    var ht = try HuffmanTable.fromBitsValues(testing.allocator, [_]u8{0} ** 17, &.{});
    defer ht.deinit();
    try testing.expectEqual(@as(usize, 0), ht.codes.len);
    try testing.expectEqual(@as(usize, 0), ht.sizes.len);
    for (ht.lookup) |v| try testing.expectEqual(@as(i16, -1), v);
}

test "single symbol table" {
    var bits = [_]u8{0} ** 17;
    bits[1] = 1;
    var ht = try HuffmanTable.fromBitsValues(testing.allocator, bits, &[_]u8{42});
    defer ht.deinit();
    try testing.expectEqual(@as(usize, 1), ht.codes.len);
    try testing.expectEqual(@as(u16, 0), ht.codes[0]);
    try testing.expectEqual(@as(u8, 1), ht.sizes[0]);
    const cs = ht.encodeSymbol(42).?;
    try testing.expectEqual(@as(u16, 0), cs.code);
    try testing.expectEqual(@as(u8, 1), cs.size);
    var b: u8 = 0;
    while (b < 128) : (b += 1) {
        const e = ht.fastLookup(b).?;
        try testing.expectEqual(@as(u8, 1), e.size);
        try testing.expectEqual(@as(u8, 42), e.value);
    }
}

// Regression: a complete code (one symbol at each length 1..=15, two at length
// 16) is Kraft-valid and its final canonical code is exactly 0xFFFF; the
// trailing increment used to overflow u16.
test "complete length16 code does not overflow" {
    var bits = [_]u8{0} ** 17;
    for (1..16) |i| bits[i] = 1;
    bits[16] = 2;
    try testing.expect(bitsValid(&bits));
    var values: [17]u8 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i);
    var ht = try HuffmanTable.fromBitsValues(testing.allocator, bits, &values);
    defer ht.deinit();
    try testing.expectEqual(@as(usize, 17), ht.codes.len);
    try testing.expectEqual(@as(u16, 0xFFFF), ht.codes[ht.codes.len - 1]);
}

test "bits valid rejects oversubscribed" {
    var bits = [_]u8{0} ** 17;
    bits[1] = 3;
    try testing.expect(!bitsValid(&bits));
    try testing.expectError(error.InvalidTable, HuffmanTable.fromBitsValues(testing.allocator, bits, &[_]u8{ 0, 1, 2 }));
}

test "from bits values rejects short values" {
    var bits = [_]u8{0} ** 17;
    bits[2] = 3;
    try testing.expectError(error.InvalidTable, HuffmanTable.fromBitsValues(testing.allocator, bits, &[_]u8{ 0, 1 }));
}
