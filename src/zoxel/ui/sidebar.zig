//! The study panel: the open study, opening another, its details, its
//! volumes and its detections (port of roxel `ui/sidebar.rs`). Desktop stacks
//! the sections in the left sidebar; compact layouts show them as pages.

const std = @import("std");
const kit = @import("kit.zig");
const theme = @import("theme.zig");
const state_mod = @import("../state.zig");

const UiState = state_mod.UiState;
const Ui = kit.Ui;
const Ctx = kit.Ctx;
const Vec2 = kit.Vec2;
const Rect = kit.Rect;
const Color = kit.Color;
const Stroke = kit.Stroke;

pub const SIDEBAR_WIDTH: f32 = 232.0;

/// Why the slice-plane tools are disabled, in one short line.
pub const SLICE_TOOLS_NOTE = "Needs a single 2D slice of this volume";

/// Left sidebar: everything about the study, nothing about a view.
pub fn drawLeftSidebar(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    var p = kit.beginPanel(ctx, area, .left, "sidebar", theme.frame(), SIDEBAR_WIDTH);
    const ui = &p.ui;
    ui.wrap_labels = true;
    studySection(ui, state);
    theme.rule(ui);
    detailsSection(ui, state);
    if (state.library.volumes.items.len > 1) {
        theme.rule(ui);
        volumesSection(ui, state);
    }
    theme.rule(ui);
    detectionsSection(ui, state);
    kit.endPanel(ctx, area, &p);
}

/// The open study as the selected item, then the ways to open another.
pub fn studySection(ui: *Ui, state: *UiState) void {
    theme.section(ui, "Study");
    studyCard(ui, state);
    openButtons(ui, state, false);
    loadStatus(ui, state);
}

/// The open study, styled as the selected library item, with its whole name.
fn studyCard(ui: *Ui, state: *const UiState) void {
    const name = state.library.fileName() orelse return;
    var scope = ui.beginFrame("study_card", .{ .fill = Color.rgb(27, 47, 52), .rounding = 6, .inner_margin = .{ .left = 14, .right = 10, .top = 8, .bottom = 9 } });
    var inner = &scope.ui;
    inner.setMinWidth(inner.availableWidth());
    inner.spacing.item.y = 2;
    _ = theme.label(inner, "Open now", .{ .size = inner.text.small, .color = theme.ACCENT, .wrap = false });
    _ = theme.label(inner, name, .{ .color = theme.HEADING, .wrap = true });
    const card = ui.endFrame(&scope);
    // The accent edge marks the selection without relying on tint alone.
    ui.painter().rectFilledCorners(Rect.fromMinMax(card.min, .{ .x = card.min.x + 4, .y = card.max.y }), 6, theme.ACCENT, .{ .round_corners_top_left = true, .round_corners_bottom_left = true });
    const resp = ui.interact(card, ui.makeId("study_card_hover"), kit.Sense.hover);
    if (state.library.loaded_path) |path| ui.ctx.hoverText(resp, path);
}

/// "Open file…" and, where the platform can pick one, "Open folder…".
pub fn openButtons(ui: *Ui, state: *UiState, first_use: bool) void {
    const idle = state.loading_file == null;
    const compact = state.layout.isCompact();
    const saved = ui.enabled;
    defer ui.enabled = saved;
    if (!idle) ui.enabled = false;
    const height = @max(ui.spacing.interact_y, 30.0);
    const size = Vec2.v(ui.availableWidth(), if (first_use) 44.0 else height);
    const open_file = if (first_use)
        theme.button(ui, "Open file\u{2026}", .{ .sized = size, .text_color = theme.BG, .fill = theme.ACCENT, .stroke = Stroke.none }).clicked
    else
        theme.button(ui, "Open file\u{2026}", .{ .sized = size }).clicked;
    if (open_file) state.actions.pick_file = true;
    // Phone browsers cannot pick folders, so phone layouts leave it out.
    if (!compact and state.can_pick_folder) {
        if (theme.button(ui, "Open folder\u{2026}", .{ .sized = size }).clicked) state.actions.pick_folder = true;
    }
}

/// Loading spinner and the last load error, with what to try next.
pub fn loadStatus(ui: *Ui, state: *const UiState) void {
    if (state.loading_file) |name| {
        var row = ui.horizontal();
        theme.spinner(&row);
        _ = theme.label(&row, ui.ctx.fmt("Loading {s}\u{2026}", .{name}), .{ .wrap = true });
        ui.endChild(&row);
    }
    if (state.load_error) |err| {
        _ = theme.label(ui, err, .{ .color = theme.DANGER, .wrap = true });
        _ = theme.label(ui, "Choose a DICOS .dcs or .dcm file to try again.", .{ .size = ui.text.small, .color = theme.MUTED, .wrap = true });
    }
}

/// Dimensions, physical extent, modality and layer count of the 3D volume.
pub fn detailsSection(ui: *Ui, state: *const UiState) void {
    theme.section(ui, "Details");
    const idx = state.library.active_3d_index orelse 0;
    if (idx >= state.library.volumes.items.len) return;
    const vol = &state.library.volumes.items[idx].volume;
    // egui `ui.scope`: a child with tight spacing, then the parent's.
    var scope = ui.child(kit.Layout.top_down);
    defer ui.endChild(&scope);
    const inner = &scope;
    inner.spacing.item.y = 2;
    const ctx = ui.ctx;
    theme.keyValue(inner, "Voxels", ctx.fmt("{d} \u{d7} {d} \u{d7} {d}", .{ vol.dim_x, vol.dim_y, vol.dim_z }));
    theme.keyValue(inner, "Extent", ctx.fmt("{d:.0} \u{d7} {d:.0} \u{d7} {d:.0} mm", .{
        @as(f64, @floatFromInt(vol.dim_x)) * vol.voxel_spacing[0],
        @as(f64, @floatFromInt(vol.dim_y)) * vol.voxel_spacing[1],
        @as(f64, @floatFromInt(vol.dim_z)) * vol.voxel_spacing[2],
    }));
    theme.keyValue(inner, "Modality", vol.modality);
    theme.keyValue(inner, "Volumes", ctx.fmt("{d}", .{state.library.volumes.items.len}));
}

/// Show layer `index` in both the 3D view and the 2D slice.
pub fn selectVolume(state: *UiState, index: usize) void {
    state.actions.upload_3d_index = index;
    showVolumeInSlice(state, index);
}

/// Show layer `index` in the 2D slice only.
pub fn showVolumeInSlice(state: *UiState, index: usize) void {
    const layer = state.library.get(index) orelse return;
    state.slice_view.volume_index = index;
    state.slice_view.updateForVolume(&layer.volume);
    state.slice_view.window_center = @floatCast(layer.volume.window_center);
    state.slice_view.window_width = @floatCast(layer.volume.window_width);
    state.library.selected_threat = null;
    state.slice_dirty = true;
}

/// Layer picker; selecting a layer shows it in both 3D and 2D.
pub fn volumesSection(ui: *Ui, state: *UiState) void {
    theme.section(ui, "Volumes");
    const active = state.library.active_3d_index orelse 0;
    const h = ui.spacing.interact_y;
    for (state.library.volumes.items, 0..) |layer, i| {
        const is_active = i == active;
        const r = theme.button(ui, layer.name, .{
            .sized = .{ .x = ui.availableWidth(), .y = h },
            .fill = if (is_active) theme.SELECTED else Color.transparent,
            .stroke = if (is_active) Stroke.init(1, theme.ACCENT) else Stroke.none,
            .id_salt = ui.ctx.fmt("layer{d}", .{i}),
        });
        if (r.clicked and !is_active) selectVolume(state, i);
    }
}

/// Number of detections on the volume shown in 2D (for the tab badge).
pub fn detectionCount(state: *const UiState) usize {
    const i = state.slice_view.volume_index;
    if (i >= state.library.volumes.items.len) return 0;
    return state.library.volumes.items[i].volume.threats.items.len;
}

fn detectionsVolume(state: *const UiState) ?usize {
    const n = state.library.volumes.items.len;
    if (n == 0) return null;
    return @min(state.slice_view.volume_index, n - 1);
}

pub fn detectionsSection(ui: *Ui, state: *UiState) void {
    if (detectionsSummary(ui, state)) detectionsList(ui, state);
}

/// Heading with the count, then either the sentence saying no report was
/// loaded or the controls that act on every detection.
pub fn detectionsSummary(ui: *Ui, state: *UiState) bool {
    const index = detectionsVolume(state) orelse return false;
    const threats = &state.library.volumes.items[index].volume.threats;
    const count = threats.items.len;
    theme.sectionWithNote(ui, "Detections", if (count > 0) ui.ctx.fmt("{d} reported", .{count}) else "");
    if (count == 0) {
        // Says what is missing; never that the scan is clear.
        _ = theme.label(ui, "No threat report was loaded with this study.", .{ .wrap = true });
        return false;
    }
    if (theme.checkbox(ui, &state.library.show_threats, "Show detection boxes").changed) state.slice_dirty = true;
    const selected: ?usize = if (state.library.selected_threat) |s| (if (s < count) s else null) else null;
    if (theme.buttonRow(ui, &.{ "Show all", "Hide all" })) |b| {
        for (threats.items) |*t| t.enabled = b == 0;
        state.slice_dirty = true;
    }
    // Always present so the list never jumps; it needs a selection.
    const only = theme.button(ui, "Show only the selected one", .{ .sized = .{ .x = ui.availableWidth(), .y = ui.spacing.interact_y }, .enabled = selected != null });
    if (only.clicked) if (selected) |sel| {
        for (threats.items, 0..) |*t, i| t.enabled = i == sel;
        state.slice_dirty = true;
    };
    return true;
}

/// One row per detection: a box to show or hide it; the row selects it.
pub fn detectionsList(ui: *Ui, state: *UiState) void {
    const index = detectionsVolume(state) orelse return;
    const threats = &state.library.volumes.items[index].volume.threats;
    var selected: ?usize = if (state.library.selected_threat) |s| (if (s < threats.items.len) s else null) else null;
    var changed = false;
    for (threats.items, 0..) |*t, i| {
        var row = ui.horizontal();
        const name = ui.ctx.fmt("Show {s}#{d}", .{ t.name, i });
        const cb = theme.checkboxNamed(&row, &t.enabled, "", name);
        ui.ctx.hoverText(cb, "Show this detection");
        if (cb.changed) changed = true;
        if (detectionRow(&row, t, i, selected != null and selected.? == i)) selected = i;
        ui.endChild(&row);
    }
    state.library.selected_threat = selected;
    if (changed) state.slice_dirty = true;
}

/// A detection as a selectable row: swatch, name, confidence percentage.
fn detectionRow(ui: *Ui, t: *const @import("../volume.zig").ThreatBox, i: usize, selected: bool) bool {
    const h = @max(ui.spacing.interact_y, 28.0);
    const resp = ui.allocateResponse(.{ .x = ui.availableWidth(), .y = h }, ui.makeId(ui.ctx.fmt("det{d}", .{i})), kit.Sense.clickable);
    const r = resp.rect;
    const p = ui.painter();
    if (selected) {
        p.rect(r, 5, theme.SELECTED, Stroke.init(1, theme.ACCENT));
    } else if (resp.hovered) {
        p.rectFilled(r, 5, theme.FILL_HOVERED);
    }
    p.rectFilled(Rect.fromCenterSize(.{ .x = r.min.x + 14, .y = r.center().y }, .{ .x = 10, .y = 10 }), 2, Color.rgb(t.color[0], t.color[1], t.color[2]));
    const size = ui.text.body;
    var right = r.max.x - 8;
    if (t.confidence) |c| {
        const shown = p.text(.{ .x = right, .y = r.center().y }, kit.Align2.right_center, ui.ctx.fmt("{d:.0}%", .{c * 100}), size, theme.MUTED);
        right = shown.min.x - 8;
    }
    const left = r.min.x + 28;
    const name = theme.elideMiddle(ui.ctx, t.name, size, right - left);
    _ = p.text(.{ .x = left, .y = r.center().y }, kit.Align2.left_center, name, size, if (selected) theme.HEADING else theme.TEXT);
    ui.ctx.hoverText(resp, t.name);
    return resp.clicked;
}

/// The slice plane and cutaway apply only to one slice of the 3D volume.
pub fn sliceToolsAvailable(state: *const UiState) bool {
    return !state.slice_view.composite and state.library.active_3d_index != null and state.library.active_3d_index.? == state.slice_view.volume_index;
}
