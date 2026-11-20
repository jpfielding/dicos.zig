//! Layout and interaction checks at the review sizes (port of roxel
//! `ui/fit_tests.rs` and the `ui/mod.rs` tests): nothing may be clipped by a
//! panel edge or run off the screen in any state, the compact flows stay
//! reachable, and pointer/keyboard input drives the expected transitions.
//! Runs headless: real ImGui font metrics, no window, no GPU.

const std = @import("std");
const zgui = @import("zgui");
const kit = @import("kit.zig");
const ui = @import("mod.zig");
const layout = @import("layout.zig");
const state_mod = @import("../state.zig");
const volume_mod = @import("../volume.zig");

const UiState = state_mod.UiState;
const Rect = kit.Rect;
const Vec2 = kit.Vec2;
const testing = std.testing;

const DESKTOP_SIZES = [_]Vec2{ .{ .x = 1440, .y = 900 }, .{ .x = 1100, .y = 720 } };
const PHONE_SIZES = [_]Vec2{ .{ .x = 393, .y = 852 }, .{ .x = 852, .y = 393 } };

var imgui_ready = false;
var font: ?zgui.Font = null;

/// A headless ImGui context with the real font, for text metrics only.
fn ensureImgui() void {
    if (imgui_ready) return;
    zgui.init(std.heap.page_allocator);
    zgui.io.setIniFilename(null);
    var cfg = zgui.FontConfig.init();
    cfg.font_data_owned_by_atlas = false;
    font = zgui.io.addFontFromMemoryWithConfig(@embedFile("../assets/Ubuntu-Light.ttf"), 15.0, cfg, null);
    zgui.io.setDisplaySize(2000, 2000);
    // No renderer: claim dynamic-texture support so the atlas needs no build.
    zgui.io.setBackendFlags(.{ .renderer_has_textures = true });
    zgui.newFrame();
    imgui_ready = true;
}

const Harness = struct {
    ctx: kit.Ctx,
    shapes: std.ArrayList(kit.Recorded) = .empty,

    fn init() Harness {
        ensureImgui();
        var h = Harness{ .ctx = kit.Ctx.init(testing.allocator) };
        h.ctx.proportional.font = font;
        return h;
    }

    fn deinit(self: *Harness) void {
        self.shapes.deinit(testing.allocator);
        self.ctx.deinit();
    }

    /// One frame with the given input edges.
    fn frame(self: *Harness, state: *UiState, size: Vec2, input: kit.Input) void {
        self.shapes.clearRetainingCapacity();
        self.ctx.recorder = &self.shapes;
        self.ctx.input = input;
        self.ctx.beginFrame(Rect.fromMinSize(.{}, size), null, null);
        ui.drawUi(&self.ctx, state);
        self.ctx.endFrame();
        self.ctx.recorder = null;
    }

    /// Panels size themselves over the first frames; judge the settled one.
    fn run(self: *Harness, state: *UiState, size: Vec2) void {
        for (0..4) |_| self.frame(state, size, .{ .pointer = .{ .x = -100, .y = -100 } });
    }

    fn textCenter(self: *Harness, label: []const u8) ?Vec2 {
        for (self.shapes.items) |s| {
            if (s.kind == .text and std.mem.eql(u8, s.text, label)) return s.rect.center();
        }
        return null;
    }

    /// Press and release the pointer on the text `label`.
    fn tap(self: *Harness, state: *UiState, size: Vec2, label: []const u8) !void {
        self.run(state, size);
        const pos = self.textCenter(label) orelse {
            std.debug.print("missing control {s}\n", .{label});
            return error.MissingControl;
        };
        self.frame(state, size, .{ .pointer = pos, .pressed = true, .down = true });
        self.frame(state, size, .{ .pointer = pos, .released = true });
    }

    fn key(self: *Harness, state: *UiState, size: Vec2, k: kit.Key) void {
        var in = kit.Input{ .pointer = .{ .x = -100, .y = -100 } };
        in.keys_pressed.insert(k);
        self.frame(state, size, in);
    }

    /// Every text and drawn rect a clip rect or the screen would cut.
    fn clipped(self: *Harness, size: Vec2) usize {
        const screen = Rect.fromMinSize(.{}, size);
        var n: usize = 0;
        for (self.shapes.items) |s| {
            if (!s.rect.isPositive()) continue;
            const ok = switch (s.kind) {
                .text => s.clip.expand(1).containsRect(s.rect) and screen.expand(0.5).containsRect(s.rect),
                .rect => s.clip.expand(1.5).containsRect(s.rect) and screen.expand(1.5).containsRect(s.rect),
            };
            if (!ok) {
                n += 1;
                std.debug.print("  clipped {s} '{s}' at {d:.1},{d:.1}-{d:.1},{d:.1} (clip {d:.1},{d:.1}-{d:.1},{d:.1})\n", .{ @tagName(s.kind), s.text, s.rect.min.x, s.rect.min.y, s.rect.max.x, s.rect.max.y, s.clip.min.x, s.clip.min.y, s.clip.max.x, s.clip.max.y });
            }
        }
        return n;
    }

    fn assertFits(self: *Harness, what: []const u8, state: *UiState, size: Vec2) !void {
        self.run(state, size);
        const n = self.clipped(size);
        if (n != 0) {
            std.debug.print("{s} at {d}x{d}: {d} clipped\n", .{ what, size.x, size.y, n });
            return error.Clipped;
        }
    }
};

/// A study shaped like the review sample: 680 x 440 x 200 mm, a long name,
/// a slice image and two detections (one with a long name).
fn study() !UiState {
    const gpa = testing.allocator;
    var state = UiState.init(.{});
    state.library.loaded_path = try gpa.dupe(u8, "backpack+purse_fishtank+goldfish_THREAT-knife_20260227-191512");
    var vol = try volume_mod.testVolume(gpa, 34, 22, 10, 0);
    vol.window_center = 238;
    vol.window_width = 2524;
    vol.voxel_spacing = .{ 20, 20, 20 };
    try vol.threats.append(gpa, .{ .name = try gpa.dupe(u8, "Knife"), .confidence = 0.93, .min = .{ 1, 1, 1 }, .max = .{ 4, 4, 4 }, .color = .{ 255, 80, 80 } });
    try vol.threats.append(gpa, .{ .name = try gpa.dupe(u8, "Lithium battery pack, oversized"), .confidence = 0.93, .min = .{ 1, 1, 1 }, .max = .{ 4, 4, 4 }, .color = .{ 255, 200, 60 } });
    try state.library.volumes.append(gpa, .{ .name = try gpa.dupe(u8, "ct"), .volume = vol });
    state.library.active_3d_index = 0;
    state.library.selected_threat = 0;
    state.slice_view.orientation = .coronal;
    state.slice_view.max_slices = 22;
    state.slice_view.slice_index = 11;
    state.slice_view.window_center = 238;
    state.slice_view.window_width = 2524;
    state.settings.window_center = 238;
    state.settings.window_width = 2524;
    state.slice_texture_size = .{ 34, 10 };
    return state;
}

fn smallStudy() !UiState {
    var s = try study();
    testing.allocator.free(s.library.loaded_path.?);
    s.library.loaded_path = try testing.allocator.dupe(u8, "study");
    return s;
}

test "desktop views fit without clipping" {
    for (DESKTOP_SIZES) |size| {
        for ([_]@import("../transfer.zig").TransferPreset{ .monochrome, .default }) |preset| {
            const modes = [_]struct { n: []const u8, focus: bool, expanded: bool, cutaway: bool }{
                .{ .n = "workspace", .focus = false, .expanded = false, .cutaway = false },
                .{ .n = "cutaway", .focus = false, .expanded = false, .cutaway = true },
                .{ .n = "focus volume", .focus = true, .expanded = false, .cutaway = false },
                .{ .n = "focus volume with cutaway", .focus = true, .expanded = false, .cutaway = true },
                .{ .n = "focus slice", .focus = false, .expanded = true, .cutaway = false },
            };
            for (modes) |m| {
                var h = Harness.init();
                defer h.deinit();
                var state = try study();
                defer state.deinit(testing.allocator);
                state.transfer.preset = preset;
                state.focus_volume = m.focus;
                state.slice_expanded = m.expanded;
                state.cutaway = m.cutaway;
                try h.assertFits(m.n, &state, size);
                try testing.expectEqual(layout.Layout.desktop, state.layout);
            }
        }
        var h = Harness.init();
        defer h.deinit();
        var empty = UiState.init(.{});
        defer empty.deinit(testing.allocator);
        try h.assertFits("first use", &empty, size);
    }
}

test "phone views fit without clipping" {
    for (PHONE_SIZES) |size| {
        for (layout.VolumePage.all) |pg| {
            for ([_][2]bool{ .{ false, false }, .{ true, true } }) |fa| {
                var h = Harness.init();
                defer h.deinit();
                var state = try study();
                defer state.deinit(testing.allocator);
                state.phone_tab = .view3d;
                state.volume_page = pg;
                state.focus_volume = fa[0];
                state.focus_adjust_open = fa[1];
                state.cutaway = true;
                state.transfer.preset = .default;
                try h.assertFits(@tagName(pg), &state, size);
            }
        }
        for ([_]layout.SlicePage{ .slice, .image }) |pg| {
            for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ true, true } }) |fa| {
                var h = Harness.init();
                defer h.deinit();
                var state = try study();
                defer state.deinit(testing.allocator);
                state.phone_tab = .slice;
                state.slice_page = pg;
                state.slice_expanded = fa[0];
                state.focus_adjust_open = fa[1];
                try h.assertFits(@tagName(pg), &state, size);
            }
        }
        {
            var h = Harness.init();
            defer h.deinit();
            var state = try study();
            defer state.deinit(testing.allocator);
            state.phone_tab = .view3d;
            state.volume_page = .display;
            state.transfer.preset = .default;
            state.bands_open = true;
            try h.assertFits("material bands", &state, size);
        }
        for ([_]layout.PhoneTab{ .study, .detections }) |tab| {
            var h = Harness.init();
            defer h.deinit();
            var state = try study();
            defer state.deinit(testing.allocator);
            state.phone_tab = tab;
            try h.assertFits(@tagName(tab), &state, size);
        }
        {
            var h = Harness.init();
            defer h.deinit();
            var state = try study();
            defer state.deinit(testing.allocator);
            state.phone_tab = .view3d;
            state.sheet_open = false;
            try h.assertFits("collapsed sheet", &state, size);
        }
        var h = Harness.init();
        defer h.deinit();
        var empty = UiState.init(.{});
        defer empty.deinit(testing.allocator);
        try h.assertFits("first use", &empty, size);
    }
}

test "phone sheets keep the view the same size on every page" {
    for (PHONE_SIZES) |size| {
        var h = Harness.init();
        defer h.deinit();
        var state = try study();
        defer state.deinit(testing.allocator);
        state.phone_tab = .view3d;
        h.run(&state, size);
        const first = state.viewport;
        try testing.expect(first.height() >= 240 and first.width() >= 300);
        for (layout.VolumePage.all) |pg| {
            state.volume_page = pg;
            h.run(&state, size);
            try testing.expect(state.viewport.eql(first));
        }
    }
}

test "the volume is on screen only where the layout shows it" {
    var h = Harness.init();
    defer h.deinit();
    var state = try study();
    defer state.deinit(testing.allocator);
    h.run(&state, DESKTOP_SIZES[0]);
    try testing.expect(state.volumeVisible());
    state.slice_expanded = true;
    try testing.expect(!state.volumeVisible());
    state.slice_expanded = false;
    h.run(&state, PHONE_SIZES[0]);
    for ([_]struct { t: layout.PhoneTab, v: bool }{ .{ .t = .view3d, .v = true }, .{ .t = .slice, .v = false }, .{ .t = .study, .v = false }, .{ .t = .detections, .v = false } }) |c| {
        state.phone_tab = c.t;
        try testing.expectEqual(c.v, state.volumeVisible());
    }
    state.focus_volume = true;
    try testing.expect(state.volumeVisible());
}

test "expanded slice navigation and escape use real input" {
    const size = Vec2{ .x = 1100, .y = 720 };
    var h = Harness.init();
    defer h.deinit();
    var state = try smallStudy();
    defer state.deinit(testing.allocator);
    state.slice_expanded = true;
    state.slice_view.max_slices = 4;
    state.slice_view.slice_index = 1;
    for ([_]struct { l: []const u8, e: usize }{ .{ .l = "Next", .e = 2 }, .{ .l = "Previous", .e = 1 } }) |c| {
        state.slice_dirty = false;
        try h.tap(&state, size, c.l);
        try testing.expectEqual(c.e, state.slice_view.slice_index);
        try testing.expect(state.slice_dirty);
    }
    h.key(&state, size, .escape);
    try testing.expect(!state.slice_expanded);
    state.focus_volume = true;
    h.key(&state, size, .escape);
    try testing.expect(!state.focus_volume);
    try testing.expect(state.fit_camera);
}

test "long study names leave a usable viewport at minimum size" {
    const size = Vec2{ .x = 1100, .y = 720 };
    var h = Harness.init();
    defer h.deinit();
    var state = try study();
    defer state.deinit(testing.allocator);
    const long = try std.mem.concat(testing.allocator, u8, &([_][]const u8{"long-study-identifier-"} ** 20));
    testing.allocator.free(state.library.loaded_path.?);
    state.library.loaded_path = long;
    h.run(&state, size);
    try testing.expect(state.viewport.width() >= 450);
    try testing.expect(state.viewport.height() >= 250);
    try testing.expect(state.viewport.max.x <= 1100);
    const before = state.viewport.size();
    try h.tap(&state, size, "Focus volume");
    try testing.expect(state.focus_volume);
    state.fit_camera = false; // the app consumes this frame's fit
    h.frame(&state, size, .{});
    try testing.expect(state.viewport.width() > before.x);
    try testing.expect(state.fit_camera);
    // Escape gives an open popup priority.
    h.ctx.popup = .{ .id = 42, .anchor = Rect.fromMinSize(.{ .x = -50, .y = -50 }, .{ .x = 1, .y = 1 }) };
    h.key(&state, size, .escape);
    try testing.expect(state.focus_volume);
}

test "phone layouts leave the volume room and tabs switch" {
    for ([_]struct { s: Vec2, l: layout.Layout }{ .{ .s = PHONE_SIZES[0], .l = .phone_portrait }, .{ .s = PHONE_SIZES[1], .l = .phone_landscape } }) |c| {
        var h = Harness.init();
        defer h.deinit();
        var state = try smallStudy();
        defer state.deinit(testing.allocator);
        state.phone_tab = .view3d;
        h.run(&state, c.s);
        try testing.expectEqual(c.l, state.layout);
        try testing.expect(state.viewport.max.x <= c.s.x + 0.5);
        try testing.expect(state.viewport.max.y <= c.s.y + 0.5);
        try testing.expect(state.viewport.width() >= 300);
        try testing.expect(state.viewport.height() >= 240);
        for ([_]struct { l: []const u8, t: layout.PhoneTab }{ .{ .l = "Study", .t = .study }, .{ .l = "Detections", .t = .detections }, .{ .l = "3D view", .t = .view3d }, .{ .l = "2D slice", .t = .slice } }) |tc| {
            try h.tap(&state, c.s, tc.l);
            try testing.expectEqual(tc.t, state.phone_tab);
        }
    }
}

test "portrait tab bar collapses and reopens the sheet" {
    const size = PHONE_SIZES[0];
    var h = Harness.init();
    defer h.deinit();
    var state = try smallStudy();
    defer state.deinit(testing.allocator);
    state.phone_tab = .slice;
    h.run(&state, size);
    try testing.expect(state.sheet_open);
    try h.tap(&state, size, "2D slice");
    try testing.expect(!state.sheet_open);
    try h.tap(&state, size, "3D view");
    try testing.expect(state.sheet_open);
    try testing.expectEqual(layout.PhoneTab.view3d, state.phone_tab);
}

test "phone focus and expanded views draw" {
    for (PHONE_SIZES) |size| {
        var h = Harness.init();
        defer h.deinit();
        var state = try smallStudy();
        defer state.deinit(testing.allocator);
        state.focus_volume = true;
        state.cutaway = true;
        h.run(&state, size);
        try testing.expect(state.viewport.height() >= 240);
        try h.tap(&state, size, "Adjust display");
        try testing.expect(state.focus_adjust_open);
        state.focus_volume = false;
        state.slice_expanded = true;
        h.run(&state, size);
    }
}

test "browser open buttons: Load sample instead of Open folder" {
    const size = Vec2{ .x = 1100, .y = 720 };
    var h = Harness.init();
    defer h.deinit();
    // First-use screen and the study sidebar both offer the browser actions.
    var empty = UiState.init(.{});
    defer empty.deinit(testing.allocator);
    empty.browser = true;
    empty.can_pick_folder = false;
    try h.assertFits("browser first use", &empty, size);
    try testing.expect(h.textCenter("Open folder\u{2026}") == null);
    try h.tap(&empty, size, "Load sample");
    try testing.expect(empty.actions.load_sample);
    try testing.expect(!empty.actions.pick_file);

    var state = try smallStudy();
    defer state.deinit(testing.allocator);
    state.browser = true;
    state.can_pick_folder = false;
    try h.assertFits("browser study", &state, size);
    try testing.expect(h.textCenter("Open folder\u{2026}") == null);
    try h.tap(&state, size, "Open file\u{2026}");
    try testing.expect(state.actions.pick_file);
    try h.tap(&state, size, "Load sample");
    try testing.expect(state.actions.load_sample);
}
