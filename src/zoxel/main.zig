//! zoxel -- GPU-accelerated DICOS volume viewer.
//!
//! Usage:
//!   zoxel                      Launch with empty viewport
//!   zoxel scan.dcs             Load a single DICOS file
//!   zoxel /path/to/slices/     Load a directory of .dcs files as a volume

const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zgui = @import("zgui");
const app_mod = @import("app.zig");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Parse CLI args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // program name
    const initial_path = args.next();

    // Initialize GLFW
    zglfw.init() catch |e| {
        std.debug.print("Failed to initialize GLFW: {}\n", .{e});
        return;
    };
    defer zglfw.terminate();

    // Create window
    const window = zglfw.Window.create(1920, 1000, "zoxel — DICOS Volume Viewer", null, null) catch |e| {
        std.debug.print("Failed to create window: {}\n", .{e});
        return;
    };
    defer window.destroy();

    // Create GPU context
    const gctx = zgpu.GraphicsContext.create(allocator, .{
        .window = @ptrCast(window),
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = &getFramebufferSize,
        .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
    }, .{}) catch |e| {
        std.debug.print("Failed to create GPU context: {}\n", .{e});
        return;
    };
    defer gctx.destroy(allocator);

    // Initialize zgui
    zgui.init(allocator);
    defer zgui.deinit();

    // Initialize zgui backend
    zgui.backend.init(
        @ptrCast(window),
        @ptrCast(gctx.device),
        @intFromEnum(zgpu.GraphicsContext.swapchain_format),
        @intFromEnum(@as(zgpu.wgpu.TextureFormat, .undef)),
    );
    defer zgui.backend.deinit();

    // Get DPI scale for the application
    const content_scale = window.getContentScale();
    const dpi_scale = content_scale[0];

    // Create application
    var application = app_mod.App.init(allocator, gctx, dpi_scale);
    defer application.deinit();

    // Load initial path if provided
    if (initial_path) |path| {
        application.loadPath(path) catch |e| {
            std.debug.print("Error loading {s}: {}\n", .{ path, e });
        };
    }

    // Main loop
    while (!window.shouldClose()) {
        zglfw.pollEvents();

        // Render frame (handles input internally after ImGui processes events)
        if (gctx.canRender()) {
            application.renderFrame(gctx, window);
        }
    }
}

fn getFramebufferSize(win: *const anyopaque) [2]u32 {
    const w: *zglfw.Window = @constCast(@ptrCast(@alignCast(win)));
    const size = w.getFramebufferSize();
    return .{ @intCast(size[0]), @intCast(size[1]) };
}

fn getWindowSize(win: *const anyopaque) [2]u32 {
    const w: *zglfw.Window = @constCast(@ptrCast(@alignCast(win)));
    const size = w.getSize();
    return .{ @intCast(size[0]), @intCast(size[1]) };
}

// Module imports for testing
pub const camera = @import("camera.zig");
pub const transfer_fn = @import("transfer_fn.zig");
pub const volume = @import("volume.zig");
pub const slice_view = @import("slice_view.zig");
pub const renderer = @import("renderer.zig");
pub const app = @import("app.zig");

test {
    _ = @import("camera.zig");
    _ = @import("transfer_fn.zig");
}
