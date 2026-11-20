//! The interface (port of roxel `ui/mod.rs`).
//!
//! Desktop: the study sidebar (left), the 3D view's header and controls
//! shelf (centre), and the 2D slice panel (right). Phone portrait/landscape:
//! the same content behind a bottom tab bar (`phone.zig`). "Focus volume"
//! and "Focus slice" are one pattern: the view takes the workspace in place,
//! keeps its controls, and "Exit focus" (or Escape) returns.

const std = @import("std");
const kit = @import("kit.zig");
const theme = @import("theme.zig");
const layout_mod = @import("layout.zig");
const sidebar = @import("sidebar.zig");
const controls = @import("controls.zig");
const slice_panel = @import("slice_panel.zig");
const phone = @import("phone.zig");
const state_mod = @import("../state.zig");
const camera_mod = @import("../camera.zig");

const UiState = state_mod.UiState;
const Ctx = kit.Ctx;
const Ui = kit.Ui;
const Vec2 = kit.Vec2;
const Rect = kit.Rect;
const Color = kit.Color;
const Stroke = kit.Stroke;

pub const Layout = layout_mod.Layout;

/// Narrowest the 3D view's column may get before the 2D panel stops growing.
const CENTER_MIN_WIDTH: f32 = 532.0;

/// How to drive the view on screen, shown once in the desktop status bar.
fn navigationText(state: *const UiState, touch: bool) []const u8 {
    if (state.slice_expanded) {
        return if (touch) "Drag to pan  \u{b7}  Pinch to zoom" else "Drag to pan  \u{b7}  Ctrl + scroll to zoom  \u{b7}  Esc to exit focus";
    }
    if (touch) return "Drag to orbit  \u{b7}  Pinch to zoom  \u{b7}  Two fingers to pan";
    if (state.focus_volume) return "Drag to orbit  \u{b7}  Shift + drag to pan  \u{b7}  Scroll to zoom  \u{b7}  Esc to exit focus";
    return "Drag to orbit  \u{b7}  Shift + drag to pan  \u{b7}  Scroll to zoom";
}

/// Draw the full UI for the current window size.
pub fn drawUi(ctx: *Ctx, state: *UiState) void {
    const lay = Layout.fromSize(ctx.screen.width(), ctx.screen.height());
    if (lay != state.layout) state.layout = lay;
    theme.setLayout(ctx, lay);
    const focus_before = state.focus_volume;
    // Escape leaves focus, unless a popup or a text field wants the key.
    if ((state.focus_volume or state.slice_expanded) and !ctx.popupOpen() and !ctx.wantsKeyboard() and ctx.input.keyPressed(.escape)) {
        if (state.slice_expanded) state.slice_expanded = false else state.focus_volume = false;
        state.fit_camera = true;
        ctx.input.keys_pressed.remove(.escape);
    }
    var area = kit.PanelArea{ .rect = ctx.screen };
    if (lay == .desktop) {
        drawDesktopPanels(ctx, &area, state);
    } else {
        phone.draw(ctx, &area, state);
    }
    // The central area left by the panels: the 3D view renders there.
    const next = area.rect;
    if (state.viewport.width() != next.width() or state.viewport.height() != next.height()) state.fit_camera = true;
    state.viewport = next;
    if (state.focus_volume != focus_before) ctx.wants_repaint = true;
    if (state.volumeVisible()) {
        drawSlicePlane(ctx, state);
        drawOrientationGizmo(ctx, state);
    } else if (state.library.isEmpty() and !state.slice_expanded) {
        drawEmptyState(ctx, &area, state);
    }
}

/// App bar: mark, name, and the open study with both ends of its name kept.
pub fn appBar(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    const compact = state.layout.isCompact();
    var p = kit.beginPanel(ctx, area, .top, "app_bar", .{ .fill = theme.PANEL, .inner_margin = kit.Margin.symmetric(16, if (compact) 6 else 8) }, null);
    const ui = &p.ui;
    ui.spacing.interact_y = 28;
    var row = ui.horizontal();
    theme.mark(&row, if (compact) 22.0 else 24.0);
    _ = theme.label(&row, "zoxel", .{ .size = if (compact) 19.0 else 21.0, .color = theme.HEADING, .wrap = false });
    if (state.library.fileName()) |name| {
        var rtl = row.rightToLeft();
        const room = std.math.clamp(rtl.availableWidth() - 16.0, 40.0, 520.0);
        const shown = theme.elideMiddle(ctx, name, 13.0, room);
        const resp = theme.label(&rtl, shown, .{ .size = 13.0, .color = theme.MUTED, .wrap = false });
        if (state.library.loaded_path) |path| ctx.hoverText(resp, path);
        row.endChildFull(&rtl);
    }
    ui.endChild(&row);
    kit.endPanel(ctx, area, &p);
}

/// Width of the 2D panel: about a third of the window, never at the cost of
/// the 3D view's column.
pub fn slicePanelWidth(window: f32) f32 {
    const most = @max(window - sidebar.SIDEBAR_WIDTH - CENTER_MIN_WIDTH, 336.0);
    return std.math.clamp(window * 0.36, 336.0, @min(most, 520.0));
}

fn drawDesktopPanels(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    appBar(ctx, area, state);
    const loaded = !state.library.isEmpty();
    if (!loaded and !state.slice_expanded) return; // First use: the card is the interface.
    const touch = ctx.input.has_touch;
    var status = kit.beginPanel(ctx, area, .bottom, "status_bar", .{ .fill = theme.BG, .inner_margin = kit.Margin.symmetric(16, 5) }, null);
    _ = theme.label(&status.ui, navigationText(state, touch), .{ .size = 12.0, .color = theme.MUTED, .wrap = false });
    kit.endPanel(ctx, area, &status);
    if (state.slice_expanded) {
        slice_panel.drawFocus(ctx, area, state);
        return;
    }
    if (!state.focus_volume) {
        sidebar.drawLeftSidebar(ctx, area, state);
        slice_panel.drawRightPanel(ctx, area, state, slicePanelWidth(ctx.screen.width()));
    }
    controls.drawVolumeHeader(ctx, area, state);
    controls.drawShelf(ctx, area, state);
}

/// X / Y / Z axes in the view's lower-left corner.
fn drawOrientationGizmo(ctx: *Ctx, state: *const UiState) void {
    const rect = state.viewport;
    if (rect.width() < 120 or rect.height() < 120) return;
    const p = ctx.painter(rect, 1);
    const origin = rect.leftBottom().add(.{ .x = 40, .y = -40 });
    const axes = [_]struct { a: camera_mod.Vec3, l: []const u8, c: Color }{
        .{ .a = camera_mod.Vec3.unit_x, .l = "X", .c = Color.rgb(231, 145, 135) },
        .{ .a = camera_mod.Vec3.unit_y, .l = "Y", .c = theme.ACCENT },
        .{ .a = camera_mod.Vec3.unit_z, .l = "Z", .c = Color.rgb(143, 177, 225) },
    };
    for (axes) |ax| {
        // As in roxel (and the ray shader), camera "up" maps to screen +y.
        const dir = Vec2.v(ax.a.dot(state.camera.right()), ax.a.dot(state.camera.up()));
        const end = origin.add(dir.scale(20));
        p.line(origin, end, Stroke.init(1.5, ax.c));
        const out = if (dir.length() > 0.05) dir.normalized() else Vec2.v(0, -1);
        _ = p.text(origin.add(out.scale(@max(dir.length() * 20 + 9, 17))), kit.Align2.center_center, ax.l, 12.0, ax.c);
    }
}

/// First-use state: say what this is and offer the one action.
fn drawEmptyState(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    const lay = state.layout;
    var ui = kit.centralPanel(ctx, area, "empty", .{ .fill = theme.BG, .inner_margin = kit.Margin.same(24) });
    if (lay == .phone_landscape) {
        ui.addSpace(@max((ui.availableHeight() - 190) * 0.5, 4));
        ui.spacing.item.x = 8;
        var cols = ui.columns(2);
        cols[0].layout = kit.Layout.topDown(.center);
        emptyIntro(&cols[0], true);
        cols[1].layout = kit.Layout.topDown(.center);
        const w = @min(cols[1].availableWidth(), 320);
        var inner = cols[1].childSized(.{ .x = w, .y = cols[1].availableHeight() }, kit.Layout.topDown(.center));
        inner.max_rect = Rect.fromMinSize(.{ .x = cols[1].max_rect.center().x - w * 0.5, .y = inner.max_rect.min.y }, .{ .x = w, .y = inner.max_rect.height() });
        inner.cursor = inner.max_rect;
        inner.min_rect = Rect.fromMinSize(inner.max_rect.min, .{});
        inner.addSpace(30);
        emptyActions(&inner, state);
        cols[1].endChild(&inner);
        ui.endColumns(&cols);
        return;
    }
    const compact = lay.isCompact();
    const w = @min(ui.availableWidth(), @as(f32, if (compact) 340.0 else 280.0));
    var col = ui.childAt(Rect.fromMinSize(.{ .x = ui.max_rect.center().x - w * 0.5, .y = ui.max_rect.min.y }, .{ .x = w, .y = ui.availableHeight() }), kit.Layout.topDown(.center));
    col.addSpace(@max(col.availableHeight() * (if (compact) @as(f32, 0.2) else 0.26), 16));
    emptyIntro(&col, compact);
    col.addSpace(20);
    emptyActions(&col, state);
}

fn emptyIntro(ui: *Ui, compact: bool) void {
    theme.mark(ui, if (compact) 56.0 else 64.0);
    ui.addSpace(12);
    _ = theme.label(ui, "Open a DICOS study", .{ .size = 22.0, .color = theme.HEADING, .wrap = false });
    ui.addSpace(4);
    centeredWrapped(ui, "See a CT scan as a 3D volume and as 2D slices.", ui.text.body, theme.MUTED);
}

/// A wrapped label whose lines centre in a centred column.
fn centeredWrapped(ui: *Ui, text: []const u8, size: f32, color: Color) void {
    const wrap = ui.availableWidth();
    const sz = kit.measureWrapped(ui.ctx, text, size, wrap);
    const r = ui.allocate(sz);
    const p = ui.painter();
    var y = r.min.y;
    var rest = text;
    const row_h = ui.ctx.rowHeight(size, .proportional);
    while (rest.len > 0) {
        const n = kit.wrapPrefix(ui.ctx, rest, size, wrap);
        const line = std.mem.trimRight(u8, rest[0..n], " ");
        const lw = ui.ctx.measure(line, size, .proportional, 0).size.x;
        p.textAt(.{ .x = r.center().x - lw * 0.5, .y = y }, line, size, .proportional, color);
        rest = std.mem.trimLeft(u8, rest[n..], " ");
        y += row_h;
    }
}

/// The open actions, load progress and accepted formats.
fn emptyActions(ui: *Ui, state: *UiState) void {
    // The buttons fill the column width.
    ui.layout.cross = .min;
    sidebar.openButtons(ui, state, true);
    ui.addSpace(4);
    sidebar.loadStatus(ui, state);
    ui.layout.cross = .center;
    const text = if (state.layout.isCompact()) "DICOS .dcs or .dcm files." else "DICOS .dcs or .dcm files, or a study folder.";
    centeredWrapped(ui, text, ui.text.small, theme.MUTED);
}

/// Outline the selected slice in the 3D view (projected with the shader's
/// camera model) and name it in the view's corner, off the object.
fn drawSlicePlane(ctx: *Ctx, state: *const UiState) void {
    if (!sidebar.sliceToolsAvailable(state) or !(state.show_slice_locator or state.cutaway)) return;
    const layer = if (state.slice_view.volume_index < state.library.volumes.items.len) &state.library.volumes.items[state.slice_view.volume_index] else return;
    const rect = state.viewport;
    const p = ctx.painter(rect, 1);
    const stroke = Stroke.init(1.0, theme.ACCENT.gammaMultiply(0.7));
    if (state.show_slice_locator) {
        const cam = state.camera;
        const aspect = rect.width() / @max(rect.height(), 1);
        var pts: [4]Vec2 = undefined;
        var ok = true;
        for (state.slice_view.planeCorners(&layer.volume), 0..) |corner, i| {
            const delta = camera_mod.Vec3.fromArray(corner).mul(state.volume_extent).sub(cam.position());
            const depth = delta.dot(cam.forward());
            if (depth <= 0) {
                ok = false;
                break;
            }
            const uv = Vec2.v(delta.dot(cam.right()) / (depth * cam.fov * aspect), delta.dot(cam.up()) / (depth * cam.fov));
            // egui maps uv with +y down here, matching the ray shader's
            // flipped screen-space v.
            pts[i] = rect.center().add(Vec2.v(uv.x * rect.width() * 0.5, uv.y * rect.height() * 0.5));
        }
        if (ok) {
            for (0..4) |i| p.line(pts[i], pts[(i + 1) % 4], stroke);
        }
    }
    const what = if (!state.cutaway) "Slice plane" else if (!state.reverse_cutaway) "Cutaway" else "Cutaway, reversed";
    const text = ctx.fmt("{s}  \u{b7}  {s} {d} / {d}", .{ what, state.slice_view.orientation.label(), state.slice_view.slice_index + 1, state.slice_view.max_slices });
    const g = ctx.measure(text, 12.5, .proportional, 0).size;
    const pos = rect.rightBottom().sub(g).sub(.{ .x = 16, .y = 14 });
    if (state.show_slice_locator) {
        const y = pos.y + g.y * 0.5;
        p.line(.{ .x = pos.x - 26, .y = y }, .{ .x = pos.x - 8, .y = y }, Stroke.init(1.5, theme.ACCENT));
    }
    p.textAt(pos, text, 12.5, .proportional, theme.ACCENT);
}
