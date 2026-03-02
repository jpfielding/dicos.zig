const std = @import("std");

/// Row-major grayscale image buffer.
///
/// Stores pixel data in row-major order (left-to-right, top-to-bottom).
/// Generic over the pixel type T.
pub fn GrayImage(comptime T: type) type {
    return struct {
        const Self = @This();

        width: u32,
        height: u32,
        data: []T,
        allocator: std.mem.Allocator,

        /// Creates a new image with the given dimensions, filled with the specified value.
        pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, fill: T) !Self {
            const len = @as(usize, width) * @as(usize, height);
            const data = try allocator.alloc(T, len);
            @memset(data, fill);
            return .{
                .width = width,
                .height = height,
                .data = data,
                .allocator = allocator,
            };
        }

        /// Creates a new image from existing pixel data. The caller transfers ownership.
        pub fn fromData(allocator: std.mem.Allocator, width: u32, height: u32, data: []T) ?Self {
            const expected = @as(usize, width) * @as(usize, height);
            if (data.len != expected) return null;
            return .{
                .width = width,
                .height = height,
                .data = data,
                .allocator = allocator,
            };
        }

        /// Frees the pixel data.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
            self.data = &.{};
        }

        /// Returns the number of pixels in the image.
        pub fn numPixels(self: Self) usize {
            return @as(usize, self.width) * @as(usize, self.height);
        }

        /// Returns the pixel at the given (x, y) coordinate.
        pub fn pixel(self: Self, x: u32, y: u32) T {
            return self.data[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
        }

        /// Sets the pixel at the given (x, y) coordinate.
        pub fn setPixel(self: *Self, x: u32, y: u32, value: T) void {
            self.data[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = value;
        }

        /// Returns a slice of the row at the given y coordinate.
        pub fn row(self: Self, y: u32) []const T {
            const start = @as(usize, y) * @as(usize, self.width);
            return self.data[start .. start + self.width];
        }

        /// Returns a mutable slice of the row at the given y coordinate.
        pub fn rowMut(self: *Self, y: u32) []T {
            const start = @as(usize, y) * @as(usize, self.width);
            return self.data[start .. start + self.width];
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "new fills with value" {
    const allocator = std.testing.allocator;
    var img = try GrayImage(u16).init(allocator, 4, 3, 42);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 3), img.height);
    try std.testing.expectEqual(@as(usize, 12), img.data.len);
    for (img.data) |v| {
        try std.testing.expectEqual(@as(u16, 42), v);
    }
}

test "from data valid" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u16, 6);
    data[0] = 1;
    data[1] = 2;
    data[2] = 3;
    data[3] = 4;
    data[4] = 5;
    data[5] = 6;

    var img = GrayImage(u16).fromData(allocator, 3, 2, data) orelse unreachable;
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 3), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
}

test "from data wrong size" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u16, 3);
    defer allocator.free(data);
    try std.testing.expect(GrayImage(u16).fromData(allocator, 2, 2, data) == null);
}

test "pixel access" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u16, 6);
    data[0] = 10;
    data[1] = 20;
    data[2] = 30;
    data[3] = 40;
    data[4] = 50;
    data[5] = 60;

    var img = GrayImage(u16).fromData(allocator, 3, 2, data) orelse unreachable;
    defer img.deinit();

    try std.testing.expectEqual(@as(u16, 10), img.pixel(0, 0));
    try std.testing.expectEqual(@as(u16, 60), img.pixel(2, 1));
    img.setPixel(1, 0, 99);
    try std.testing.expectEqual(@as(u16, 99), img.pixel(1, 0));
}

test "row access" {
    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u16, 6);
    data[0] = 1;
    data[1] = 2;
    data[2] = 3;
    data[3] = 4;
    data[4] = 5;
    data[5] = 6;

    var img = GrayImage(u16).fromData(allocator, 3, 2, data) orelse unreachable;
    defer img.deinit();

    try std.testing.expectEqualSlices(u16, &[_]u16{ 1, 2, 3 }, img.row(0));
    try std.testing.expectEqualSlices(u16, &[_]u16{ 4, 5, 6 }, img.row(1));
}

test "num pixels" {
    const allocator = std.testing.allocator;
    var img = try GrayImage(u8).init(allocator, 10, 20, 0);
    defer img.deinit();
    try std.testing.expectEqual(@as(usize, 200), img.numPixels());
}
