//! Deterministic ports of the Rust `fuzz/fuzz_targets/*` harnesses.
//!
//! Each target's oracle is reproduced exactly; libFuzzer's coverage-guided
//! input stream is replaced by a seeded PRNG and a fixed iteration budget so
//! the suite stays fast and reproducible. A panic (safety check) or a broken
//! invariant fails the test. Geometry stays small (<= 64x64x3), so no case can
//! allocate more than a few hundred KiB.

const std = @import("std");
const jpegls = @import("../root.zig");
const util = @import("util.zig");

const testing = std.testing;
const ta = testing.allocator;

const ITERATIONS = 300;

// ---------------------------------------------------------------------------
// Shared helpers (Rust fuzz/src/lib.rs)
// ---------------------------------------------------------------------------

const Input = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(self: *Input) u8 {
        const b = if (self.pos < self.data.len) self.data[self.pos] else 0;
        self.pos += 1;
        return b;
    }

    fn word(self: *Input) u16 {
        const lo = self.byte();
        const hi = self.byte();
        return @as(u16, hi) << 8 | lo;
    }

    fn rest(self: *Input) []const u8 {
        const start = @min(self.pos, self.data.len);
        self.pos = self.data.len;
        return self.data[start..];
    }
};

fn maxVal(precision: u8) u32 {
    return (@as(u32, 1) << @intCast(precision)) - 1;
}

fn nearMax(max_val: u32) u8 {
    return @intCast(@min(max_val / 2, 255));
}

fn samplesFrom(body: []const u8, n: usize, mask: u32) ![]u16 {
    const out = try ta.alloc(u16, n);
    for (out, 0..) |*v, i| {
        if (body.len == 0) {
            v.* = 0;
            continue;
        }
        const lo = body[(2 * i) % body.len];
        const hi = body[(2 * i + 1) % body.len];
        v.* = @intCast((@as(u32, hi) << 8 | lo) & mask);
    }
    return out;
}

const ImageSpec = struct {
    components: u8,
    precision: u8,
    width: u32,
    height: u32,
    near: u8,
    samples: []u16,

    const HEADER_LEN = 5;

    fn fromBytes(data: []const u8) !?ImageSpec {
        if (data.len < HEADER_LEN) return null;
        const components: u8 = if (data[0] & 1 == 1) 3 else 1;
        const precision: u8 = 2 + data[1] % 15;
        const width = 1 + @as(u32, data[2] % 64);
        const height = 1 + @as(u32, data[3] % 64);
        const mv = maxVal(precision);
        const near: u8 = if (data[4] & 0x80 == 0) 0 else @intCast(@as(u32, data[4] & 0x7f) % (@as(u32, nearMax(mv)) + 1));
        const n = width * height * components;
        return .{
            .components = components,
            .precision = precision,
            .width = width,
            .height = height,
            .near = near,
            .samples = try samplesFrom(data[HEADER_LEN..], n, mv),
        };
    }

    fn deinit(self: ImageSpec) void {
        ta.free(self.samples);
    }

    fn encode(self: ImageSpec) ![]u8 {
        return util.encodeImg(self.samples, self.width, self.height, self.components, .{ .near = self.near, .precision = self.precision });
    }
};

fn assertImageContract(img: jpegls.DecodedImage, max_sample: ?u32) !void {
    try testing.expect(img.components == 1 or img.components == 3);
    try testing.expectEqual(@as(u8, 0), img.interleave_mode);
    try testing.expect(img.bits_per_sample >= 2 and img.bits_per_sample <= 16);
    try testing.expectEqual(@as(usize, img.width) * img.height * img.components, img.samples.len);
    const max = max_sample orelse maxVal(img.bits_per_sample);
    for (img.samples) |s| try testing.expect(s <= max);
}

fn assertDecodeAgrees(data: []const u8, img: jpegls.DecodedImage) !void {
    if (img.components != 1) return;
    const samples = try jpegls.decode(ta, data, img.width, img.height);
    defer ta.free(samples);
    try testing.expectEqualSlices(u16, img.samples, samples);
}

fn assertWithinNear(decoded: []const u16, original: []const u16, near: u8) !void {
    try testing.expectEqual(original.len, decoded.len);
    if (near == 0) return testing.expectEqualSlices(u16, original, decoded);
    for (decoded, original) |d, o| try testing.expect(@abs(@as(i32, d) - @as(i32, o)) <= near);
}

fn randomBytes(r: std.Random, buf: []u8, max_len: usize) []u8 {
    const n = r.uintAtMost(usize, @min(max_len, buf.len));
    r.bytes(buf[0..n]);
    return buf[0..n];
}

/// A random but valid ImageSpec input (header + sample bytes).
fn randomSpecBytes(r: std.Random, buf: []u8) []u8 {
    const n = ImageSpec.HEADER_LEN + r.uintAtMost(usize, buf.len - ImageSpec.HEADER_LEN);
    r.bytes(buf[0..n]);
    // Bias toward small images so the suite stays quick.
    buf[2] %= 24;
    buf[3] %= 24;
    return buf[0..n];
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

/// fuzz_targets/decode.rs
fn targetDecode(data: []const u8) !void {
    if (data.len < 4) return;
    const dim = struct {
        fn f(lo: u8, hi: u8) u32 {
            return std.math.clamp(@as(u32, hi) << 8 | lo, 1, 512);
        }
    }.f;
    const width = dim(data[0], data[1]);
    const height = dim(data[2], data[3]);
    const body = data[4..];
    _ = util.decodeErr(body, width, height);
    if (data[0] & 1 == 1) _ = util.decodeErrOpts(body, width, height, .{ .profile = .legacy_go });
}

/// fuzz_targets/decode_image.rs
fn targetDecodeImage(data: []const u8) !void {
    var img = jpegls.decodeImage(ta, data) catch return;
    defer img.deinit(ta);
    try assertImageContract(img, null);
    try assertDecodeAgrees(data, img);
}

fn segment(out: *std.ArrayList(u8), marker: u8, payload: []const u8) !void {
    try out.appendSlice(ta, &.{ 0xFF, marker });
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @intCast(payload.len + 2), .big);
    try out.appendSlice(ta, &len);
    try out.appendSlice(ta, payload);
}

/// fuzz_targets/decode_lse.rs
fn targetDecodeLse(data: []const u8) !void {
    var in = Input{ .data = data };
    const flags = in.byte();
    const nf: u8 = if (flags & 1 == 1) 3 else 1;
    const precision: u8 = 2 + in.byte() % 15;
    const width: u16 = 1 + @as(u16, in.byte() % 32);
    const height: u16 = 1 + @as(u16, in.byte() % 32);
    const b = in.byte();
    const near: u8 = if (b & 0x80 == 0) 0 else b & 0x7f;
    const raw = [5]u16{ in.word(), in.word(), in.word(), in.word(), in.word() };
    const splits = [2]u8{ in.byte(), in.byte() };
    const body = in.rest();

    const sof_max = maxVal(precision);
    var fields: [5]u16 = raw;
    if (flags & 0x10 == 0) {
        const maxval: u16 = @intCast(@as(u32, raw[0]) % (sof_max + 1));
        const m: u32 = if (maxval == 0) sof_max else maxval;
        const t = struct {
            fn f(r: u16, mm: u32) u16 {
                return @intCast(@as(u32, r) % (mm + 1));
            }
        }.f;
        const reset: u16 = @intCast(3 + @as(u32, raw[4]) % (@max(m, 255) - 2));
        fields = .{ maxval, t(raw[1], m), t(raw[2], m), t(raw[3], m), reset };
    }

    var lse: std.ArrayList(u8) = .empty;
    defer lse.deinit(ta);
    try lse.append(ta, 1);
    for (fields) |v| {
        var be: [2]u8 = undefined;
        std.mem.writeInt(u16, &be, v, .big);
        try lse.appendSlice(ta, &be);
    }
    if (flags & 0x20 != 0) try lse.appendSlice(ta, &.{ 0xA5, 0xA5, 0xA5 });

    var sof: std.ArrayList(u8) = .empty;
    defer sof.deinit(ta);
    try sof.append(ta, precision);
    var be: [4]u8 = undefined;
    std.mem.writeInt(u16, be[0..2], height, .big);
    std.mem.writeInt(u16, be[2..4], width, .big);
    try sof.appendSlice(ta, &be);
    try sof.append(ta, nf);
    for (1..nf + 1) |c| try sof.appendSlice(ta, &.{ @intCast(c), 0x11, 0x00 });

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(ta);
    try stream.appendSlice(ta, &.{ 0xFF, 0xD8 });
    if (flags & 0x02 != 0) try segment(&stream, 0xE0, "fuzz");
    if (flags & 0x08 == 0) try segment(&stream, 0xF8, lse.items);
    try segment(&stream, 0xF7, sof.items);
    if (flags & 0x08 != 0) try segment(&stream, 0xF8, lse.items);
    if (flags & 0x04 != 0) try segment(&stream, 0xDD, &.{ 0x00, 0x00 });

    var cuts: [4]usize = undefined;
    cuts[0] = 0;
    for (0..nf - 1) |i| cuts[i + 1] = cuts[i] + (body.len - cuts[i]) * splits[i] / 255;
    cuts[nf] = body.len;
    for (0..nf) |c| {
        try segment(&stream, 0xDA, &.{ 1, @intCast(c + 1), 0, near, 0, 0 });
        try stream.appendSlice(ta, body[cuts[c]..cuts[c + 1]]);
    }
    try stream.appendSlice(ta, &.{ 0xFF, 0xD9 });

    var img = jpegls.decodeImage(ta, stream.items) catch return;
    defer img.deinit(ta);
    const maxval = fields[0];
    const reset = fields[4];
    const effective_max: u32 = if (maxval == 0) sof_max else maxval;
    try testing.expect(effective_max <= sof_max);
    try testing.expect(reset >= 3);
    try testing.expect(near <= @min(effective_max / 2, 255));
    try assertImageContract(img, effective_max);
    try testing.expectEqual(@as(u32, width), img.width);
    try testing.expectEqual(@as(u32, height), img.height);
    try testing.expectEqual(nf, img.components);
    try testing.expectEqual(precision, img.bits_per_sample);
    try testing.expectEqual(near, img.near);
    try assertDecodeAgrees(stream.items, img);
}

/// fuzz_targets/decode_mutated.rs
fn targetDecodeMutated(data: []const u8) !void {
    var in = Input{ .data = data };
    const n_edits = in.byte() % 9;
    var edits: [8][3]u16 = undefined;
    for (0..n_edits) |i| edits[i] = .{ in.byte(), in.word(), in.byte() };
    const spec = (try ImageSpec.fromBytes(in.rest())) orelse return;
    defer spec.deinit();
    const original = try spec.encode();
    defer ta.free(original);

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(ta);
    try stream.appendSlice(ta, original);
    for (edits[0..n_edits]) |e| {
        const op: u8 = @intCast(e[0]);
        const val: u8 = @intCast(e[2]);
        const len = stream.items.len;
        const at = struct {
            fn f(pos: u16, n: usize) usize {
                return @as(usize, pos) % @max(n, 1);
            }
        }.f;
        switch (op % 6) {
            0 => if (len > 0) {
                stream.items[at(e[1], len)] = val;
            },
            1 => if (len > 0) {
                stream.items[at(e[1], len)] ^= val | 1;
            },
            2 => try stream.insert(ta, at(e[1], len + 1), val),
            3 => if (len > 0) {
                _ = stream.orderedRemove(at(e[1], len));
            },
            4 => stream.shrinkRetainingCapacity(at(e[1], len + 1)),
            5 => try stream.insertSlice(ta, at(e[1], len + 1), &.{ 0xFF, val }),
            else => unreachable,
        }
    }

    _ = util.decodeErr(stream.items, spec.width, spec.height);
    _ = util.decodeErrOpts(stream.items, spec.width, spec.height, .{ .profile = .legacy_go });

    const unchanged = std.mem.eql(u8, stream.items, original);
    var img = jpegls.decodeImage(ta, stream.items) catch |e| {
        if (unchanged) return e; // must not reject an unmodified stream
        return;
    };
    defer img.deinit(ta);
    if (unchanged) try assertWithinNear(img.samples, spec.samples, spec.near);
    try assertImageContract(img, null);
    try assertDecodeAgrees(stream.items, img);
}

/// fuzz_targets/encode_gray.rs
fn targetEncodeGray(data: []const u8) !void {
    if (data.len < 5) return;
    const legacy = data[0] & 1 == 1;
    const explicit = data[0] & 2 == 2;
    const precision: u8 = 2 + data[1] % 15;
    const width = 1 + @as(u32, data[2] % 64);
    const height = 1 + @as(u32, data[3] % 64);
    const mask: u32 = if (explicit) maxVal(precision) else 0xFFFF;
    const pixels = try samplesFrom(data[5..], width * height, mask);
    defer ta.free(pixels);

    const max_pixel = std.mem.max(u16, pixels);
    const derived: u8 = std.math.clamp(16 - @as(u8, @clz(max_pixel)), 8, 16);
    const effective = if (explicit) precision else derived;
    const near: u8 = if (legacy or data[0] & 4 == 0) 0 else @intCast(@as(u16, data[4]) % (@as(u16, nearMax(maxVal(effective))) + 1));

    const opts: jpegls.EncodeOptions = .{
        .near = near,
        .precision = if (explicit) precision else null,
        .profile = if (legacy) .legacy_go else .t87,
    };
    const stream = try util.encodeOpts(pixels, width, height, opts);
    defer ta.free(stream);

    if (legacy) {
        const decoded = try jpegls.decodeWithOptions(ta, stream, width, height, .{ .profile = .legacy_go });
        defer ta.free(decoded);
        try testing.expectEqualSlices(u16, pixels, decoded);
        _ = util.decodeImageErr(stream);
        return;
    }

    var img = try jpegls.decodeImage(ta, stream);
    defer img.deinit(ta);
    try assertImageContract(img, null);
    try testing.expectEqual(width, img.width);
    try testing.expectEqual(height, img.height);
    try testing.expectEqual(@as(u8, 1), img.components);
    try testing.expectEqual(effective, img.bits_per_sample);
    try testing.expectEqual(near, img.near);
    try assertWithinNear(img.samples, pixels, near);

    const decoded = try jpegls.decode(ta, stream, width, height);
    defer ta.free(decoded);
    try testing.expectEqualSlices(u16, img.samples, decoded);

    const planar = try util.encodeImg(pixels, width, height, 1, opts);
    defer ta.free(planar);
    try testing.expectEqualSlices(u8, stream, planar);

    if (near == 0 and !explicit) {
        var aw = std.Io.Writer.Allocating.init(ta);
        defer aw.deinit();
        try jpegls.encode(ta, pixels, width, height, &aw.writer);
        try testing.expectEqualSlices(u8, stream, aw.written());
    }

    _ = util.decodeErrOpts(stream, width, height, .{ .profile = .legacy_go });
}

const Entry = enum { encode, with_options, image };

fn runEntry(entry: Entry, pixels: []const u16, width: u32, height: u32, components: u8, opts: jpegls.EncodeOptions, w: *std.Io.Writer) jpegls.CodecError!void {
    return switch (entry) {
        .encode => jpegls.encode(ta, pixels, width, height, w),
        .with_options => jpegls.encodeWithOptions(ta, pixels, width, height, opts, w),
        .image => jpegls.encodeImage(ta, pixels, width, height, components, opts, w),
    };
}

/// fuzz_targets/encode_params.rs
fn targetEncodeParams(data: []const u8) !void {
    const MAX_SAMPLES = 1 << 17;
    var in = Input{ .data = data };
    const b0 = in.byte();
    const entry: Entry = @enumFromInt(b0 % 3);
    const legacy = b0 & 0x80 != 0;
    var b = in.byte();
    const components: u8 = switch (b % 4) {
        0 => 1,
        1 => 3,
        2 => b >> 2,
        else => 255 - (b >> 2),
    };
    b = in.byte();
    const precision: ?u8 = switch (b % 4) {
        0 => null,
        1, 2 => 2 + (b >> 2) % 15,
        else => b >> 2,
    };
    b = in.byte();
    const near: u8 = if (b & 1 == 0) 0 else b;
    const dim = struct {
        fn f(sel: u8, val: u8) u32 {
            if (sel % 4 == 0) return ([_]u32{ 0, 65535, 65536, std.math.maxInt(u32) })[val % 4];
            return 1 + @as(u32, val % 64);
        }
    }.f;
    const ws = in.byte();
    const wv = in.byte();
    const hs = in.byte();
    const hv = in.byte();
    const width = dim(ws, wv);
    const height = dim(hs, hv);
    b = in.byte();
    const count_error: i64 = if (b & 0x80 == 0) 0 else @as(i64, b & 0x7f) - 64;
    const flags = in.byte();
    const body = in.rest();

    var opts: jpegls.EncodeOptions = .{};
    if (entry != .encode) {
        opts.near = near;
        opts.precision = precision;
        opts.profile = if (legacy) .legacy_go else .t87;
    }
    const comps: u8 = if (entry == .image) components else 1;
    const expected: i128 = @as(i128, width) * height * comps;
    const count: usize = @intCast(std.math.clamp(expected + count_error, 0, MAX_SAMPLES));
    const mask: u32 = if (flags & 1 == 1 and opts.precision != null and opts.precision.? >= 2 and opts.precision.? <= 16)
        maxVal(opts.precision.?)
    else
        0xFFFF;
    const pixels = try samplesFrom(body, count, mask);
    defer ta.free(pixels);

    const max_pixel: u16 = if (pixels.len == 0) 0 else std.mem.max(u16, pixels);
    const effective: ?u8 = if (opts.precision) |p|
        (if (p >= 2 and p <= 16) p else null)
    else
        std.math.clamp(16 - @as(u8, @clz(max_pixel)), 8, 16);
    const valid = (entry != .image or ((comps == 1 or comps == 3) and opts.profile == .t87)) and
        width >= 1 and width <= 65535 and height >= 1 and height <= 65535 and
        @as(i128, count) == expected and
        (if (effective) |p| max_pixel <= maxVal(p) and opts.near <= nearMax(maxVal(p)) else false) and
        (opts.profile == .t87 or opts.near == 0);

    var aw = std.Io.Writer.Allocating.init(ta);
    defer aw.deinit();
    const result = runEntry(entry, pixels, width, height, comps, opts, &aw.writer);
    if (std.meta.isError(result) == valid) {
        std.debug.print("encoder/oracle disagree: valid={} result={any}\n", .{ valid, result });
        return error.TestUnexpectedResult;
    }
    if (!valid) return;
    const stream = aw.written();

    if (opts.profile == .legacy_go) {
        const decoded = try jpegls.decodeWithOptions(ta, stream, width, height, .{ .profile = .legacy_go });
        defer ta.free(decoded);
        try testing.expectEqualSlices(u16, pixels, decoded);
    } else {
        var img = try jpegls.decodeImage(ta, stream);
        defer img.deinit(ta);
        try testing.expectEqual(width, img.width);
        try testing.expectEqual(height, img.height);
        try testing.expectEqual(comps, img.components);
        try testing.expectEqual(opts.near, img.near);
        try testing.expectEqual(effective.?, img.bits_per_sample);
        try assertWithinNear(img.samples, pixels, opts.near);
    }

    // A size-limited sink must surface as error.Io, never anything else.
    const limit = stream.len * (flags >> 2) / 63;
    const sink_buf = try ta.alloc(u8, limit);
    defer ta.free(sink_buf);
    var sink = std.Io.Writer.fixed(sink_buf);
    if (runEntry(entry, pixels, width, height, comps, opts, &sink)) {
        try testing.expect(limit >= stream.len);
        try testing.expectEqualSlices(u8, stream, sink.buffered());
    } else |e| {
        try testing.expectEqual(error.Io, e);
        try testing.expect(limit < stream.len);
    }
}

/// fuzz_targets/roundtrip.rs
fn targetRoundtrip(data: []const u8) !void {
    const spec = (try ImageSpec.fromBytes(data)) orelse return;
    defer spec.deinit();
    const stream = try spec.encode();
    defer ta.free(stream);
    var img = try jpegls.decodeImage(ta, stream);
    defer img.deinit(ta);
    try testing.expectEqual(spec.width, img.width);
    try testing.expectEqual(spec.height, img.height);
    try testing.expectEqual(spec.components, img.components);
    try testing.expectEqual(spec.precision, img.bits_per_sample);
    try testing.expectEqual(spec.near, img.near);
    try assertWithinNear(img.samples, spec.samples, spec.near);
}

// ---------------------------------------------------------------------------
// Drivers
// ---------------------------------------------------------------------------

test "fuzz smoke decode" {
    var prng = std.Random.DefaultPrng.init(0xF022_0001);
    const r = prng.random();
    var buf: [1024]u8 = undefined;
    for (0..ITERATIONS) |_| try targetDecode(randomBytes(r, &buf, 1024));
    // Also drive real headers: a valid stream behind random dimensions.
    for (0..ITERATIONS) |_| {
        const spec_bytes = randomSpecBytes(r, buf[0..256]);
        spec_bytes[0] &= 0xFE; // single component
        const spec = (try ImageSpec.fromBytes(spec_bytes)).?;
        defer spec.deinit();
        const stream = try spec.encode();
        defer ta.free(stream);
        const framed = try util.concat(&.{ &.{ @truncate(spec.width), 0, @truncate(spec.height), 0 }, stream });
        defer ta.free(framed);
        framed[r.uintLessThan(usize, framed.len)] ^= r.int(u8);
        try targetDecode(framed);
    }
}

test "fuzz smoke decode image" {
    var prng = std.Random.DefaultPrng.init(0xF022_0002);
    const r = prng.random();
    var buf: [1024]u8 = undefined;
    for (0..ITERATIONS) |_| try targetDecodeImage(randomBytes(r, &buf, 1024));
}

test "fuzz smoke decode lse" {
    var prng = std.Random.DefaultPrng.init(0xF022_0003);
    const r = prng.random();
    var buf: [2048]u8 = undefined;
    for (0..ITERATIONS * 3) |_| try targetDecodeLse(randomBytes(r, &buf, 2048));
}

test "fuzz smoke decode mutated" {
    var prng = std.Random.DefaultPrng.init(0xF022_0004);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..ITERATIONS) |_| {
        const n_edits = r.uintAtMost(usize, 8);
        buf[0] = @intCast(n_edits);
        r.bytes(buf[1 .. 1 + 4 * n_edits]);
        const spec = randomSpecBytes(r, buf[1 + 4 * n_edits ..]);
        try targetDecodeMutated(buf[0 .. 1 + 4 * n_edits + spec.len]);
    }
}

test "fuzz smoke encode gray" {
    var prng = std.Random.DefaultPrng.init(0xF022_0005);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..ITERATIONS) |_| try targetEncodeGray(randomBytes(r, &buf, 512));
}

test "fuzz smoke encode params" {
    var prng = std.Random.DefaultPrng.init(0xF022_0006);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..ITERATIONS * 2) |_| {
        const data = randomBytes(r, &buf, 512);
        // Usually aim the sample count exactly so the valid path is reached.
        if (data.len > 7 and r.boolean()) data[7] &= 0x7f;
        try targetEncodeParams(data);
    }
}

test "fuzz smoke roundtrip" {
    var prng = std.Random.DefaultPrng.init(0xF022_0007);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..ITERATIONS) |_| try targetRoundtrip(randomSpecBytes(r, &buf));
}
