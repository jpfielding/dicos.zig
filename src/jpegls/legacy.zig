//! Frozen 1.0.0 / Go-compatible JPEG-LS coder.
//!
//! This module is a self-contained copy of the entropy-coded scan path as it
//! existed in the 1.0.0 release: **0xFF00 byte stuffing, no run mode, uncapped
//! Golomb, pre-spec bias updates**. It is byte-compatible with the Go dicos
//! codec and with the Rust crate's `legacy.rs`, and is pinned forever by
//! `tests/legacy_fixtures.zig`.
//!
//! DO NOT MODIFY. The conformant T.87 coder lives in `bitstream.zig` /
//! `context.zig` / `run_mode.zig`; this frozen path preserves the legacy
//! bitstream verbatim so existing files keep decoding byte-for-byte.

const std = @import("std");
const errors = @import("error.zig");
const predictor = @import("predictor.zig");

const CodecError = errors.CodecError;
const Diagnostic = errors.Diagnostic;
const clamp = predictor.clamp;
const predictMed = predictor.predictMed;

// ===========================================================================
// Frozen bit I/O (0xFF00 stuffing, 65536 unary cap)
// ===========================================================================

/// `Marker`: a non-stuffed `0xFFxx` was reached (normally EOI).
/// `EndOfData`: input ran out. `GolombOverflow`: unary prefix > 65536.
const ReadError = error{ Marker, EndOfData, EndAfterFF, GolombOverflow };

/// Reads bits from a byte slice, handling legacy 0xFF00 byte-stuffing.
pub const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    /// Bit accumulator (MSB-first).
    bits: u64 = 0,
    /// Number of valid bits in `bits`.
    n_bits: i32 = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    fn fill(self: *BitReader, n: i32) ReadError!void {
        while (self.n_bits < n) {
            if (self.pos >= self.data.len) return error.EndOfData;
            const b = self.data[self.pos];
            self.pos += 1;

            if (b == 0xFF) {
                if (self.pos >= self.data.len) return error.EndAfterFF;
                const next = self.data[self.pos];
                if (next == 0x00) {
                    // Byte stuffing -- consume the 0x00 and treat as 0xFF data.
                    self.pos += 1;
                } else {
                    // A marker (e.g. EOI). Back up so it can be parsed later.
                    self.pos -= 1;
                    return error.Marker;
                }
            }

            self.bits = (self.bits << 8) | b;
            self.n_bits += 8;
        }
    }

    /// Read `n` bits (0..=32) and return them right-justified.
    pub fn readBits(self: *BitReader, n: i32) ReadError!u32 {
        if (n == 0) return 0;
        try self.fill(n);
        const shift: u6 = @intCast(self.n_bits - n);
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        const val = (self.bits >> shift) & mask;
        self.n_bits -= n;
        return @intCast(val);
    }

    pub inline fn readBit(self: *BitReader) ReadError!u32 {
        return self.readBits(1);
    }

    /// Read a Golomb-Rice code with parameter `k` (uncapped remainder).
    pub fn readGolomb(self: *BitReader, k: i32) ReadError!u32 {
        var q: u32 = 0;
        while (true) {
            if ((try self.readBit()) == 1) break;
            q += 1;
            if (q > 65536) return error.GolombOverflow;
        }
        if (k == 0) return q;
        const r = try self.readBits(k);
        return (q << @intCast(k)) | r;
    }
};

/// Writes bits to a `std.Io.Writer`, handling legacy 0xFF00 stuffing.
pub const BitWriter = struct {
    out: *std.Io.Writer,
    bits: u64 = 0,
    n_bits: i32 = 0,

    pub fn init(out: *std.Io.Writer) BitWriter {
        return .{ .out = out };
    }

    fn emit(self: *BitWriter, b: u8) error{Io}!void {
        self.out.writeByte(b) catch return error.Io;
    }

    /// Write `n` bits from `val` (MSB-first).
    pub fn writeBits(self: *BitWriter, val: u32, n: i32) error{Io}!void {
        const mask = (@as(u64, 1) << @intCast(n)) - 1;
        self.bits = (self.bits << @intCast(n)) | (@as(u64, val) & mask);
        self.n_bits += n;

        while (self.n_bits >= 8) {
            const shift: u6 = @intCast(self.n_bits - 8);
            const b: u8 = @truncate(self.bits >> shift);
            try self.emit(b);
            // Byte stuffing: after 0xFF, insert 0x00.
            if (b == 0xFF) try self.emit(0x00);
            self.n_bits -= 8;
        }
    }

    pub inline fn writeBit(self: *BitWriter, bit: u32) error{Io}!void {
        return self.writeBits(bit, 1);
    }

    /// Flush remaining bits (zero-padded to byte boundary).
    pub fn flush(self: *BitWriter) error{Io}!void {
        if (self.n_bits > 0) {
            const shift: u6 = @intCast(8 - self.n_bits);
            const b: u8 = @truncate(self.bits << shift);
            try self.emit(b);
            if (b == 0xFF) try self.emit(0x00);
            self.n_bits = 0;
            self.bits = 0;
        }
    }

    /// Write a Golomb-Rice code for the non-negative mapped value `val`.
    pub fn writeGolomb(self: *BitWriter, k: i32, val: u32) error{Io}!void {
        const kk: u5 = @intCast(k);
        const q = val >> kk;
        const r = val & ((@as(u32, 1) << kk) - 1);
        var i: u32 = 0;
        while (i < q) : (i += 1) try self.writeBit(0);
        try self.writeBit(1);
        if (k > 0) try self.writeBits(r, k);
    }
};

// ===========================================================================
// Frozen context model (pre-spec bias / statistics)
// ===========================================================================

const NUM_CONTEXTS: usize = 367;

/// The frozen context model used during legacy encoding and decoding.
pub const ContextModel = struct {
    t1: i32,
    t2: i32,
    t3: i32,
    max_val: i32,
    a: [NUM_CONTEXTS]i32,
    b: [NUM_CONTEXTS]i32,
    c: [NUM_CONTEXTS]i32,
    n: [NUM_CONTEXTS]i32,
    reset: i32,

    pub fn init(max_val: i32, near: i32, reset: i32) ContextModel {
        // Compute quantization thresholds (legacy formula).
        const factor = @divTrunc(@min(max_val, 4095) + 128, 256);
        const t1 = clamp(factor + 2 + 3 * near, near + 1, max_val);
        const t2 = clamp(factor * (7 - 3) + 3 + 5 * near, t1, max_val);
        const t3 = clamp(factor * (21 - 4) + 4 + 7 * near, t2, max_val);
        return .{
            .t1 = t1,
            .t2 = t2,
            .t3 = t3,
            .max_val = max_val,
            .a = @splat(4),
            .b = @splat(0),
            .c = @splat(0),
            .n = @splat(1),
            .reset = reset,
        };
    }

    pub inline fn quantizeGradient(self: *const ContextModel, d: i32) i32 {
        if (d <= -self.t3) return -4;
        if (d <= -self.t2) return -3;
        if (d <= -self.t1) return -2;
        if (d < 0) return -1;
        if (d == 0) return 0;
        if (d < self.t1) return 1;
        if (d < self.t2) return 2;
        if (d < self.t3) return 3;
        return 4;
    }

    pub fn getContextIndex(self: *const ContextModel, d1: i32, d2: i32, d3: i32) struct { usize, i32 } {
        var q1 = self.quantizeGradient(d1);
        var q2 = self.quantizeGradient(d2);
        var q3 = self.quantizeGradient(d3);
        var sign: i32 = 1;
        if (q1 < 0 or (q1 == 0 and q2 < 0) or (q1 == 0 and q2 == 0 and q3 < 0)) {
            q1 = -q1;
            q2 = -q2;
            q3 = -q3;
            sign = -1;
        }
        return .{ @intCast(q1 * 81 + q2 * 9 + q3), sign };
    }

    pub fn computeK(self: *const ContextModel, q: usize) i32 {
        const n = self.n[q];
        if (n == 0) return 0;
        const a = self.a[q];
        var k: i32 = 0;
        while (k < 31 and (n << @intCast(k)) < a) k += 1;
        return k;
    }

    pub fn updateStats(self: *ContextModel, q: usize, err_val: i32) void {
        self.b[q] +|= err_val;
        self.a[q] +|= @as(i32, @intCast(@abs(err_val)));
        // Halve when N reaches reset threshold.
        if (self.n[q] >= self.reset) {
            self.a[q] >>= 1;
            self.b[q] >>= 1;
            self.n[q] >>= 1;
        }
        self.n[q] +|= 1;
        self.updateBias(q);
    }

    fn updateBias(self: *ContextModel, q: usize) void {
        if (self.b[q] <= -self.n[q]) {
            self.b[q] += self.n[q];
            self.c[q] -= 1;
            if (self.b[q] <= -self.n[q]) {
                self.b[q] += self.n[q];
                self.c[q] -= 1;
            }
        } else if (self.b[q] > 0) {
            self.b[q] -= self.n[q];
            self.c[q] += 1;
            if (self.b[q] > 0) {
                self.b[q] -= self.n[q];
                self.c[q] += 1;
            }
        }
        self.c[q] = std.math.clamp(self.c[q], -128, 127);
    }
};

// ===========================================================================
// Frozen scan coders
// ===========================================================================

const Neighbors = struct { ra: i32, rb: i32, rc: i32, rd: i32 };

inline fn neighbors(curr: []const i32, prev: []const i32, x: usize, y: usize, w: usize) Neighbors {
    const ra = if (x > 0) curr[x - 1] else if (y > 0) prev[0] else 0;
    const rb = if (y > 0) prev[x] else 0;
    const rc = if (y > 0) (if (x > 0) prev[x - 1] else prev[0]) else 0;
    const rd = if (y > 0) (if (x < w - 1) prev[x + 1] else rb) else 0;
    return .{ .ra = ra, .rb = rb, .rc = rc, .rd = rd };
}

/// Encode the entropy-coded scan body for a single-component image.
/// Header/EOI markers are written by the caller.
pub fn encodeScan(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    pixels: []const u16,
    w: usize,
    h: usize,
    max_val: i32,
    near: i32,
) error{ Io, OutOfMemory }!void {
    var bw = BitWriter.init(out);
    var ctx = ContextModel.init(max_val, near, 64);

    const curr_line = try allocator.alloc(i32, w);
    defer allocator.free(curr_line);
    const prev_line = try allocator.alloc(i32, w);
    defer allocator.free(prev_line);
    @memset(prev_line, 0);

    const range_val = max_val + 1;

    for (0..h) |y| {
        for (0..w) |x| curr_line[x] = pixels[y * w + x];

        for (0..w) |x| {
            const nb = neighbors(curr_line, prev_line, x, y, w);
            const d1 = nb.rd - nb.rb;
            const d2 = nb.rb - nb.rc;
            const d3 = nb.rc - nb.ra;

            // Run mode is intentionally disabled for compatibility with
            // existing DICOS files produced by the Go codec. Regular mode:
            const q, const sign = ctx.getContextIndex(d1, d2, d3);

            var px = predictMed(nb.ra, nb.rb, nb.rc);
            px += sign * ctx.c[q];
            px = clamp(px, 0, max_val);

            var err_val = curr_line[x] - px;
            if (sign == -1) err_val = -err_val;

            // Modulo reduction.
            if (err_val < -@divTrunc(range_val, 2)) err_val += range_val;
            if (err_val > @divTrunc(range_val, 2)) err_val -= range_val;

            const mapped: u32 = if (err_val >= 0) @intCast(2 * err_val) else @intCast(-2 * err_val - 1);

            const k = ctx.computeK(q);
            try bw.writeGolomb(k, mapped);
            ctx.updateStats(q, err_val);
        }

        @memcpy(prev_line, curr_line);
    }
    try bw.flush();
}

/// Decode the entropy-coded scan body for a single-component image.
///
/// A marker reached before the image is complete ends decoding early (the
/// remaining pixels keep their prior contents), exactly as 1.0.0 did.
pub fn decodeScan(
    allocator: std.mem.Allocator,
    scan_data: []const u8,
    pixels: []u16,
    w: usize,
    h: usize,
    max_val: i32,
    near: i32,
    diag: ?*Diagnostic,
) CodecError!void {
    var br = BitReader.init(scan_data);
    var ctx = ContextModel.init(max_val, near, 64);

    const curr_line = try allocator.alloc(i32, w);
    defer allocator.free(curr_line);
    @memset(curr_line, 0);
    const prev_line = try allocator.alloc(i32, w);
    defer allocator.free(prev_line);
    @memset(prev_line, 0);

    const max_val_plus1 = max_val + 1;

    for (0..h) |y| {
        for (0..w) |x| {
            const nb = neighbors(curr_line, prev_line, x, y, w);
            const d1 = nb.rd - nb.rb;
            const d2 = nb.rb - nb.rc;
            const d3 = nb.rc - nb.ra;

            const q, const sign = ctx.getContextIndex(d1, d2, d3);

            var px = predictMed(nb.ra, nb.rb, nb.rc);
            px += sign * ctx.c[q];
            px = clamp(px, 0, max_val);

            const k = ctx.computeK(q);
            const mapped_err = br.readGolomb(k) catch |e| switch (e) {
                // A marker during the last pixels of the image is normal (EOI).
                error.Marker => return,
                error.EndOfData => return errors.invalidData(diag, "unexpected end of JPEG-LS data", .{}),
                error.EndAfterFF => return errors.invalidData(diag, "unexpected end of data after 0xFF", .{}),
                error.GolombOverflow => return errors.invalidData(diag, "golomb q overflow", .{}),
            };

            // Inverse-map the error (using wrapping to handle large values).
            const em: i32 = @bitCast(mapped_err);
            const stats_err = if (em & 1 == 0) em >> 1 else (-%(em +% 1)) >> 1;

            var err_val = stats_err;
            if (sign == -1) err_val = -err_val;

            ctx.updateStats(q, stats_err);

            var rx: i32 = @truncate(@as(i64, px) + @as(i64, err_val));

            // Modulo reduction to [0, max_val].
            if (rx < 0) rx += max_val_plus1;
            if (rx > max_val) rx -= max_val_plus1;
            rx = std.math.clamp(rx, 0, max_val);

            curr_line[x] = rx;
            pixels[y * w + x] = @intCast(rx);
        }

        @memcpy(prev_line, curr_line);
    }
}

// ===========================================================================
// Tests -- lock the frozen primitives (end-to-end bytes are pinned by
// tests/legacy_fixtures.zig).
// ===========================================================================

const testing = std.testing;

test "legacy bit roundtrip" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var bw = BitWriter.init(&aw.writer);
    try bw.writeBits(0b101, 3);
    try bw.writeBits(0b1100, 4);
    try bw.writeBits(0b1, 1);
    try bw.flush();
    try testing.expectEqualSlices(u8, &.{0xB9}, aw.written());

    var br = BitReader.init(aw.written());
    try testing.expectEqual(@as(u32, 0b101), try br.readBits(3));
    try testing.expectEqual(@as(u32, 0b1100), try br.readBits(4));
    try testing.expectEqual(@as(u32, 0b1), try br.readBits(1));
}

test "legacy golomb roundtrip many" {
    var k: i32 = 0;
    while (k < 8) : (k += 1) {
        var aw = std.Io.Writer.Allocating.init(testing.allocator);
        defer aw.deinit();
        var bw = BitWriter.init(&aw.writer);
        for (0..50) |v| try bw.writeGolomb(k, @intCast(v));
        try bw.flush();
        var br = BitReader.init(aw.written());
        for (0..50) |v| try testing.expectEqual(@as(u32, @intCast(v)), try br.readGolomb(k));
    }
}

test "legacy byte stuffing 0xff00" {
    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var bw = BitWriter.init(&aw.writer);
    try bw.writeBits(0xFF, 8);
    try bw.writeBits(0x01, 8);
    try bw.flush();
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x01 }, aw.written());

    var br = BitReader.init(aw.written());
    try testing.expectEqual(@as(u32, 0xFF), try br.readBits(8));
    try testing.expectEqual(@as(u32, 0x01), try br.readBits(8));
}

test "legacy context thresholds 8bit" {
    const m = ContextModel.init(255, 0, 64);
    try testing.expectEqual(@as(i32, 3), m.t1);
    try testing.expectEqual(@as(i32, 7), m.t2);
    try testing.expectEqual(@as(i32, 21), m.t3);
}

test "legacy context initial stats" {
    const m = ContextModel.init(255, 0, 64);
    for (0..NUM_CONTEXTS) |i| {
        try testing.expectEqual(@as(i32, 4), m.a[i]);
        try testing.expectEqual(@as(i32, 1), m.n[i]);
    }
}

test "legacy context update stats double step bias" {
    var m = ContextModel.init(255, 0, 64);
    m.updateStats(0, 5);
    try testing.expectEqual(@as(i32, 9), m.a[0]);
    try testing.expectEqual(@as(i32, 1), m.b[0]);
    try testing.expectEqual(@as(i32, 2), m.c[0]);
    try testing.expectEqual(@as(i32, 2), m.n[0]);
}
