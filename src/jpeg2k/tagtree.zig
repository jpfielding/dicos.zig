//! Tag-tree (quad-tree) codec for JPEG 2000 packet headers (ITU-T T.800
//! B.10.2).
//!
//! A tag tree describes a 2-D array of non-negative integers where each
//! interior node holds the minimum of its four children. Packet headers use
//! two per precinct: code-block inclusion and zero-bit-plane counts. Values
//! are coded *incrementally*: repeated queries at rising thresholds emit /
//! consume only the bits needed to refine what the decoder already knows, and
//! per-node state persists across queries. Mirrors the canonical Taubman /
//! OpenJPEG `tgt_encode` / `tgt_decode`.
//!
//! Bit I/O is duck-typed: `encode` takes any `out` with
//! `putBit(self, u8) !void`; `decode` takes any `src` with
//! `readBit(self) !u32`. This keeps the module independent of `packet.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sentinel meaning "value not yet known".
const UNKNOWN: u32 = std.math.maxInt(u32);

/// Upper bound on tree depth: each level halves (ceil) a u32 dimension.
const MAX_LEVELS = 33;

const Node = struct {
    /// Encoder: min-propagated value. Decoder: current upper bound, lowered
    /// to the exact value once a `1` bit is read.
    value: u32 = UNKNOWN,
    /// Coding-state lower bound.
    low: u32 = 0,
    /// Encoder only: a `1` has already been emitted at this node.
    known: bool = false,
};

const Level = struct {
    w: u32,
    h: u32,
    /// Offset of this level's first node in `TagTree.nodes`.
    base: usize,

    inline fn idx(self: Level, x: u32, y: u32) usize {
        return self.base + @as(usize, y) * self.w + x;
    }
};

const PathEntry = struct { level: usize, x: u32, y: u32 };

/// A tag tree over a `leaves_w x leaves_h` grid of non-negative values.
pub const TagTree = struct {
    /// `levels[0]` is the leaf grid; the last level is the 1x1 root.
    levels: [MAX_LEVELS]Level = undefined,
    num_levels: usize = 0,
    nodes: []Node = &.{},
    leaves_w: u32,
    leaves_h: u32,

    /// Build a tag tree. A zero dimension yields an empty tree that ignores
    /// `set`/`encode` and decodes as "not established".
    pub fn init(gpa: Allocator, leaves_w: u32, leaves_h: u32) Allocator.Error!TagTree {
        var t: TagTree = .{ .leaves_w = leaves_w, .leaves_h = leaves_h };
        if (leaves_w == 0 or leaves_h == 0) return t;

        var total: usize = 0;
        var w = leaves_w;
        var h = leaves_h;
        while (true) {
            t.levels[t.num_levels] = .{ .w = w, .h = h, .base = total };
            t.num_levels += 1;
            total += @as(usize, w) * h;
            if (w == 1 and h == 1) break;
            w = w / 2 + w % 2;
            h = h / 2 + h % 2;
        }
        t.nodes = try gpa.alloc(Node, total);
        @memset(t.nodes, .{});
        return t;
    }

    pub fn deinit(self: *TagTree, gpa: Allocator) void {
        gpa.free(self.nodes);
        self.* = undefined;
    }

    inline fn inRange(self: *const TagTree, x: u32, y: u32) bool {
        return self.num_levels != 0 and x < self.leaves_w and y < self.leaves_h;
    }

    /// Set a leaf value (encoder side), propagating the running minimum up.
    pub fn set(self: *TagTree, x: u32, y: u32, value: u32) void {
        if (!self.inRange(x, y)) return;
        var cx = x;
        var cy = y;
        for (self.levels[0..self.num_levels]) |lvl| {
            const n = &self.nodes[lvl.idx(cx, cy)];
            if (value < n.value) n.value = value;
            cx /= 2;
            cy /= 2;
        }
    }

    /// Clear coding state (`low`, emitted flags) while keeping values.
    pub fn reset(self: *TagTree) void {
        for (self.nodes) |*n| {
            n.low = 0;
            n.known = false;
        }
    }

    fn path(self: *const TagTree, x: u32, y: u32, buf: *[MAX_LEVELS]PathEntry) []const PathEntry {
        var cx = x;
        var cy = y;
        for (0..self.num_levels) |l| {
            buf[l] = .{ .level = l, .x = cx, .y = cy };
            cx /= 2;
            cy /= 2;
        }
        return buf[0..self.num_levels];
    }

    /// Encode what is needed to establish whether leaf `(x, y)` is
    /// `< threshold`, emitting bits through `out.putBit`. Walks root -> leaf.
    pub fn encode(self: *TagTree, out: anytype, x: u32, y: u32, threshold: u32) !void {
        if (!self.inRange(x, y)) return;
        var buf: [MAX_LEVELS]PathEntry = undefined;
        const p = self.path(x, y, &buf);
        var low: u32 = 0;
        var i = p.len;
        while (i > 0) {
            i -= 1;
            const node = &self.nodes[self.levels[p[i].level].idx(p[i].x, p[i].y)];
            if (low > node.low) node.low = low else low = node.low;

            while (low < threshold) {
                if (low >= node.value) {
                    if (!node.known) {
                        try out.putBit(1);
                        node.known = true;
                    }
                    break;
                }
                try out.putBit(0);
                low += 1;
            }
            node.low = low;
        }
    }

    /// Decode the mirror of `encode`, pulling bits from `src.readBit`.
    /// Returns `true` when leaf `(x, y)` is established to be `< threshold`.
    pub fn decode(self: *TagTree, src: anytype, x: u32, y: u32, threshold: u32) !bool {
        if (!self.inRange(x, y)) return false;
        var buf: [MAX_LEVELS]PathEntry = undefined;
        const p = self.path(x, y, &buf);
        var low: u32 = 0;
        var i = p.len;
        while (i > 0) {
            i -= 1;
            const node = &self.nodes[self.levels[p[i].level].idx(p[i].x, p[i].y)];
            if (low > node.low) node.low = low else low = node.low;

            while (low < threshold and low < node.value) {
                if (try src.readBit() != 0) {
                    node.value = low;
                } else {
                    low += 1;
                }
            }
            node.low = low;
        }
        return self.nodes[self.levels[0].idx(x, y)].value < threshold;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ta = testing.allocator;

const BitSink = struct {
    bits: std.ArrayList(u8) = .empty,
    fn putBit(self: *BitSink, b: u8) !void {
        try self.bits.append(ta, b);
    }
    fn deinit(self: *BitSink) void {
        self.bits.deinit(ta);
    }
};

const BitSrc = struct {
    bits: []const u8,
    pos: usize = 0,
    fn readBit(self: *BitSrc) !u32 {
        if (self.pos >= self.bits.len) return error.TestUnexpectedResult; // ran out
        const b = self.bits[self.pos];
        self.pos += 1;
        return b;
    }
};

const NullSink = struct {
    fn putBit(_: *NullSink, _: u8) !void {}
};

const PanicIo = struct {
    fn putBit(_: *PanicIo, _: u8) !void {
        @panic("no bits for empty tree");
    }
    fn readBit(_: *PanicIo) !u32 {
        @panic("no reads for empty tree");
    }
};

const EmptySrc = struct {
    fn readBit(_: *EmptySrc) error{InvalidData}!u32 {
        return error.InvalidData;
    }
};

fn encodeSweep(vals: []const u32, w: u32, h: u32, max_t: u32, sink: *BitSink) !void {
    var tree = try TagTree.init(ta, w, h);
    defer tree.deinit(ta);
    for (0..h) |y| for (0..w) |x| tree.set(@intCast(x), @intCast(y), vals[y * w + x]);
    var t: u32 = 1;
    while (t <= max_t) : (t += 1) {
        for (0..h) |y| for (0..w) |x| try tree.encode(sink, @intCast(x), @intCast(y), t);
    }
}

fn decodeSweepAndCheck(vals: []const u32, w: u32, h: u32, max_t: u32, bits: []const u8) !void {
    var tree = try TagTree.init(ta, w, h);
    defer tree.deinit(ta);
    var src: BitSrc = .{ .bits = bits };
    var t: u32 = 1;
    while (t <= max_t) : (t += 1) {
        for (0..h) |y| for (0..w) |x| {
            const got = try tree.decode(&src, @intCast(x), @intCast(y), t);
            try testing.expectEqual(vals[y * w + x] < t, got);
        };
    }
    try testing.expectEqual(bits.len, src.pos);
}

fn roundtrip(vals: []const u32, w: u32, h: u32) !void {
    const max = std.mem.max(u32, vals);
    var sink: BitSink = .{};
    defer sink.deinit();
    try encodeSweep(vals, w, h, max + 1, &sink);
    try decodeSweepAndCheck(vals, w, h, max + 1, sink.bits.items);
}

test "worked example 3x2" {
    try roundtrip(&.{ 1, 3, 2, 2, 2, 3 }, 3, 2);
}

test "single leaf" {
    try roundtrip(&.{0}, 1, 1);
    try roundtrip(&.{5}, 1, 1);
    try roundtrip(&.{1}, 1, 1);
}

test "all zero and flat" {
    try roundtrip(&.{ 0, 0, 0, 0, 0, 0 }, 3, 2);
    try roundtrip(&.{ 7, 7, 7, 7, 7, 7 }, 2, 3);
}

test "threshold learns value exactly" {
    var enc = try TagTree.init(ta, 1, 1);
    defer enc.deinit(ta);
    enc.set(0, 0, 3);
    var sink: BitSink = .{};
    defer sink.deinit();
    var t: u32 = 1;
    while (t <= 5) : (t += 1) try enc.encode(&sink, 0, 0, t);

    var dec = try TagTree.init(ta, 1, 1);
    defer dec.deinit(ta);
    var src: BitSrc = .{ .bits = sink.bits.items };
    t = 1;
    while (t <= 5) : (t += 1) try testing.expectEqual(3 < t, try dec.decode(&src, 0, 0, t));
    try testing.expectEqual(sink.bits.items.len, src.pos);
}

test "reset keeps values" {
    const vals = [_]u32{ 1, 4, 2, 0 };
    var a: BitSink = .{};
    defer a.deinit();
    try encodeSweep(&vals, 2, 2, 5, &a);

    var tree = try TagTree.init(ta, 2, 2);
    defer tree.deinit(ta);
    for (0..2) |y| for (0..2) |x| tree.set(@intCast(x), @intCast(y), vals[y * 2 + x]);
    var nul: NullSink = .{};
    var t: u32 = 1;
    while (t <= 5) : (t += 1) for (0..2) |y| for (0..2) |x| try tree.encode(&nul, @intCast(x), @intCast(y), t);
    tree.reset();
    var b: BitSink = .{};
    defer b.deinit();
    t = 1;
    while (t <= 5) : (t += 1) for (0..2) |y| for (0..2) |x| try tree.encode(&b, @intCast(x), @intCast(y), t);
    try testing.expectEqualSlices(u8, a.bits.items, b.bits.items);
}

test "empty tree graceful" {
    var p: PanicIo = .{};
    var t = try TagTree.init(ta, 0, 5);
    defer t.deinit(ta);
    t.set(0, 0, 3);
    try t.encode(&p, 0, 0, 4);
    try testing.expect(!(try t.decode(&p, 0, 0, 4)));

    var t2 = try TagTree.init(ta, 4, 0);
    defer t2.deinit(ta);
    try t2.encode(&p, 1, 0, 2);
    try testing.expect(!(try t2.decode(&p, 1, 0, 2)));
}

test "decode out of bits errors" {
    var enc = try TagTree.init(ta, 2, 2);
    defer enc.deinit(ta);
    for (0..2) |y| for (0..2) |x| enc.set(@intCast(x), @intCast(y), 2);
    var sink: BitSink = .{};
    defer sink.deinit();
    try enc.encode(&sink, 0, 0, 3);

    var dec = try TagTree.init(ta, 2, 2);
    defer dec.deinit(ta);
    var src: EmptySrc = .{};
    try testing.expectError(error.InvalidData, dec.decode(&src, 0, 0, 3));
}

// Property test (Rust proptest, 200 cases): random grids, full incremental
// sweep, exact match. Deterministic seeds here.
test "prop incremental roundtrip" {
    var prng = std.Random.DefaultPrng.init(0x7A6_7EE5);
    const r = prng.random();
    for (0..200) |_| {
        const w = r.intRangeAtMost(u32, 1, 17);
        const h = r.intRangeAtMost(u32, 1, 13);
        var state: u64 = r.int(u64) | 1;
        var vals: [17 * 13]u32 = undefined;
        for (vals[0 .. w * h]) |*v| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            v.* = @intCast(state % 21);
        }
        try roundtrip(vals[0 .. w * h], w, h);
    }
}
