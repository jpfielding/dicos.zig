//! MQ arithmetic coder state machine (ITU-T T.800 Annex C).
//!
//! Implements the binary adaptive arithmetic coder used by EBCOT for encoding
//! and decoding code-block bit-planes, using the normative T.800 / OpenJPEG
//! interval convention (LPS sub-interval at the base; MPS advances `C` by
//! `Qe`), so codewords are byte-interoperable with OpenJPEG.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Probability estimation table (ITU-T T.800 Table C.2)
// ---------------------------------------------------------------------------

const MqEntry = struct {
    qe: u16,
    nmps: u8,
    nlps: u8,
    swi: bool,
};

fn e(qe: u16, nmps: u8, nlps: u8, swi: bool) MqEntry {
    return .{ .qe = qe, .nmps = nmps, .nlps = nlps, .swi = swi };
}

const MQ_TABLE = [_]MqEntry{
    e(0x5601, 1, 1, true),    e(0x3401, 2, 6, false),   e(0x1801, 3, 9, false),
    e(0x0AC1, 4, 12, false),  e(0x0521, 5, 29, false),  e(0x0221, 38, 33, false),
    e(0x5601, 7, 6, true),    e(0x5401, 8, 14, false),  e(0x4801, 9, 14, false),
    e(0x3801, 10, 14, false), e(0x3001, 11, 17, false), e(0x2401, 12, 18, false),
    e(0x1C01, 13, 20, false), e(0x1601, 29, 21, false), e(0x5601, 15, 14, true),
    e(0x5401, 16, 14, false), e(0x5101, 17, 15, false), e(0x4801, 18, 16, false),
    e(0x3801, 19, 17, false), e(0x3401, 20, 18, false), e(0x3001, 21, 19, false),
    e(0x2801, 22, 19, false), e(0x2401, 23, 20, false), e(0x2201, 24, 21, false),
    e(0x1C01, 25, 22, false), e(0x1801, 26, 23, false), e(0x1601, 27, 24, false),
    e(0x1401, 28, 25, false), e(0x1201, 29, 26, false), e(0x1101, 30, 27, false),
    e(0x0AC1, 31, 28, false), e(0x09C1, 32, 29, false), e(0x08A1, 33, 30, false),
    e(0x0521, 34, 31, false), e(0x0441, 35, 32, false), e(0x02A1, 36, 33, false),
    e(0x0221, 37, 34, false), e(0x0141, 38, 35, false), e(0x0111, 39, 36, false),
    e(0x0085, 40, 37, false), e(0x0049, 41, 38, false), e(0x0025, 42, 39, false),
    e(0x0015, 43, 40, false), e(0x0009, 44, 41, false), e(0x0005, 45, 42, false),
    e(0x0001, 45, 43, false), e(0x5601, 46, 46, false),
};

comptime {
    std.debug.assert(MQ_TABLE.len == 47);
}

// ---------------------------------------------------------------------------
// Context state
// ---------------------------------------------------------------------------

/// MQ coder context state -- one per context label.
pub const MqState = struct {
    /// Index into the probability estimation table.
    index: u8 = 0,
    /// Most probable symbol (0 or 1).
    mps: u8 = 0,

    /// Uniform-distribution context (used for bypass-like coding).
    pub const uniform: MqState = .{ .index = 46, .mps = 0 };
};

// ---------------------------------------------------------------------------
// EBCOT context labels
// ---------------------------------------------------------------------------

/// Total number of MQ contexts used by EBCOT tier-1.
pub const NUM_MQ_CONTEXTS: usize = 19;
/// First zero-coding (significance) context. Contexts `0..=8`.
pub const CTX_ZC_START: usize = 0;
/// First sign-coding context. Contexts `9..=13`.
pub const CTX_SC_START: usize = 9;
/// First magnitude-refinement context. Contexts `14..=16`.
pub const CTX_MR_START: usize = 14;
/// Run-length (cleanup) context.
pub const CTX_RUN_LENGTH: usize = 17;
/// Uniform-distribution context.
pub const CTX_UNIFORM: usize = 18;

pub const Contexts = [NUM_MQ_CONTEXTS]MqState;

/// The default EBCOT context array (T.800 Annex D): all contexts at state 0 /
/// MPS 0, except ZC-0 -> 4, run-length -> 3, uniform -> 46.
pub fn setupDefaultContexts() Contexts {
    var c: Contexts = @splat(.{});
    c[CTX_ZC_START] = .{ .index = 4, .mps = 0 };
    c[CTX_RUN_LENGTH] = .{ .index = 3, .mps = 0 };
    c[CTX_UNIFORM] = MqState.uniform;
    return c;
}

// ---------------------------------------------------------------------------
// MQ Encoder
// ---------------------------------------------------------------------------

/// MQ arithmetic encoder.
pub const MqEncoder = struct {
    gpa: Allocator,
    output: std.ArrayList(u8) = .empty,
    /// Interval size.
    a: u32 = 0x8000,
    /// Lower bound.
    c: u32 = 0,
    /// Bit counter.
    t: i32 = 12,
    /// Output length counter.
    l: i32 = -1,
    /// Pending byte.
    temp: u8 = 0,

    pub fn init(gpa: Allocator) MqEncoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *MqEncoder) void {
        self.output.deinit(self.gpa);
    }

    /// Encode a single bit using the given context (normative CODEMPS /
    /// CODELPS, identical to OpenJPEG `opj_mqc_codemps`/`opj_mqc_codelps`).
    pub fn encode(self: *MqEncoder, bit: u8, ctx: *MqState) Allocator.Error!void {
        const entry = MQ_TABLE[ctx.index];
        const qe: u32 = entry.qe;
        self.a -%= qe;

        if (bit == ctx.mps) {
            if (self.a & 0x8000 == 0) {
                if (self.a < qe) {
                    self.a = qe;
                } else {
                    self.c +%= qe;
                }
                ctx.index = entry.nmps;
                try self.renorm();
            } else {
                self.c +%= qe;
            }
        } else {
            if (self.a < qe) {
                self.c +%= qe;
            } else {
                self.a = qe;
            }
            if (entry.swi) ctx.mps = 1 - ctx.mps;
            ctx.index = entry.nlps;
            try self.renorm();
        }
    }

    fn renorm(self: *MqEncoder) Allocator.Error!void {
        while (self.a < 0x8000) {
            self.a <<= 1;
            self.c <<= 1;
            self.t -= 1;
            if (self.t == 0) try self.putByte();
        }
    }

    fn putByte(self: *MqEncoder) Allocator.Error!void {
        if (self.temp == 0xFF) {
            // Previous byte was 0xFF -- 7-bit extraction.
            if (self.l >= 0) try self.emit(self.temp);
            self.temp = @truncate(self.c >> 20);
            self.c &= 0xF_FFFF;
            self.t = 7;
        } else if (self.c & 0x800_0000 == 0) {
            if (self.l >= 0) try self.emit(self.temp);
            self.temp = @truncate(self.c >> 19);
            self.c &= 0x7_FFFF;
            self.t = 8;
        } else {
            // Carry into the pending byte.
            self.temp +%= 1;
            self.c &= 0x7FF_FFFF;
            if (self.l >= 0) try self.emit(self.temp);
            if (self.temp == 0xFF) {
                self.temp = @truncate(self.c >> 20);
                self.c &= 0xF_FFFF;
                self.t = 7;
            } else {
                self.temp = @truncate(self.c >> 19);
                self.c &= 0x7_FFFF;
                self.t = 8;
            }
        }
        self.l += 1;
    }

    fn emit(self: *MqEncoder, b: u8) Allocator.Error!void {
        try self.output.append(self.gpa, b);
    }

    fn setBits(self: *MqEncoder) void {
        const tempc = self.c +% self.a;
        self.c |= 0xFFFF;
        if (self.c >= tempc) self.c -%= 0x8000;
    }

    /// Flush the encoder -- must be called after all bits are encoded.
    pub fn flush(self: *MqEncoder) Allocator.Error!void {
        self.setBits();
        self.c <<= @intCast(self.t);
        try self.putByte();
        self.c <<= @intCast(self.t);
        try self.putByte();
        // The final pending byte is dropped if it is 0xFF (no stuff needed).
        if (self.temp != 0xFF) try self.emit(self.temp);
    }

    /// The encoded bytes (borrowed).
    pub fn bytes(self: *const MqEncoder) []const u8 {
        return self.output.items;
    }

    /// Transfer ownership of the encoded bytes.
    pub fn toOwnedSlice(self: *MqEncoder) Allocator.Error![]u8 {
        return self.output.toOwnedSlice(self.gpa);
    }

    /// Reset for reuse with a new code-block.
    pub fn reset(self: *MqEncoder) void {
        self.output.clearRetainingCapacity();
        self.a = 0x8000;
        self.c = 0;
        self.t = 12;
        self.l = -1;
        self.temp = 0;
    }
};

// ---------------------------------------------------------------------------
// MQ Decoder
// ---------------------------------------------------------------------------

/// MQ arithmetic decoder. Never fails: past end-of-data it is fed synthetic
/// 1-bits (as at a marker), per T.800 C.3.4.
pub const MqDecoder = struct {
    data: []const u8,
    pos: usize = 0,
    a: u32 = 0x8000,
    c: u32 = 0,
    t: i32 = 0,
    b: u8 = 0,

    pub fn init(data: []const u8) MqDecoder {
        var d: MqDecoder = .{ .data = data };
        d.b = d.nextByte();
        d.c = @as(u32, d.b) << 16;
        d.byteIn();
        d.c <<= 7;
        d.t -= 7;
        d.a = 0x8000;
        return d;
    }

    fn nextByte(self: *MqDecoder) u8 {
        if (self.pos >= self.data.len) return 0xFF;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn peekByte(self: *const MqDecoder) u8 {
        return if (self.pos >= self.data.len) 0xFF else self.data[self.pos];
    }

    /// BYTEIN procedure (T.800 C.3.4, Figure C.19).
    fn byteIn(self: *MqDecoder) void {
        if (self.b == 0xFF) {
            const b1 = self.peekByte();
            if (b1 > 0x8F) {
                // Marker (or end-of-data): stay put and feed 1-bits.
                self.c +%= 0xFF00;
                self.t = 8;
            } else {
                self.pos += 1;
                self.b = b1;
                self.c +%= @as(u32, b1) << 9;
                self.t = 7;
            }
        } else {
            const b1 = self.peekByte();
            if (self.pos < self.data.len) self.pos += 1;
            self.b = b1;
            self.c +%= @as(u32, b1) << 8;
            self.t = 8;
        }
    }

    /// Decode a single bit using the given context (normative convention,
    /// identical to OpenJPEG `opj_mqc_decode`).
    pub fn decode(self: *MqDecoder, ctx: *MqState) u8 {
        const entry = MQ_TABLE[ctx.index];
        const qe: u32 = entry.qe;
        self.a -%= qe;

        if ((self.c >> 16) < qe) {
            return self.lpsExchange(ctx, entry, qe);
        }
        self.c -%= qe << 16;
        if (self.a & 0x8000 == 0) return self.mpsExchange(ctx, entry, qe);
        return ctx.mps;
    }

    fn mpsExchange(self: *MqDecoder, ctx: *MqState, entry: MqEntry, qe: u32) u8 {
        var bit: u8 = undefined;
        if (self.a < qe) {
            bit = 1 - ctx.mps;
            if (entry.swi) ctx.mps = 1 - ctx.mps;
            ctx.index = entry.nlps;
        } else {
            bit = ctx.mps;
            ctx.index = entry.nmps;
        }
        self.renorm();
        return bit;
    }

    fn lpsExchange(self: *MqDecoder, ctx: *MqState, entry: MqEntry, qe: u32) u8 {
        var bit: u8 = undefined;
        if (self.a < qe) {
            bit = ctx.mps;
            self.a = qe;
            ctx.index = entry.nmps;
        } else {
            bit = 1 - ctx.mps;
            self.a = qe;
            if (entry.swi) ctx.mps = 1 - ctx.mps;
            ctx.index = entry.nlps;
        }
        self.renorm();
        return bit;
    }

    fn renorm(self: *MqDecoder) void {
        while (self.a < 0x8000) {
            if (self.t == 0) self.byteIn();
            self.a <<= 1;
            self.c <<= 1;
            self.t -= 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Sym = struct { ctx: usize, bit: u8 };

/// Encode `(ctx, bit)` pairs, then decode and compare.
fn roundtrip(seq: []const Sym) !void {
    var ce = setupDefaultContexts();
    var enc = MqEncoder.init(testing.allocator);
    defer enc.deinit();
    for (seq) |s| try enc.encode(s.bit, &ce[s.ctx]);
    try enc.flush();

    var cd = setupDefaultContexts();
    var dec = MqDecoder.init(enc.bytes());
    for (seq, 0..) |s, i| {
        const got = dec.decode(&cd[s.ctx]);
        if (got != s.bit) {
            std.debug.print("mismatch at {d}\n", .{i});
            return error.TestUnexpectedResult;
        }
    }
}

fn roundtripSingleCtx(bits: []const u8) !void {
    const seq = try testing.allocator.alloc(Sym, bits.len);
    defer testing.allocator.free(seq);
    for (bits, seq) |b, *s| s.* = .{ .ctx = 0, .bit = b };
    try roundtrip(seq);
}

test "mq encode decode all zeros" {
    try roundtripSingleCtx(&(@as([100]u8, @splat(0))));
}

test "mq encode decode all ones" {
    try roundtripSingleCtx(&(@as([100]u8, @splat(1))));
}

test "mq encode decode alternating" {
    var bits: [200]u8 = undefined;
    for (&bits, 0..) |*b, i| b.* = @intCast(i % 2);
    try roundtripSingleCtx(&bits);
}

test "mq encode decode multiple contexts" {
    const data = [_]Sym{
        .{ .ctx = 0, .bit = 1 }, .{ .ctx = 1, .bit = 0 }, .{ .ctx = 0, .bit = 1 },
        .{ .ctx = 2, .bit = 1 }, .{ .ctx = 1, .bit = 0 }, .{ .ctx = 0, .bit = 0 },
        .{ .ctx = 2, .bit = 1 }, .{ .ctx = 0, .bit = 1 }, .{ .ctx = 1, .bit = 1 },
        .{ .ctx = 2, .bit = 0 },
    };
    try roundtrip(&data);
}

test "mq encode decode random pattern" {
    var rng: u32 = 12345;
    var bits: [500]u8 = undefined;
    for (&bits) |*b| {
        rng = rng *% 1103515245 +% 12345;
        b.* = @intCast((rng >> 16) & 1);
    }
    try roundtripSingleCtx(&bits);
}

test "mq encoder reset" {
    var enc = MqEncoder.init(testing.allocator);
    defer enc.deinit();
    var ctx = setupDefaultContexts();
    try enc.encode(1, &ctx[0]);
    try enc.flush();
    try testing.expect(enc.bytes().len != 0);
    enc.reset();
    try testing.expectEqual(@as(usize, 0), enc.bytes().len);
}

test "mq initial context states" {
    const ctx = setupDefaultContexts();
    try testing.expectEqual(NUM_MQ_CONTEXTS, ctx.len);
    for (ctx, 0..) |st, i| {
        const expected: u8 = switch (i) {
            CTX_ZC_START => 4,
            CTX_RUN_LENGTH => 3,
            CTX_UNIFORM => 46,
            else => 0,
        };
        try testing.expectEqual(expected, st.index);
        try testing.expectEqual(@as(u8, 0), st.mps);
    }
}

fn constAllContexts(bit: u8) !void {
    const seq = try testing.allocator.alloc(Sym, NUM_MQ_CONTEXTS * 500);
    defer testing.allocator.free(seq);
    for (seq, 0..) |*s, i| s.* = .{ .ctx = i / 500, .bit = bit };
    try roundtrip(seq);
}

test "mq roundtrip all zeros all contexts" {
    try constAllContexts(0);
}

test "mq roundtrip all ones all contexts" {
    try constAllContexts(1);
}

test "mq roundtrip alternating all contexts" {
    const seq = try testing.allocator.alloc(Sym, 10_000);
    defer testing.allocator.free(seq);
    for (seq, 0..) |*s, i| s.* = .{ .ctx = i % NUM_MQ_CONTEXTS, .bit = @intCast(i % 2) };
    try roundtrip(seq);
}

test "mq roundtrip random 10k all contexts" {
    var rng: u64 = 0x2545F4914F6CDD1D;
    const seq = try testing.allocator.alloc(Sym, 10_000);
    defer testing.allocator.free(seq);
    for (seq) |*s| {
        rng = rng *% 6364136223846793005 +% 1;
        s.* = .{ .ctx = @intCast((rng >> 40) % NUM_MQ_CONTEXTS), .bit = @intCast((rng >> 33) & 1) };
    }
    try roundtrip(seq);
}

test "mq decode truncated stream no panic" {
    var ce = setupDefaultContexts();
    var enc = MqEncoder.init(testing.allocator);
    defer enc.deinit();
    var rng: u32 = 0x1234_5678;
    for (0..2_000) |_| {
        rng = rng *% 1103515245 +% 12345;
        const c: usize = (rng >> 20) % NUM_MQ_CONTEXTS;
        try enc.encode(@intCast((rng >> 16) & 1), &ce[c]);
    }
    try enc.flush();
    const encoded = enc.bytes();
    for (0..encoded.len + 1) |cut| {
        var cd = setupDefaultContexts();
        var dec = MqDecoder.init(encoded[0..cut]);
        for (0..3_000) |i| _ = dec.decode(&cd[i % NUM_MQ_CONTEXTS]);
    }
}

test "mq decode empty stream no panic" {
    var ctx = setupDefaultContexts();
    var dec = MqDecoder.init(&.{});
    for (0..1_000) |i| _ = dec.decode(&ctx[i % NUM_MQ_CONTEXTS]);
}
