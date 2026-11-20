//! Compact (phone-sized) layouts (port of roxel `ui/phone.rs`).
//!
//! A bottom tab bar holds Study, Detections, 2D slice and 3D view in both
//! orientations. Each view takes the main area when selected, with its
//! controls in a paged sheet: under the view in portrait, beside it in
//! landscape. Tapping the selected view's tab hides or shows its sheet.
//! Focus drops the bars and leaves one action bar in thumb reach.

const std = @import("std");
const kit = @import("kit.zig");
const theme = @import("theme.zig");
const sidebar = @import("sidebar.zig");
const controls = @import("controls.zig");
const slice_panel = @import("slice_panel.zig");
const layout_mod = @import("layout.zig");
const mod = @import("mod.zig");
const state_mod = @import("../state.zig");

const UiState = state_mod.UiState;
const Ui = kit.Ui;
const Ctx = kit.Ctx;
const Vec2 = kit.Vec2;
const Rect = kit.Rect;
const Color = kit.Color;
const Stroke = kit.Stroke;
const PhoneTab = layout_mod.PhoneTab;

/// Tab targets: 49 pt tall, the height phone tab bars use.
const TAB_ROW: f32 = 49.0;
/// Four touch rows and the gaps between them.
const SHEET_BODY: f32 = 4.0 * theme.TOUCH_TARGET + 3.0 * 8.0;
/// Page selector, body and the sheet's margins.
pub const SHEET_HEIGHT: f32 = 8.0 + theme.TOUCH_TARGET + 8.0 + SHEET_BODY + 8.0;
/// Controls panel beside the view in landscape.
const LANDSCAPE_PANEL: f32 = 400.0;

const SheetKind = enum { volume, slice };

pub fn draw(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    const loaded = !state.library.isEmpty();
    if (state.slice_expanded or (state.focus_volume and loaded)) {
        focusView(ctx, area, state);
    } else if (loaded) {
        tabView(ctx, area, state);
    } else {
        mod.appBar(ctx, area, state);
    }
}

fn tabView(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    // First, so the bar stays put whatever the page above it does.
    tabBar(ctx, area, state);
    mod.appBar(ctx, area, state);
    switch (state.phone_tab) {
        .study => {
            var ui = page(ctx, area);
            studyPage(&ui, state);
            area.rect = Rect.fromMinSize(area.rect.min, .{});
        },
        .detections => {
            var ui = page(ctx, area);
            detectionsPage(&ui, state);
            area.rect = Rect.fromMinSize(area.rect.min, .{});
        },
        .slice => {
            if (state.sheet_open) sheet(ctx, area, state, .slice);
            sliceArea(ctx, area, state);
        },
        .view3d => {
            if (state.sheet_open) sheet(ctx, area, state, .volume);
            // The 3D view renders in the area left over.
        },
    }
}

/// A full page of reading content. Pages hold no sliders.
fn page(ctx: *Ctx, area: *kit.PanelArea) Ui {
    var ui = kit.centralPanel(ctx, area, "page", .{ .fill = theme.PANEL, .inner_margin = kit.Margin.same(16) });
    ui.wrap_labels = true;
    return ui;
}

fn studyPage(ui: *Ui, state: *UiState) void {
    const many = state.library.volumes.items.len > 1;
    if (state.layout == .phone_landscape) {
        ui.spacing.item.x = 24;
        var cols = ui.columns(2);
        for (&cols) |*c| c.spacing.item.x = 10;
        sidebar.studySection(&cols[0], state);
        sidebar.detailsSection(&cols[1], state);
        if (many) {
            theme.rule(&cols[1]);
            sidebar.volumesSection(&cols[1], state);
        }
        ui.endColumns(&cols);
    } else {
        sidebar.studySection(ui, state);
        theme.rule(ui);
        sidebar.detailsSection(ui, state);
        if (many) {
            theme.rule(ui);
            sidebar.volumesSection(ui, state);
        }
    }
}

fn detectionsPage(ui: *Ui, state: *UiState) void {
    if (state.layout == .phone_landscape) {
        ui.spacing.item.x = 24;
        var cols = ui.columns(2);
        for (&cols) |*c| c.spacing.item.x = 10;
        if (sidebar.detectionsSummary(&cols[0], state)) sidebar.detectionsList(&cols[1], state);
        ui.endColumns(&cols);
    } else {
        sidebar.detectionsSection(ui, state);
    }
}

/// The 2D slice in the main area, edge to edge.
fn sliceArea(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    var ui = kit.centralPanel(ctx, area, "slice_area", .{ .fill = theme.WELL });
    // Focus makes the slice as large as the screen allows.
    slice_panel.imageWell(&ui, state, ui.availableRect().size(), state.slice_expanded);
    area.rect = Rect.fromMinSize(area.rect.min, .{});
}

/// The controls of the selected view: below it in portrait, beside it in
/// landscape. Fixed size, so changing page never resizes the view.
fn sheet(ctx: *Ctx, area: *kit.PanelArea, state: *UiState, kind: SheetKind) void {
    const f = kit.Frame{ .fill = theme.PANEL, .inner_margin = kit.Margin.symmetric(16, 8) };
    var p = if (state.layout == .phone_landscape)
        kit.beginPanel(ctx, area, .right, "phone_side", f, LANDSCAPE_PANEL)
    else
        kit.beginPanel(ctx, area, .bottom, "phone_sheet", f, SHEET_HEIGHT);
    switch (kind) {
        .volume => controls.volumeSheet(&p.ui, state),
        .slice => slice_panel.sliceSheet(&p.ui, state),
    }
    kit.endPanel(ctx, area, &p);
}

/// Bottom tab bar, clear of the home indicator.
fn tabBar(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    const inset = state.layout.homeIndicatorInset();
    var p = kit.beginPanel(ctx, area, .bottom, "phone_tabs", .{ .fill = theme.BG, .inner_margin = .{ .left = 8, .right = 8, .bottom = inset } }, TAB_ROW + inset);
    p.ui.spacing.item = .{};
    if (tabRow(&p.ui, state)) |tab| {
        if (tab != state.phone_tab) {
            state.phone_tab = tab;
            state.sheet_open = true;
        } else if (tab.isView()) {
            state.sheet_open = !state.sheet_open;
        }
    }
    kit.endPanel(ctx, area, &p);
}

/// The four tabs as equal full-height targets; returns the tab tapped.
fn tabRow(ui: *Ui, state: *const UiState) ?PhoneTab {
    const ctx = ui.ctx;
    const detections = sidebar.detectionCount(state);
    var tapped: ?PhoneTab = null;
    const width = @floor(ui.availableWidth() / @as(f32, PhoneTab.all.len));
    var row = ui.horizontal();
    row.setRowHeight(TAB_ROW);
    for (PhoneTab.all) |tab| {
        const resp = row.allocateResponse(.{ .x = width, .y = TAB_ROW }, row.makeId(tab.label()), kit.Sense.clickable);
        const rect = resp.rect;
        const active = tab == state.phone_tab;
        const toggles = active and tab.isView();
        if (resp.clicked) tapped = tab;
        const p = row.painter();
        if (active or resp.is_pointer_down_on) {
            p.rectFilled(Rect.fromMinMax(rect.min.add(.{ .x = 3, .y = 2 }), rect.max.sub(.{ .x = 3, .y = 4 })), 8, theme.PANEL);
        }
        if (active) {
            p.rectFilled(Rect.fromMinSize(.{ .x = rect.min.x + 14, .y = rect.min.y + 2 }, .{ .x = rect.width() - 28, .y = 3 }), 2, theme.ACCENT);
        }
        const color = if (active) theme.ACCENT else theme.TEXT;
        const g = ctx.measure(tab.label(), 14, .proportional, 0).size;
        const extra: f32 = if (toggles) 13 else 0;
        const left = rect.center().x - (g.x + extra) * 0.5;
        p.textAt(.{ .x = left, .y = rect.center().y - g.y * 0.5 }, tab.label(), 14, .proportional, color);
        if (toggles) {
            const c = Vec2.v(left + g.x + 9, rect.center().y + 1);
            const dy: f32 = if (state.sheet_open) 2.5 else -2.5;
            p.polyline(&.{ c.add(.{ .x = -4, .y = -dy }), c.add(.{ .y = dy }), c.add(.{ .x = 4, .y = -dy }) }, Stroke.init(1.6, color), false);
        }
        if (tab == .detections and detections > 0) {
            const center = Vec2.v(rect.max.x - 9, rect.min.y + 13);
            p.circleFilled(center, 8, theme.DANGER);
            _ = p.text(center, kit.Align2.center_center, ctx.fmt("{d}", .{detections}), 11, theme.BG);
        }
    }
    ui.endChild(&row);
    return tapped;
}

/// Focus on a compact layout: the view fills the screen above one action
/// bar; "Adjust display" opens the same paged controls.
fn focusView(ctx: *Ctx, area: *kit.PanelArea, state: *UiState) void {
    const slice = state.slice_expanded;
    const inset = state.layout.homeIndicatorInset();
    var bar = kit.beginPanel(ctx, area, .bottom, "focus_bar", .{ .fill = theme.BG, .inner_margin = .{ .left = 16, .right = 16, .top = 8, .bottom = 8 + inset } }, null);
    {
        const ui = &bar.ui;
        const gap = ui.spacing.item.x;
        const w = @floor((ui.availableWidth() - 2 * gap) / 3);
        const sz = Vec2.v(w, theme.TOUCH_TARGET);
        var row = ui.horizontal();
        if (theme.button(&row, "Exit focus", .{ .sized = sz }).clicked) {
            state.slice_expanded = false;
            state.focus_volume = false;
            state.focus_adjust_open = false;
            state.fit_camera = true;
        }
        if (theme.button(&row, if (slice) "Fit image" else "Fit view", .{ .sized = sz }).clicked) {
            if (slice) state.slice_view.zoom = 100 else state.fit_camera = true;
        }
        if (theme.button(&row, "Adjust display", .{ .sized = sz, .selected = state.focus_adjust_open }).clicked) {
            state.focus_adjust_open = !state.focus_adjust_open;
        }
        ui.endChild(&row);
    }
    kit.endPanel(ctx, area, &bar);
    if (state.focus_adjust_open) {
        sheet(ctx, area, state, if (slice) .slice else .volume);
    } else if (slice and !state.slice_view.composite and state.slice_view.max_slices > 1) {
        // Stepping through slices is the main thing to do here.
        var row = kit.beginPanel(ctx, area, .bottom, "focus_slice_row", .{ .fill = theme.PANEL, .inner_margin = kit.Margin.symmetric(16, 8) }, null);
        slice_panel.sliceRowOnly(&row.ui, state);
        kit.endPanel(ctx, area, &row);
    }
    if (slice) sliceArea(ctx, area, state);
}
