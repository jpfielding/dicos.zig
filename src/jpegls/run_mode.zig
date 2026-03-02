//! Run-length mode for JPEG-LS.
//!
//! When all three local gradients are zero (D1 == D2 == D3 == 0) the codec
//! enters run mode, efficiently coding long runs of identical pixel values.
//!
//! Reference: ISO/IEC 14495-1, Section A.7.

const std = @import("std");
const bitstream = @import("bitstream.zig");
const ctx_mod = @import("context.zig");
const CodecError = bitstream.CodecError;
const BitReader = bitstream.BitReader;
const BitWriter = bitstream.BitWriter;
const ContextModel = ctx_mod.ContextModel;

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Encode a run-mode segment starting at column `x` in the current line.
///
/// On return, `x.*` is updated to point past the last encoded pixel.
pub fn encodeRun(
    bw: *BitWriter,
    ctx: *ContextModel,
    curr_line: []const i32,
    x: *usize,
    width: usize,
    ra: i32,
    rb: i32,
) CodecError!void {
    const max_val = ctx.max_val;

    // 1. Measure the run of pixels equal to Ra starting at *x.
    const start = x.*;
    while (x.* < width and curr_line[x.*] == ra) {
        x.* += 1;
    }
    var run_length = x.* - start;

    // 2. Encode the run using the J table.
    while (true) {
        const j: u5 = @intCast(ctx.j[ctx.run_index]);
        const limit: usize = @as(usize, 1) << j;

        if (run_length >= limit) {
            // Full segment -- write a 1-bit.
            try bw.writeBit(1);
            run_length -= limit;
            if (ctx.run_index < 31) {
                ctx.run_index += 1;
            }

            // If the run consumed exactly to the end of the line, we are
            // done. No trailing 0-bit or remainder is written in this
            // case (ISO 14495-1 A.7.1.1).
            if (run_length == 0 and x.* >= width) {
                return;
            }
        } else {
            // Partial segment -- write a 0-bit, then the remainder in j bits.
            try bw.writeBit(0);
            if (j > 0) {
                try bw.writeBits(@intCast(run_length), @as(i32, j));
            }
            if (ctx.run_index > 0) {
                ctx.run_index -= 1;
            }

            // If we consumed the entire line, we are done.
            if (x.* >= width) {
                return;
            }

            // 3. Encode the interruption sample.
            const ix = curr_line[x.*];
            const pred = runInterruptionPrediction(ra, rb);
            const px = pred[0];
            const sign = pred[1];

            var err_val = ix - px;
            if (sign == -1) {
                err_val = -err_val;
            }

            // Modulo reduction.
            const range_val = max_val + 1;
            if (err_val < -@divTrunc(range_val, 2)) {
                err_val += range_val;
            }
            if (err_val > @divTrunc(range_val, 2)) {
                err_val -= range_val;
            }

            // Context for interruption: Q = 365 if Ra == Rb, else 366.
            const q: usize = if (ra == rb) 365 else 366;

            // Map error to non-negative value.
            const mapped: u32 = if (err_val >= 0)
                @intCast(2 * err_val)
            else
                @intCast(-2 * err_val - 1);

            const k = ctx.computeK(q);
            try bw.writeGolomb(k, mapped);
            ctx.updateStats(q, err_val);

            x.* += 1;
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

/// Decode a run-mode segment, writing pixels into `curr_line` starting at `*x`.
///
/// On return, `x.*` is updated to point past the last decoded pixel.
pub fn decodeRun(
    br: *BitReader,
    ctx: *ContextModel,
    curr_line: []i32,
    x: *usize,
    width: usize,
    ra: i32,
    rb: i32,
) CodecError!void {
    const max_val = ctx.max_val;

    while (true) {
        const b = try br.readBit();

        if (b == 1) {
            // Full segment of 2^J[RunIndex] pixels all equal to Ra.
            const j: u5 = @intCast(ctx.j[ctx.run_index]);
            var run_length: usize = @as(usize, 1) << j;

            const remaining = width - x.*;
            if (run_length > remaining) {
                run_length = remaining;
            }

            var i: usize = 0;
            while (i < run_length) : (i += 1) {
                curr_line[x.*] = ra;
                x.* += 1;
            }

            if (ctx.run_index < 31) {
                ctx.run_index += 1;
            }

            // If we filled the entire line, return.
            if (x.* >= width) {
                return;
            }
            // Otherwise loop to read the next segment.
        } else {
            // Partial segment -- read j bits for remainder.
            const j: u5 = @intCast(ctx.j[ctx.run_index]);
            const r_bits: u32 = if (j > 0) try br.readBits(@as(i32, j)) else 0;
            var run_length: usize = @intCast(r_bits);

            const remaining = width - x.*;
            if (run_length > remaining) {
                run_length = remaining;
            }

            var i: usize = 0;
            while (i < run_length) : (i += 1) {
                curr_line[x.*] = ra;
                x.* += 1;
            }

            if (ctx.run_index > 0) {
                ctx.run_index -= 1;
            }

            // End of line?
            if (x.* >= width) {
                return;
            }

            // Decode the interruption sample.
            const q: usize = if (ra == rb) 365 else 366;
            const k = ctx.computeK(q);
            const mapped_err = try br.readGolomb(k);

            const err_val: i32 = if (mapped_err % 2 == 0)
                @intCast(mapped_err / 2)
            else
                -@as(i32, @intCast((mapped_err +% 1) / 2));

            ctx.updateStats(q, err_val);

            const pred = runInterruptionPrediction(ra, rb);
            const px = pred[0];
            const sign = pred[1];
            // Use i64 for intermediate computation to avoid overflow.
            var ix: i32 = @intCast(@as(i64, px) + @as(i64, sign) * @as(i64, err_val));

            // Modulo reduction to [0, max_val].
            const range_val = max_val + 1;
            if (ix < 0) {
                ix += range_val;
            }
            if (ix > max_val) {
                ix -= range_val;
            }
            ix = std.math.clamp(ix, 0, max_val);

            curr_line[x.*] = ix;
            x.* += 1;
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Compute the prediction and sign for a run interruption sample.
///
/// Returns `{ Px, sign }`.
fn runInterruptionPrediction(ra: i32, rb: i32) struct { i32, i32 } {
    if (ra == rb) {
        return .{ ra, 1 };
    } else if (ra > rb) {
        return .{ rb, -1 };
    } else {
        return .{ rb, 1 };
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Encode then decode a run and verify the output matches.
fn roundtripRun(curr_line: []const i32, ra: i32, rb: i32) ![]i32 {
    const width = curr_line.len;

    // Encode
    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();
    {
        var bw = BitWriter.init(&buf);
        var ctx = try ContextModel.init(testing.allocator, 255, 0, 64);
        defer ctx.deinit();
        var x: usize = 0;
        try encodeRun(&bw, &ctx, curr_line, &x, width, ra, rb);
        try testing.expectEqual(width, x);
        try bw.flush();
    }

    // Decode
    const out = try testing.allocator.alloc(i32, width);
    @memset(out, 0);
    {
        var br = BitReader.init(buf.items);
        var ctx = try ContextModel.init(testing.allocator, 255, 0, 64);
        defer ctx.deinit();
        var x: usize = 0;
        try decodeRun(&br, &ctx, out, &x, width, ra, rb);
        try testing.expectEqual(width, x);
    }
    return out;
}

test "run all same" {
    const line = [_]i32{ 42, 42, 42, 42, 42, 42, 42, 42 };
    const out = try roundtripRun(&line, 42, 42);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i32, &line, out);
}

test "run with interruption" {
    // 5 pixels of Ra=100, then one different pixel 120.
    const line = [_]i32{ 100, 100, 100, 100, 100, 120 };
    const ra: i32 = 100;
    const rb: i32 = 100;
    const width: usize = line.len;

    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();
    {
        var bw = BitWriter.init(&buf);
        var ctx = try ContextModel.init(testing.allocator, 255, 0, 64);
        defer ctx.deinit();
        var x: usize = 0;
        try encodeRun(&bw, &ctx, &line, &x, width, ra, rb);
        // x should be at 6 (past the interruption sample).
        try testing.expectEqual(@as(usize, 6), x);
        try bw.flush();
    }

    var out = [_]i32{0} ** 6;
    {
        var br = BitReader.init(buf.items);
        var ctx = try ContextModel.init(testing.allocator, 255, 0, 64);
        defer ctx.deinit();
        var x: usize = 0;
        try decodeRun(&br, &ctx, &out, &x, width, ra, rb);
        try testing.expectEqual(@as(usize, 6), x);
    }
    try testing.expectEqualSlices(i32, &line, &out);
}

test "run single pixel differs" {
    // Immediate interruption: first pixel differs from Ra.
    const line = [_]i32{50};
    const ra: i32 = 100;
    const rb: i32 = 100;
    const width: usize = 1;

    var buf = std.array_list.AlignedManaged(u8, null).init(testing.allocator);
    defer buf.deinit();
    {
        var bw = BitWriter.init(&buf);
        var ctx = try ContextModel.init(testing.allocator, 255, 0, 64);
        defer ctx.deinit();
        var x: usize = 0;
        try encodeRun(&bw, &ctx, &line, &x, width, ra, rb);
        try testing.expectEqual(@as(usize, 1), x);
        try bw.flush();
    }

    var out = [_]i32{0};
    {
        var br = BitReader.init(buf.items);
        var ctx = try ContextModel.init(testing.allocator, 255, 0, 64);
        defer ctx.deinit();
        var x: usize = 0;
        try decodeRun(&br, &ctx, &out, &x, width, ra, rb);
        try testing.expectEqual(@as(usize, 1), x);
    }
    try testing.expectEqualSlices(i32, &line, &out);
}

test "run interruption prediction same" {
    const result = runInterruptionPrediction(100, 100);
    try testing.expectEqual(@as(i32, 100), result[0]);
    try testing.expectEqual(@as(i32, 1), result[1]);
}

test "run interruption prediction ra gt rb" {
    const result = runInterruptionPrediction(200, 100);
    try testing.expectEqual(@as(i32, 100), result[0]);
    try testing.expectEqual(@as(i32, -1), result[1]);
}

test "run interruption prediction ra lt rb" {
    const result = runInterruptionPrediction(50, 200);
    try testing.expectEqual(@as(i32, 200), result[0]);
    try testing.expectEqual(@as(i32, 1), result[1]);
}
