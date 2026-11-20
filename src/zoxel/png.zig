//! Minimal RGBA8 PNG encoder for reproducible screenshots.
//!
//! Zig 0.15's `std.compress.flate.Compress` is not implemented yet, so this
//! carries a small deflate: rows use the PNG "Sub" or "Up" filter (whichever
//! leaves more zeros), then greedy LZ77 (4-byte hash, 32 KiB window) coded
//! with the fixed Huffman tables of RFC 1951. Flat UI regions collapse into
//! long matches, which keeps captures to a few hundred KiB.

const std = @import("std");

const BitWriter = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    acc: u64 = 0,
    n: u6 = 0,

    fn bits(self: *BitWriter, value: u32, count: u6) !void {
        self.acc |= @as(u64, value) << self.n;
        self.n += count;
        while (self.n >= 8) {
            try self.out.append(self.gpa, @truncate(self.acc));
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    /// Huffman codes are sent most-significant bit first.
    fn code(self: *BitWriter, c: u32, len: u6) !void {
        var rev: u32 = 0;
        var i: u6 = 0;
        while (i < len) : (i += 1) rev |= ((c >> @intCast(i)) & 1) << @intCast(len - 1 - i);
        try self.bits(rev, len);
    }

    fn flush(self: *BitWriter) !void {
        if (self.n > 0) try self.out.append(self.gpa, @truncate(self.acc));
        self.acc = 0;
        self.n = 0;
    }
};

fn literal(w: *BitWriter, v: u32) !void {
    if (v <= 143) try w.code(0x30 + v, 8) else if (v <= 255) try w.code(0x190 + (v - 144), 9) else if (v <= 279) try w.code(v - 256, 7) else try w.code(0xC0 + (v - 280), 8);
}

const len_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

fn match(w: *BitWriter, length: u32, dist: u32) !void {
    var li: usize = len_base.len - 1;
    while (len_base[li] > length) li -= 1;
    try literal(w, @intCast(257 + li));
    if (len_extra[li] > 0) try w.bits(length - len_base[li], len_extra[li]);
    var di: usize = dist_base.len - 1;
    while (dist_base[di] > dist) di -= 1;
    try w.code(@intCast(di), 5);
    if (dist_extra[di] > 0) try w.bits(dist - dist_base[di], dist_extra[di]);
}

/// zlib stream of `data` (fixed Huffman, greedy LZ77).
pub fn zlibCompress(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x78, 0x01 });
    var w = BitWriter{ .out = &out, .gpa = gpa };
    try w.bits(1, 1); // final block
    try w.bits(1, 2); // fixed Huffman
    const HASH_BITS = 15;
    const table = try gpa.alloc(i32, 1 << HASH_BITS);
    defer gpa.free(table);
    @memset(table, -1);
    var i: usize = 0;
    while (i < data.len) {
        if (i + 4 <= data.len) {
            const key = std.mem.readInt(u32, data[i..][0..4], .little);
            const h = (key *% 2654435761) >> (32 - HASH_BITS);
            const cand = table[h];
            table[h] = @intCast(i);
            if (cand >= 0) {
                const c: usize = @intCast(cand);
                const dist = i - c;
                if (dist <= 32768 and std.mem.eql(u8, data[c..][0..4], data[i..][0..4])) {
                    var len: usize = 4;
                    const max = @min(258, data.len - i);
                    while (len < max and data[c + len] == data[i + len]) len += 1;
                    try match(&w, @intCast(len), @intCast(dist));
                    // Index a few positions inside the match.
                    var k: usize = i + 1;
                    const end = @min(i + len, data.len -| 4);
                    while (k < end) : (k += 1) {
                        const kk = std.mem.readInt(u32, data[k..][0..4], .little);
                        table[(kk *% 2654435761) >> (32 - HASH_BITS)] = @intCast(k);
                    }
                    i += len;
                    continue;
                }
            }
        }
        try literal(&w, data[i]);
        i += 1;
    }
    try literal(&w, 256);
    try w.flush();
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, &tail, std.hash.Adler32.permute(1, data), .big);
    try out.appendSlice(gpa, &tail);
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, body: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(body.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(gpa, &c);
}

/// Encode tightly packed RGBA8 rows as a PNG file.
pub fn encodeRgba(gpa: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    const stride = @as(usize, width) * 4;
    std.debug.assert(rgba.len == stride * height);
    const raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        const row = rgba[y * stride ..][0..stride];
        const dst = raw[y * (stride + 1) ..][0 .. stride + 1];
        // Choose Sub (1) or Up (2) by the number of zero bytes produced.
        var zs: usize = 0;
        var zu: usize = 0;
        for (0..stride) |x| {
            const left: u8 = if (x >= 4) row[x - 4] else 0;
            const up: u8 = if (y > 0) rgba[(y - 1) * stride + x] else 0;
            if (row[x] -% left == 0) zs += 1;
            if (row[x] -% up == 0) zu += 1;
        }
        const use_up = y > 0 and zu > zs;
        dst[0] = if (use_up) 2 else 1;
        for (0..stride) |x| {
            const pred: u8 = if (use_up) rgba[(y - 1) * stride + x] else if (x >= 4) row[x - 4] else 0;
            dst[x + 1] = row[x] -% pred;
        }
    }
    const z = try zlibCompress(gpa, raw);
    defer gpa.free(z);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' });
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(gpa, &out, "IHDR", &ihdr);
    try chunk(gpa, &out, "IDAT", z);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

test "zlib stream round-trips through std's decompressor" {
    const gpa = std.testing.allocator;
    var data: [5000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(if (i % 700 < 500) 7 else i * 31);
    const z = try zlibCompress(gpa, &data);
    defer gpa.free(z);
    try std.testing.expect(z.len < data.len);
    var in: std.Io.Reader = .fixed(z);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dec.reader.streamRemaining(&out.writer);
    try std.testing.expectEqualSlices(u8, &data, out.written());
}

test "png has signature and chunks" {
    const gpa = std.testing.allocator;
    const px = [_]u8{ 255, 0, 0, 255 } ** 6;
    const png = try encodeRgba(gpa, 3, 2, &px);
    defer gpa.free(png);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, png[0..4]);
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
}
