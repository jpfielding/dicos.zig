//! Tier-2 packet-header codec (ITU-T T.800 B.10), single quality layer.
//!
//! A packet is a byte-aligned header followed by the concatenated code-block
//! bodies. For this profile (LRCP, 1 layer, 1 component, 1 precinct per band)
//! one packet is written per resolution, covering its sub-bands in order (LL
//! at r=0; HL, LH, HH at r>0).
//!
//! Header bits are packed MSB-first with B.10.1 stuffing: a byte equal to
//! `0xFF` is followed by a byte carrying only 7 data bits (MSB forced to 0),
//! and a header never *ends* with `0xFF` (a `0x00` is appended instead).
//!
//! Two tag trees per precinct carry inclusion (B.10.4) and zero-bit-plane
//! counts (B.10.5); pass counts use the T.800 Table B.4 code (identical to
//! OpenJPEG's `opj_t2_{put,get}numpasses`) and lengths the B.10.7 `Lblock`
//! signalling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const CodecError = @import("error.zig").CodecError;
const CodedBlock = @import("ebcot.zig").CodedBlock;
const geometry = @import("geometry.zig");
const Band = geometry.Band;
const TagTree = @import("tagtree.zig").TagTree;

// ---------------------------------------------------------------------------
// B.10.1 stuffing bit I/O
// ---------------------------------------------------------------------------

/// MSB-first bit writer with B.10.1 `0xFF` stuffing.
pub const PacketBitWriter = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Partial byte being assembled (bits shifted in from the LSB).
    cur: u8 = 0,
    /// Bits already placed into `cur`.
    filled: u8 = 0,
    /// Capacity of the current byte: 8, or 7 right after a `0xFF` byte.
    cap: u8 = 8,

    pub fn init(gpa: Allocator) PacketBitWriter {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *PacketBitWriter) void {
        self.bytes.deinit(self.gpa);
    }

    /// Append one bit (only bit 0 is used).
    pub fn putBit(self: *PacketBitWriter, bit: u8) Allocator.Error!void {
        self.cur = (self.cur << 1) | (bit & 1);
        self.filled += 1;
        if (self.filled == self.cap) try self.emit();
    }

    /// Append the low `n` bits of `val`, MSB-first (`n <= 64`).
    pub fn putBits(self: *PacketBitWriter, val: u64, n: u32) Allocator.Error!void {
        var i = n;
        while (i > 0) {
            i -= 1;
            try self.putBit(@intCast((val >> @intCast(i)) & 1));
        }
    }

    fn emit(self: *PacketBitWriter) Allocator.Error!void {
        const byte = self.cur;
        try self.bytes.append(self.gpa, byte);
        self.cur = 0;
        self.filled = 0;
        self.cap = if (byte == 0xFF) 7 else 8;
    }

    /// Flush the final partial byte (zero-padded), append a `0x00` if the last
    /// byte is `0xFF`, and return the header bytes (caller owns). The writer
    /// is left empty.
    pub fn finish(self: *PacketBitWriter) Allocator.Error![]u8 {
        if (self.filled > 0) {
            self.cur <<= @intCast(self.cap - self.filled);
            try self.emit();
        }
        if (self.bytes.items.len > 0 and self.bytes.items[self.bytes.items.len - 1] == 0xFF) {
            try self.bytes.append(self.gpa, 0x00);
        }
        return self.bytes.toOwnedSlice(self.gpa);
    }
};

/// MSB-first bit reader mirroring `PacketBitWriter`, strictly bounds-checked
/// (truncation is `error.InvalidData`, never a panic).
pub const PacketBitReader = struct {
    data: []const u8,
    pos: usize = 0,
    cur: u8 = 0,
    /// Unread valid bits remaining in `cur`.
    avail: u8 = 0,
    /// Previous loaded byte was `0xFF` (next byte holds 7 bits).
    prev_ff: bool = false,

    pub fn init(data: []const u8) PacketBitReader {
        return .{ .data = data };
    }

    fn loadNext(self: *PacketBitReader) CodecError!void {
        // "packet header truncated"
        if (self.pos >= self.data.len) return error.InvalidData;
        const b = self.data[self.pos];
        self.pos += 1;
        self.cur = b;
        self.avail = if (self.prev_ff) 7 else 8;
        self.prev_ff = b == 0xFF;
    }

    /// Read a single bit (MSB-first).
    pub fn readBit(self: *PacketBitReader) CodecError!u32 {
        if (self.avail == 0) try self.loadNext();
        self.avail -= 1;
        return (self.cur >> @intCast(self.avail)) & 1;
    }

    /// Read `n` bits (MSB-first, `n <= 64`).
    pub fn readBits(self: *PacketBitReader, n: u32) CodecError!u64 {
        std.debug.assert(n <= 64);
        var v: u64 = 0;
        for (0..n) |_| v = (v << 1) | try self.readBit();
        return v;
    }

    /// Header bytes consumed, including the stuffed `0x00` that must follow a
    /// header ending exactly on a `0xFF` byte.
    pub fn consumed(self: *const PacketBitReader) CodecError!usize {
        var n = self.pos;
        if (self.avail == 0 and self.pos > 0 and self.data[self.pos - 1] == 0xFF) {
            // "packet header truncated at stuffing byte"
            if (self.pos >= self.data.len) return error.InvalidData;
            n += 1;
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// Number-of-passes code (T.800 Table B.4)
// ---------------------------------------------------------------------------

fn writeNumPasses(bw: *PacketBitWriter, n: u32) Allocator.Error!void {
    std.debug.assert(n >= 1 and n <= 164);
    if (n == 1) {
        try bw.putBit(0);
    } else if (n == 2) {
        try bw.putBits(0b10, 2);
    } else if (n <= 5) {
        try bw.putBits(0xc | @as(u64, n - 3), 4);
    } else if (n <= 36) {
        try bw.putBits(0x1e0 | @as(u64, n - 6), 9);
    } else {
        try bw.putBits(0xff80 | @as(u64, n - 37), 16);
    }
}

fn readNumPasses(br: *PacketBitReader) CodecError!u32 {
    if (try br.readBit() == 0) return 1;
    if (try br.readBit() == 0) return 2;
    var f: u32 = @intCast(try br.readBits(2));
    if (f != 3) return 3 + f;
    f = @intCast(try br.readBits(5));
    if (f != 31) return 6 + f;
    f = @intCast(try br.readBits(7));
    return 37 + f; // max 164
}

/// `floor(log2(v))` for `v >= 1`.
fn floorLog2(v: u32) u32 {
    std.debug.assert(v > 0);
    return 31 - @as(u32, @clz(v));
}

// ---------------------------------------------------------------------------
// Precinct state
// ---------------------------------------------------------------------------

/// Per-precinct persistent packet-coding state (one per band here).
pub const PrecinctState = struct {
    /// Inclusion tag tree (leaf = first layer the block is included in).
    incl: TagTree,
    /// Zero-bit-plane tag tree (leaf = `Mb - num_bitplanes`).
    zbp: TagTree,
    /// `Lblock` per code-block (raster order), initialised to 3 (B.10.7.1).
    lblock: []u8,
    /// Whether each code-block was already included in an earlier layer.
    first_layer_included: []bool,

    pub fn init(gpa: Allocator, grid_w: u32, grid_h: u32) Allocator.Error!PrecinctState {
        const n = @as(usize, grid_w) * grid_h;
        var incl = try TagTree.init(gpa, grid_w, grid_h);
        errdefer incl.deinit(gpa);
        var zbp = try TagTree.init(gpa, grid_w, grid_h);
        errdefer zbp.deinit(gpa);
        const lblock = try gpa.alloc(u8, n);
        errdefer gpa.free(lblock);
        @memset(lblock, 3);
        const fli = try gpa.alloc(bool, n);
        @memset(fli, false);
        return .{ .incl = incl, .zbp = zbp, .lblock = lblock, .first_layer_included = fli };
    }

    pub fn deinit(self: *PrecinctState, gpa: Allocator) void {
        self.incl.deinit(gpa);
        self.zbp.deinit(gpa);
        gpa.free(self.lblock);
        gpa.free(self.first_layer_included);
        self.* = undefined;
    }
};

/// Free a slice of precinct states and the slice itself.
pub fn freeStates(gpa: Allocator, states: []PrecinctState) void {
    for (states) |*s| s.deinit(gpa);
    gpa.free(states);
}

/// One code-block's contribution recovered from a packet header.
pub const BlockContribution = struct {
    num_passes: u32,
    /// Zero (skipped) MSB bit-planes (`Mb - num_bitplanes`).
    zero_bitplanes: u32,
    /// Body length in bytes.
    len: usize,
};

/// Result of `readPacket`: per-band, per-block contributions plus header size.
pub const ReadResult = struct {
    contributions: [][]?BlockContribution,
    header_len: usize,

    pub fn deinit(self: *ReadResult, gpa: Allocator) void {
        for (self.contributions) |c| gpa.free(c);
        gpa.free(self.contributions);
        self.* = undefined;
    }
};

/// Included in this (only) layer iff it produced a non-empty segment.
fn isIncluded(cb: ?CodedBlock) bool {
    return if (cb) |c| c.num_bitplanes > 0 else false;
}

// ---------------------------------------------------------------------------
// Packet writer / reader
// ---------------------------------------------------------------------------

/// Write one packet for `bands`, appending header then bodies to `out`.
/// `states[i]`, `blocks[i]`, `mb_per_band[i]` correspond to `bands[i]`;
/// `blocks[i]` holds one entry per code-block in raster order.
pub fn writePacket(
    gpa: Allocator,
    states: []PrecinctState,
    bands: []const Band,
    blocks: []const []const ?CodedBlock,
    mb_per_band: []const u32,
    out: *std.ArrayList(u8),
) CodecError!void {
    std.debug.assert(states.len == bands.len);
    std.debug.assert(blocks.len == bands.len);
    std.debug.assert(mb_per_band.len == bands.len);

    var any_included = false;
    for (blocks) |bb| for (bb) |b| {
        if (isIncluded(b)) any_included = true;
    };

    var bw = PacketBitWriter.init(gpa);
    defer bw.deinit();

    if (!any_included) {
        // Empty packet: a single 0 bit, no bodies.
        try bw.putBit(0);
        const hdr = try bw.finish();
        defer gpa.free(hdr);
        try out.appendSlice(gpa, hdr);
        return;
    }

    try bw.putBit(1);

    for (bands, 0..) |band, bi| {
        const st = &states[bi];
        const gw = band.cb_grid_w;
        const gh = band.cb_grid_h;
        const mb = mb_per_band[bi];
        const band_blocks = blocks[bi];
        std.debug.assert(band_blocks.len == @as(usize, gw) * gh);

        // Populate every leaf before coding any node (min-propagation).
        for (0..gh) |cy| for (0..gw) |cx| {
            const k = cy * gw + cx;
            const nb: u32 = if (band_blocks[k]) |c| c.num_bitplanes else 0;
            st.incl.set(@intCast(cx), @intCast(cy), if (isIncluded(band_blocks[k])) 0 else 1);
            // "num_bitplanes exceeds Mb"
            if (nb > mb) return error.InvalidData;
            st.zbp.set(@intCast(cx), @intCast(cy), mb - nb);
        };

        for (0..gh) |cy_u| for (0..gw) |cx_u| {
            const cx: u32 = @intCast(cx_u);
            const cy: u32 = @intCast(cy_u);
            const k = cy_u * gw + cx_u;
            const cb = band_blocks[k];
            try st.incl.encode(&bw, cx, cy, 1);
            if (!isIncluded(cb)) continue;
            const coded = cb.?;
            const zbp = mb - coded.num_bitplanes;

            // Zero-bit-planes: rising thresholds until pinned (at zbp + 1).
            var t: u32 = 1;
            while (true) : (t += 1) {
                try st.zbp.encode(&bw, cx, cy, t);
                if (zbp < t) break;
            }

            try writeNumPasses(&bw, coded.num_passes);

            // Length: grow Lblock as needed (k ones + a zero), then the length.
            const passlog2 = floorLog2(coded.num_passes);
            const len: u64 = coded.data.len;
            const bits_needed: u32 = if (len == 0) 1 else floorLog2(@intCast(len)) + 1;
            const base = @as(u32, st.lblock[k]) + passlog2;
            const increment = bits_needed -| base;
            st.lblock[k] += @intCast(increment);
            for (0..increment) |_| try bw.putBit(1);
            try bw.putBit(0);
            try bw.putBits(len, @as(u32, st.lblock[k]) + passlog2);

            st.first_layer_included[k] = true;
        };
    }

    const hdr = try bw.finish();
    defer gpa.free(hdr);
    try out.appendSlice(gpa, hdr);

    // Bodies, same band-then-raster order as the header.
    for (bands, 0..) |band, bi| {
        for (0..band.cb_grid_h) |cy| for (0..band.cb_grid_w) |cx| {
            if (blocks[bi][cy * band.cb_grid_w + cx]) |c| {
                if (c.num_bitplanes > 0) try out.appendSlice(gpa, c.data);
            }
        };
    }
}

/// Read one packet header for `bands`, returning per-band per-block
/// contributions (`null` when not included) and the header byte count. The
/// caller takes each included block's `len` body bytes, in band-then-raster
/// order, from the bytes following the header.
pub fn readPacket(
    gpa: Allocator,
    states: []PrecinctState,
    bands: []const Band,
    mb_per_band: []const u32,
    data: []const u8,
) CodecError!ReadResult {
    std.debug.assert(states.len == bands.len);
    std.debug.assert(mb_per_band.len == bands.len);

    var br = PacketBitReader.init(data);

    const contributions = try gpa.alloc([]?BlockContribution, bands.len);
    var made: usize = 0;
    errdefer {
        for (contributions[0..made]) |c| gpa.free(c);
        gpa.free(contributions);
    }
    for (bands, 0..) |band, bi| {
        contributions[bi] = try gpa.alloc(?BlockContribution, band.cbs.len);
        @memset(contributions[bi], null);
        made += 1;
    }

    // Non-empty indicator.
    if (try br.readBit() == 0) {
        return .{ .contributions = contributions, .header_len = try br.consumed() };
    }

    for (bands, 0..) |band, bi| {
        const st = &states[bi];
        const gw = band.cb_grid_w;
        const gh = band.cb_grid_h;
        const mb = mb_per_band[bi];
        const band_out = contributions[bi];

        for (0..gh) |cy_u| for (0..gw) |cx_u| {
            const cx: u32 = @intCast(cx_u);
            const cy: u32 = @intCast(cy_u);
            const k = cy_u * gw + cx_u;
            if (!try st.incl.decode(&br, cx, cy, 1)) continue;

            // Zero-bit-planes: rising thresholds until resolved.
            var t: u32 = 1;
            const zbp = while (true) {
                if (try st.zbp.decode(&br, cx, cy, t)) break t - 1;
                t += 1;
                // "zero-bit-plane count exceeds Mb"
                if (t > mb +| 1) return error.InvalidData;
            };

            const num_passes = try readNumPasses(&br);
            const passlog2 = floorLog2(num_passes);

            // Lblock increment (ones terminated by a zero).
            var increment: u32 = 0;
            while (try br.readBit() == 1) {
                increment += 1;
                // "Lblock increment runaway"
                if (increment > 32) return error.InvalidData;
            }
            st.lblock[k] += @intCast(increment);
            const field = @as(u32, st.lblock[k]) + passlog2;
            // "length field width exceeds 63 bits"
            if (field > 63) return error.InvalidData;
            const len64 = try br.readBits(field);
            // "code-block length exceeds buffer"
            if (len64 > data.len) return error.InvalidData;

            st.first_layer_included[k] = true;
            band_out[k] = .{ .num_passes = num_passes, .zero_bitplanes = zbp, .len = @intCast(len64) };
        };
    }

    return .{ .contributions = contributions, .header_len = try br.consumed() };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

test "bit io roundtrip random" {
    var rng: u64 = 0x1234_5678_9abc_def0;
    for (0..500) |_| {
        rng = rng *% 6364136223846793005 +% 1;
        const nbits: u32 = @intCast(rng % 40 + 1);
        var bits: [40]u8 = undefined;
        for (0..nbits) |i| bits[i] = @intCast((rng >> @intCast(i % 63)) & 1);
        var bw = PacketBitWriter.init(ta);
        defer bw.deinit();
        for (bits[0..nbits]) |b| try bw.putBit(b);
        const bytes = try bw.finish();
        defer ta.free(bytes);
        try testing.expect(bytes[bytes.len - 1] != 0xFF);
        var br = PacketBitReader.init(bytes);
        for (bits[0..nbits]) |b| try testing.expectEqual(@as(u32, b), try br.readBit());
    }
}

test "stuffing all ones hits ff boundary" {
    for (1..41) |nbits| {
        var bw = PacketBitWriter.init(ta);
        defer bw.deinit();
        for (0..nbits) |_| try bw.putBit(1);
        const bytes = try bw.finish();
        defer ta.free(bytes);
        try testing.expect(bytes[bytes.len - 1] != 0xFF);
        for (0..bytes.len - 1) |i| {
            if (bytes[i] == 0xFF) try testing.expectEqual(@as(u8, 0), bytes[i + 1] & 0x80);
        }
        var br = PacketBitReader.init(bytes);
        for (0..nbits) |_| try testing.expectEqual(@as(u32, 1), try br.readBit());
    }
}

test "reader truncation errors" {
    var bw = PacketBitWriter.init(ta);
    defer bw.deinit();
    for (0..20) |_| try bw.putBit(1);
    const bytes = try bw.finish();
    defer ta.free(bytes);
    var empty = PacketBitReader.init(&.{});
    try testing.expectError(error.InvalidData, empty.readBit());
    var br = PacketBitReader.init(bytes);
    var errored = false;
    for (0..bytes.len * 8 + 16) |_| {
        _ = br.readBit() catch {
            errored = true;
            break;
        };
    }
    try testing.expect(errored);
}

test "num passes roundtrip full range" {
    for (1..165) |n| {
        var bw = PacketBitWriter.init(ta);
        defer bw.deinit();
        try writeNumPasses(&bw, @intCast(n));
        const bytes = try bw.finish();
        defer ta.free(bytes);
        var br = PacketBitReader.init(bytes);
        try testing.expectEqual(@as(u32, @intCast(n)), try readNumPasses(&br));
    }
}

// -- packet round-trips -----------------------------------------------------

/// Owns a geometry so a band (which borrows its `cbs`) stays valid.
const BandFixture = struct {
    geom: geometry.TileGeometry,
    fn band(self: *const BandFixture) Band {
        return self.geom.resolutions[0].bands[0];
    }
    fn deinit(self: *BandFixture) void {
        self.geom.deinit(ta);
    }
};

fn llBand(w: u32, h: u32, levels: u8, xcb: u8, ycb: u8) !BandFixture {
    return .{ .geom = try geometry.buildGeometry(ta, w, h, levels, xcb, ycb) };
}

/// Synthetic coded block; `data` is owned by `ta`.
fn synth(num_bitplanes: u32, num_passes: u32, len: usize, fill: u8) !CodedBlock {
    const d = try ta.alloc(u8, len);
    @memset(d, fill);
    return .{ .data = d, .num_passes = num_passes, .num_bitplanes = num_bitplanes };
}

fn freeBlocks(blocks: []?CodedBlock) void {
    for (blocks) |*b| if (b.*) |*c| c.deinit(ta);
}

fn oneState(band: Band) ![1]PrecinctState {
    return .{try PrecinctState.init(ta, band.cb_grid_w, band.cb_grid_h)};
}

test "empty packet roundtrip" {
    var fx = try llBand(64, 64, 0, 6, 6);
    defer fx.deinit();
    const bands = [_]Band{fx.band()};
    const mb = [_]u32{18};
    const blocks = [_]?CodedBlock{null};
    var states = try oneState(bands[0]);
    defer states[0].deinit(ta);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try writePacket(ta, &states, &bands, &.{&blocks}, &mb, &out);
    try testing.expectEqualSlices(u8, &.{0x00}, out.items);

    var rstates = try oneState(bands[0]);
    defer rstates[0].deinit(ta);
    var rr = try readPacket(ta, &rstates, &bands, &mb, out.items);
    defer rr.deinit(ta);
    try testing.expectEqual(@as(usize, 1), rr.header_len);
    try testing.expect(rr.contributions[0][0] == null);
}

test "single block included roundtrip" {
    var fx = try llBand(64, 64, 0, 6, 6);
    defer fx.deinit();
    const bands = [_]Band{fx.band()};
    const mb = [_]u32{18};
    var blocks = [_]?CodedBlock{try synth(7, 19, 42, 0xAB)};
    defer freeBlocks(&blocks);
    var states = try oneState(bands[0]);
    defer states[0].deinit(ta);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try writePacket(ta, &states, &bands, &.{&blocks}, &mb, &out);

    var rstates = try oneState(bands[0]);
    defer rstates[0].deinit(ta);
    var rr = try readPacket(ta, &rstates, &bands, &mb, out.items);
    defer rr.deinit(ta);
    const c = rr.contributions[0][0].?;
    try testing.expectEqual(@as(u32, 19), c.num_passes);
    try testing.expectEqual(@as(u32, 18 - 7), c.zero_bitplanes);
    try testing.expectEqual(@as(usize, 42), c.len);
    try testing.expectEqualSlices(u8, blocks[0].?.data, out.items[rr.header_len .. rr.header_len + c.len]);
    try testing.expectEqual(rr.header_len + 42, out.items.len);
}

/// Write then read one packet over a single band; verify bodies and lengths.
fn runPacketCase(band: Band, mb: u32, blocks: []const ?CodedBlock) !void {
    const bands = [_]Band{band};
    const mbv = [_]u32{mb};
    var states = try oneState(band);
    defer states[0].deinit(ta);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try writePacket(ta, &states, &bands, &.{blocks}, &mbv, &out);

    var rstates = try oneState(band);
    defer rstates[0].deinit(ta);
    var rr = try readPacket(ta, &rstates, &bands, &mbv, out.items);
    defer rr.deinit(ta);

    var body_pos = rr.header_len;
    for (blocks, 0..) |blk, k| {
        const got = rr.contributions[0][k];
        if (isIncluded(blk)) {
            const coded = blk.?;
            const c = got.?;
            try testing.expectEqual(coded.num_passes, c.num_passes);
            try testing.expectEqual(mb - coded.num_bitplanes, c.zero_bitplanes);
            try testing.expectEqual(coded.data.len, c.len);
            try testing.expectEqualSlices(u8, coded.data, out.items[body_pos .. body_pos + c.len]);
            body_pos += c.len;
        } else {
            try testing.expect(got == null);
        }
    }
    try testing.expectEqual(out.items.len, body_pos);
}

test "multi block mixed inclusion" {
    var fx = try llBand(64, 64, 0, 2, 2);
    defer fx.deinit();
    const band = fx.band();
    const n: usize = band.cb_grid_w * band.cb_grid_h;
    try testing.expect(n > 1);
    const blocks = try ta.alloc(?CodedBlock, n);
    defer ta.free(blocks);
    @memset(blocks, null);
    defer freeBlocks(blocks);
    blocks[0] = try synth(3, 7, 1, 0x01);
    blocks[n / 3] = try synth(12, 34, 200, 0x02);
    blocks[n / 2] = try synth(1, 1, 5, 0x03);
    blocks[n - 1] = try synth(20, 58, 999, 0x04);
    try runPacketCase(band, 20, blocks);
}

test "truncation at every byte errors" {
    var fx = try llBand(64, 64, 0, 2, 2);
    defer fx.deinit();
    const band = fx.band();
    const n: usize = band.cb_grid_w * band.cb_grid_h;
    const blocks = try ta.alloc(?CodedBlock, n);
    defer ta.free(blocks);
    @memset(blocks, null);
    defer freeBlocks(blocks);
    blocks[1] = try synth(9, 25, 300, 0x55);
    blocks[n - 2] = try synth(4, 10, 7, 0xAA);

    const bands = [_]Band{band};
    const mbv = [_]u32{20};
    var states = try oneState(band);
    defer states[0].deinit(ta);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ta);
    try writePacket(ta, &states, &bands, &.{blocks}, &mbv, &out);

    for (0..out.items.len) |cut| {
        var rs = try oneState(band);
        defer rs[0].deinit(ta);
        if (readPacket(ta, &rs, &bands, &mbv, out.items[0..cut])) |r| {
            var rr = r;
            rr.deinit(ta);
        } else |_| {}
    }
    var rs = try oneState(band);
    defer rs[0].deinit(ta);
    var rr = try readPacket(ta, &rs, &bands, &mbv, out.items);
    rr.deinit(ta);
}

test "sequential packets shared buffer" {
    var g = try geometry.buildGeometry(ta, 64, 64, 2, 3, 3);
    defer g.deinit(ta);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(ta);

    const Plan = struct { band: Band, blocks: []?CodedBlock, start: usize };
    var plan: std.ArrayList(Plan) = .empty;
    defer {
        for (plan.items) |p| {
            freeBlocks(p.blocks);
            ta.free(p.blocks);
        }
        plan.deinit(ta);
    }
    const mb: u32 = 22;

    for (g.resolutions) |res| for (res.bands) |band| {
        if (band.rect.isEmpty()) continue;
        const n: usize = band.cb_grid_w * band.cb_grid_h;
        const blocks = try ta.alloc(?CodedBlock, n);
        @memset(blocks, null);
        try plan.append(ta, .{ .band = band, .blocks = blocks, .start = stream.items.len });
        blocks[0] = try synth(6, 16, 40 + n, 0x11);
        if (n > 1) blocks[n - 1] = try synth(2, 4, 17, 0x22);
        const bands = [_]Band{band};
        var states = try oneState(band);
        defer states[0].deinit(ta);
        try writePacket(ta, &states, &bands, &.{blocks}, &.{mb}, &stream);
    };

    var pos: usize = 0;
    for (plan.items) |p| {
        try testing.expectEqual(p.start, pos);
        const bands = [_]Band{p.band};
        var rs = try oneState(p.band);
        defer rs[0].deinit(ta);
        var rr = try readPacket(ta, &rs, &bands, &.{mb}, stream.items[pos..]);
        defer rr.deinit(ta);
        var body_pos = pos + rr.header_len;
        for (p.blocks, 0..) |blk, k| {
            if (blk) |coded| {
                const c = rr.contributions[0][k].?;
                try testing.expectEqual(coded.data.len, c.len);
                try testing.expectEqualSlices(u8, coded.data, stream.items[body_pos .. body_pos + c.len]);
                body_pos += c.len;
            }
        }
        pos = body_pos;
    }
    try testing.expectEqual(stream.items.len, pos);
}

// Rust proptest (300 cases): random inclusion / bit-planes / passes / lengths
// over a 32x32 LL band with 4x4 code-blocks. Deterministic seeds here.
test "prop header roundtrip" {
    var fx = try llBand(32, 32, 0, 2, 2);
    defer fx.deinit();
    const band = fx.band();
    const n: usize = band.cb_grid_w * band.cb_grid_h;
    var prng = std.Random.DefaultPrng.init(0x9AC_4E7);
    const r = prng.random();
    const blocks = try ta.alloc(?CodedBlock, n);
    defer ta.free(blocks);
    for (0..300) |_| {
        const mb = r.intRangeAtMost(u32, 4, 30);
        var rng: u64 = r.int(u64) | 1;
        const next = struct {
            fn f(s: *u64) u64 {
                s.* = s.* *% 6364136223846793005 +% 1;
                return s.* >> 33;
            }
        }.f;
        @memset(blocks, null);
        defer freeBlocks(blocks);
        for (blocks) |*b| {
            if (next(&rng) % 3 == 0) continue;
            const nb = @min(1 + @as(u32, @intCast(next(&rng) % mb)), mb);
            const max_passes = 3 * nb - 2;
            const np = 1 + @min(@as(u32, @intCast(next(&rng) % max_passes)), 163);
            const len: usize = @intCast(next(&rng) % 2000);
            b.* = try synth(nb, np, len, @truncate(next(&rng)));
        }
        try runPacketCase(band, mb, blocks);
    }
}
