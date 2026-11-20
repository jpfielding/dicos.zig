//! Responsive layout selection. The layout follows the logical size of the
//! window or browser canvas, never a platform flag.

const std = @import("std");

/// Narrower than this and the three desktop panels cannot coexist.
const PORTRAIT_MAX_WIDTH: f32 = 640.0;
/// Shorter than this (and wide enough) the desktop shelf leaves no room.
const LANDSCAPE_MAX_HEIGHT: f32 = 520.0;

pub const Layout = enum {
    /// Study, 3D view and 2D slice side by side.
    desktop,
    /// Narrow and tall: view on top, controls sheet above the tab bar.
    phone_portrait,
    /// Wide and short: view on the left, controls on the right.
    phone_landscape,

    pub fn fromSize(w: f32, h: f32) Layout {
        if (w < PORTRAIT_MAX_WIDTH) return .phone_portrait;
        if (h < LANDSCAPE_MAX_HEIGHT) return .phone_landscape;
        return .desktop;
    }

    pub fn isCompact(self: Layout) bool {
        return self != .desktop;
    }

    /// Space kept clear under bottom bars for the phone's home indicator.
    pub fn homeIndicatorInset(self: Layout) f32 {
        return switch (self) {
            .desktop => 0,
            .phone_portrait => 34,
            .phone_landscape => 21,
        };
    }
};

pub const PhoneTab = enum {
    study,
    detections,
    slice,
    view3d,

    pub const all = [_]PhoneTab{ .study, .detections, .slice, .view3d };

    pub fn label(self: PhoneTab) []const u8 {
        return switch (self) {
            .study => "Study",
            .detections => "Detections",
            .slice => "2D slice",
            .view3d => "3D view",
        };
    }

    /// The two views have a controls sheet; the pages do not.
    pub fn isView(self: PhoneTab) bool {
        return self == .slice or self == .view3d;
    }
};

pub const VolumePage = enum {
    camera,
    slice,
    windowing,
    display,
    lighting,

    pub const all = [_]VolumePage{ .camera, .slice, .windowing, .display, .lighting };

    pub fn label(self: VolumePage) []const u8 {
        return switch (self) {
            .camera => "Camera",
            .slice => "Slice",
            .windowing => "Windowing",
            .display => "Display",
            .lighting => "Lighting",
        };
    }
};

pub const SlicePage = enum {
    slice,
    image,
    volume,

    pub fn label(self: SlicePage) []const u8 {
        return switch (self) {
            .slice => "Slice",
            .image => "Image",
            .volume => "Volume",
        };
    }
};

test "layout follows logical size" {
    const cases = [_]struct { w: f32, h: f32, l: Layout }{
        .{ .w = 1440, .h = 900, .l = .desktop },
        .{ .w = 1100, .h = 720, .l = .desktop },
        .{ .w = 393, .h = 852, .l = .phone_portrait },
        .{ .w = 852, .h = 393, .l = .phone_landscape },
        .{ .w = 390, .h = 300, .l = .phone_portrait },
        .{ .w = 1024, .h = 768, .l = .desktop },
    };
    for (cases) |c| try std.testing.expectEqual(c.l, Layout.fromSize(c.w, c.h));
}
