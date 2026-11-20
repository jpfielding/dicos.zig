//! Error set for JPEG 2000 codec encode/decode operations.
//!
//! Mirrors the Rust crate's `CodecError` (`error.rs`): `Io`, `InvalidData`,
//! `Unsupported`, `DimensionMismatch`. Zig errors carry no payload, so the
//! Rust messages are documented at each return site instead.
//!
//! The I/O variant is spelled `IoError` (not `Io`) so this set is a strict
//! subset of `dicos.CodecError` and coerces into it without mapping.

/// Errors from JPEG 2000 codec encode/decode operations.
pub const CodecError = error{
    /// The output writer failed (Rust `CodecError::Io`).
    IoError,
    /// The codestream (or an encoder option) is malformed / out of range.
    InvalidData,
    /// Legal T.800 but outside the supported profile (support matrix).
    Unsupported,
    /// Pixel count or caller dimensions disagree with the image.
    DimensionMismatch,
    /// Allocation failure.
    OutOfMemory,
};
