//! Controls of the 3D view: camera, slice plane, windowing, palette and
//! lighting (port of roxel `ui/controls.rs`). Desktop puts camera actions and
//! slice-plane options in a header above the view and appearance groups in
//! a shelf below it; compact layouts show them as pages of a sheet.

const std = @import("std");
const kit = @import("kit.zig");
const theme = @import("theme.zig");
const sidebar = @import("sidebar.zig");
const slice_panel = @import("slice_panel.zig");
const band_slider = @import("band_slider.zig");
const layout_mod = @import("layout.zig");
const state_mod = @import("../state.zig");
const transfer = @import("../transfer.zig");
const slice_view = @import("../slice_view.zig");

const UiState = state_mod.UiState;
const Ui = kit.Ui;
const Ctx = kit.Ctx;
const Vec2 = kit.Vec2;
const Rect = kit.Rect;
const Color = kit.Color;
const Stroke = kit.Stroke;
const SliderSpec = theme.SliderSpec;

const PRESETS = [_]struct { p: transfer.TransferPreset, l: []const u8 }{
    .{ .p = .default, .l = "Materials" },
    .{ .p = .threat, .l = "Threat" },
    .{ .p = .monochrome, .l = "Grayscale" },
};
const PRESET_LABELS = [_][]const u8{ "Materials", "Threat", "Grayscale" };

/// Fixed legend height, so switching palettes moves nothing.
const LEGEND_HEIGHT: f32 = 34.0;
/// One press of an orbit arrow (radians), pan arrow (pixels), zoom button.
const ORBIT_STEP: f32 = 0.2618;
const PAN_STEP: f32 = 80.0;
const ZOOM_STEP: f32 = 1.25;

// ---------------------------------------------------------------------------
// Shared actions
// ---------------------------------------------------------------------------

/// "Focus volume" / "Exit focus": the 3D view takes the workspace.
pub fn focusVolumeButton(ui: *Ui, state: *UiState) void {
    const r = theme.iconButton(ui, if (state.focus_volume) .reduce else .enlarge, if (state.focus_volume) "Exit focus" else "Focus volume");
    ui.ctx.hoverText(r, if (state.focus_volume) "Back to the workspace (Esc)" else "Enlarge the 3D view to fill the workspace");
    if (r.clicked) {
        state.focus_volume = !state.focus_volume;
        state.fit_camera = true;
    }
}

/// One-shot camera moves named for the axes the corner gizmo draws.
fn lookAlong(state: *UiState, axis: usize) void {
    switch (axis) {
        0 => state.camera.setSagittal(),
        1 => state.camera.setCoronal(),
        else => state.camera.setAxial(),
    }
    state.fit_camera = true;
}

fn planePicker(ui: *Ui, state: *UiState) void {
    const labels = [_][]const u8{ "Axial", "Coronal", "Sagittal" };
    if (theme.segmented(ui, "plane3d", state.slice_view.orientation.index(), &labels)) |i| {
        slice_panel.setOrientation(state, slice_view.Orientation.all[i]);
    }
}

// ---------------------------------------------------------------------------
// Desktop
// ---------------------------------------------------------------------------

/// Header above the 3D view. Row one: the view's name and its one-shot
/// camera actions. Row two: options that change what the view draws.
pub fn drawVolumeHeader(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    var f = theme.frame();
    f.inner_margin = kit.Margin.symmetric(16, 10);
    var p = kit.beginPanel(ctx, area, .top, "volume_header", f, null);
    const ui = &p.ui;
    var row = ui.horizontal();
    _ = theme.title(&row, "3D view");
    var rtl = row.rightToLeft();
    focusVolumeButton(&rtl, state);
    const fit = theme.button(&rtl, "Fit view", .{});
    ctx.hoverText(fit, "Center and fit the whole volume");
    if (fit.clicked) state.fit_camera = true;
    rtl.addSpace(8);
    // Right-to-left, so Z is added first.
    const saved = rtl.spacing.item.x;
    rtl.spacing.item.x = 4;
    for ([_]struct { a: usize, l: []const u8 }{ .{ .a = 2, .l = "Z" }, .{ .a = 1, .l = "Y" }, .{ .a = 0, .l = "X" } }) |ax| {
        const r = theme.button(&rtl, ax.l, .{ .min_size = .{ .x = 30 } });
        ctx.hoverText(r, ctx.fmt("Look along the {s} axis", .{ax.l}));
        if (r.clicked) lookAlong(state, ax.a);
    }
    rtl.spacing.item.x = saved;
    // roxel groups the axis buttons in `ui.scope`: the parent's spacing
    // (8) follows the group, not the buttons' 4.
    rtl.addSpace(saved - 4);
    _ = theme.label(&rtl, "View along", .{ .size = 13.0, .color = theme.MUTED, .wrap = false });
    row.endChildFull(&rtl);
    ui.endChild(&row);
    // A fixed-height row, so every option centres on one line.
    var opts = ui.childSized(.{ .x = ui.availableWidth(), .y = 32 }, kit.Layout.leftToRight(.center));
    opts.setRowHeight(32);
    opts.spacing.item.x = 14;
    slicePlaneOptions(&opts, state);
    ui.endChildFull(&opts);
    kit.endPanel(ctx, area, &p);
}

/// "Slice plane", then "Cutaway" with its dependent "Reverse cutaway"
/// enclosed with it. In focus the plane and slice position join them.
fn slicePlaneOptions(ui: *Ui, state: *UiState) void {
    const available = sidebar.sliceToolsAvailable(state);
    const saved = ui.enabled;
    if (!available) ui.enabled = false;
    const sp = theme.checkbox(ui, &state.show_slice_locator, "Slice plane");
    ui.ctx.hoverText(sp, "Outline the 2D slice in the 3D view");
    var scope = ui.beginFrame("cutaway_group", .{ .stroke = Stroke.init(1, theme.HAIRLINE), .rounding = 6, .inner_margin = kit.Margin.symmetric(10, 2) });
    const ca = theme.checkbox(&scope.ui, &state.cutaway, "Cutaway");
    ui.ctx.hoverText(ca, "Hide the volume on one side of the slice plane");
    const inner_saved = scope.ui.enabled;
    if (!state.cutaway) scope.ui.enabled = false;
    const rc = theme.checkbox(&scope.ui, &state.reverse_cutaway, "Reverse cutaway");
    ui.ctx.hoverText(rc, "Hide the other side instead");
    scope.ui.enabled = inner_saved;
    _ = ui.endFrame(&scope);
    ui.enabled = saved;
    if (!available) {
        _ = theme.label(ui, SLICE_NOTE(), .{ .size = ui.text.small, .color = theme.MUTED, .wrap = false });
    } else if (state.focus_volume) {
        planePicker(ui, state);
        if (state.slice_view.max_slices > 1) {
            const width = @min(ui.availableWidth(), 340);
            var cell = ui.childSized(.{ .x = width, .y = 24 }, kit.Layout.top_down);
            cell.spacing.item.x = 8;
            const max_slices = state.slice_view.max_slices;
            if (theme.sliceSlider(&cell, &state.slice_view.slice_index, max_slices)) state.slice_dirty = true;
            ui.endChildFull(&cell);
        }
    }
}

fn SLICE_NOTE() []const u8 {
    return sidebar.SLICE_TOOLS_NOTE;
}

/// Shelf below the 3D view: windowing, palette and lighting, in as many
/// equal columns as fit.
pub fn drawShelf(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    var f = theme.frame();
    f.inner_margin = kit.Margin.symmetric(16, 12);
    var p = kit.beginPanel(ctx, area, .bottom, "controls", f, null);
    const ui = &p.ui;
    // On very wide windows keep rows a usable length.
    const width = @min(ui.availableWidth(), 1440);
    const pad = (ui.availableWidth() - width) * 0.5;
    var body = ui.childAt(Rect.fromMinSize(.{ .x = ui.max_rect.min.x + pad, .y = ui.cursor.min.y }, .{ .x = width, .y = ui.availableHeight() }), kit.Layout.top_down);
    const three = width >= 720;
    body.spacing.item.x = 24;
    if (three) {
        var cols = body.columns(3);
        for (&cols) |*c| c.spacing.item = Vec2.v(8, 6);
        windowingGroup(&cols[0], state);
        paletteGroup(&cols[1], state, false);
        theme.section(&cols[2], "Lighting");
        lightingRows(&cols[2], state);
        body.endColumns(&cols);
    } else {
        var cols = body.columns(2);
        for (&cols) |*c| c.spacing.item = Vec2.v(8, 6);
        windowingGroup(&cols[0], state);
        paletteGroup(&cols[1], state, true);
        body.endColumns(&cols);
    }
    ui.endChild(&body);
    kit.endPanel(ctx, area, &p);
}

fn windowingGroup(ui: *Ui, state: *UiState) void {
    const ranges = windowRangesFor(state, state.library.active_3d_index orelse 0);
    theme.sectionWithNote(ui, "3D windowing", "stored values");
    _ = theme.windowRows(ui, &state.settings.window_center, &state.settings.window_width, ranges);
    opacityRow(ui, state);
    densityRow(ui, state);
}

pub fn windowRangesFor(state: *const UiState, index: usize) theme.WindowRanges {
    if (index < state.library.volumes.items.len) {
        const v = &state.library.volumes.items[index].volume;
        return theme.windowRanges(v.window_center, v.window_width);
    }
    return theme.windowRanges(null, null);
}

fn opacityRow(ui: *Ui, state: *UiState) void {
    _ = theme.sliderF32(ui, SliderSpec.fraction("Opacity", 0, 1), &state.settings.global_opacity);
}

fn densityRow(ui: *Ui, state: *UiState) void {
    _ = theme.sliderF32(ui, SliderSpec.fraction("Density", 0, 1), &state.settings.density_threshold);
}

fn lightingRows(ui: *Ui, state: *UiState) void {
    _ = theme.sliderF32(ui, SliderSpec.fraction("Depth cue", 0, 1), &state.settings.depth_cue);
    _ = theme.sliderF32(ui, SliderSpec.fraction("Ambient", 0, 1), &state.settings.ambient);
    _ = theme.sliderF32(ui, SliderSpec.fraction("Diffuse", 0, 1), &state.settings.diffuse);
    _ = theme.sliderF32(ui, SliderSpec.fraction("Specular", 0, 1), &state.settings.specular);
}

fn presetIndex(p: transfer.TransferPreset) usize {
    for (PRESETS, 0..) |e, i| if (e.p == p) return i;
    return 0;
}

fn palettePicker(ui: *Ui, state: *UiState) void {
    if (theme.segmented(ui, "palette", presetIndex(state.transfer.preset), &PRESET_LABELS)) |i| {
        state.transfer.preset = PRESETS[i].p;
        state.actions.preset_changed = true;
    }
}

fn qualityPicker(ui: *Ui, state: *UiState) void {
    const sel: usize = switch (state.settings.quality) {
        .fast => 0,
        .medium => 1,
        .high => 2,
    };
    if (theme.segmented(ui, "quality", sel, &.{ "Fast", "Balanced", "High" })) |i| {
        state.settings.quality = switch (i) {
            0 => .fast,
            1 => .medium,
            else => .high,
        };
    }
}

/// Palette with its legend, quality, and the editors opened on request.
fn paletteGroup(ui: *Ui, state: *UiState, lighting_menu: bool) void {
    theme.section(ui, "Palette");
    palettePicker(ui, state);
    const width = ui.availableWidth();
    paletteLegend(ui, state, width);
    var qrow = ui.horizontal();
    _ = theme.label(&qrow, "Quality", .{ .size = 13.0, .color = theme.MUTED, .wrap = false });
    qualityPicker(&qrow, state);
    ui.endChild(&qrow);
    const materials = state.transfer.preset == .default;
    if (lighting_menu or materials) {
        var row = ui.horizontal();
        if (lighting_menu) {
            var pop = theme.menuButton(&row, "Lighting", 300);
            if (pop.open) {
                theme.section(&pop.ui, "Lighting");
                pop.ui.spacing.item.y = 8;
                lightingRows(&pop.ui, state);
                theme.endPopup(&pop);
            }
        }
        if (materials) {
            var pop = theme.menuButton(&row, "Material bands", 340);
            if (pop.open) {
                materialBandsEditor(&pop.ui, state);
                theme.endPopup(&pop);
            }
        }
        ui.endChild(&row);
    }
}

/// What the palette's colours mean, in a fixed-height strip.
fn paletteLegend(ui: *Ui, state: *const UiState, width: f32) void {
    const rect = ui.allocate(.{ .x = width, .y = LEGEND_HEIGHT });
    const p = ui.painterAt(rect);
    const size: f32 = if (theme.isTouch(ui)) 13.0 else 12.0;
    const ctx = ui.ctx;
    switch (state.transfer.preset) {
        .default => {
            // Dot-and-name pairs on one line, or two balanced lines.
            const gap: f32 = 12;
            var widths: [transfer.BAND_COUNT]f32 = undefined;
            for (state.transfer.bands, 0..) |b, i| widths[i] = 14 + ctx.measure(b.name, size, .proportional, 0).size.x;
            const run = struct {
                fn f(w: []const f32, g: f32) f32 {
                    var s: f32 = 0;
                    for (w) |x| s += x;
                    return s + g * @as(f32, @floatFromInt(w.len -| 1));
                }
            }.f;
            var first_line: usize = widths.len;
            if (run(&widths, gap) > width) {
                var best: f32 = std.math.inf(f32);
                for (1..widths.len) |k| {
                    const longest = @max(run(widths[0..k], gap), run(widths[k..], gap));
                    if (longest < best) {
                        best = longest;
                        first_line = k;
                    }
                }
            }
            const line = size + 4;
            const lines: f32 = if (first_line == widths.len) 1 else 2;
            const top = rect.min.y + (LEGEND_HEIGHT - line * lines) * 0.5;
            var pos = Vec2.v(rect.min.x, top);
            for (state.transfer.bands, 0..) |b, i| {
                if (i == first_line) pos = Vec2.v(rect.min.x, top + line);
                p.circleFilled(pos.add(.{ .x = 5, .y = line * 0.5 }), 4.5, Color.rgb(b.color[0], b.color[1], b.color[2]));
                const g = ctx.measure(b.name, size, .proportional, 0).size;
                p.textAt(pos.add(.{ .x = 14, .y = (line - g.y) * 0.5 }), b.name, size, .proportional, theme.TEXT);
                pos.x += widths[i] + gap;
            }
        },
        .monochrome => {
            const bar = Rect.fromMinSize(rect.min.add(.{ .y = 3 }), .{ .x = @min(width, 360), .y = 9 });
            const steps: usize = @intFromFloat(@max(bar.width() / 2.0, 2));
            const step_w = bar.width() / @as(f32, @floatFromInt(steps));
            for (0..steps) |i| {
                const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps - 1));
                const g: u8 = @intFromFloat(transfer.TransferFunction.grayscaleLevel(t) * 255.0);
                p.rectFilled(Rect.fromMinSize(.{ .x = bar.min.x + @as(f32, @floatFromInt(i)) * step_w, .y = bar.min.y }, .{ .x = step_w + 0.5, .y = bar.height() }), 0, Color.gray(g));
            }
            p.rectStroke(bar, 0, Stroke.init(1, theme.HAIRLINE), .outside);
            const lo = state.settings.window_center - state.settings.window_width * 0.5;
            const hi = state.settings.window_center + state.settings.window_width * 0.5;
            _ = p.text(.{ .x = bar.min.x, .y = rect.max.y }, kit.Align2.left_bottom, ctx.fmt("{d:.0}", .{lo}), size, theme.MUTED);
            _ = p.text(.{ .x = bar.center().x, .y = rect.max.y }, kit.Align2.center_bottom, "Stored value", size, theme.MUTED);
            _ = p.text(.{ .x = bar.max.x, .y = rect.max.y }, kit.Align2.right_bottom, ctx.fmt("{d:.0}", .{hi}), size, theme.MUTED);
        },
        .threat => {
            p.circleFilled(rect.leftCenter().add(.{ .x = 5 }), 4.5, Color.rgb(235, 80, 70));
            _ = p.text(rect.leftCenter().add(.{ .x = 14 }), kit.Align2.left_center, "Dense material in red", size, theme.TEXT);
        },
    }
}

/// Desktop band editor: thresholds strip plus one opacity row per band.
fn materialBandsEditor(ui: *Ui, state: *UiState) void {
    transfer.clampBandThresholds(&state.transfer.bands);
    theme.sectionWithNote(ui, "Band thresholds", "stored values");
    if (band_slider.draw(ui, &state.transfer.bands)) state.transfer.bands_changed = true;
    theme.section(ui, "Band opacity");
    for (&state.transfer.bands) |*b| {
        if (bandOpacityRow(ui, b.name, &b.alpha)) state.transfer.bands_changed = true;
    }
}

fn bandOpacityRow(ui: *Ui, lbl: []const u8, alpha: *f32) bool {
    return theme.sliderF32(ui, SliderSpec.fraction(lbl, 0, 2).withUnit("\u{d7}"), alpha).committed;
}

// ---------------------------------------------------------------------------
// Compact layouts: pages of the 3D controls sheet
// ---------------------------------------------------------------------------

pub fn volumeSheet(ui: *Ui, state: *UiState) void {
    if (state.bands_open and state.transfer.preset == .default) {
        bandsPage(ui, state);
        return;
    }
    state.bands_open = false;
    const labels = [_][]const u8{ "Camera", "Slice", "Windowing", "Display", "Lighting" };
    if (theme.segmented(ui, "volume_pages", @intFromEnum(state.volume_page), &labels)) |i| {
        state.volume_page = layout_mod.VolumePage.all[i];
    }
    switch (state.volume_page) {
        .camera => cameraPage(ui, state),
        .slice => slicePlanePage(ui, state),
        .windowing => {
            const ranges = windowRangesFor(state, state.library.active_3d_index orelse 0);
            theme.sectionWithNote(ui, "3D windowing", "stored values");
            _ = theme.windowRows(ui, &state.settings.window_center, &state.settings.window_width, ranges);
            opacityRow(ui, state);
        },
        .display => {
            palettePicker(ui, state);
            var row = theme.touchRow(ui);
            const materials = state.transfer.preset == .default;
            const bw: f32 = if (materials) 132 else 0;
            const w = row.availableWidth() - bw - (if (materials) @as(f32, 10) else 0);
            paletteLegend(&row, state, w);
            if (materials and theme.button(&row, "Material bands", .{ .sized = .{ .x = bw, .y = theme.TOUCH_TARGET } }).clicked) state.bands_open = true;
            ui.endChildFull(&row);
            var qrow = theme.touchRow(ui);
            theme.rowLabel(&qrow, "Quality");
            qualityPicker(&qrow, state);
            ui.endChildFull(&qrow);
            densityRow(ui, state);
        },
        .lighting => lightingRows(ui, state),
    }
}

/// Camera page: view actions, then a single-tap way to do every gesture.
fn cameraPage(ui: *Ui, state: *UiState) void {
    if (!state.focus_volume) {
        if (theme.buttonRow(ui, &.{ "Fit view", "Focus volume" })) |i| {
            state.fit_camera = true;
            if (i == 1) state.focus_volume = true;
        }
    }
    var r1 = theme.touchRow(ui);
    theme.rowLabel(&r1, "View along");
    if (theme.buttonRow(&r1, &.{ "X", "Y", "Z" })) |axis| lookAlong(state, axis);
    ui.endChildFull(&r1);

    var r2 = theme.touchRow(ui);
    const arrows = 4 * theme.TOUCH_TARGET + 4 * r2.spacing.item.x;
    var seg = r2.childSized(.{ .x = r2.availableWidth() - arrows, .y = theme.TOUCH_TARGET }, kit.Layout.leftToRight(.center));
    seg.setRowHeight(theme.TOUCH_TARGET);
    if (theme.segmented(&seg, "drag_mode", @intFromBool(state.drag_pans), &.{ "Orbit", "Pan" })) |i| state.drag_pans = i == 1;
    r2.endChildFull(&seg);
    const dirs = [_]struct { a: Arrow, dx: f32, dy: f32 }{
        .{ .a = .left, .dx = -1, .dy = 0 },
        .{ .a = .right, .dx = 1, .dy = 0 },
        .{ .a = .up, .dx = 0, .dy = -1 },
        .{ .a = .down, .dx = 0, .dy = 1 },
    };
    for (dirs) |d| {
        if (arrowButton(&r2, d.a, state.drag_pans).clicked) {
            if (state.drag_pans) state.camera.panPixels(d.dx * PAN_STEP, d.dy * PAN_STEP) else state.camera.rotate(d.dx * ORBIT_STEP, -d.dy * ORBIT_STEP);
        }
    }
    ui.endChildFull(&r2);

    var r3 = theme.touchRow(ui);
    theme.rowLabel(&r3, "Zoom");
    const sz = Vec2.v(theme.TOUCH_TARGET, theme.TOUCH_TARGET);
    const out = theme.stepper(&r3, "\u{2212}", sz, true, "zoom out");
    ui.ctx.hoverText(out, "Zoom out");
    if (out.clicked) state.camera.zoom(1.0 / ZOOM_STEP);
    const in_ = theme.stepper(&r3, "+", sz, true, "zoom in");
    ui.ctx.hoverText(in_, "Zoom in");
    if (in_.clicked) state.camera.zoom(ZOOM_STEP);
    _ = theme.label(&r3, if (state.drag_pans) "Or drag to pan and pinch to zoom." else "Or drag to orbit, pinch to zoom, two fingers to pan.", .{ .size = 13.0, .color = theme.MUTED, .wrap = true });
    ui.endChildFull(&r3);
}

const Arrow = enum { left, right, up, down };

/// A full-size button with a drawn chevron.
fn arrowButton(ui: *Ui, arrow: Arrow, pans: bool) kit.Response {
    const sz = Vec2.v(theme.TOUCH_TARGET, theme.TOUCH_TARGET);
    const name = @tagName(arrow);
    const verb = if (pans) "Pan" else "Orbit";
    const r = theme.button(ui, "", .{ .min_size = sz, .id_salt = ui.ctx.fmt("arrow {s}", .{name}) });
    ui.ctx.hoverText(r, ui.ctx.fmt("{s} {s}", .{ verb, name }));
    const c = r.rect.center();
    const tip: Vec2, const side: Vec2 = switch (arrow) {
        .left => .{ Vec2.v(-5, 0), Vec2.v(0, 7) },
        .right => .{ Vec2.v(5, 0), Vec2.v(0, 7) },
        .up => .{ Vec2.v(0, -5), Vec2.v(7, 0) },
        .down => .{ Vec2.v(0, 5), Vec2.v(7, 0) },
    };
    ui.painter().polyline(&.{ c.sub(tip).add(side), c.add(tip), c.sub(tip).sub(side) }, Stroke.init(2, theme.TEXT), false);
    return r;
}

/// Slice page: slice plane, cutaway with its dependent option indented
/// beneath it, and the slice position that moves both.
fn slicePlanePage(ui: *Ui, state: *UiState) void {
    const available = sidebar.sliceToolsAvailable(state);
    const saved = ui.enabled;
    if (!available) ui.enabled = false;
    var a = theme.touchRow(ui);
    _ = theme.checkbox(&a, &state.show_slice_locator, "Slice plane");
    ui.endChildFull(&a);
    var b = theme.touchRow(ui);
    _ = theme.checkbox(&b, &state.cutaway, "Cutaway");
    ui.endChildFull(&b);
    var c = theme.touchRow(ui);
    if (!state.cutaway) c.enabled = false;
    c.addSpace(34);
    _ = theme.checkbox(&c, &state.reverse_cutaway, "Reverse cutaway");
    ui.endChildFull(&c);
    ui.enabled = saved;
    if (!available) {
        var r = theme.touchRow(ui);
        _ = theme.label(&r, sidebar.SLICE_TOOLS_NOTE, .{ .size = 13.0, .color = theme.MUTED, .wrap = true });
        ui.endChildFull(&r);
    } else if (state.slice_view.max_slices > 1) {
        if (theme.sliceSlider(ui, &state.slice_view.slice_index, state.slice_view.max_slices)) state.slice_dirty = true;
    }
}

/// Compact band editor: thresholds strip, then one band at a time.
fn bandsPage(ui: *Ui, state: *UiState) void {
    transfer.clampBandThresholds(&state.transfer.bands);
    var row = theme.touchRow(ui);
    if (theme.button(&row, "Done", .{ .min_size = .{ .x = 72, .y = theme.TOUCH_TARGET } }).clicked) state.bands_open = false;
    _ = theme.title(&row, "Material bands");
    ui.endChildFull(&row);
    if (band_slider.draw(ui, &state.transfer.bands)) state.transfer.bands_changed = true;
    var names: [transfer.BAND_COUNT][]const u8 = undefined;
    for (state.transfer.bands, 0..) |b, i| names[i] = b.name;
    state.selected_band = @min(state.selected_band, names.len - 1);
    if (theme.segmented(ui, "band_pick", state.selected_band, &names)) |i| state.selected_band = i;
    if (bandOpacityRow(ui, "Opacity", &state.transfer.bands[state.selected_band].alpha)) state.transfer.bands_changed = true;
}
