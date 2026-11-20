//! Public option types shared by the encoder and decoder (Rust `lib.rs`).

const errors = @import("error.zig");

/// Bitstream profile selecting the entropy-coded scan format.
///
/// The two formats are not bridgeable by a single flag -- single-bit stuffing
/// and the length-limited Golomb code differ from the legacy path -- so the
/// choice is a whole-stream profile.
pub const Profile = enum {
    /// ITU-T T.87 conformant (default).
    t87,
    /// Frozen 1.0.0 / Go-compatible bytes (lossless only).
    legacy_go,
};

/// Options controlling `encodeWithOptions` / `encodeImage`.
pub const EncodeOptions = struct {
    /// Near-lossless error bound (`0` = lossless). Bounded by
    /// `min(255, MAXVAL/2)`. Must be `0` for `Profile.legacy_go`.
    near: u8 = 0,
    /// Bitstream profile.
    profile: Profile = .t87,
    /// Explicit sample precision in bits (`2..=16`). `null` derives it from the
    /// data (at least 8), preserving legacy behavior.
    precision: ?u8 = null,
    /// Optional error detail sink.
    diagnostic: ?*errors.Diagnostic = null,
};

/// Options controlling `decodeWithOptions`.
pub const DecodeOptions = struct {
    /// Bitstream profile to decode with.
    profile: Profile = .t87,
    /// Optional error detail sink.
    diagnostic: ?*errors.Diagnostic = null,
};

/// Limits for decoding images whose geometry comes from the stream.
/// The limit counts all output samples, including every component, at two
/// bytes per sample. It excludes input bytes and small scan working buffers.
pub const DecodeImageOptions = struct {
    /// Maximum decoded sample-buffer size in bytes. Default: 64 MiB.
    max_decoded_bytes: usize = 64 * 1024 * 1024,
    /// Optional error detail sink.
    diagnostic: ?*errors.Diagnostic = null,
};
