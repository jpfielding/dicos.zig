//! Arcball camera for 3D volume viewing.
//!
//! An orbit camera rotating around a target point, with screen-space panning,
//! zoom and an automatic fit of the whole volume. World space is the physical
//! volume extent normalised by its X length (see `physicalExtent`).

const std = @import("std");

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    pub const one: Vec3 = .{ .x = 1, .y = 1, .z = 1 };
    pub const unit_x: Vec3 = .{ .x = 1 };
    pub const unit_y: Vec3 = .{ .y = 1 };
    pub const unit_z: Vec3 = .{ .z = 1 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn fromArray(a: [3]f32) Vec3 {
        return .{ .x = a[0], .y = a[1], .z = a[2] };
    }
    pub fn toArray(v: Vec3) [3]f32 {
        return .{ v.x, v.y, v.z };
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
    pub fn div(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x / b.x, .y = a.y / b.y, .z = a.z / b.z };
    }
    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn length(v: Vec3) f32 {
        return @sqrt(v.dot(v));
    }
    pub fn normalize(v: Vec3) Vec3 {
        return v.scale(1.0 / v.length());
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub fn minElement(v: Vec3) f32 {
        return @min(v.x, @min(v.y, v.z));
    }
    pub fn eql(a: Vec3, b: Vec3) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

/// Physical volume dimensions normalised by physical X length. Invalid
/// spacing falls back to one unit per voxel on that axis. No aspect clamp:
/// narrow and anisotropic volumes keep their geometry.
pub fn physicalExtent(dims: [3]usize, spacing: [3]f64) Vec3 {
    var physical: [3]f64 = undefined;
    for (0..3) |axis| {
        const s = if (std.math.isFinite(spacing[axis]) and spacing[axis] > 0.0) spacing[axis] else 1.0;
        physical[axis] = @as(f64, @floatFromInt(@max(dims[axis], 1))) * s;
    }
    return .{
        .x = 1.0,
        .y = @floatCast(physical[1] / physical[0]),
        .z = @floatCast(physical[2] / physical[0]),
    };
}

/// Arcball camera orbiting a target point.
pub const Camera = struct {
    /// Target point in physical world coordinates.
    target: Vec3 = .{ .x = 0.5, .y = 0.5, .z = 0.5 },
    /// Azimuth (radians, around Y). Slight oblique view by default.
    azimuth: f32 = 0.25,
    /// Elevation (radians). Inspect the open volume from above.
    elevation: f32 = -1.1,
    distance: f32 = 1.0,
    /// Vertical field-of-view factor (a ray spread, not degrees).
    fov: f32 = 0.8,
    max_distance: f32 = MAX_DISTANCE,

    pub const MIN_DISTANCE: f32 = 0.5;
    pub const MAX_DISTANCE: f32 = 5.0;

    /// Fit all eight volume corners into the viewport with a 6% margin.
    pub fn fitBounds(self: *Camera, min: Vec3, max: Vec3, aspect: f32) void {
        self.target = min.add(max).scale(0.5);
        const fwd = self.forward();
        const rgt = self.right();
        const upv = self.up();
        var distance: f32 = MIN_DISTANCE;
        for ([_]f32{ min.x, max.x }) |x| {
            for ([_]f32{ min.y, max.y }) |y| {
                for ([_]f32{ min.z, max.z }) |z| {
                    const delta = Vec3.init(x, y, z).sub(self.target);
                    const depth = delta.dot(fwd);
                    distance = @max(distance, @abs(delta.dot(rgt)) * 1.06 / (self.fov * @max(aspect, 0.1)) - depth);
                    distance = @max(distance, @abs(delta.dot(upv)) * 1.06 / self.fov - depth);
                }
            }
        }
        self.max_distance = @max(MAX_DISTANCE, distance * 2.0);
        self.distance = @max(distance, MIN_DISTANCE);
    }

    pub fn position(self: Camera) Vec3 {
        const sa = @sin(self.azimuth);
        const ca = @cos(self.azimuth);
        const se = @sin(self.elevation);
        const ce = @cos(self.elevation);
        return .{
            .x = sa * ce * self.distance + self.target.x,
            .y = se * self.distance + self.target.y,
            .z = ca * ce * self.distance + self.target.z,
        };
    }

    pub fn forward(self: Camera) Vec3 {
        return self.target.sub(self.position()).normalize();
    }

    pub fn right(self: Camera) Vec3 {
        return .{ .x = @cos(self.azimuth), .y = 0, .z = -@sin(self.azimuth) };
    }

    pub fn up(self: Camera) Vec3 {
        return self.forward().cross(self.right()).normalize();
    }

    pub fn rotate(self: *Camera, d_azimuth: f32, d_elevation: f32) void {
        self.azimuth += d_azimuth;
        self.elevation += d_elevation;
    }

    /// Zoom by a multiplicative factor (>1 zooms in).
    pub fn zoom(self: *Camera, factor: f32) void {
        self.distance = std.math.clamp(self.distance / factor, MIN_DISTANCE, self.max_distance);
    }

    /// Pan the target in view space by pixel deltas (x right, y down).
    pub fn panPixels(self: *Camera, dx: f32, dy: f32) void {
        const s = self.distance * 0.0015;
        self.target = self.target.add(self.right().scale(-dx).add(self.up().scale(dy)).scale(s));
    }

    pub fn setAxial(self: *Camera) void {
        self.azimuth = 0;
        self.elevation = 0;
    }

    pub fn setCoronal(self: *Camera) void {
        self.azimuth = 0;
        self.elevation = -std.math.pi / 2.0 + 0.01;
    }

    pub fn setSagittal(self: *Camera) void {
        self.azimuth = std.math.pi / 2.0;
        self.elevation = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "anisotropic samples form a physical cube" {
    try testing.expect(physicalExtent(.{ 100, 50, 25 }, .{ 1, 2, 4 }).eql(Vec3.one));
    try testing.expect(physicalExtent(.{ 256, 128, 256 }, .{ 1, 1, 1 }).eql(Vec3.init(1, 0.5, 1)));
    try testing.expect(physicalExtent(.{ 100, 200, 1 }, .{ 1, 1, 1 }).eql(Vec3.init(1, 2, 0.01)));
}

test "physical geometry camera fit covers all corners without aspect clamp" {
    const cases = [_]struct { d: [3]usize, s: [3]f64 }{
        .{ .d = .{ 100, 50, 25 }, .s = .{ 1, 2, 4 } },
        .{ .d = .{ 256, 128, 256 }, .s = .{ 1, 1, 1 } },
        .{ .d = .{ 10, 500, 100 }, .s = .{ 1, 1, 1 } },
    };
    for (cases) |c| {
        const extent = physicalExtent(c.d, c.s);
        for ([_]f32{ 0.5, 1.0, 2.0 }) |aspect| {
            var cam = Camera{};
            cam.fitBounds(Vec3.zero, extent, aspect);
            try testing.expect(cam.target.eql(extent.scale(0.5)));
            const fit = cam.distance;
            cam.zoom(1.0);
            try testing.expectEqual(fit, cam.distance);
            for ([_]f32{ 0, extent.x }) |x| for ([_]f32{ 0, extent.y }) |y| for ([_]f32{ 0, extent.z }) |z| {
                const delta = Vec3.init(x, y, z).sub(cam.position());
                const depth = delta.dot(cam.forward());
                try testing.expect(depth > 0);
                try testing.expect(@abs(delta.dot(cam.right())) < depth * cam.fov * aspect);
                try testing.expect(@abs(delta.dot(cam.up())) < depth * cam.fov);
            };
        }
    }
}

test "fitted volume corners stay inside viewport" {
    for ([_]f32{ 0.8, 1.2, 2.0 }) |aspect| {
        for ([_]f32{ 0.1, 0.5, 1.0, 2.0 }) |depth_z| {
            var cam = Camera{};
            cam.fitBounds(Vec3.zero, Vec3.init(1, 1, depth_z), aspect);
            for ([_]f32{ 0, 1 }) |x| for ([_]f32{ 0, 1 }) |y| for ([_]f32{ 0, depth_z }) |z| {
                const delta = Vec3.init(x, y, z).sub(cam.position());
                const d = delta.dot(cam.forward());
                try testing.expect(d > 0);
                try testing.expect(@abs(delta.dot(cam.right())) / (d * cam.fov * aspect) < 1.0);
                try testing.expect(@abs(delta.dot(cam.up())) / (d * cam.fov) < 1.0);
            };
        }
    }
}

test "default camera" {
    const cam = Camera{};
    try testing.expect(cam.target.eql(Vec3.init(0.5, 0.5, 0.5)));
    try testing.expect(@abs(cam.position().sub(cam.target).length() - cam.distance) < 1e-4);
    try testing.expect(cam.forward().z < 0);
}

test "zoom clamps, rotation is continuous, pan moves target" {
    var cam = Camera{};
    cam.zoom(100.0);
    try testing.expect(cam.distance >= 0.5);
    cam.zoom(0.001);
    try testing.expect(cam.distance <= 5.0);

    var c2 = Camera{};
    const start = c2.elevation;
    c2.rotate(0, std.math.pi);
    try testing.expect(@abs(c2.elevation - (start + std.math.pi)) < 1e-6);

    var c3 = Camera{};
    const t0 = c3.target;
    c3.panPixels(10, -8);
    try testing.expect(!c3.target.eql(t0));
}
