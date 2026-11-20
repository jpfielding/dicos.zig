//! JPEG-LS codec (ISO/IEC 14495-1 / ITU-T T.87).
//!
//! Implements the LOCO-I algorithm with context-based Golomb-Rice coding
//! and run-length mode for uniform regions. Port of the Rust `pure_jpegls`
//! 2.1.0 crate; the encoder emits byte-identical streams.
//!
//! # Conformance scope
//!
//! Conformant T.87 for **single-component** images and **multi-component
//! planar** images (`ILV = 0`, one scan per component, e.g. RGB, through
//! `decodeImage` / `encodeImage`), precision `2..=16`, with LSE ID=1
//! presets, run mode, and near-lossless. Line- and sample-interleaved scans
//! (`ILV != 0`) and restart markers inside a scan are rejected as
//! `error.Unsupported`; a `DRI` segment on its own is skipped.
//!
//! # Profiles
//!
//! The default `Profile.t87` path is ITU-T T.87 conformant. The
//! `Profile.legacy_go` path reproduces the frozen 1.0.0 / Go-compatible
//! bitstream (T.81-style `0xFF00` stuffing, no run mode, uncapped Golomb) for
//! reading and writing files produced by earlier releases.

const errors = @import("error.zig");
const options = @import("options.zig");
const encode_mod = @import("encode.zig");
const decode_mod = @import("decode.zig");

pub const CodecError = errors.CodecError;
pub const Diagnostic = errors.Diagnostic;

pub const Profile = options.Profile;
pub const EncodeOptions = options.EncodeOptions;
pub const DecodeOptions = options.DecodeOptions;
pub const DecodeImageOptions = options.DecodeImageOptions;
pub const DecodedImage = decode_mod.DecodedImage;

pub const encode = encode_mod.encode;
pub const encodeWithOptions = encode_mod.encodeWithOptions;
pub const encodeImage = encode_mod.encodeImage;

pub const decode = decode_mod.decode;
pub const decodeWithOptions = decode_mod.decodeWithOptions;
pub const decodeImage = decode_mod.decodeImage;
pub const decodeImageWithOptions = decode_mod.decodeImageWithOptions;

/// DICOM Transfer Syntax UID for JPEG-LS Lossless.
pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.4.80";

/// Internal building blocks, exposed for tests and tooling.
pub const internal = struct {
    pub const bitstream = @import("bitstream.zig");
    pub const context = @import("context.zig");
    pub const legacy = @import("legacy.zig");
    pub const predictor = @import("predictor.zig");
    pub const run_mode = @import("run_mode.zig");
    pub const encodeScanT87 = encode_mod.encodeScanT87;
    pub const decodeScanT87 = decode_mod.decodeScanT87;
};

test {
    _ = @import("error.zig");
    _ = @import("predictor.zig");
    _ = @import("bitstream.zig");
    _ = @import("context.zig");
    _ = @import("run_mode.zig");
    _ = @import("legacy.zig");
    _ = @import("encode.zig");
    _ = @import("decode.zig");
    _ = @import("tests/t87_roundtrip.zig");
    _ = @import("tests/image_api.zig");
    _ = @import("tests/legacy_fixtures.zig");
    _ = @import("tests/mutation.zig");
    _ = @import("tests/fuzz_regressions.zig");
    _ = @import("tests/fuzz_crash_regressions.zig");
    _ = @import("tests/interop.zig");
    _ = @import("tests/charls_encode_interop.zig");
    _ = @import("tests/parity.zig");
    _ = @import("tests/fuzz_smoke.zig");
}
