//! Shared visual language: the palette, the per-layout style, and the
//! controls every panel is built from (port of roxel `ui/theme.rs`, plus the
//! egui stock widgets roxel relies on: Button, DragValue, menu buttons,
//! combo boxes and labels).
//!
//! Contrast against PANEL (WCAG 2.2): text 13.3:1, muted text 9.4:1, control
//! outlines 5.3:1, slider rail 3.9:1, selected-segment text 7.1:1.

const std = @import("std");
const zgui = @import("zgui");
const kit = @import("kit.zig");
const layout_mod = @import("layout.zig");

const Vec2 = kit.Vec2;
const Rect = kit.Rect;
const Color = kit.Color;
const Stroke = kit.Stroke;
const Ui = kit.Ui;
const Ctx = kit.Ctx;
const Response = kit.Response;
const Align2 = kit.Align2;

pub const BG = Color.rgb(16, 22, 29);
pub const PANEL = Color.rgb(23, 31, 40);
/// Body text.
pub const TEXT = Color.rgb(222, 231, 239);
/// Headings: the brightest text on a panel.
pub const HEADING = Color.rgb(244, 248, 251);
/// Captions and row labels.
pub const MUTED = Color.rgb(184, 196, 208);
pub const ACCENT = Color.rgb(105, 211, 191);
/// Error text; 7.7:1 on PANEL.
pub const DANGER = Color.rgb(246, 151, 141);
/// Fill of the selected segment, tab or list item.
pub const SELECTED = Color.rgb(36, 81, 80);
/// Outline of buttons, number boxes and unchecked boxes.
pub const OUTLINE = Color.rgb(124, 148, 168);
/// Unfilled part of a slider rail.
pub const RAIL = Color.rgb(104, 126, 146);
pub const THUMB = Color.rgb(236, 242, 247);
/// Hairlines between panels and groups.
pub const HAIRLINE = Color.rgb(48, 62, 76);
/// Background of the 2D image well.
pub const WELL = Color.rgb(0, 0, 0);
/// egui `faint_bg_color`.
pub const FAINT = Color.rgb(29, 40, 51);
/// Widget fills (egui widgets.inactive / hovered).
pub const FILL_INACTIVE = Color.rgb(38, 52, 66);
pub const FILL_HOVERED = Color.rgb(52, 70, 86);
/// Smallest touch target edge for compact layouts.
pub const TOUCH_TARGET: f32 = 44.0;
/// Label column of a desktop control row.
pub const LABEL_W: f32 = 64.0;
/// Label-and-value column of a touch control row.
pub const TOUCH_LABEL_W: f32 = 78.0;
/// Number box of a desktop control row.
const NUMBER_W: f32 = 56.0;
const WIDGET_ROUNDING: f32 = 5.0;

/// (Re)build the style for a layout: compact layouts get touch-sized
/// targets, larger type and roomier spacing; the palette is shared.
pub fn setLayout(ctx: *Ctx, layout: layout_mod.Layout) void {
    const compact = layout.isCompact();
    ctx.style = .{
        .item = if (compact) Vec2.v(10, 8) else Vec2.v(8, 8),
        .button_padding = if (compact) Vec2.v(12, 8) else Vec2.v(10, 5),
        .interact_y = if (compact) TOUCH_TARGET else 28,
        .menu_margin = 12,
    };
    ctx.text_sizes = .{
        .body = if (compact) 16.0 else 13.5,
        .button = if (compact) 15.0 else 13.0,
        .heading = if (compact) 18.0 else 17.0,
        .small = if (compact) 13.0 else 12.0,
    };
}

/// True when controls are sized for fingers.
pub fn isTouch(ui: *const Ui) bool {
    return ui.spacing.interact_y >= TOUCH_TARGET - 1.0;
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

pub const LabelOpts = struct {
    size: ?f32 = null,
    color: Color = TEXT,
    wrap: ?bool = null,
    kind: kit.FontKind = .proportional,
};

/// egui `Label`: allocates its galley; wraps at the available width when
/// asked (or when the Ui wraps labels).
pub fn label(ui: *Ui, text: []const u8, opts: LabelOpts) Response {
    const size = opts.size orelse ui.text.body;
    const wrap = opts.wrap orelse ui.wrap_labels;
    const avail = ui.availableWidth();
    var sz: Vec2 = undefined;
    if (wrap and !ui.layout.isHorizontal()) {
        sz = kit.measureWrapped(ui.ctx, text, size, avail);
    } else if (wrap) {
        sz = kit.measureWrapped(ui.ctx, text, size, avail);
    } else {
        sz = ui.ctx.measure(text, size, opts.kind, 0).size;
    }
    const resp = ui.allocateResponse(sz, ui.makeId(text), kit.Sense.hover);
    const p = ui.painter();
    if (wrap) {
        p.textWrapped(resp.rect.min, text, size, opts.color, avail);
    } else {
        p.textAt(resp.rect.min, text, size, opts.kind, opts.color);
    }
    return resp;
}

/// The name of a panel or page: its largest text.
pub fn title(ui: *Ui, text: []const u8) Response {
    return label(ui, text, .{ .size = if (isTouch(ui)) 18.0 else 17.0, .color = HEADING });
}

/// A group heading.
pub fn section(ui: *Ui, text: []const u8) void {
    sectionWithNote(ui, text, "");
}

/// A group heading with a short muted qualifier at the right of the line.
pub fn sectionWithNote(ui: *Ui, text: []const u8, note: []const u8) void {
    const touch = isTouch(ui);
    // roxel sets interact_size.y = 20 inside the `horizontal` closure, after
    // the row took its height: the row keeps the full interact height and
    // only the right-to-left note row inside it is 20 tall.
    var row = ui.horizontal();
    _ = label(&row, text, .{ .size = if (touch) 16.0 else 14.5, .color = HEADING, .wrap = false });
    if (note.len > 0) {
        var rtl = row.rightToLeft();
        _ = label(&rtl, note, .{ .size = if (touch) 13.0 else 12.0, .color = MUTED, .wrap = false });
        row.endChildFull(&rtl);
    }
    ui.endChild(&row);
}

/// A thin rule between groups.
pub fn rule(ui: *Ui) void {
    const r = ui.allocate(.{ .x = ui.availableWidth(), .y = 9.0 });
    ui.painter().hline(r.min.x, r.max.x, r.center().y, Stroke.init(1, HAIRLINE));
}

pub fn frame() kit.Frame {
    return .{ .fill = PANEL, .inner_margin = kit.Margin.same(16) };
}

// ---------------------------------------------------------------------------
// Buttons (egui Button visuals with roxel's theme)
// ---------------------------------------------------------------------------

pub const ButtonOpts = struct {
    min_size: Vec2 = .{},
    fill: ?Color = null,
    stroke: ?Stroke = null,
    text_color: Color = TEXT,
    text_size: ?f32 = null,
    rounding: f32 = WIDGET_ROUNDING,
    selected: bool = false,
    /// Exact size (egui `add_sized`): the button is centred in it.
    sized: ?Vec2 = null,
    /// A glyph drawn before the label (icon buttons).
    icon: ?Icon = null,
    /// Draw "open" visuals (menu button with its popup open).
    open: bool = false,
    enabled: bool = true,
    id_salt: []const u8 = "",
};

const Visual = struct { fill: Color, stroke: Stroke };

fn widgetVisual(r: Response, open: bool) Visual {
    if (r.is_pointer_down_on) return .{ .fill = SELECTED, .stroke = Stroke.init(1, ACCENT) };
    if (open) return .{ .fill = SELECTED, .stroke = Stroke.init(1, ACCENT) };
    if (r.hovered) return .{ .fill = FILL_HOVERED, .stroke = Stroke.init(1, THUMB) };
    return .{ .fill = FILL_INACTIVE, .stroke = Stroke.init(1, OUTLINE) };
}

pub fn buttonSize(ui: *Ui, text: []const u8, opts: ButtonOpts) Vec2 {
    const ts = opts.text_size orelse ui.text.button;
    const g = ui.ctx.measure(text, ts, .proportional, 0).size;
    var w = g.x + 2 * ui.spacing.button_padding.x;
    if (opts.icon != null) w += iconSide(ui) + 4 + (if (text.len > 0) ui.spacing.icon_spacing else 0);
    var h = @max(g.y + 2 * ui.spacing.button_padding.y, ui.spacing.interact_y);
    w = @max(w, opts.min_size.x);
    h = @max(h, opts.min_size.y);
    return .{ .x = w, .y = h };
}

pub fn button(ui: *Ui, text: []const u8, opts: ButtonOpts) Response {
    const ts = opts.text_size orelse ui.text.button;
    const natural = buttonSize(ui, text, opts);
    const id = ui.makeId(if (opts.id_salt.len > 0) opts.id_salt else text);
    const saved = ui.enabled;
    defer ui.enabled = saved;
    if (!opts.enabled) ui.enabled = false;
    var resp: Response = undefined;
    var rect: Rect = undefined;
    if (opts.sized) |s| {
        const cell = ui.allocate(s);
        rect = Rect.fromCenterSize(cell.center(), .{ .x = @max(natural.x, s.x), .y = @max(natural.y, s.y) });
        rect = cell;
        resp = ui.interact(rect, id, kit.Sense.clickable);
    } else {
        resp = ui.allocateResponse(natural, id, kit.Sense.clickable);
        rect = resp.rect;
    }
    var vis = widgetVisual(resp, opts.open);
    if (opts.selected and !resp.is_pointer_down_on) {
        vis = .{ .fill = SELECTED, .stroke = Stroke.init(1, ACCENT) };
    }
    const fill = opts.fill orelse vis.fill;
    const stroke = opts.stroke orelse vis.stroke;
    const p = ui.painter();
    p.rect(rect, opts.rounding, fill, stroke);
    const g = ui.ctx.measure(text, ts, .proportional, 0).size;
    if (opts.icon) |icon| {
        const side = iconSide(ui);
        const total = side + 4 + (if (text.len > 0) ui.spacing.icon_spacing + g.x else 0);
        const x0 = rect.center().x - total * 0.5;
        const icon_rect = Rect.fromMinSize(.{ .x = x0, .y = rect.center().y - side * 0.5 }, .{ .x = side, .y = side });
        drawIcon(p, icon, icon_rect);
        p.textAt(.{ .x = x0 + side + 4 + ui.spacing.icon_spacing, .y = rect.center().y - g.y * 0.5 }, text, ts, .proportional, opts.text_color);
    } else {
        p.textAt(.{ .x = rect.center().x - g.x * 0.5, .y = rect.center().y - g.y * 0.5 }, text, ts, .proportional, opts.text_color);
    }
    return resp;
}

/// The one dominant action of a view.
pub fn primaryButton(ui: *Ui, text: []const u8, min_size: Vec2) Response {
    return button(ui, text, .{ .text_color = BG, .fill = ACCENT, .stroke = Stroke.none, .min_size = min_size });
}

/// A row of equally wide buttons filling the available width. Returns the
/// index pressed.
pub fn buttonRow(ui: *Ui, labels: []const []const u8) ?usize {
    var pressed: ?usize = null;
    const gap = ui.spacing.item.x;
    const n: f32 = @floatFromInt(@max(labels.len, 1));
    const w = @floor((ui.availableWidth() - gap * (n - 1)) / n);
    const h = ui.spacing.interact_y;
    var row = ui.horizontal();
    for (labels, 0..) |l, i| {
        if (button(&row, l, .{ .sized = .{ .x = w, .y = h } }).clicked) pressed = i;
    }
    ui.endChild(&row);
    return pressed;
}

/// A minus or plus button with a glyph large enough to read at arm's length.
pub fn stepper(ui: *Ui, glyph: []const u8, size: Vec2, enabled: bool, id_salt: []const u8) Response {
    return button(ui, glyph, .{ .text_size = 22.0, .min_size = size, .enabled = enabled, .id_salt = id_salt });
}

// ---------------------------------------------------------------------------
// Icons and the mark
// ---------------------------------------------------------------------------

pub const Icon = enum { enlarge, reduce };

fn iconSide(ui: *const Ui) f32 {
    return if (isTouch(ui)) 14.0 else 12.0;
}

fn drawIcon(p: kit.Painter, icon: Icon, r: Rect) void {
    const side = r.width();
    const stroke = Stroke.init(1.5, TEXT);
    const arm = side * 0.36;
    const corners = [_]struct { c: Vec2, dx: f32, dy: f32 }{
        .{ .c = r.leftTop(), .dx = 1, .dy = 1 },
        .{ .c = r.rightTop(), .dx = -1, .dy = 1 },
        .{ .c = r.leftBottom(), .dx = 1, .dy = -1 },
        .{ .c = r.rightBottom(), .dx = -1, .dy = -1 },
    };
    for (corners) |k| {
        const elbow = switch (icon) {
            .enlarge => k.c,
            .reduce => k.c.add(.{ .x = k.dx * arm, .y = k.dy * arm }),
        };
        const sign: f32 = if (icon == .enlarge) 1 else -1;
        p.line(elbow, elbow.add(.{ .x = sign * k.dx * arm }), stroke);
        p.line(elbow, elbow.add(.{ .y = sign * k.dy * arm }), stroke);
    }
}

pub fn iconButton(ui: *Ui, icon: Icon, text: []const u8) Response {
    return button(ui, text, .{ .icon = icon });
}

/// The roxel mark: an isometric cube outline in the accent.
pub fn mark(ui: *Ui, size: f32) void {
    const r = ui.allocate(.{ .x = size, .y = size });
    drawMark(ui.painter(), r.center(), size);
}

pub fn drawMark(p: kit.Painter, c: Vec2, size: f32) void {
    const a = size * 0.40;
    const pts = [6]Vec2{
        c.add(.{ .y = -a }),
        c.add(.{ .x = a, .y = -a * 0.5 }),
        c.add(.{ .x = a, .y = a * 0.5 }),
        c.add(.{ .y = a }),
        c.add(.{ .x = -a, .y = a * 0.5 }),
        c.add(.{ .x = -a, .y = -a * 0.5 }),
    };
    const s = Stroke.init(1.5, ACCENT);
    for (0..6) |i| p.line(pts[i], pts[(i + 1) % 6], s);
    for ([_]usize{ 1, 3, 5 }) |i| p.line(c, pts[i], s);
}

// ---------------------------------------------------------------------------
// Checkbox
// ---------------------------------------------------------------------------

/// A box that is unmistakably empty or ticked: dark with a light outline
/// when off, filled with the accent and a dark tick when on.
pub fn checkbox(ui: *Ui, checked: *bool, text: []const u8) Response {
    return checkboxNamed(ui, checked, text, text);
}

pub fn checkboxNamed(ui: *Ui, checked: *bool, text: []const u8, name: []const u8) Response {
    const touch = isTouch(ui);
    const side: f32 = if (touch) 22.0 else 16.0;
    const gap: f32 = if (text.len == 0) 0 else if (touch) 12.0 else 8.0;
    const g = ui.ctx.measure(text, ui.text.body, .proportional, 0).size;
    const height = if (touch) TOUCH_TARGET else @max(g.y, 24.0);
    var resp = ui.allocateResponse(.{ .x = side + gap + (if (text.len > 0) g.x else 0), .y = height }, ui.makeId(name), kit.Sense.clickable);
    if (resp.clicked) {
        checked.* = !checked.*;
        resp.markChanged();
    }
    const p = ui.painter();
    const rect = resp.rect;
    const sq = Rect.fromMinSize(.{ .x = rect.min.x, .y = rect.center().y - side * 0.5 }, .{ .x = side, .y = side });
    if (checked.*) {
        p.rectFilled(sq, 4, ACCENT);
        const s = side * 0.26;
        const c = sq.center();
        p.polyline(&.{ c.add(.{ .x = -s }), c.add(.{ .x = -s * 0.25, .y = s * 0.75 }), c.add(.{ .x = s, .y = -s * 0.7 }) }, Stroke.init(2, BG), false);
    } else {
        p.rect(sq, 4, BG, Stroke.init(1.5, if (resp.hovered) THUMB else OUTLINE));
    }
    if (text.len > 0) p.textAt(.{ .x = sq.max.x + gap, .y = rect.center().y - g.y * 0.5 }, text, ui.text.body, .proportional, TEXT);
    return resp;
}

// ---------------------------------------------------------------------------
// Slider rows
// ---------------------------------------------------------------------------

pub const SliderSpec = struct {
    label: []const u8,
    /// Range the track covers.
    lo: f64,
    hi: f64,
    /// Range the number box and steppers accept.
    limit_lo: f64,
    limit_hi: f64,
    /// One stepper press or arrow key.
    step: f64,
    decimals: u8 = 0,
    /// Added for display (1 for a one-based slice number).
    offset: f64 = 0,
    unit: []const u8 = "",
    /// Shown as "value / total" where the layout has room.
    total: ?usize = null,

    pub fn fraction(lbl: []const u8, lo: f64, hi: f64) SliderSpec {
        return .{ .label = lbl, .lo = lo, .hi = hi, .limit_lo = lo, .limit_hi = hi, .step = 0.05, .decimals = 2 };
    }
    pub fn whole(lbl: []const u8, lo: f64, hi: f64, step: f64) SliderSpec {
        return .{ .label = lbl, .lo = lo, .hi = hi, .limit_lo = lo, .limit_hi = hi, .step = step, .decimals = 0 };
    }
    pub fn limit(self: SliderSpec, lo: f64, hi: f64) SliderSpec {
        var s = self;
        s.limit_lo = lo;
        s.limit_hi = hi;
        return s;
    }
    pub fn withUnit(self: SliderSpec, u: []const u8) SliderSpec {
        var s = self;
        s.unit = u;
        return s;
    }
    fn display(self: *const SliderSpec, ctx: *Ctx, value: f64) []const u8 {
        return formatValue(ctx, value + self.offset, self.decimals, self.unit);
    }
};

fn formatValue(ctx: *Ctx, value: f64, decimals: u8, unit: []const u8) []const u8 {
    return switch (decimals) {
        0 => ctx.fmt("{d:.0}{s}", .{ value, unit }),
        1 => ctx.fmt("{d:.1}{s}", .{ value, unit }),
        2 => ctx.fmt("{d:.2}{s}", .{ value, unit }),
        else => ctx.fmt("{d:.3}{s}", .{ value, unit }),
    };
}

pub const SliderOutcome = struct {
    changed: bool = false,
    /// The change is final (drag ended, stepper, typed number entered).
    committed: bool = false,
};

/// The one control row of the app. Desktop: label column, track, number
/// box. Touch: label over value, minus, track, plus.
pub fn slider(ui: *Ui, spec: SliderSpec, value: *f64) SliderOutcome {
    return if (isTouch(ui)) touchSlider(ui, spec, value) else desktopSlider(ui, spec, value);
}

pub fn sliderF32(ui: *Ui, spec: SliderSpec, value: *f32) SliderOutcome {
    var wide: f64 = value.*;
    const o = slider(ui, spec, &wide);
    if (o.changed) value.* = @floatCast(wide);
    return o;
}

/// The slice position row: one-based, with the slice count.
pub fn sliceSlider(ui: *Ui, index: *usize, max_slices: usize) bool {
    const last: f64 = @floatFromInt(max_slices -| 1);
    var spec = SliderSpec.whole("Slice", 0, last, 1);
    spec.offset = 1;
    spec.total = max_slices;
    var wide: f64 = @floatFromInt(index.*);
    const o = slider(ui, spec, &wide);
    if (o.changed) index.* = @intFromFloat(std.math.clamp(@round(wide), 0, last));
    return o.changed;
}

fn snap(value: f64, spec: SliderSpec) f64 {
    const s = std.math.pow(f64, 10, @floatFromInt(spec.decimals));
    return @round(value * s) / s;
}

fn desktopSlider(ui: *Ui, spec: SliderSpec, value: *f64) SliderOutcome {
    var out = SliderOutcome{};
    var row = ui.childSized(.{ .x = ui.availableWidth(), .y = 24 }, kit.Layout.leftToRight(.center));
    row.spacing.item.x = 8;
    row.spacing.interact_y = 24;
    row.setRowHeight(24);
    labelCell(&row, spec.label, .{ .x = LABEL_W, .y = 24 });
    const width = @max(row.availableWidth() - NUMBER_W - 8, 40);
    const rail = track(&row, spec, value, .{ .x = width, .y = 24 });
    const num = numberBox(&row, spec, value, .{ .x = NUMBER_W, .y = 24 });
    out.changed = rail.changed or num.changed;
    out.committed = rail.drag_stopped or (rail.changed and !rail.dragged) or num.committed;
    ui.endChild(&row);
    return out;
}

fn touchSlider(ui: *Ui, spec: SliderSpec, value: *f64) SliderOutcome {
    var out = SliderOutcome{};
    var row = ui.childSized(.{ .x = ui.availableWidth(), .y = TOUCH_TARGET }, kit.Layout.leftToRight(.center));
    row.spacing.item.x = 10;
    row.setRowHeight(TOUCH_TARGET);
    const cell = row.allocate(.{ .x = TOUCH_LABEL_W, .y = TOUCH_TARGET });
    const shown = if (spec.total) |t| ui.ctx.fmt("{s} / {d}", .{ spec.display(ui.ctx, value.*), t }) else spec.display(ui.ctx, value.*);
    const p = row.painter();
    _ = p.text(cell.leftTop().add(.{ .y = 3 }), Align2.left_top, spec.label, 13.0, MUTED);
    _ = p.text(cell.leftBottom().add(.{ .y = -3 }), Align2.left_bottom, shown, 15.0, TEXT);
    const step = Vec2.v(TOUCH_TARGET, TOUCH_TARGET);
    const minus_id = ui.ctx.fmt("minus {s}", .{spec.label});
    const less = stepper(&row, "\u{2212}", step, value.* > spec.limit_lo, minus_id);
    ui.ctx.hoverText(less, ui.ctx.fmt("Decrease {s}", .{spec.label}));
    if (less.clicked) {
        value.* = std.math.clamp(snap(value.* - spec.step, spec), spec.limit_lo, spec.limit_hi);
        out.changed = true;
        out.committed = true;
    }
    const width = @max(row.availableWidth() - step.x - 10, 40);
    const rail = track(&row, spec, value, .{ .x = width, .y = TOUCH_TARGET });
    out.changed = out.changed or rail.changed;
    out.committed = out.committed or rail.drag_stopped or (rail.changed and !rail.dragged);
    const plus_id = ui.ctx.fmt("plus {s}", .{spec.label});
    const more = stepper(&row, "+", step, value.* < spec.limit_hi, plus_id);
    ui.ctx.hoverText(more, ui.ctx.fmt("Increase {s}", .{spec.label}));
    if (more.clicked) {
        value.* = std.math.clamp(snap(value.* + spec.step, spec), spec.limit_lo, spec.limit_hi);
        out.changed = true;
        out.committed = true;
    }
    ui.endChild(&row);
    return out;
}

/// Rail and thumb: light thumb on a mid-tone rail, travelled part accent.
fn track(ui: *Ui, spec: SliderSpec, value: *f64, size: Vec2) Response {
    const touch = isTouch(ui);
    var resp = ui.allocateResponse(size, ui.makeId(ui.ctx.fmt("track {s}", .{spec.label})), kit.Sense.click_and_drag);
    const rect = resp.rect;
    const radius: f32 = if (touch) 12.0 else 7.0;
    const x0 = rect.min.x + radius;
    const x1 = rect.max.x - radius;
    const span = @max(spec.hi - spec.lo, std.math.floatEps(f64));
    const before = value.*;
    if (resp.is_pointer_down_on or resp.dragged or resp.clicked) {
        if (resp.interact_pointer) |pt| {
            const t: f64 = std.math.clamp((pt.x - x0) / @max(x1 - x0, 1.0), 0.0, 1.0);
            value.* = snap(spec.lo + t * span, spec);
        }
    }
    if (resp.has_focus) {
        const steps = @as(f64, @floatFromInt(ui.ctx.input.right_presses)) - @as(f64, @floatFromInt(ui.ctx.input.left_presses));
        if (steps != 0) value.* = std.math.clamp(snap(value.* + steps * spec.step, spec), spec.limit_lo, spec.limit_hi);
    }
    if (value.* != before) resp.markChanged();
    const p = ui.painter();
    const half: f32 = if (touch) 3.0 else 2.0;
    const y = rect.center().y;
    const t: f32 = @floatCast(std.math.clamp((value.* - spec.lo) / span, 0.0, 1.0));
    const x = x0 + (x1 - x0) * t;
    const rail = Rect.fromMinMax(.{ .x = x0, .y = y - half }, .{ .x = x1, .y = y + half });
    p.rectFilled(rail, half, RAIL);
    p.rectFilled(Rect.fromMinMax(rail.min, .{ .x = x, .y = rail.max.y }), half, ACCENT);
    const grow: f32 = if (resp.dragged) 1.0 else 0.0;
    p.circle(.{ .x = x, .y = y }, radius + grow, THUMB, Stroke.init(1.5, BG));
    if (resp.has_focus and ui.ctx.active_id == null and !resp.hovered) {
        // Keyboard focus ring only once the pointer has moved away.
    }
    return resp;
}

const NumberOutcome = struct { changed: bool = false, committed: bool = false };

/// egui DragValue: drag horizontally to change, click to type.
fn numberBox(ui: *Ui, spec: SliderSpec, value: *f64, size: Vec2) NumberOutcome {
    var out = NumberOutcome{};
    const ctx = ui.ctx;
    const id = ui.makeId(ctx.fmt("number {s}", .{spec.label}));
    // egui sizes the box like a button: text plus padding, at least the
    // requested size (24.94 pt for 13 pt text).
    const h = @max(size.y, ctx.rowHeight(ui.text.button, .proportional) + 2 * ui.spacing.button_padding.y);
    const resp = ui.allocateResponse(.{ .x = size.x, .y = h }, id, kit.Sense.click_and_drag);
    const rect = resp.rect;
    const editing = ctx.edit_id != null and ctx.edit_id.? == id;
    if (!editing) {
        if (resp.dragged) {
            const speed: f64 = if (spec.decimals == 0) 1.0 else 0.01;
            const d = resp.drag_delta.x - resp.drag_delta.y;
            if (d != 0) {
                value.* = std.math.clamp(snap(value.* + d * speed, spec), spec.limit_lo, spec.limit_hi);
                out.changed = true;
            }
        }
        if (resp.drag_stopped) out.committed = true;
        if (resp.clicked and ui.enabled) {
            ctx.edit_id = id;
            ctx.edit_started = true;
            const shown = spec.display(ctx, value.*);
            const n = @min(shown.len, ctx.edit_buf.len - 1);
            @memcpy(ctx.edit_buf[0..n], shown[0..n]);
            ctx.edit_buf[n] = 0;
        }
    }
    if (ctx.edit_commit_id != null and ctx.edit_commit_id.? == id) {
        if (ctx.edit_committed) |typed| {
            const v = std.math.clamp(typed - spec.offset, spec.limit_lo, spec.limit_hi);
            if (v != value.*) {
                value.* = v;
                out.changed = true;
            }
            out.committed = true;
        }
        ctx.edit_commit_id = null;
        ctx.edit_committed = null;
    }
    const vis = widgetVisual(resp, false);
    const p = ui.painter();
    if (ctx.edit_id != null and ctx.edit_id.? == id) {
        p.rect(rect, WIDGET_ROUNDING, BG, Stroke.init(1, ACCENT));
        editField(ui, rect, spec);
    } else {
        p.rect(rect, WIDGET_ROUNDING, vis.fill, vis.stroke);
        const shown = spec.display(ctx, value.*);
        const g = ctx.measure(shown, ui.text.button, .proportional, 0).size;
        p.textAt(.{ .x = rect.center().x - g.x * 0.5, .y = rect.center().y - g.y * 0.5 }, shown, ui.text.button, .proportional, TEXT);
    }
    return out;
}

/// The text field of a number box being edited (an ImGui InputText placed
/// on the box). Enter or leaving the field commits; Escape cancels.
fn editField(ui: *Ui, rect: Rect, spec: SliderSpec) void {
    const ctx = ui.ctx;
    const font = ctx.proportional.font orelse return;
    const id = ctx.edit_id.?;
    const k = ctx.pixels_per_point;
    zgui.pushFont(font, ui.text.button * ctx.proportional.em_to_px * k);
    defer zgui.popFont();
    zgui.pushStyleColor4f(.{ .idx = .frame_bg, .c = .{ 0, 0, 0, 0 } });
    zgui.pushStyleColor4f(.{ .idx = .text, .c = .{ 222.0 / 255.0, 231.0 / 255.0, 239.0 / 255.0, 1 } });
    zgui.pushStyleColor4f(.{ .idx = .text_selected_bg, .c = .{ 36.0 / 255.0, 81.0 / 255.0, 80.0 / 255.0, 1 } });
    zgui.pushStyleVar2f(.{ .idx = .frame_padding, .v = .{ 6 * k, (rect.height() - ui.text.button * ctx.proportional.em_to_px) * 0.5 * k } });
    defer zgui.popStyleVar(.{ .count = 1 });
    defer zgui.popStyleColor(.{ .count = 3 });
    zgui.setCursorScreenPos(.{ rect.min.x * k, rect.min.y * k });
    zgui.setNextItemWidth(rect.width() * k);
    if (ctx.edit_started) {
        zgui.setKeyboardFocusHere(0);
        ctx.edit_started = false;
    }
    const buf: [:0]u8 = ctx.edit_buf[0 .. ctx.edit_buf.len - 1 :0];
    const label_z = ctx.fmt("##edit{d}\x00", .{id});
    const entered = zgui.inputText(label_z[0 .. label_z.len - 1 :0], .{ .buf = buf, .flags = .{ .auto_select_all = true, .enter_returns_true = true } });
    const deactivated = zgui.isItemDeactivated();
    if (ctx.input.keyPressed(.escape)) {
        ctx.edit_id = null;
        return;
    }
    if (entered or deactivated) {
        const len = std.mem.indexOfScalar(u8, &ctx.edit_buf, 0) orelse 0;
        var text = std.mem.trim(u8, ctx.edit_buf[0..len], " ");
        if (spec.unit.len > 0 and std.mem.endsWith(u8, text, spec.unit)) text = std.mem.trim(u8, text[0 .. text.len - spec.unit.len], " ");
        if (std.fmt.parseFloat(f64, text)) |v| {
            ctx.edit_committed = v;
            ctx.edit_commit_id = id;
        } else |_| {}
        ctx.edit_id = null;
        ctx.wants_repaint = true;
    }
}

// ---------------------------------------------------------------------------
// Segmented control
// ---------------------------------------------------------------------------

/// A mutually exclusive choice among a few visible options. Returns the
/// index clicked this frame. Touch layouts stretch options across the row.
pub fn segmented(ui: *Ui, name: []const u8, selected: ?usize, labels: []const []const u8) ?usize {
    const touch = isTouch(ui);
    var clicked: ?usize = null;
    var scope = ui.beginFrame(name, .{ .fill = BG, .stroke = Stroke.init(1, HAIRLINE), .rounding = 7, .inner_margin = kit.Margin.same(2) });
    var inner = &scope.ui;
    inner.spacing.item.x = 2;
    inner.spacing.button_padding = .{ .x = if (touch) 4 else 9, .y = 4 };
    const n: f32 = @floatFromInt(@max(labels.len, 1));
    const height: f32 = if (touch) TOUCH_TARGET - 6 else 24;
    var widths: [8]f32 = undefined;
    var sum: f32 = 0;
    for (labels, 0..) |l, i| {
        widths[i] = ui.ctx.measure(l, inner.text.button, .proportional, 0).size.x;
        sum += widths[i];
    }
    const spare: f32 = if (touch) @max((inner.availableWidth() - 2 * (n - 1) - sum) / n, 8) else 0;
    inner.spacing.interact_y = height;
    var row = inner.horizontal();
    for (labels, 0..) |l, i| {
        const active = selected != null and selected.? == i;
        const w: f32 = if (touch) @floor(widths[i] + spare) else 0;
        const r = button(&row, l, .{
            .min_size = .{ .x = w, .y = height },
            .rounding = 5,
            .fill = if (active) SELECTED else Color.transparent,
            .stroke = if (active) Stroke.init(1, ACCENT) else Stroke.none,
            .text_color = if (active) HEADING else MUTED,
            .id_salt = ui.ctx.fmt("{s}#{d}", .{ name, i }),
        });
        if (r.clicked) clicked = i;
    }
    inner.endChild(&row);
    _ = ui.endFrame(&scope);
    return clicked;
}

// ---------------------------------------------------------------------------
// Rows and labels
// ---------------------------------------------------------------------------

/// One fixed-height row of a touch controls page, vertically centred.
pub fn touchRow(ui: *Ui) Ui {
    var row = ui.childSized(.{ .x = ui.availableWidth(), .y = TOUCH_TARGET }, kit.Layout.leftToRight(.center));
    row.setRowHeight(TOUCH_TARGET);
    return row;
}

/// A muted row label in the same column the control rows use.
pub fn rowLabel(ui: *Ui, text: []const u8) void {
    const sz = if (isTouch(ui)) Vec2.v(TOUCH_LABEL_W, TOUCH_TARGET) else Vec2.v(LABEL_W, 24);
    labelCell(ui, text, sz);
}

/// A fixed-size cell with muted text at its left.
fn labelCell(ui: *Ui, text: []const u8, size: Vec2) void {
    const r = ui.allocate(size);
    _ = ui.painter().text(r.leftCenter(), Align2.left_center, text, if (isTouch(ui)) 14.0 else 13.0, MUTED);
}

/// A muted caption / value pair: `Voxels   256 × 256 × 128`.
pub fn keyValue(ui: *Ui, key: []const u8, value: []const u8) void {
    const touch = isTouch(ui);
    const height: f32 = if (touch) 28.0 else 22.0;
    const saved = ui.spacing.interact_y;
    ui.spacing.interact_y = height;
    var row = ui.horizontal();
    ui.spacing.interact_y = saved;
    labelCell(&row, key, .{ .x = if (touch) 84.0 else 68.0, .y = height });
    _ = label(&row, value, .{ .wrap = true });
    ui.endChild(&row);
}

/// Keep both ends of a long name. Returns the text unchanged when it fits.
pub fn elideMiddle(ctx: *Ctx, text: []const u8, size: f32, max_width: f32) []const u8 {
    if (ctx.measure(text, size, .proportional, 0).size.x <= max_width) return text;
    // Work in codepoints.
    var starts: [512]usize = undefined;
    var count: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var pos: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        if (count < starts.len) {
            starts[count] = pos;
            count += 1;
        }
        pos += cp.len;
    }
    const a = ctx.arena.allocator();
    const build = struct {
        fn f(alloc: std.mem.Allocator, t: []const u8, st: []const usize, kept: usize) []const u8 {
            const head = kept * 2 / 5;
            const tail = kept - head;
            const head_end = if (head < st.len) st[head] else t.len;
            const tail_start = if (st.len >= tail) st[st.len - tail] else 0;
            return std.fmt.allocPrint(alloc, "{s}\u{2026}{s}", .{ t[0..head_end], if (tail == 0) "" else t[tail_start..] }) catch "\u{2026}";
        }
    }.f;
    var low: usize = 0;
    var high: usize = count -| 1;
    var best: []const u8 = "\u{2026}";
    while (low <= high) {
        const mid = (low + high) / 2;
        const cand = build(a, text, starts[0..count], mid);
        if (ctx.measure(cand, size, .proportional, 0).size.x <= max_width) {
            best = cand;
            low = mid + 1;
        } else if (mid == 0) {
            break;
        } else {
            high = mid - 1;
        }
    }
    return best;
}

/// Useful window range for a volume: the track covers it, the number box
/// and steppers accept the full stored range.
pub const WindowRanges = struct { center_lo: f64, center_hi: f64, width_lo: f64, width_hi: f64 };

pub fn windowRanges(center: ?f64, width_in: ?f64) WindowRanges {
    if (center) |c| {
        const w = @max(width_in.?, 1.0);
        return .{ .center_lo = c - w * 0.5, .center_hi = c + w * 0.5, .width_lo = 1.0, .width_hi = w * 2.0 };
    }
    return .{ .center_lo = 0, .center_hi = 65535, .width_lo = 1, .width_hi = 65536 };
}

/// The two windowing rows, shared by 3D and 2D. Returns true on commit.
pub fn windowRows(ui: *Ui, center: *f32, width: *f32, r: WindowRanges) bool {
    const step = windowStep(r.width_lo, r.width_hi);
    const c = sliderF32(ui, SliderSpec.whole("Center", r.center_lo, r.center_hi, step).limit(-65535, 65535), center);
    const w = sliderF32(ui, SliderSpec.whole("Width", r.width_lo, r.width_hi, step).limit(1, 65536), width);
    return c.committed or w.committed;
}

/// About 1/200 of the useful range, rounded up to a tidy number.
pub fn windowStep(lo: f64, hi: f64) f64 {
    const raw = (hi - lo) / 200.0;
    if (raw <= 1.0) return 1.0;
    const mag = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    for ([_]f64{ 1, 2, 5, 10 }) |m| {
        if (m * mag >= raw) return m * mag;
    }
    return raw;
}

// ---------------------------------------------------------------------------
// Popups: menu buttons and combo boxes
// ---------------------------------------------------------------------------

pub const PopupScope = struct {
    ui: Ui,
    open: bool,
    id: kit.Id,
    prev_over: bool,
};

/// egui `menu_button`: a button that toggles a popup below it. When the
/// returned scope is open, add content to `scope.ui` then call `endPopup`.
pub fn menuButton(ui: *Ui, text: []const u8, width: f32) PopupScope {
    const ctx = ui.ctx;
    const id = ui.makeId(ctx.fmt("menu {s}", .{text}));
    const is_open = ctx.popup != null and ctx.popup.?.id == id;
    const resp = button(ui, text, .{ .open = is_open, .id_salt = ctx.fmt("menu {s}", .{text}) });
    var open = is_open;
    if (resp.clicked) {
        if (is_open) {
            ctx.popup = null;
            open = false;
        } else {
            ctx.popup = .{ .id = id, .anchor = resp.rect };
            ctx.popup_opened_this_frame = true;
            open = true;
        }
    }
    if (!open) return .{ .ui = ui.*, .open = false, .id = id, .prev_over = ctx.over };
    return beginPopupAt(ui, id, resp.rect, width);
}

fn beginPopupAt(ui: *Ui, id: kit.Id, anchor: Rect, width: f32) PopupScope {
    const ctx = ui.ctx;
    const prev = ctx.over;
    ctx.over = true;
    const margin = ctx.style.menu_margin;
    var pos = Vec2.v(anchor.min.x, anchor.max.y + 4);
    const remembered_h = ctx.getMem(id ^ 0x707) orelse 100;
    const outer_w = width + 2 * margin + 2;
    if (pos.x + outer_w > ctx.screen.max.x - 4) pos.x = ctx.screen.max.x - 4 - outer_w;
    if (pos.y + remembered_h > ctx.screen.max.y - 4) pos.y = anchor.min.y - 4 - remembered_h;
    const outer = Rect.fromMinSize(pos, .{ .x = outer_w, .y = remembered_h });
    const p = ctx.painter(ctx.screen, 1);
    // A soft shadow, then the window frame.
    p.rectFilled(outer.translate(.{ .y = 4 }).expand(4), 10, Color{ .r = 0, .g = 0, .b = 0, .a = 60 });
    p.rect(outer, 6, PANEL, Stroke.init(1, OUTLINE));
    const inner = Rect.fromMinSize(pos.add(.{ .x = margin + 1, .y = margin + 1 }), .{ .x = width, .y = 2000 });
    var c = kit.Ui.root(ctx, "popup", inner, kit.Layout.top_down);
    c.id = id;
    c.clip = ctx.screen;
    c.setMinWidth(width);
    return .{ .ui = c, .open = true, .id = id, .prev_over = prev };
}

pub fn endPopup(scope: *PopupScope) void {
    if (!scope.open) return;
    const ctx = scope.ui.ctx;
    const margin = ctx.style.menu_margin;
    const h = scope.ui.min_rect.height() + 2 * margin + 2;
    if (ctx.getMem(scope.id ^ 0x707) != h) {
        ctx.setMem(scope.id ^ 0x707, h);
        ctx.wants_repaint = true;
    }
    const outer = Rect.fromMinSize(scope.ui.max_rect.min.sub(.{ .x = margin + 1, .y = margin + 1 }), .{ .x = scope.ui.max_rect.width() + 2 * margin + 2, .y = h });
    ctx.popup_rect = outer;
    ctx.over = scope.prev_over;
}

/// egui ComboBox: shows the selected text; returns the index picked.
pub fn comboBox(ui: *Ui, name: []const u8, selected_text: []const u8, items: []const []const u8, selected: usize, width: f32) ?usize {
    const ctx = ui.ctx;
    const id = ui.makeId(ctx.fmt("combo {s}", .{name}));
    const is_open = ctx.popup != null and ctx.popup.?.id == id;
    const shown = elideMiddle(ctx, selected_text, ui.text.button, width - 2 * ui.spacing.button_padding.x - 16);
    const resp = button(ui, "", .{ .sized = .{ .x = width, .y = ui.spacing.interact_y }, .open = is_open, .id_salt = ctx.fmt("combo {s}", .{name}) });
    const p = ui.painter();
    const g = ctx.measure(shown, ui.text.button, .proportional, 0).size;
    p.textAt(.{ .x = resp.rect.min.x + ui.spacing.button_padding.x, .y = resp.rect.center().y - g.y * 0.5 }, shown, ui.text.button, .proportional, TEXT);
    const c = Vec2.v(resp.rect.max.x - ui.spacing.button_padding.x - 5, resp.rect.center().y);
    p.polyline(&.{ c.add(.{ .x = -5, .y = -2.5 }), c.add(.{ .y = 2.5 }), c.add(.{ .x = 5, .y = -2.5 }) }, Stroke.init(1.5, TEXT), false);
    if (resp.clicked) {
        if (is_open) ctx.popup = null else {
            ctx.popup = .{ .id = id, .anchor = resp.rect };
            ctx.popup_opened_this_frame = true;
        }
    }
    const open_now = ctx.popup != null and ctx.popup.?.id == id;
    if (!open_now) return null;
    var scope = beginPopupAt(ui, id, resp.rect, width);
    var picked: ?usize = null;
    for (items, 0..) |item, i| {
        const r = button(&scope.ui, item, .{ .sized = .{ .x = width, .y = scope.ui.spacing.interact_y }, .selected = i == selected, .fill = if (i == selected) SELECTED else Color.transparent, .stroke = if (i == selected) Stroke.init(1, ACCENT) else Stroke.none, .id_salt = ctx.fmt("{s}#item{d}", .{ name, i }) });
        if (r.clicked) picked = i;
    }
    endPopup(&scope);
    if (picked != null) ctx.popup = null;
    return picked;
}

/// egui Spinner: a rotating arc.
pub fn spinner(ui: *Ui) void {
    const s = ui.spacing.interact_y * 0.7;
    const r = ui.allocate(.{ .x = s, .y = s });
    const c = r.center();
    const radius = s * 0.5 - 2;
    const t: f32 = @floatCast(ui.ctx.input.time);
    const start = t * 4.0;
    var pts: [12]Vec2 = undefined;
    for (0..pts.len) |i| {
        const a = start + @as(f32, @floatFromInt(i)) / @as(f32, pts.len - 1) * std.math.pi * 1.5;
        pts[i] = c.add(.{ .x = @cos(a) * radius, .y = @sin(a) * radius });
    }
    ui.painter().polyline(&pts, Stroke.init(2, TEXT), false);
    ui.ctx.wants_repaint = true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "window steps are tidy" {
    try std.testing.expectEqual(@as(f64, 50), windowStep(1, 5048));
    try std.testing.expectEqual(@as(f64, 2), windowStep(1, 400));
    try std.testing.expectEqual(@as(f64, 1), windowStep(1, 50));
}

test "long names keep both ends" {
    var ctx = Ctx.init(std.testing.allocator);
    defer ctx.deinit();
    ctx.beginFrame(Rect.fromMinSize(.{}, .{ .x = 100, .y = 100 }), null, null);
    const name = "backpack+purse_fishtank+goldfish_THREAT-knife_20260227-191512";
    const shown = elideMiddle(&ctx, name, 13.0, 200.0);
    try std.testing.expect(ctx.measure(shown, 13.0, .proportional, 0).size.x <= 200.0);
    try std.testing.expect(std.mem.startsWith(u8, shown, "backpack"));
    try std.testing.expect(std.mem.endsWith(u8, shown, "191512"));
    try std.testing.expect(std.mem.indexOf(u8, shown, "\u{2026}") != null);
    try std.testing.expectEqualStrings(name, elideMiddle(&ctx, name, 13.0, 2000.0));
    ctx.endFrame();
}
