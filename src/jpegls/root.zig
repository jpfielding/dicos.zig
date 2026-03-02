//! JPEG-LS Lossless codec.
//!
//! Implements ISO/IEC 14495-1 / ITU-T T.87 -- LOCO-I algorithm with
//! context-based Golomb-Rice coding.

pub const bitstream = @import("bitstream.zig");
pub const context = @import("context.zig");
pub const predictor = @import("predictor.zig");
pub const run_mode = @import("run_mode.zig");
pub const encode = @import("encode.zig");
pub const decode = @import("decode.zig");

pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.4.80";

test {
    _ = @import("bitstream.zig");
    _ = @import("context.zig");
    _ = @import("predictor.zig");
    _ = @import("run_mode.zig");
    _ = @import("encode.zig");
    _ = @import("decode.zig");
}
