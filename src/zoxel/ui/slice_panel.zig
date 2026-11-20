//! The 2D slice: its image well and its controls (port of roxel
//! `ui/slice_panel.rs`). Desktop docks it as the right panel; "Focus slice"
//! gives it the workspace; compact layouts page its controls in a sheet.

const std = @import("std");
const zgui = @import("zgui");
const kit = @import("kit.zig");
const theme = @import("theme.zig");
const sidebar = @import("sidebar.zig");
const controls = @import("controls.zig");
const layout_mod = @import("layout.zig");
const state_mod = @import("../state.zig");
const slice_view = @import("../slice_view.zig");

const UiState = state_mod.UiState;
const Ui = kit.Ui;
const Ctx = kit.Ctx;
const Vec2 = kit.Vec2;
const Rect = kit.Rect;
const Color = kit.Color;
const Stroke = kit.Stroke;
const SliderSpec = theme.SliderSpec;

/// Strip under the image for the scale bar and caption.
const FOOTER_HEIGHT: f32 = 30.0;
/// How much larger a slice must get on its side before it is turned.
const TURN_GAIN: f32 = 1.25;
/// Height of the desktop controls under the well (three headed groups).
const DESKTOP_CONTROLS_HEIGHT: f32 = 326.0;

/// The slice texture, set by the app each frame (ImGui texture id).
pub var slice_texture: ?u64 = null;
/// Physical pixels per slice texel at the current display size (largest
/// well drawn this frame); the app uploads the slice at a matching scale.
pub var slice_display_scale: f32 = 1.0;

pub fn setOrientation(state: *UiState, o: slice_view.Orientation) void {
    if (state.slice_view.orientation == o) return;
    state.slice_view.orientation = o;
    if (state.library.get(state.slice_view.volume_index)) |layer| state.slice_view.updateForVolume(&layer.volume);
    state.slice_dirty = true;
}

/// "Focus slice" / "Exit focus": the 2D slice takes the workspace.
pub fn focusSliceButton(ui: *Ui, state: *UiState) void {
    const r = theme.iconButton(ui, if (state.slice_expanded) .reduce else .enlarge, if (state.slice_expanded) "Exit focus" else "Focus slice");
    ui.ctx.hoverText(r, if (state.slice_expanded) "Back to the workspace (Esc)" else "Enlarge the 2D slice to fill the workspace");
    if (r.clicked) {
        state.slice_expanded = !state.slice_expanded;
        state.fit_camera = true;
    }
}

fn planePicker(ui: *Ui, state: *UiState) void {
    const labels = [_][]const u8{ "Axial", "Coronal", "Sagittal" };
    if (theme.segmented(ui, "plane2d", state.slice_view.orientation.index(), &labels)) |i| {
        setOrientation(state, slice_view.Orientation.all[i]);
    }
}

/// Slice position row; inert while a composite projection is shown.
fn sliceRow(ui: *Ui, state: *UiState) void {
    const scrubbable = !state.slice_view.composite and state.slice_view.max_slices > 1;
    const saved = ui.enabled;
    if (!scrubbable) ui.enabled = false;
    if (theme.sliceSlider(ui, &state.slice_view.slice_index, state.slice_view.max_slices)) state.slice_dirty = true;
    ui.enabled = saved;
}

fn compositeToggle(ui: *Ui, state: *UiState) void {
    const r = theme.checkbox(ui, &state.slice_view.composite, "Composite projection");
    ui.ctx.hoverText(r, "Blend every slice along this plane into one image");
    if (r.changed) state.slice_dirty = true;
}

fn zoomRow(ui: *Ui, state: *UiState) void {
    _ = theme.sliderF32(ui, SliderSpec.whole("Zoom", 50, 500, 25).withUnit("%"), &state.slice_view.zoom);
}

fn windowingGroup(ui: *Ui, state: *UiState) void {
    const ranges = controls.windowRangesFor(state, state.slice_view.volume_index);
    theme.sectionWithNote(ui, "2D windowing", "stored values");
    // Re-rendering is CPU work: wait for the change to be committed.
    if (theme.windowRows(ui, &state.slice_view.window_center, &state.slice_view.window_width, ranges)) state.slice_dirty = true;
}

fn volumePicker(ui: *Ui, state: *UiState) void {
    var names: [64][]const u8 = undefined;
    const n = @min(state.library.volumes.items.len, names.len);
    for (state.library.volumes.items[0..n], 0..) |l, i| names[i] = l.name;
    const sel = state.slice_view.volume_index;
    const shown = if (sel < n) names[sel] else "None";
    const w = std.math.clamp(ui.availableWidth() - 8, 120, 280);
    if (theme.comboBox(ui, "slice_volume", shown, names[0..n], sel, w)) |i| sidebar.showVolumeInSlice(state, i);
}

// ---------------------------------------------------------------------------
// The image well
// ---------------------------------------------------------------------------

/// The slice in a black well. Fitted at 100% and panned inside the well when
/// zoomed; a footer strip carries the scale bar and caption. With
/// `turn_to_fit`, a slice clearly larger on its side is drawn turned.
pub fn imageWell(ui: *Ui, state: *UiState, size: Vec2, turn_to_fit: bool) void {
    const ctx = ui.ctx;
    const rect = ui.allocate(size);
    const p = ui.painter();
    p.rectFilled(rect, 6, theme.WELL);
    const area = Rect.fromMinMax(rect.min, .{ .x = rect.max.x, .y = rect.max.y - FOOTER_HEIGHT }).shrink(1);
    const footer = Rect.fromMinMax(.{ .x = rect.min.x, .y = rect.max.y - FOOTER_HEIGHT }, rect.max);
    const layer = state.library.get(state.slice_view.volume_index);
    const tex_size = state.slice_texture_size orelse {
        _ = p.text(rect.center(), kit.Align2.center_center, if (layer != null) "Preparing slice\u{2026}" else "No study open", 14, theme.MUTED);
        return;
    };
    const physical: slice_view.Size2 = if (layer) |l| state.slice_view.physicalSliceSize(&l.volume) else .{ .x = @floatFromInt(tex_size[0]), .y = @floatFromInt(tex_size[1]) };
    const fitWithin = struct {
        fn f(a: Rect, x: f32, y: f32) f32 {
            return @min(a.width() / @max(x, 1), a.height() / @max(y, 1));
        }
    }.f;
    const upright = fitWithin(area, physical.x, physical.y);
    const on_side = fitWithin(area, physical.y, physical.x);
    const turned = turn_to_fit and on_side >= upright * TURN_GAIN;
    const fit = if (turned) on_side else upright;

    // Pinch (or Ctrl + scroll) zooms the image.
    if (ctx.input.pointer) |pt| if (area.contains(pt) and ctx.input.zoom_delta != 1.0) {
        state.slice_view.zoom = std.math.clamp(state.slice_view.zoom * ctx.input.zoom_delta, 50, 500);
    };
    const scale = fit * state.slice_view.zoom / 100.0;
    const shown = if (turned) Vec2.v(physical.y * scale, physical.x * scale) else Vec2.v(physical.x * scale, physical.y * scale);

    // A both-ways scroll area: drag or scroll to pan a zoomed image.
    const sid = ui.makeId("slice_pan");
    var ox = ctx.getMem(sid) orelse 0;
    var oy = ctx.getMem(sid ^ 1) orelse 0;
    const max_x = @max(shown.x - area.width(), 0);
    const max_y = @max(shown.y - area.height(), 0);
    const pan = ctx.interact(sid, area, ui.clip, kit.Sense.draggable, ui.enabled);
    if (pan.dragged) {
        ox -= pan.drag_delta.x;
        oy -= pan.drag_delta.y;
    }
    if (pan.hovered and ctx.input.zoom_delta == 1.0) {
        ox -= ctx.input.scroll.x;
        oy -= ctx.input.scroll.y;
    }
    ox = std.math.clamp(ox, 0, max_x);
    oy = std.math.clamp(oy, 0, max_y);
    ctx.setMem(sid, ox);
    ctx.setMem(sid ^ 1, oy);
    const origin = Vec2.v(area.min.x + @max((area.width() - shown.x) * 0.5, 0) - ox, area.min.y + @max((area.height() - shown.y) * 0.5, 0) - oy);
    const img = Rect.fromMinSize(origin, shown);
    const texels_wide: f32 = @floatFromInt(if (turned) tex_size[1] else tex_size[0]);
    slice_display_scale = shown.x * ctx.pixels_per_point / @max(texels_wide, 1);
    const wp = p.withClip(area);
    if (slice_texture) |tex| {
        if (turned) {
            // Screen corner <- image corner: the image's left edge on top.
            wp.imageQuad(tex, .{ img.leftTop(), img.rightTop(), img.rightBottom(), img.leftBottom() }, .{ Vec2.v(0, 1), Vec2.v(0, 0), Vec2.v(1, 0), Vec2.v(1, 1) });
        } else {
            wp.image(tex, img, Vec2.v(0, 0), Vec2.v(1, 1));
        }
    }

    // Footer: scale bar on the left, caption on the right.
    const fp = p.withClip(footer);
    fp.hline(footer.min.x, footer.max.x, footer.min.y, Stroke.init(1, Color.gray(48)));
    const font: f32 = 12.0;
    var left = footer.min.x + 12;
    if (layer != null and std.math.isFinite(scale) and scale > 0) {
        const bar = scaleBarLength(scale, 72);
        const y = footer.center().y;
        const s = Stroke.init(1.5, Color.white);
        fp.line(.{ .x = left, .y = y }, .{ .x = left + bar.px, .y = y }, s);
        for ([_]f32{ left, left + bar.px }) |x| fp.line(.{ .x = x, .y = y - 4 }, .{ .x = x, .y = y + 4 }, s);
        const lr = fp.text(.{ .x = left + bar.px + 8, .y = y }, kit.Align2.left_center, ctx.fmt("{d} mm", .{bar.mm}), font, Color.white);
        left = lr.max.x + 16;
    }
    const plane = state.slice_view.orientation.label();
    const position = if (state.slice_view.composite) ctx.fmt("{s} projection", .{plane}) else ctx.fmt("{s} {d} / {d}", .{ plane, state.slice_view.slice_index + 1, state.slice_view.max_slices });
    const extent = if (turned) "turned 90\u{b0}" else ctx.fmt("{d:.0} \u{d7} {d:.0} mm", .{ physical.x, physical.y });
    const room = footer.max.x - 12 - left;
    for ([_][]const u8{ ctx.fmt("{s}  \u{b7}  {s}", .{ position, extent }), position }) |caption| {
        const g = ctx.measure(caption, font, .proportional, 0).size;
        if (g.x <= room) {
            fp.textAt(.{ .x = footer.max.x - 12 - g.x, .y = footer.center().y - g.y * 0.5 }, caption, font, .proportional, theme.MUTED);
            break;
        }
    }
}

pub const ScaleBar = struct { mm: f32, px: f32 };

/// A round length (1, 2 or 5 x 10^n mm) whose bar is at most `max_px` wide.
pub fn scaleBarLength(pixels_per_mm: f32, max_px: f32) ScaleBar {
    const target = max_px / pixels_per_mm;
    const base = std.math.pow(f32, 10, @floor(std.math.log10(target)));
    var mm = base;
    for ([_]f32{ 5, 2, 1 }) |n| {
        if (n * base <= target) {
            mm = n * base;
            break;
        }
    }
    return .{ .mm = mm, .px = mm * pixels_per_mm };
}

/// Tallest a fitted slice can be at this width over the three planes, so
/// switching planes never moves the controls.
fn tallestFit(state: *UiState, width: f32) f32 {
    const layer = state.library.get(state.slice_view.volume_index) orelse return width * 0.6;
    var probe = slice_view.SliceView{};
    var best: f32 = 0;
    for (slice_view.Orientation.all) |o| {
        probe.orientation = o;
        const s = probe.physicalSliceSize(&layer.volume);
        best = @max(best, width / @max(s.x, 1) * s.y);
    }
    return best;
}

// ---------------------------------------------------------------------------
// Desktop
// ---------------------------------------------------------------------------

fn sliceHeader(ui: *Ui, state: *UiState) void {
    var row = ui.horizontal();
    _ = theme.title(&row, "2D slice");
    var rtl = row.rightToLeft();
    focusSliceButton(&rtl, state);
    const fit = theme.button(&rtl, "Fit image", .{});
    ui.ctx.hoverText(fit, "Show the whole slice");
    if (fit.clicked) state.slice_view.zoom = 100;
    row.endChildFull(&rtl);
    ui.endChild(&row);
}

/// "Previous" / "Next" under the slice track.
fn pager(ui: *Ui, state: *UiState) void {
    const scrubbable = !state.slice_view.composite and state.slice_view.max_slices > 1;
    const saved = ui.enabled;
    if (!scrubbable) ui.enabled = false;
    var row = ui.horizontal();
    // Start where the slice rail starts (the track is inset by its thumb).
    row.addSpace(theme.LABEL_W + 7);
    const index = state.slice_view.slice_index;
    const prev = theme.button(&row, "Previous", .{ .enabled = index > 0 });
    ui.ctx.hoverText(prev, "Previous slice");
    if (prev.clicked) {
        state.slice_view.slice_index -= 1;
        state.slice_dirty = true;
    }
    const next = theme.button(&row, "Next", .{ .enabled = index + 1 < state.slice_view.max_slices });
    ui.ctx.hoverText(next, "Next slice");
    if (next.clicked) {
        state.slice_view.slice_index += 1;
        state.slice_dirty = true;
    }
    ui.endChild(&row);
    ui.enabled = saved;
}

fn sliceGroup(ui: *Ui, state: *UiState) void {
    theme.section(ui, "Slice");
    planePicker(ui, state);
    sliceRow(ui, state);
    pager(ui, state);
}

fn imageGroup(ui: *Ui, state: *UiState) void {
    theme.section(ui, "Image");
    zoomRow(ui, state);
    if (state.library.volumes.items.len > 1) {
        var row = ui.horizontal();
        theme.rowLabel(&row, "Volume");
        volumePicker(&row, state);
        ui.endChild(&row);
    }
    compositeToggle(ui, state);
}

/// Right panel: the slice in its well, then its three control groups.
pub fn drawRightPanel(ctx: *Ctx, area: *kit.PanelArea, state: *UiState, width: f32) void {
    var p = kit.beginPanel(ctx, area, .right, "slice_panel", theme.frame(), width);
    const ui = &p.ui;
    ui.spacing.item.y = 6;
    sliceHeader(ui, state);
    ui.addSpace(2);
    const w = ui.availableWidth();
    const extra: f32 = if (state.library.volumes.items.len > 1) 30 else 0;
    const room = ui.availableHeight() - DESKTOP_CONTROLS_HEIGHT - extra;
    const tallest = tallestFit(state, w) + FOOTER_HEIGHT + 2;
    const h = @max(@min(room, tallest), 140);
    imageWell(ui, state, .{ .x = w, .y = h }, false);
    ui.addSpace(4);
    sliceGroup(ui, state);
    ui.addSpace(4);
    windowingGroup(ui, state);
    ui.addSpace(4);
    imageGroup(ui, state);
    kit.endPanel(ctx, area, &p);
}

/// Focus slice on desktop: the well takes the workspace; the same three
/// groups dock below it side by side.
pub fn drawFocus(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    var hf = theme.frame();
    hf.inner_margin = kit.Margin.symmetric(16, 10);
    var header = kit.beginPanel(ctx, area, .top, "slice_header", hf, null);
    sliceHeader(&header.ui, state);
    kit.endPanel(ctx, area, &header);

    var df = theme.frame();
    df.inner_margin = kit.Margin.symmetric(16, 12);
    var dock = kit.beginPanel(ctx, area, .bottom, "slice_dock", df, null);
    {
        const ui = &dock.ui;
        const width = @min(ui.availableWidth(), 1440);
        const pad = (ui.availableWidth() - width) * 0.5;
        var body = ui.childAt(Rect.fromMinSize(.{ .x = ui.max_rect.min.x + pad, .y = ui.cursor.min.y }, .{ .x = width, .y = ui.availableHeight() }), kit.Layout.top_down);
        body.spacing.item.x = 24;
        var cols = body.columns(3);
        for (&cols) |*c| c.spacing.item = Vec2.v(8, 6);
        sliceGroup(&cols[0], state);
        windowingGroup(&cols[1], state);
        imageGroup(&cols[2], state);
        body.endColumns(&cols);
        ui.endChild(&body);
    }
    kit.endPanel(ctx, area, &dock);

    var central = kit.centralPanel(ctx, area, "slice_focus", .{ .fill = theme.PANEL, .inner_margin = .{ .left = 16, .right = 16 } });
    imageWell(&central, state, central.availableRect().size(), false);
    area.rect = Rect.fromMinSize(area.rect.min, .{});
}

// ---------------------------------------------------------------------------
// Compact layouts: pages of the 2D controls sheet
// ---------------------------------------------------------------------------

pub fn sliceSheet(ui: *Ui, state: *UiState) void {
    var pages: [3]layout_mod.SlicePage = .{ .slice, .image, .volume };
    const n: usize = if (state.library.volumes.items.len > 1) 3 else 2;
    if (std.mem.indexOfScalar(layout_mod.SlicePage, pages[0..n], state.slice_page) == null) state.slice_page = .slice;
    var labels: [3][]const u8 = undefined;
    for (pages[0..n], 0..) |pg, i| labels[i] = pg.label();
    const sel = std.mem.indexOfScalar(layout_mod.SlicePage, pages[0..n], state.slice_page);
    if (theme.segmented(ui, "slice_pages", sel, labels[0..n])) |i| state.slice_page = pages[i];
    switch (state.slice_page) {
        .slice => {
            planePicker(ui, state);
            sliceRow(ui, state);
            var row = theme.touchRow(ui);
            compositeToggle(&row, state);
            ui.endChildFull(&row);
            if (!state.slice_expanded) {
                if (theme.buttonRow(ui, &.{ "Fit image", "Focus slice" })) |i| {
                    if (i == 0) state.slice_view.zoom = 100 else state.slice_expanded = true;
                }
            }
        },
        .image => {
            windowingGroup(ui, state);
            zoomRow(ui, state);
        },
        .volume => {
            var row = theme.touchRow(ui);
            theme.rowLabel(&row, "Volume");
            volumePicker(&row, state);
            ui.endChildFull(&row);
            _ = theme.label(ui, "Changes the 2D slice only. Pick the 3D volume under Study.", .{ .size = 13, .color = theme.MUTED, .wrap = true });
        },
    }
}

/// The slice row alone, for the compact focus view.
pub fn sliceRowOnly(ui: *Ui, state: *UiState) void {
    sliceRow(ui, state);
}

test "scale bar is a round length that fits" {
    const a = scaleBarLength(0.45, 72);
    try std.testing.expectEqual(@as(f32, 100), a.mm);
    try std.testing.expectApproxEqAbs(@as(f32, 45), a.px, 1e-4);
    const b = scaleBarLength(2, 72);
    try std.testing.expectEqual(@as(f32, 20), b.mm);
    try std.testing.expectEqual(@as(f32, 40), b.px);
}
