//! Test root for zoxel (`zig build zoxel-test`). Nothing here needs a window
//! or a GPU: UI tests run the real layout code headless.

test {
    _ = @import("volume.zig");
    _ = @import("dicos_adapter.zig");
    _ = @import("camera.zig");
    _ = @import("transfer.zig");
    _ = @import("slice_view.zig");
    _ = @import("touch.zig");
    _ = @import("state.zig");
    _ = @import("loader.zig");
    _ = @import("png.zig");
    _ = @import("platform.zig");
    _ = @import("ui/kit.zig");
    _ = @import("ui/layout.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/slice_panel.zig");
    _ = @import("ui/fit_tests.zig");
    _ = @import("renderer.zig");
    _ = @import("app.zig");
}
