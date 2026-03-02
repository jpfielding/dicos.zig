const std = @import("std");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(v: Vec3, s: f32) Vec3 {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len < 1e-8) return .{ .x = 0, .y = 0, .z = 0 };
        return v.scale(1.0 / len);
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
};

/// Arcball camera orbiting a target point.
pub const Camera = struct {
    target: Vec3 = Vec3.init(0.5, 0.5, 0.5),
    azimuth: f32 = 0.5,
    elevation: f32 = -0.4,
    distance: f32 = 1.0,
    fov: f32 = 0.8,

    /// Compute the camera position in world space.
    pub fn position(self: Camera) Vec3 {
        const sin_az = @sin(self.azimuth);
        const cos_az = @cos(self.azimuth);
        const sin_el = @sin(self.elevation);
        const cos_el = @cos(self.elevation);

        return Vec3.init(
            sin_az * cos_el * self.distance + self.target.x,
            sin_el * self.distance + self.target.y,
            cos_az * cos_el * self.distance + self.target.z,
        );
    }

    /// Compute the forward direction (toward target).
    pub fn forward(self: Camera) Vec3 {
        return Vec3.sub(self.target, self.position()).normalize();
    }

    /// Compute the right vector.
    pub fn right(self: Camera) Vec3 {
        const cos_az = @cos(self.azimuth);
        const sin_az = @sin(self.azimuth);
        return Vec3.init(cos_az, 0.0, -sin_az);
    }

    /// Compute the up vector.
    pub fn up(self: Camera) Vec3 {
        return Vec3.cross(self.forward(), self.right()).normalize();
    }

    /// Rotate the camera by delta angles (in radians).
    pub fn rotate(self: *Camera, delta_azimuth: f32, delta_elevation: f32) void {
        self.azimuth += delta_azimuth;
        self.elevation = std.math.clamp(
            self.elevation + delta_elevation,
            -std.math.pi / 2.0 + 0.01,
            std.math.pi / 2.0 - 0.01,
        );
    }

    /// Zoom by a multiplicative factor.
    pub fn zoom(self: *Camera, factor: f32) void {
        self.distance = std.math.clamp(self.distance / factor, 0.5, 5.0);
    }

    /// Pan the camera target in view space.
    pub fn panPixels(self: *Camera, delta_x: f32, delta_y: f32) void {
        const s = self.distance * 0.0015;
        const r = self.right();
        const u = self.up();
        self.target = Vec3.add(self.target, Vec3.add(
            Vec3.scale(r, -delta_x * s),
            Vec3.scale(u, delta_y * s),
        ));
    }

    pub fn setAxial(self: *Camera) void {
        // Top-down: camera above on +Y, looking at X-Z plane
        self.azimuth = 0.0;
        self.elevation = std.math.pi / 2.0 - 0.01;
    }

    pub fn setCoronal(self: *Camera) void {
        // Front view: camera on +Z, looking at X-Y plane
        self.azimuth = 0.0;
        self.elevation = 0.0;
    }

    pub fn setSagittal(self: *Camera) void {
        // Side view: camera on +X, looking at Y-Z plane
        self.azimuth = std.math.pi / 2.0;
        self.elevation = 0.0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "default camera looks at center" {
    const cam = Camera{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cam.target.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cam.target.y, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cam.target.z, 1e-4);
}

test "position at default angles" {
    const cam = Camera{};
    const pos = cam.position();
    const diff = Vec3.sub(pos, cam.target);
    const dist = diff.length();
    try std.testing.expectApproxEqAbs(cam.distance, dist, 1e-4);
}

test "zoom clamps" {
    var cam = Camera{};
    cam.zoom(100.0);
    try std.testing.expect(cam.distance >= 0.5);
    cam.zoom(0.001);
    try std.testing.expect(cam.distance <= 5.0);
}

test "rotation clamps elevation" {
    var cam = Camera{};
    cam.rotate(0.0, 100.0);
    try std.testing.expect(cam.elevation < std.math.pi / 2.0);
    cam.rotate(0.0, -200.0);
    try std.testing.expect(cam.elevation > -std.math.pi / 2.0);
}

test "pan changes target" {
    var cam = Camera{};
    const start_x = cam.target.x;
    cam.panPixels(10.0, -8.0);
    try std.testing.expect(cam.target.x != start_x or cam.target.y != 0.5 or cam.target.z != 0.5);
}
