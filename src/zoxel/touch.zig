//! Touch gestures for the 3D viewport: one finger orbits, two fingers pinch
//! to zoom and drag to pan. Plain data (physical pixels in, camera operations
//! out) so it is testable without a window.

const std = @import("std");

pub const Gesture = union(enum) {
    orbit: struct { dx: f32, dy: f32 },
    pan: struct { dx: f32, dy: f32 },
    /// >1 fingers moved apart, <1 together.
    zoom: f32,
};

pub const Phase = enum { started, moved, ended };

pub const Gestures = struct {
    items: [2]Gesture = undefined,
    len: usize = 0,

    fn push(self: *Gestures, g: Gesture) void {
        self.items[self.len] = g;
        self.len += 1;
    }
    pub fn slice(self: *const Gestures) []const Gesture {
        return self.items[0..self.len];
    }
};

const Point = struct { id: u64, pos: [2]f32 };

/// Follows up to two fingers that began a gesture inside the 3D viewport.
pub const TouchTracker = struct {
    points: [2]Point = undefined,
    count: usize = 0,

    /// `inside_viewport` only matters for the first finger: a drag that
    /// starts on a panel never moves the camera.
    pub fn update(self: *TouchTracker, id: u64, phase: Phase, pos: [2]f32, inside_viewport: bool) Gestures {
        var out = Gestures{};
        switch (phase) {
            .started => {
                const accept = if (self.count == 0) inside_viewport else self.count < 2;
                if (accept and self.find(id) == null) {
                    self.points[self.count] = .{ .id = id, .pos = pos };
                    self.count += 1;
                }
            },
            .moved => {
                const index = self.find(id) orelse return out;
                const before = self.points;
                self.points[index].pos = pos;
                if (self.count == 1) {
                    out.push(.{ .orbit = .{ .dx = pos[0] - before[0].pos[0], .dy = pos[1] - before[0].pos[1] } });
                } else if (self.count == 2) {
                    const a0 = before[0].pos;
                    const b0 = before[1].pos;
                    const a1 = self.points[0].pos;
                    const b1 = self.points[1].pos;
                    const d0 = distance(a0, b0);
                    const d1 = distance(a1, b1);
                    const m0 = midpoint(a0, b0);
                    const m1 = midpoint(a1, b1);
                    out.push(.{ .pan = .{ .dx = m1[0] - m0[0], .dy = m1[1] - m0[1] } });
                    if (d0 > 8.0 and d1 > 8.0) out.push(.{ .zoom = d1 / d0 });
                }
            },
            .ended => {
                if (self.find(id)) |i| {
                    if (i == 0 and self.count == 2) self.points[0] = self.points[1];
                    self.count -= 1;
                }
            },
        }
        return out;
    }

    pub fn reset(self: *TouchTracker) void {
        self.count = 0;
    }

    pub fn isActive(self: *const TouchTracker) bool {
        return self.count > 0;
    }

    fn find(self: *const TouchTracker, id: u64) ?usize {
        for (self.points[0..self.count], 0..) |p, i| if (p.id == id) return i;
        return null;
    }
};

fn distance(a: [2]f32, b: [2]f32) f32 {
    return @sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
}

fn midpoint(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
}

const testing = std.testing;

test "one finger orbits only when it starts in the viewport" {
    var t = TouchTracker{};
    _ = t.update(1, .started, .{ 10, 10 }, false);
    try testing.expect(!t.isActive());
    try testing.expectEqual(@as(usize, 0), t.update(1, .moved, .{ 20, 10 }, true).len);
    _ = t.update(2, .started, .{ 100, 100 }, true);
    const g = t.update(2, .moved, .{ 110, 95 }, true);
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expectEqual(@as(f32, 10), g.items[0].orbit.dx);
    try testing.expectEqual(@as(f32, -5), g.items[0].orbit.dy);
    _ = t.update(2, .ended, .{ 110, 95 }, true);
    try testing.expect(!t.isActive());
}

test "two fingers pinch to zoom and pan together" {
    var t = TouchTracker{};
    _ = t.update(1, .started, .{ 100, 100 }, true);
    _ = t.update(2, .started, .{ 200, 100 }, false);
    const spread = t.update(2, .moved, .{ 300, 100 }, true);
    try testing.expectEqual(@as(usize, 2), spread.len);
    try testing.expectEqual(@as(f32, 50), spread.items[0].pan.dx);
    try testing.expectEqual(@as(f32, 2), spread.items[1].zoom);
    const slide = t.update(1, .moved, .{ 100, 120 }, true);
    try testing.expectEqual(@as(f32, 10), slide.items[0].pan.dy);
}

test "a third finger is ignored" {
    var t = TouchTracker{};
    _ = t.update(1, .started, .{ 0, 0 }, true);
    _ = t.update(2, .started, .{ 50, 0 }, true);
    _ = t.update(3, .started, .{ 90, 0 }, true);
    try testing.expectEqual(@as(usize, 0), t.update(3, .moved, .{ 99, 0 }, true).len);
}
