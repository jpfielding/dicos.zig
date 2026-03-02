//! JPEG 2000 Part-1 Lossless codec.
//!
//! Implements ITU-T T.800 -- reversible 5/3 DWT, EBCOT tier-1/tier-2
//! coding, and MQ arithmetic coding.

pub const bitstream = @import("bitstream.zig");
pub const mq = @import("mq.zig");
pub const rct = @import("rct.zig");
pub const markers = @import("markers.zig");
pub const dwt = @import("dwt.zig");
pub const ebcot = @import("ebcot.zig");
pub const tile = @import("tile.zig");
pub const codestream = @import("codestream.zig");

pub const TRANSFER_SYNTAX_UID = "1.2.840.10008.1.2.4.90";

test {
    _ = @import("bitstream.zig");
    _ = @import("mq.zig");
    _ = @import("rct.zig");
    _ = @import("markers.zig");
    _ = @import("dwt.zig");
    _ = @import("ebcot.zig");
    _ = @import("tile.zig");
    _ = @import("codestream.zig");
}
