//! MQ arithmetic coder state machine (ITU-T T.800 Annex C).
//!
//! Implements the binary adaptive arithmetic coder used by EBCOT
//! for encoding and decoding code-block bit-planes.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Probability estimation table (ITU-T T.800 Table C.2)
// ---------------------------------------------------------------------------

const MqEntry = struct {
    qe: u16,
    nmps: usize,
    nlps: usize,
    swi: bool,
};

const MQ_TABLE = [_]MqEntry{
    .{ .qe = 0x5601, .nmps = 1, .nlps = 1, .swi = true },
    .{ .qe = 0x3401, .nmps = 2, .nlps = 6, .swi = false },
    .{ .qe = 0x1801, .nmps = 3, .nlps = 9, .swi = false },
    .{ .qe = 0x0AC1, .nmps = 4, .nlps = 12, .swi = false },
    .{ .qe = 0x0521, .nmps = 5, .nlps = 29, .swi = false },
    .{ .qe = 0x0221, .nmps = 38, .nlps = 33, .swi = false },
    .{ .qe = 0x5601, .nmps = 7, .nlps = 6, .swi = true },
    .{ .qe = 0x5401, .nmps = 8, .nlps = 14, .swi = false },
    .{ .qe = 0x4801, .nmps = 9, .nlps = 14, .swi = false },
    .{ .qe = 0x3801, .nmps = 10, .nlps = 14, .swi = false },
    .{ .qe = 0x3001, .nmps = 11, .nlps = 17, .swi = false },
    .{ .qe = 0x2401, .nmps = 12, .nlps = 18, .swi = false },
    .{ .qe = 0x1C01, .nmps = 13, .nlps = 20, .swi = false },
    .{ .qe = 0x1601, .nmps = 29, .nlps = 21, .swi = false },
    .{ .qe = 0x5601, .nmps = 15, .nlps = 14, .swi = true },
    .{ .qe = 0x5401, .nmps = 16, .nlps = 14, .swi = false },
    .{ .qe = 0x5101, .nmps = 17, .nlps = 15, .swi = false },
    .{ .qe = 0x4801, .nmps = 18, .nlps = 16, .swi = false },
    .{ .qe = 0x3801, .nmps = 19, .nlps = 17, .swi = false },
    .{ .qe = 0x3401, .nmps = 20, .nlps = 18, .swi = false },
    .{ .qe = 0x3001, .nmps = 21, .nlps = 19, .swi = false },
    .{ .qe = 0x2801, .nmps = 22, .nlps = 19, .swi = false },
    .{ .qe = 0x2401, .nmps = 23, .nlps = 20, .swi = false },
    .{ .qe = 0x2201, .nmps = 24, .nlps = 21, .swi = false },
    .{ .qe = 0x1C01, .nmps = 25, .nlps = 22, .swi = false },
    .{ .qe = 0x1801, .nmps = 26, .nlps = 23, .swi = false },
    .{ .qe = 0x1601, .nmps = 27, .nlps = 24, .swi = false },
    .{ .qe = 0x1401, .nmps = 28, .nlps = 25, .swi = false },
    .{ .qe = 0x1201, .nmps = 29, .nlps = 26, .swi = false },
    .{ .qe = 0x1101, .nmps = 30, .nlps = 27, .swi = false },
    .{ .qe = 0x0AC1, .nmps = 31, .nlps = 28, .swi = false },
    .{ .qe = 0x09C1, .nmps = 32, .nlps = 29, .swi = false },
    .{ .qe = 0x08A1, .nmps = 33, .nlps = 30, .swi = false },
    .{ .qe = 0x0521, .nmps = 34, .nlps = 31, .swi = false },
    .{ .qe = 0x0441, .nmps = 35, .nlps = 32, .swi = false },
    .{ .qe = 0x02A1, .nmps = 36, .nlps = 33, .swi = false },
    .{ .qe = 0x0221, .nmps = 37, .nlps = 34, .swi = false },
    .{ .qe = 0x0141, .nmps = 38, .nlps = 35, .swi = false },
    .{ .qe = 0x0111, .nmps = 39, .nlps = 36, .swi = false },
    .{ .qe = 0x0085, .nmps = 40, .nlps = 37, .swi = false },
    .{ .qe = 0x0049, .nmps = 41, .nlps = 38, .swi = false },
    .{ .qe = 0x0025, .nmps = 42, .nlps = 39, .swi = false },
    .{ .qe = 0x0015, .nmps = 43, .nlps = 40, .swi = false },
    .{ .qe = 0x0009, .nmps = 44, .nlps = 41, .swi = false },
    .{ .qe = 0x0005, .nmps = 45, .nlps = 42, .swi = false },
    .{ .qe = 0x0001, .nmps = 45, .nlps = 43, .swi = false },
    .{ .qe = 0x5601, .nmps = 46, .nlps = 46, .swi = false },
};

// ---------------------------------------------------------------------------
// Context state
// ---------------------------------------------------------------------------

/// MQ coder context state -- one per context label.
pub const MqState = struct {
    /// Index into the probability estimation table.
    index: usize,
    /// Most probable symbol (0 or 1).
    mps: u8,

    pub fn init() MqState {
        return .{ .index = 0, .mps = 0 };
    }

    /// Create a uniform-distribution context (used for bypass coding).
    pub fn uniform() MqState {
        return .{ .index = 46, .mps = 0 };
    }
};

// ---------------------------------------------------------------------------
// EBCOT context labels
// ---------------------------------------------------------------------------

/// Total number of MQ contexts used by EBCOT tier-1.
pub const NUM_MQ_CONTEXTS: usize = 19;

/// Context index for the uniform distribution (EBCOT).
pub const CTX_UNIFORM: usize = 18;

/// Context index for run-length coding (EBCOT).
pub const CTX_RUN_LENGTH: usize = 17;

/// Context index for magnitude refinement.
pub const CTX_MAG_REF: usize = 15;

/// Context index for sign coding.
pub const CTX_SIGN_START: usize = 9;

/// Allocate and initialize the default EBCOT context array.
pub fn setupDefaultContexts() [NUM_MQ_CONTEXTS]MqState {
    var contexts: [NUM_MQ_CONTEXTS]MqState = undefined;
    for (0..NUM_MQ_CONTEXTS) |i| {
        contexts[i] = MqState.init();
    }
    contexts[CTX_UNIFORM] = MqState.uniform();
    return contexts;
}

// ---------------------------------------------------------------------------
// MQ Encoder
// ---------------------------------------------------------------------------

/// MQ arithmetic encoder.
pub const MqEncoder = struct {
    output: std.array_list.AlignedManaged(u8, null),
    a: u32, // interval size
    c: u32, // lower bound
    t: i32, // bit counter
    l: i32, // output length counter
    temp: u8, // temporary byte

    pub fn init(allocator: Allocator) MqEncoder {
        return .{
            .output = std.array_list.AlignedManaged(u8, null).init(allocator),
            .a = 0x8000,
            .c = 0,
            .t = 12,
            .l = -1,
            .temp = 0,
        };
    }

    pub fn deinit(self: *MqEncoder) void {
        self.output.deinit();
    }

    /// Encode a single bit using the given context.
    pub fn encode(self: *MqEncoder, bit: u8, ctx: *MqState) Allocator.Error!void {
        const entry = &MQ_TABLE[ctx.index];
        const qe: u32 = entry.qe;
        self.a -%= qe;

        if (bit == ctx.mps) {
            if (self.a < 0x8000) {
                if (self.a < qe) {
                    self.c +%= self.a;
                    self.a = qe;
                }
                ctx.index = entry.nmps;
                try self.renormEncode();
            }
        } else {
            if (self.a >= qe) {
                self.c +%= self.a;
                self.a = qe;
            }
            if (entry.swi) {
                ctx.mps = 1 - ctx.mps;
            }
            ctx.index = entry.nlps;
            try self.renormEncode();
        }
    }

    fn renormEncode(self: *MqEncoder) Allocator.Error!void {
        while (self.a < 0x8000) {
            self.a <<= 1;
            self.c <<= 1;
            self.t -= 1;
            if (self.t == 0) {
                try self.putByte();
            }
        }
    }

    fn putByte(self: *MqEncoder) Allocator.Error!void {
        if (self.temp == 0xFF) {
            // Previous byte was 0xFF -- byte-stuffing mode (7-bit extraction).
            if (self.l >= 0) {
                try self.emit(self.temp);
            }
            self.temp = @intCast((self.c >> 20) & 0xFF);
            self.c &= 0xF_FFFF;
            self.t = 7;
        } else if ((self.c & 0x800_0000) == 0) {
            // No carry.
            if (self.l >= 0) {
                try self.emit(self.temp);
            }
            self.temp = @intCast((self.c >> 19) & 0xFF);
            self.c &= 0x7_FFFF;
            self.t = 8;
        } else {
            // Carry -- propagate into the pending temp byte.
            self.temp +%= 1;
            if (self.temp == 0xFF) {
                // Carry made temp 0xFF -- switch to 7-bit stuffing mode.
                self.c &= 0x7FF_FFFF;
                if (self.l >= 0) {
                    try self.emit(self.temp);
                }
                self.temp = @intCast((self.c >> 20) & 0xFF);
                self.c &= 0xF_FFFF;
                self.t = 7;
            } else {
                // Normal carry.
                self.c &= 0x7FF_FFFF;
                if (self.l >= 0) {
                    try self.emit(self.temp);
                }
                self.temp = @intCast((self.c >> 19) & 0xFF);
                self.c &= 0x7_FFFF;
                self.t = 8;
            }
        }
        self.l += 1;
    }

    fn emit(self: *MqEncoder, b: u8) Allocator.Error!void {
        try self.output.append(b);
    }

    fn setbits(self: *MqEncoder) void {
        const tempc = self.c +% self.a;
        self.c |= 0xFFFF;
        if (self.c >= tempc) {
            self.c -%= 0x8000;
        }
    }

    /// Flush the encoder -- must be called after all bits are encoded.
    pub fn flush(self: *MqEncoder) Allocator.Error!void {
        self.setbits();
        self.c <<= @intCast(self.t);
        try self.putByte();
        self.c <<= @intCast(self.t);
        try self.putByte();
        // Emit the final pending byte, unless it is 0xFF (which would
        // require a stuff byte and is not needed at end-of-stream).
        if (self.temp != 0xFF) {
            try self.emit(self.temp);
        }
    }

    /// Return the encoded byte stream.
    pub fn bytes(self: *const MqEncoder) []const u8 {
        return self.output.items;
    }

    /// Consume the encoder and return the output buffer.
    pub fn toOwnedSlice(self: *MqEncoder) Allocator.Error![]u8 {
        return self.output.toOwnedSlice();
    }

    /// Reset the encoder for reuse with a new code-block.
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

/// MQ arithmetic decoder.
pub const MqDecoder = struct {
    data: []const u8,
    pos: usize,
    a: u32,
    c: u32,
    t: i32,
    b: u8,

    pub fn init(data: []const u8) MqDecoder {
        var dec = MqDecoder{
            .data = data,
            .pos = 0,
            .a = 0x8000,
            .c = 0,
            .t = 0,
            .b = 0,
        };
        dec.initState();
        return dec;
    }

    fn initState(self: *MqDecoder) void {
        self.b = self.nextByte();
        self.c = @as(u32, self.b) << 16;
        self.getByte();
        self.c <<= 7;
        self.t -= 7;
        self.a = 0x8000;
    }

    fn nextByte(self: *MqDecoder) u8 {
        if (self.pos >= self.data.len) {
            return 0xFF;
        }
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn getByte(self: *MqDecoder) void {
        if (self.b == 0xFF) {
            const b = self.nextByte();
            if (b > 0x8F) {
                self.pos -= 1;
                self.t = 8;
            } else {
                self.b = b;
                self.c +%= @as(u32, self.b) << 9;
                self.t = 7;
            }
        } else {
            self.b = self.nextByte();
            self.c +%= @as(u32, self.b) << 8;
            self.t = 8;
        }
    }

    /// Decode a single bit using the given context.
    pub fn decode(self: *MqDecoder, ctx: *MqState) u8 {
        const entry = &MQ_TABLE[ctx.index];
        const qe: u32 = entry.qe;
        self.a -%= qe;

        const chigh = self.c >> 16;
        if (chigh < self.a) {
            if (self.a < 0x8000) {
                return self.mpsExchange(ctx, entry, qe);
            } else {
                return ctx.mps;
            }
        } else {
            return self.lpsExchange(ctx, entry, qe);
        }
    }

    fn mpsExchange(self: *MqDecoder, ctx: *MqState, entry: *const MqEntry, qe: u32) u8 {
        var bit: u8 = undefined;
        if (self.a < qe) {
            bit = 1 - ctx.mps;
            if (entry.swi) {
                ctx.mps = 1 - ctx.mps;
            }
            ctx.index = entry.nlps;
        } else {
            bit = ctx.mps;
            ctx.index = entry.nmps;
        }
        self.renormDecode();
        return bit;
    }

    fn lpsExchange(self: *MqDecoder, ctx: *MqState, entry: *const MqEntry, qe: u32) u8 {
        self.c -%= self.a << 16;
        var bit: u8 = undefined;
        if (self.a < qe) {
            bit = ctx.mps;
            self.a = qe;
            ctx.index = entry.nmps;
        } else {
            bit = 1 - ctx.mps;
            self.a = qe;
            if (entry.swi) {
                ctx.mps = 1 - ctx.mps;
            }
            ctx.index = entry.nlps;
        }
        self.renormDecode();
        return bit;
    }

    fn renormDecode(self: *MqDecoder) void {
        while (self.a < 0x8000) {
            if (self.t == 0) {
                self.getByte();
            }
            self.a <<= 1;
            self.c <<= 1;
            self.t -= 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mq encode decode all zeros" {
    const allocator = std.testing.allocator;
    var ctx_enc = setupDefaultContexts();
    var enc = MqEncoder.init(allocator);
    defer enc.deinit();

    const n = 100;
    for (0..n) |_| {
        try enc.encode(0, &ctx_enc[0]);
    }
    try enc.flush();

    const encoded = enc.bytes();
    var ctx_dec = setupDefaultContexts();
    var dec = MqDecoder.init(encoded);

    for (0..n) |_| {
        const bit = dec.decode(&ctx_dec[0]);
        try std.testing.expectEqual(@as(u8, 0), bit);
    }
}

test "mq encode decode all ones" {
    const allocator = std.testing.allocator;
    var ctx_enc = setupDefaultContexts();
    var enc = MqEncoder.init(allocator);
    defer enc.deinit();

    const n = 100;
    for (0..n) |_| {
        try enc.encode(1, &ctx_enc[0]);
    }
    try enc.flush();

    const encoded = enc.bytes();
    var ctx_dec = setupDefaultContexts();
    var dec = MqDecoder.init(encoded);

    for (0..n) |_| {
        const bit = dec.decode(&ctx_dec[0]);
        try std.testing.expectEqual(@as(u8, 1), bit);
    }
}

test "mq encode decode alternating" {
    const allocator = std.testing.allocator;
    var ctx_enc = setupDefaultContexts();
    var enc = MqEncoder.init(allocator);
    defer enc.deinit();

    const n = 200;
    var pattern: [n]u8 = undefined;
    for (0..n) |i| {
        pattern[i] = @intCast(i % 2);
    }
    for (&pattern) |bit| {
        try enc.encode(bit, &ctx_enc[0]);
    }
    try enc.flush();

    const encoded = enc.bytes();
    var ctx_dec = setupDefaultContexts();
    var dec = MqDecoder.init(encoded);

    for (pattern) |expected| {
        const bit = dec.decode(&ctx_dec[0]);
        try std.testing.expectEqual(expected, bit);
    }
}

test "mq encode decode multiple contexts" {
    const allocator = std.testing.allocator;
    var ctx_enc = setupDefaultContexts();
    var enc = MqEncoder.init(allocator);
    defer enc.deinit();

    const Entry = struct { ctx_idx: usize, bit: u8 };
    const data = [_]Entry{
        .{ .ctx_idx = 0, .bit = 1 },
        .{ .ctx_idx = 1, .bit = 0 },
        .{ .ctx_idx = 0, .bit = 1 },
        .{ .ctx_idx = 2, .bit = 1 },
        .{ .ctx_idx = 1, .bit = 0 },
        .{ .ctx_idx = 0, .bit = 0 },
        .{ .ctx_idx = 2, .bit = 1 },
        .{ .ctx_idx = 0, .bit = 1 },
        .{ .ctx_idx = 1, .bit = 1 },
        .{ .ctx_idx = 2, .bit = 0 },
    };

    for (&data) |e| {
        try enc.encode(e.bit, &ctx_enc[e.ctx_idx]);
    }
    try enc.flush();

    const encoded = enc.bytes();
    var ctx_dec = setupDefaultContexts();
    var dec = MqDecoder.init(encoded);

    for (data) |e| {
        const bit = dec.decode(&ctx_dec[e.ctx_idx]);
        try std.testing.expectEqual(e.bit, bit);
    }
}

test "mq encode decode random pattern" {
    const allocator = std.testing.allocator;
    var ctx_enc = setupDefaultContexts();
    var enc = MqEncoder.init(allocator);
    defer enc.deinit();

    // Pseudo-random pattern using a simple LCG.
    var rng: u32 = 12345;
    const n = 500;
    var bits: [n]u8 = undefined;
    for (0..n) |i| {
        rng = rng *% 1103515245 +% 12345;
        const bit: u8 = @intCast((rng >> 16) & 1);
        bits[i] = bit;
        try enc.encode(bit, &ctx_enc[0]);
    }
    try enc.flush();

    const encoded = enc.bytes();
    var ctx_dec = setupDefaultContexts();
    var dec = MqDecoder.init(encoded);

    for (bits) |expected| {
        const bit = dec.decode(&ctx_dec[0]);
        try std.testing.expectEqual(expected, bit);
    }
}

test "mq encoder reset" {
    const allocator = std.testing.allocator;
    var enc = MqEncoder.init(allocator);
    defer enc.deinit();
    var ctx = setupDefaultContexts();

    try enc.encode(1, &ctx[0]);
    try enc.flush();
    try std.testing.expect(enc.bytes().len > 0);

    enc.reset();
    try std.testing.expectEqual(@as(usize, 0), enc.bytes().len);
}
