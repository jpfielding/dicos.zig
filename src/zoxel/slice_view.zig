//! CPU 2D slice renderer.
//!
//! Renders a single slice (window/level grayscale) or a front-to-back
//! composite projection (transfer function colours) of a volume into an RGBA8
//! image, and defines the slice-plane geometry the 3D view uses (locator
//! corners and cutaway clip plane). No GPU required.

const std = @import("std");
const volume_mod = @import("volume.zig");
const transfer = @import("transfer.zig");

const Volume = volume_mod.Volume;
const ThreatBox = volume_mod.ThreatBox;

pub const Orientation = enum {
    /// XY plane (looking down Z).
    axial,
    /// XZ plane (looking down Y).
    coronal,
    /// YZ plane (looking down X).
    sagittal,

    pub const all = [_]Orientation{ .axial, .coronal, .sagittal };

    pub fn label(self: Orientation) []const u8 {
        return switch (self) {
            .axial => "Axial",
            .coronal => "Coronal",
            .sagittal => "Sagittal",
        };
    }

    pub fn index(self: Orientation) usize {
        return @intFromEnum(self);
    }
};

/// An RGBA8 image, row-major, owned.
pub const Image = struct {
    width: usize,
    height: usize,
    /// `width * height` pixels, `[r, g, b, a]`.
    pixels: [][4]u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    fn filled(gpa: std.mem.Allocator, w: usize, h: usize, c: [4]u8) !Image {
        const px = try gpa.alloc([4]u8, w * h);
        @memset(px, c);
        return .{ .width = w, .height = h, .pixels = px };
    }
};

pub const Size2 = struct { x: f32, y: f32 };

pub const SliceView = struct {
    orientation: Orientation = .axial,
    /// 0-based slice index.
    slice_index: usize = 0,
    max_slices: usize = 1,
    window_center: f32 = 32768.0,
    window_width: f32 = 65536.0,
    /// Composite projection instead of a single slice.
    composite: bool = false,
    /// Volume layer shown.
    volume_index: usize = 0,
    /// Global alpha scale for composites (synced from 3D opacity).
    alpha_scale: f32 = 0.5,
    /// Transfer table for composites; grayscale MIP when null.
    transfer_func: ?transfer.TransferFunction = null,
    /// Display zoom percentage (100 = fit).
    zoom: f32 = 100.0,

    /// Keep the half-volume at or after the selected voxel-centre plane.
    pub fn clipPlane(self: *const SliceView, vol: *const Volume, reverse: bool) [4]f32 {
        const depth = @max(depthFor(vol, self.orientation), 1);
        const t = (@as(f32, @floatFromInt(@min(self.slice_index, depth - 1))) + 0.5) / @as(f32, @floatFromInt(depth));
        var plane: [4]f32 = switch (self.orientation) {
            .axial => .{ 0, 0, 1, t },
            .coronal => .{ 0, 1, 0, t },
            .sagittal => .{ 1, 0, 0, t },
        };
        if (reverse) {
            for (&plane) |*v| v.* = -v.*;
        }
        return plane;
    }

    /// Physical image size (mm) for aspect-preserving display.
    pub fn physicalSliceSize(self: *const SliceView, vol: *const Volume) Size2 {
        var sp: [3]f32 = undefined;
        for (0..3) |i| {
            const s = vol.voxel_spacing[i];
            sp[i] = if (std.math.isFinite(s) and s > 0) @floatCast(s) else 1.0;
        }
        const d = sliceDims(vol, self.orientation);
        const s: [2]f32 = switch (self.orientation) {
            .axial => .{ sp[0], sp[1] },
            .coronal => .{ sp[0], sp[2] },
            .sagittal => .{ sp[1], sp[2] },
        };
        return .{ .x = @as(f32, @floatFromInt(d[0])) * s[0], .y = @as(f32, @floatFromInt(d[1])) * s[1] };
    }

    /// Normalised corners of the selected voxel-centre plane (texture space).
    pub fn planeCorners(self: *const SliceView, vol: *const Volume) [4][3]f32 {
        const depth = @max(depthFor(vol, self.orientation), 1);
        const t = (@as(f32, @floatFromInt(@min(self.slice_index, depth - 1))) + 0.5) / @as(f32, @floatFromInt(depth));
        return switch (self.orientation) {
            .axial => .{ .{ 0, 0, t }, .{ 1, 0, t }, .{ 1, 1, t }, .{ 0, 1, t } },
            .coronal => .{ .{ 0, t, 0 }, .{ 1, t, 0 }, .{ 1, t, 1 }, .{ 0, t, 1 } },
            .sagittal => .{ .{ t, 0, 0 }, .{ t, 1, 0 }, .{ t, 1, 1 }, .{ t, 0, 1 } },
        };
    }

    /// Update max_slices for the volume and current orientation.
    pub fn updateForVolume(self: *SliceView, vol: *const Volume) void {
        self.max_slices = depthFor(vol, self.orientation);
        if (self.slice_index >= self.max_slices) self.slice_index = self.max_slices -| 1;
    }

    pub fn depthFor(vol: *const Volume, o: Orientation) usize {
        return switch (o) {
            .axial => vol.dim_z,
            .coronal => vol.dim_y,
            .sagittal => vol.dim_x,
        };
    }

    pub fn sliceDims(vol: *const Volume, o: Orientation) [2]usize {
        return switch (o) {
            .axial => .{ vol.dim_x, vol.dim_y },
            .coronal => .{ vol.dim_x, vol.dim_z },
            .sagittal => .{ vol.dim_y, vol.dim_z },
        };
    }

    inline fn sample(vol: *const Volume, o: Orientation, u: usize, v: usize, s: usize) u16 {
        const xyz: [3]usize = switch (o) {
            .axial => .{ u, v, s },
            .coronal => .{ u, s, v },
            .sagittal => .{ s, u, v },
        };
        return vol.data[xyz[2] * vol.dim_y * vol.dim_x + xyz[1] * vol.dim_x + xyz[0]];
    }

    /// Single slice as grayscale, in the modality (rescaled) domain.
    pub fn renderSlice(self: *const SliceView, gpa: std.mem.Allocator, vol: *const Volume) !Image {
        const d = sliceDims(vol, self.orientation);
        if (d[0] == 0 or d[1] == 0) return Image.filled(gpa, 1, 1, .{ 0, 0, 0, 255 });
        const low = self.window_center - self.window_width * 0.5;
        const inv = if (self.window_width > 0) 255.0 / self.window_width else 0.0;
        var img = try Image.filled(gpa, d[0], d[1], .{ 0, 0, 0, 255 });
        const s = @min(self.slice_index, depthFor(vol, self.orientation) -| 1);
        for (0..d[1]) |v| {
            for (0..d[0]) |u| {
                const raw: f32 = @floatCast(vol.modalityValue(sample(vol, self.orientation, u, v, s)));
                const g: u8 = @intFromFloat(std.math.clamp((raw - low) * inv, 0.0, 255.0));
                img.pixels[v * d[0] + u] = .{ g, g, g, 255 };
            }
        }
        return img;
    }

    fn compositePixel(vol: *const Volume, o: Orientation, u: usize, v: usize, depth: usize, w_min: f32, w_range: f32, tf: ?*const transfer.TransferFunction, alpha_scale: f32) [4]u8 {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;
        var a: f32 = 0;
        for (0..depth) |s| {
            if (a >= 0.98) break;
            const density: f32 = @floatCast(vol.modalityValue(sample(vol, o, u, v, s)));
            if (density <= w_min) continue;
            const norm = std.math.clamp((density - w_min) / w_range, 0.0, 1.0);
            if (tf) |t| {
                const n = transfer.TRANSFER_SIZE;
                const idx: usize = @min(@as(usize, @intFromFloat(norm * @as(f32, n - 1))), n - 1);
                const c = t.data[idx];
                // pow(alpha, 1.5) * alphaScale (matches the Go viewer).
                const alpha = std.math.pow(f32, c[3], 1.5) * alpha_scale;
                if (alpha > 0) {
                    r += (1 - a) * c[0] * alpha;
                    g += (1 - a) * c[1] * alpha;
                    b += (1 - a) * c[2] * alpha;
                    a += (1 - a) * alpha;
                }
            } else {
                r = @max(r, norm);
                g = @max(g, norm);
                b = @max(b, norm);
                a = 1;
            }
        }
        // Over a white background.
        return .{
            @intFromFloat(std.math.clamp(r + (1 - a), 0.0, 1.0) * 255.0),
            @intFromFloat(std.math.clamp(g + (1 - a), 0.0, 1.0) * 255.0),
            @intFromFloat(std.math.clamp(b + (1 - a), 0.0, 1.0) * 255.0),
            255,
        };
    }

    /// Front-to-back alpha composite along the plane normal using the
    /// transfer function (grayscale MIP when none is set).
    pub fn renderComposite(self: *const SliceView, gpa: std.mem.Allocator, vol: *const Volume) !Image {
        const d = sliceDims(vol, self.orientation);
        const depth = depthFor(vol, self.orientation);
        if (d[0] == 0 or d[1] == 0 or depth == 0) return Image.filled(gpa, 1, 1, .{ 0, 0, 0, 255 });
        const w_min = self.window_center - self.window_width * 0.5;
        var img = try Image.filled(gpa, d[0], d[1], .{ 0, 0, 0, 255 });
        const tf: ?*const transfer.TransferFunction = if (self.transfer_func) |*t| t else null;
        for (0..d[1]) |v| {
            for (0..d[0]) |u| {
                img.pixels[v * d[0] + u] = compositePixel(vol, self.orientation, u, v, depth, w_min, self.window_width, tf, self.alpha_scale);
            }
        }
        return img;
    }

    fn drawThreatRect(img: *Image, x0_in: usize, y0_in: usize, x1_in: usize, y1_in: usize, c: [4]u8) void {
        const w = img.width;
        const h = img.height;
        if (w == 0 or h == 0) return;
        const x0 = @min(x0_in, w - 1);
        const x1 = @min(x1_in, w - 1);
        const y0 = @min(y0_in, h - 1);
        const y1 = @min(y1_in, h - 1);
        if (x0 > x1 or y0 > y1) return;
        for (x0..x1 + 1) |x| {
            img.pixels[y0 * w + x] = c;
            img.pixels[y1 * w + x] = c;
        }
        for (y0..y1 + 1) |y| {
            img.pixels[y * w + x0] = c;
            img.pixels[y * w + x1] = c;
        }
    }

    pub fn projectThreat(self: *const SliceView, t: *const ThreatBox, composite: bool) ?[4]usize {
        const lo = t.min;
        const hi = t.max;
        const s = self.slice_index;
        const visible = composite or switch (self.orientation) {
            .axial => lo[2] <= s and s <= hi[2],
            .coronal => lo[1] <= s and s <= hi[1],
            .sagittal => lo[0] <= s and s <= hi[0],
        };
        if (!visible) return null;
        return switch (self.orientation) {
            .axial => .{ lo[0], lo[1], hi[0], hi[1] },
            .coronal => .{ lo[0], lo[2], hi[0], hi[2] },
            .sagittal => .{ lo[1], lo[2], hi[1], hi[2] },
        };
    }

    /// Single slice or composite, with enabled threat boxes outlined.
    pub fn render(self: *const SliceView, gpa: std.mem.Allocator, vol: *const Volume, show_threats: bool) !Image {
        var img = if (self.composite) try self.renderComposite(gpa, vol) else try self.renderSlice(gpa, vol);
        if (show_threats) {
            for (vol.threats.items) |*t| {
                if (!t.enabled) continue;
                if (self.projectThreat(t, self.composite)) |r| {
                    drawThreatRect(&img, r[0], r[1], r[2], r[3], .{ t.color[0], t.color[1], t.color[2], 255 });
                }
            }
        }
        return img;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// 4x3x2 volume with value z*1000 + y*100 + x.
fn testVolume(gpa: std.mem.Allocator) !Volume {
    var vol = try volume_mod.testVolume(gpa, 4, 3, 2, 0);
    for (0..2) |z| for (0..3) |y| for (0..4) |x| {
        vol.data[z * 12 + y * 4 + x] = @intCast(z * 1000 + y * 100 + x);
    };
    vol.window_center = 1000;
    vol.window_width = 2000;
    return vol;
}

test "rescale intercept matches slice and projection window" {
    const gpa = testing.allocator;
    var vol = try volume_mod.testVolume(gpa, 1, 1, 1, 1524);
    defer vol.deinit(gpa);
    vol.rescale_intercept = -1024.0;
    const view = SliceView{ .window_center = 500, .window_width = 1000 };
    var a = try view.renderSlice(gpa, &vol);
    defer a.deinit(gpa);
    var b = try view.renderComposite(gpa, &vol);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(u8, 127), a.pixels[0][0]);
    try testing.expectEqual(@as(u8, 127), b.pixels[0][0]);
}

test "signed pixels and slope match slice and projection window" {
    const gpa = testing.allocator;
    var vol = try volume_mod.testVolume(gpa, 1, 1, 1, @bitCast(@as(i16, -1)));
    defer vol.deinit(gpa);
    vol.signed_pixels = true;
    vol.rescale_slope = 2.0;
    vol.rescale_intercept = 1.0;
    try testing.expectEqual(@as(f64, -1.0), vol.modalityValue(vol.data[0]));
    const view = SliceView{ .window_center = -1, .window_width = 2 };
    var a = try view.renderSlice(gpa, &vol);
    defer a.deinit(gpa);
    var b = try view.renderComposite(gpa, &vol);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(u8, 127), a.pixels[0][0]);
    try testing.expectEqual(@as(u8, 127), b.pixels[0][0]);
}

test "reverse cutaway keeps opposite half and physical slice preserves aspect" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa);
    defer vol.deinit(gpa);
    vol.dim_y = 2;
    vol.voxel_spacing = .{ 1, 2, 2 };
    for (Orientation.all) |o| {
        const view = SliceView{ .orientation = o };
        const size = view.physicalSliceSize(&vol);
        try testing.expectEqual(@as(f32, 4), size.x);
        try testing.expectEqual(@as(f32, 4), size.y);
        const plane = view.clipPlane(&vol, false);
        const rev = view.clipPlane(&vol, true);
        for (0..4) |i| try testing.expectEqual(-plane[i], rev[i]);
        const at_origin = -plane[3];
        const at_far = plane[0] + plane[1] + plane[2] - plane[3];
        try testing.expect(at_origin < 0 and at_far > 0);
    }
}

test "locator plane uses the selected voxel center" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa);
    defer vol.deinit(gpa);
    const cases = [_]struct { o: Orientation, axis: usize, depth: usize }{
        .{ .o = .axial, .axis = 2, .depth = 2 },
        .{ .o = .coronal, .axis = 1, .depth = 3 },
        .{ .o = .sagittal, .axis = 0, .depth = 4 },
    };
    for (cases) |c| {
        for ([_]usize{ 0, c.depth - 1 }) |index| {
            const view = SliceView{ .orientation = c.o, .slice_index = index };
            for (view.planeCorners(&vol)) |corner| {
                const expect = (@as(f32, @floatFromInt(index)) + 0.5) / @as(f32, @floatFromInt(c.depth));
                try testing.expect(@abs(corner[c.axis] - expect) < 1e-6);
                for (corner) |v| try testing.expect(v >= 0 and v <= 1);
            }
        }
    }
}

test "slice dims and sampling" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa);
    defer vol.deinit(gpa);
    try testing.expectEqual([2]usize{ 4, 3 }, SliceView.sliceDims(&vol, .axial));
    try testing.expectEqual([2]usize{ 4, 2 }, SliceView.sliceDims(&vol, .coronal));
    try testing.expectEqual([2]usize{ 3, 2 }, SliceView.sliceDims(&vol, .sagittal));
    try testing.expectEqual(@as(u16, 102), SliceView.sample(&vol, .axial, 2, 1, 0));
    try testing.expectEqual(@as(u16, 1203), SliceView.sample(&vol, .axial, 3, 2, 1));
    try testing.expectEqual(@as(u16, 1201), SliceView.sample(&vol, .coronal, 1, 1, 2));
    try testing.expectEqual(@as(u16, 1203), SliceView.sample(&vol, .sagittal, 2, 1, 3));
    try testing.expectEqualStrings("Coronal", Orientation.coronal.label());
}

test "render dimensions, composite MIP and dispatch" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa);
    defer vol.deinit(gpa);
    var sv = SliceView{ .orientation = .axial, .max_slices = 2, .window_center = 1000, .window_width = 2000 };
    var single = try sv.renderSlice(gpa, &vol);
    defer single.deinit(gpa);
    try testing.expectEqual(@as(usize, 12), single.pixels.len);
    sv.window_width = 3000;
    var comp = try sv.renderComposite(gpa, &vol);
    defer comp.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), comp.width);
    try testing.expect(comp.pixels[2 * 4 + 3][0] < 200);
    sv.composite = true;
    var d = try sv.render(gpa, &vol, true);
    defer d.deinit(gpa);
    try testing.expectEqual(single.width, d.width);
}

test "update for volume clamps index" {
    const gpa = testing.allocator;
    var vol = try testVolume(gpa);
    defer vol.deinit(gpa);
    var sv = SliceView{ .orientation = .axial, .slice_index = 100 };
    sv.updateForVolume(&vol);
    try testing.expectEqual(@as(usize, 2), sv.max_slices);
    try testing.expectEqual(@as(usize, 1), sv.slice_index);
}
