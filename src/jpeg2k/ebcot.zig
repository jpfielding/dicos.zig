//! EBCOT (Embedded Block Coding with Optimal Truncation) -- ITU-T T.800 Annex D.
//!
//! Simplified tier-1 implementation for lossless encoding: significance
//! propagation, magnitude refinement, and cleanup passes over bit-planes
//! using the MQ arithmetic coder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mq = @import("mq.zig");

const MqEncoder = mq.MqEncoder;
const MqDecoder = mq.MqDecoder;
const MqState = mq.MqState;
const NUM_MQ_CONTEXTS = mq.NUM_MQ_CONTEXTS;
const CTX_MAG_REF = mq.CTX_MAG_REF;
const CTX_RUN_LENGTH = mq.CTX_RUN_LENGTH;
const CTX_SIGN_START = mq.CTX_SIGN_START;
const CTX_UNIFORM = mq.CTX_UNIFORM;

/// Compute the unsigned absolute value of an i32.
fn absU32(v: i32) u32 {
    return if (v < 0) @intCast(-@as(i64, v)) else @intCast(v);
}

// ---------------------------------------------------------------------------
// Code-block encoder
// ---------------------------------------------------------------------------

/// Encodes a single code-block using EBCOT tier-1.
pub const CodeBlockEncoder = struct {
    mq_enc: MqEncoder,
    contexts: [NUM_MQ_CONTEXTS]MqState,
    width: usize,
    height: usize,
    /// Significance state with 1-pixel border: stride = width + 2.
    sigma: []u8,
    /// Snapshot of sigma at the start of each bit-plane.
    sigma_snapshot: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: usize, height: usize) Allocator.Error!CodeBlockEncoder {
        const n = (width + 2) * (height + 2);
        const sigma = try allocator.alloc(u8, n);
        errdefer allocator.free(sigma);
        @memset(sigma, 0);
        const sigma_snapshot = try allocator.alloc(u8, n);
        errdefer allocator.free(sigma_snapshot);
        @memset(sigma_snapshot, 0);
        return .{
            .mq_enc = MqEncoder.init(allocator),
            .contexts = mq.setupDefaultContexts(),
            .width = width,
            .height = height,
            .sigma = sigma,
            .sigma_snapshot = sigma_snapshot,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CodeBlockEncoder) void {
        self.allocator.free(self.sigma);
        self.allocator.free(self.sigma_snapshot);
        self.mq_enc.deinit();
    }

    /// Encode the coefficients and return `(num_passes, num_bit_planes)`.
    ///
    /// Returns `(0, 0)` when all coefficients are zero.
    /// The encoded bytes are available via `self.mq_enc.bytes()`.
    pub fn encode(self: *CodeBlockEncoder, data: []const i32) Allocator.Error!struct { usize, usize } {
        // Find maximum magnitude.
        var max_val: u32 = 0;
        for (data) |v| {
            const abs_v = absU32(v);
            if (abs_v > max_val) max_val = abs_v;
        }
        if (max_val == 0) {
            return .{ 0, 0 };
        }

        const num_bit_planes = 32 - @as(usize, @clz(max_val));
        var passes: usize = 0;

        var bp: usize = num_bit_planes;
        while (bp > 0) {
            bp -= 1;
            const mask: u32 = @as(u32, 1) << @intCast(bp);

            // Snapshot sigma before this bit-plane.
            @memcpy(self.sigma_snapshot, self.sigma);

            // Significance propagation pass.
            try self.sigPropPass(data, mask);
            passes += 1;

            // Magnitude refinement pass (not for the first bit-plane).
            if (bp < num_bit_planes - 1) {
                try self.magRefPass(data, mask);
                passes += 1;
            }

            // Cleanup pass.
            try self.cleanupPass(data, mask);
            passes += 1;
        }

        try self.mq_enc.flush();
        return .{ passes, num_bit_planes };
    }

    /// Reset for a new code-block.
    pub fn reset(self: *CodeBlockEncoder) void {
        self.mq_enc.reset();
        self.contexts = mq.setupDefaultContexts();
        @memset(self.sigma, 0);
        @memset(self.sigma_snapshot, 0);
    }

    // -- Coding passes -------------------------------------------------------

    fn sigPropPass(self: *CodeBlockEncoder, data: []const i32, mask: u32) Allocator.Error!void {
        const stride = self.width + 2;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = (y + 1) * stride + (x + 1);
                if (self.sigma_snapshot[idx] != 0) continue; // already significant
                if (!hasSignificantNeighborIn(self.sigma_snapshot, idx, stride)) continue;

                const abs_val = absU32(data[y * self.width + x]);
                const sig: u8 = if ((abs_val & mask) != 0) 1 else 0;

                const ctx = zcContextIn(self.sigma_snapshot, idx, stride);
                try self.mq_enc.encode(sig, &self.contexts[ctx]);

                if (sig == 1) {
                    self.sigma[idx] = 1;
                    const sign_bit: u8 = if (data[y * self.width + x] < 0) 1 else 0;
                    try self.mq_enc.encode(sign_bit, &self.contexts[CTX_SIGN_START]);
                }
            }
        }
    }

    fn magRefPass(self: *CodeBlockEncoder, data: []const i32, mask: u32) Allocator.Error!void {
        const stride = self.width + 2;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = (y + 1) * stride + (x + 1);
                if (self.sigma_snapshot[idx] == 0) continue;

                const abs_val = absU32(data[y * self.width + x]);
                const bit: u8 = if ((abs_val & mask) != 0) 1 else 0;
                try self.mq_enc.encode(bit, &self.contexts[CTX_MAG_REF]);
            }
        }
    }

    fn cleanupPass(self: *CodeBlockEncoder, data: []const i32, mask: u32) Allocator.Error!void {
        const stride = self.width + 2;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = (y + 1) * stride + (x + 1);
                if (self.sigma[idx] != 0) continue; // already significant
                if (hasSignificantNeighborIn(self.sigma_snapshot, idx, stride)) continue; // handled in sig-prop

                const abs_val = absU32(data[y * self.width + x]);
                const sig: u8 = if ((abs_val & mask) != 0) 1 else 0;
                try self.mq_enc.encode(sig, &self.contexts[CTX_RUN_LENGTH]);

                if (sig == 1) {
                    self.sigma[idx] = 1;
                    const sign_bit: u8 = if (data[y * self.width + x] < 0) 1 else 0;
                    try self.mq_enc.encode(sign_bit, &self.contexts[CTX_UNIFORM]);
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Code-block decoder
// ---------------------------------------------------------------------------

/// Decodes a single code-block using EBCOT tier-1.
pub const CodeBlockDecoder = struct {
    mq_dec: MqDecoder,
    contexts: [NUM_MQ_CONTEXTS]MqState,
    width: usize,
    height: usize,
    sigma: []u8,
    sigma_snapshot: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, data: []const u8, width: usize, height: usize) Allocator.Error!CodeBlockDecoder {
        const n = (width + 2) * (height + 2);
        const sigma = try allocator.alloc(u8, n);
        errdefer allocator.free(sigma);
        @memset(sigma, 0);
        const sigma_snapshot = try allocator.alloc(u8, n);
        errdefer allocator.free(sigma_snapshot);
        @memset(sigma_snapshot, 0);
        return .{
            .mq_dec = MqDecoder.init(data),
            .contexts = mq.setupDefaultContexts(),
            .width = width,
            .height = height,
            .sigma = sigma,
            .sigma_snapshot = sigma_snapshot,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CodeBlockDecoder) void {
        self.allocator.free(self.sigma);
        self.allocator.free(self.sigma_snapshot);
    }

    /// Decode the code-block data and return reconstructed coefficients.
    pub fn decode(self: *CodeBlockDecoder, allocator: Allocator, num_bit_planes: usize, num_passes: usize) Allocator.Error![]i32 {
        const n = self.width * self.height;
        const coeffs = try allocator.alloc(u32, n);
        defer allocator.free(coeffs);
        @memset(coeffs, 0);
        const signs = try allocator.alloc(u8, n);
        defer allocator.free(signs);
        @memset(signs, 0);

        var pass_idx: usize = 0;
        var bp: usize = num_bit_planes;
        while (bp > 0) {
            bp -= 1;
            const mask: u32 = @as(u32, 1) << @intCast(bp);

            // Snapshot sigma before this bit-plane (must match encoder).
            @memcpy(self.sigma_snapshot, self.sigma);

            // Significance propagation pass.
            if (pass_idx < num_passes) {
                self.decodeSigPropPass(coeffs, signs, mask);
                pass_idx += 1;
            }

            // Magnitude refinement pass.
            if (bp < num_bit_planes - 1 and pass_idx < num_passes) {
                self.decodeMagRefPass(coeffs, mask);
                pass_idx += 1;
            }

            // Cleanup pass.
            if (pass_idx < num_passes) {
                self.decodeCleanupPass(coeffs, signs, mask);
                pass_idx += 1;
            }
        }

        // Apply signs.
        const result = try allocator.alloc(i32, n);
        for (0..n) |i| {
            result[i] = if (signs[i] != 0)
                -@as(i32, @intCast(coeffs[i]))
            else
                @as(i32, @intCast(coeffs[i]));
        }
        return result;
    }

    // -- Decoding passes ------------------------------------------------------

    fn decodeSigPropPass(self: *CodeBlockDecoder, coeffs: []u32, signs: []u8, mask: u32) void {
        const stride = self.width + 2;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = (y + 1) * stride + (x + 1);
                if (self.sigma_snapshot[idx] != 0) continue;
                if (!hasSignificantNeighborIn(self.sigma_snapshot, idx, stride)) continue;

                const ctx = zcContextIn(self.sigma_snapshot, idx, stride);
                const sig = self.mq_dec.decode(&self.contexts[ctx]);

                if (sig == 1) {
                    self.sigma[idx] = 1;
                    coeffs[y * self.width + x] |= mask;
                    signs[y * self.width + x] = self.mq_dec.decode(&self.contexts[CTX_SIGN_START]);
                }
            }
        }
    }

    fn decodeMagRefPass(self: *CodeBlockDecoder, coeffs: []u32, mask: u32) void {
        const stride = self.width + 2;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = (y + 1) * stride + (x + 1);
                if (self.sigma_snapshot[idx] == 0) continue;
                const bit = self.mq_dec.decode(&self.contexts[CTX_MAG_REF]);
                if (bit == 1) {
                    coeffs[y * self.width + x] |= mask;
                }
            }
        }
    }

    fn decodeCleanupPass(self: *CodeBlockDecoder, coeffs: []u32, signs: []u8, mask: u32) void {
        const stride = self.width + 2;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = (y + 1) * stride + (x + 1);
                if (self.sigma[idx] != 0) continue;
                if (hasSignificantNeighborIn(self.sigma_snapshot, idx, stride)) continue;

                const sig = self.mq_dec.decode(&self.contexts[CTX_RUN_LENGTH]);
                if (sig == 1) {
                    self.sigma[idx] = 1;
                    coeffs[y * self.width + x] |= mask;
                    signs[y * self.width + x] = self.mq_dec.decode(&self.contexts[CTX_UNIFORM]);
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Context helpers
// ---------------------------------------------------------------------------

fn hasSignificantNeighborIn(sigma: []const u8, idx: usize, stride: usize) bool {
    return sigma[idx - stride - 1] != 0 or
        sigma[idx - stride] != 0 or
        sigma[idx - stride + 1] != 0 or
        sigma[idx - 1] != 0 or
        sigma[idx + 1] != 0 or
        sigma[idx + stride - 1] != 0 or
        sigma[idx + stride] != 0 or
        sigma[idx + stride + 1] != 0;
}

fn zcContextIn(sigma: []const u8, idx: usize, stride: usize) usize {
    var count: usize = 0;
    if (sigma[idx - 1] != 0) count += 1;
    if (sigma[idx + 1] != 0) count += 1;
    if (sigma[idx - stride] != 0) count += 1;
    if (sigma[idx + stride] != 0) count += 1;
    return @min(count, 4);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ebcot all zeros" {
    const allocator = std.testing.allocator;
    var enc = try CodeBlockEncoder.init(allocator, 4, 4);
    defer enc.deinit();
    const data = [_]i32{0} ** 16;
    const result = try enc.encode(&data);
    const passes = result[0];
    const bit_planes = result[1];
    try std.testing.expectEqual(@as(usize, 0), enc.mq_enc.bytes().len);
    try std.testing.expectEqual(@as(usize, 0), passes);
    try std.testing.expectEqual(@as(usize, 0), bit_planes);
}

test "ebcot roundtrip small" {
    const allocator = std.testing.allocator;
    const w = 4;
    const h = 4;
    const data = [_]i32{ 1, -2, 3, -4, 5, -6, 7, -8, 9, -10, 11, -12, 13, -14, 15, -16 };

    var enc = try CodeBlockEncoder.init(allocator, w, h);
    defer enc.deinit();
    const enc_result = try enc.encode(&data);
    const passes = enc_result[0];
    const bit_planes = enc_result[1];
    try std.testing.expect(enc.mq_enc.bytes().len > 0);
    try std.testing.expect(passes > 0);
    try std.testing.expect(bit_planes > 0);

    var dec = try CodeBlockDecoder.init(allocator, enc.mq_enc.bytes(), w, h);
    defer dec.deinit();
    const decoded = try dec.decode(allocator, bit_planes, passes);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, &data, decoded);
}

test "ebcot roundtrip uniform" {
    const allocator = std.testing.allocator;
    const w = 8;
    const h = 8;
    const data = [_]i32{42} ** (w * h);

    var enc = try CodeBlockEncoder.init(allocator, w, h);
    defer enc.deinit();
    const enc_result = try enc.encode(&data);

    var dec = try CodeBlockDecoder.init(allocator, enc.mq_enc.bytes(), w, h);
    defer dec.deinit();
    const decoded = try dec.decode(allocator, enc_result[1], enc_result[0]);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, &data, decoded);
}

test "ebcot roundtrip single nonzero" {
    const allocator = std.testing.allocator;
    const w = 4;
    const h = 4;
    var data = [_]i32{0} ** (w * h);
    data[5] = 255;

    var enc = try CodeBlockEncoder.init(allocator, w, h);
    defer enc.deinit();
    const enc_result = try enc.encode(&data);

    var dec = try CodeBlockDecoder.init(allocator, enc.mq_enc.bytes(), w, h);
    defer dec.deinit();
    const decoded = try dec.decode(allocator, enc_result[1], enc_result[0]);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, &data, decoded);
}

test "ebcot roundtrip negative values" {
    const allocator = std.testing.allocator;
    const w = 4;
    const h = 4;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @as(i32, @intCast(i)) - 8;

    var enc = try CodeBlockEncoder.init(allocator, w, h);
    defer enc.deinit();
    const enc_result = try enc.encode(&data);

    var dec = try CodeBlockDecoder.init(allocator, enc.mq_enc.bytes(), w, h);
    defer dec.deinit();
    const decoded = try dec.decode(allocator, enc_result[1], enc_result[0]);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, &data, decoded);
}

test "ebcot roundtrip large values" {
    const allocator = std.testing.allocator;
    const w = 4;
    const h = 4;
    var data: [w * h]i32 = undefined;
    for (0..w * h) |i| data[i] = @as(i32, @intCast(i)) * 1000 - 8000;

    var enc = try CodeBlockEncoder.init(allocator, w, h);
    defer enc.deinit();
    const enc_result = try enc.encode(&data);

    var dec = try CodeBlockDecoder.init(allocator, enc.mq_enc.bytes(), w, h);
    defer dec.deinit();
    const decoded = try dec.decode(allocator, enc_result[1], enc_result[0]);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, &data, decoded);
}

test "ebcot encoder reset" {
    const allocator = std.testing.allocator;
    const w = 4;
    const h = 4;
    const data1 = [_]i32{10} ** (w * h);
    var data2: [w * h]i32 = undefined;
    for (0..w * h) |i| data2[i] = @as(i32, @intCast(i)) + 1;

    var enc = try CodeBlockEncoder.init(allocator, w, h);
    defer enc.deinit();

    // Encode first block.
    const enc_result1 = try enc.encode(&data1);
    // Copy the encoded bytes before reset.
    const bytes1 = try allocator.dupe(u8, enc.mq_enc.bytes());
    defer allocator.free(bytes1);
    enc.reset();

    // Encode second block.
    const enc_result2 = try enc.encode(&data2);
    const bytes2 = try allocator.dupe(u8, enc.mq_enc.bytes());
    defer allocator.free(bytes2);

    // Decode both independently.
    var dec1 = try CodeBlockDecoder.init(allocator, bytes1, w, h);
    defer dec1.deinit();
    const decoded1 = try dec1.decode(allocator, enc_result1[1], enc_result1[0]);
    defer allocator.free(decoded1);
    try std.testing.expectEqualSlices(i32, &data1, decoded1);

    var dec2 = try CodeBlockDecoder.init(allocator, bytes2, w, h);
    defer dec2.deinit();
    const decoded2 = try dec2.decode(allocator, enc_result2[1], enc_result2[0]);
    defer allocator.free(decoded2);
    try std.testing.expectEqualSlices(i32, &data2, decoded2);
}
