//! A small immediate-mode layout and interaction kit with egui semantics,
//! drawn through Dear ImGui draw lists.
//!
//! roxel's interface is written against egui: panels that remember their
//! size, a cursor that advances by item size plus `item_spacing`, horizontal
//! rows whose items centre on the row, right-to-left sub-layouts and equal
//! columns. Reproducing those rules (instead of ImGui's own window layout)
//! lets the panels be ported almost line by line and land on the same pixels.
//!
//! ImGui provides fonts, text rasterisation, draw lists and the WebGPU
//! renderer; it also hosts the one text field (editing a number box). All
//! other interaction (hover, click, drag, focus, popups) is handled here
//! from the raw `Input` the platform layer collects, so the same code runs
//! natively and, later, in the browser.

const std = @import("std");
const zgui = @import("zgui");

// ---------------------------------------------------------------------------
// Geometry and colour
// ---------------------------------------------------------------------------

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub const zero: Vec2 = .{};
    pub fn v(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2, s: f32) Vec2 {
        return .{ .x = a.x * s, .y = a.y * s };
    }
    pub fn mul(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x * b.x, .y = a.y * b.y };
    }
    pub fn length(a: Vec2) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }
    pub fn normalized(a: Vec2) Vec2 {
        const l = a.length();
        return if (l > 0) a.scale(1.0 / l) else a;
    }
    pub fn arr(a: Vec2) [2]f32 {
        return .{ a.x, a.y };
    }
};

pub const Rect = struct {
    min: Vec2 = .{},
    max: Vec2 = .{},

    pub const nothing: Rect = .{ .min = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) }, .max = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) } };
    pub const everything: Rect = .{ .min = .{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) }, .max = .{ .x = std.math.inf(f32), .y = std.math.inf(f32) } };

    pub fn fromMinSize(min: Vec2, sz: Vec2) Rect {
        return .{ .min = min, .max = min.add(sz) };
    }
    pub fn fromMinMax(min: Vec2, max: Vec2) Rect {
        return .{ .min = min, .max = max };
    }
    pub fn fromCenterSize(c: Vec2, sz: Vec2) Rect {
        return .{ .min = c.sub(sz.scale(0.5)), .max = c.add(sz.scale(0.5)) };
    }
    pub fn width(r: Rect) f32 {
        return r.max.x - r.min.x;
    }
    pub fn height(r: Rect) f32 {
        return r.max.y - r.min.y;
    }
    pub fn size(r: Rect) Vec2 {
        return .{ .x = r.width(), .y = r.height() };
    }
    pub fn center(r: Rect) Vec2 {
        return .{ .x = (r.min.x + r.max.x) * 0.5, .y = (r.min.y + r.max.y) * 0.5 };
    }
    pub fn left(r: Rect) f32 {
        return r.min.x;
    }
    pub fn right(r: Rect) f32 {
        return r.max.x;
    }
    pub fn top(r: Rect) f32 {
        return r.min.y;
    }
    pub fn bottom(r: Rect) f32 {
        return r.max.y;
    }
    pub fn leftTop(r: Rect) Vec2 {
        return r.min;
    }
    pub fn rightBottom(r: Rect) Vec2 {
        return r.max;
    }
    pub fn leftBottom(r: Rect) Vec2 {
        return .{ .x = r.min.x, .y = r.max.y };
    }
    pub fn rightTop(r: Rect) Vec2 {
        return .{ .x = r.max.x, .y = r.min.y };
    }
    pub fn leftCenter(r: Rect) Vec2 {
        return .{ .x = r.min.x, .y = r.center().y };
    }
    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.min.x and p.x <= r.max.x and p.y >= r.min.y and p.y <= r.max.y;
    }
    pub fn containsRect(r: Rect, o: Rect) bool {
        return r.contains(o.min) and r.contains(o.max);
    }
    pub fn shrink(r: Rect, m: f32) Rect {
        return r.shrink2(.{ .x = m, .y = m });
    }
    pub fn shrink2(r: Rect, m: Vec2) Rect {
        return .{ .min = r.min.add(m), .max = r.max.sub(m) };
    }
    pub fn expand(r: Rect, m: f32) Rect {
        return r.shrink(-m);
    }
    pub fn translate(r: Rect, d: Vec2) Rect {
        return .{ .min = r.min.add(d), .max = r.max.add(d) };
    }
    pub fn intersect(a: Rect, b: Rect) Rect {
        return .{
            .min = .{ .x = @max(a.min.x, b.min.x), .y = @max(a.min.y, b.min.y) },
            .max = .{ .x = @min(a.max.x, b.max.x), .y = @min(a.max.y, b.max.y) },
        };
    }
    pub fn unionWith(a: Rect, b: Rect) Rect {
        return .{
            .min = .{ .x = @min(a.min.x, b.min.x), .y = @min(a.min.y, b.min.y) },
            .max = .{ .x = @max(a.max.x, b.max.x), .y = @max(a.max.y, b.max.y) },
        };
    }
    pub fn isPositive(r: Rect) bool {
        return r.width() > 0 and r.height() > 0;
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.min.x == b.min.x and a.min.y == b.min.y and a.max.x == b.max.x and a.max.y == b.max.y;
    }
};

/// Straight-alpha sRGB colour. `gammaMultiply` scales alpha only, which,
/// blended with straight alpha, equals egui's premultiplied multiply.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
    pub fn gray(l: u8) Color {
        return .{ .r = l, .g = l, .b = l };
    }
    pub fn gammaMultiply(c: Color, f: f32) Color {
        var out = c;
        out.a = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt(c.a)) * f, 0, 255)));
        return out;
    }
    /// ImGui's packed ABGR.
    pub fn u32v(c: Color) u32 {
        return @as(u32, c.a) << 24 | @as(u32, c.b) << 16 | @as(u32, c.g) << 8 | @as(u32, c.r);
    }
    pub fn isTransparent(c: Color) bool {
        return c.a == 0;
    }
};

pub const Stroke = struct {
    width: f32 = 0,
    color: Color = Color.transparent,

    pub const none: Stroke = .{};
    pub fn init(w: f32, c: Color) Stroke {
        return .{ .width = w, .color = c };
    }
};

pub const Align = enum { min, center, max };
pub const Align2 = struct {
    x: Align,
    y: Align,
    pub const left_top: Align2 = .{ .x = .min, .y = .min };
    pub const left_center: Align2 = .{ .x = .min, .y = .center };
    pub const left_bottom: Align2 = .{ .x = .min, .y = .max };
    pub const center_top: Align2 = .{ .x = .center, .y = .min };
    pub const center_center: Align2 = .{ .x = .center, .y = .center };
    pub const center_bottom: Align2 = .{ .x = .center, .y = .max };
    pub const right_top: Align2 = .{ .x = .max, .y = .min };
    pub const right_center: Align2 = .{ .x = .max, .y = .center };
    pub const right_bottom: Align2 = .{ .x = .max, .y = .max };

    pub fn anchorRect(a: Align2, pos: Vec2, sz: Vec2) Rect {
        const x = switch (a.x) {
            .min => pos.x,
            .center => pos.x - sz.x * 0.5,
            .max => pos.x - sz.x,
        };
        const y = switch (a.y) {
            .min => pos.y,
            .center => pos.y - sz.y * 0.5,
            .max => pos.y - sz.y,
        };
        return Rect.fromMinSize(.{ .x = x, .y = y }, sz);
    }
};

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

pub const Key = enum { escape, enter, tab, left, right, up, down };

/// Raw input for one frame, in logical points. Filled by the platform layer.
pub const Input = struct {
    pointer: ?Vec2 = null,
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
    /// Scroll this frame in points (scroll areas).
    scroll: Vec2 = .{},
    /// Raw wheel/trackpad scroll this frame (lines, or 0.1 pt when precise).
    scroll_lines: f32 = 0,
    /// The scroll came from a trackpad (fractional, pixel-precise).
    scroll_precise: bool = false,
    /// Pinch / ctrl-scroll zoom factor this frame (1 = none).
    zoom_delta: f32 = 1.0,
    shift: bool = false,
    ctrl: bool = false,
    keys_pressed: std.EnumSet(Key) = .initEmpty(),
    /// Arrow presses this frame (repeats included).
    left_presses: u32 = 0,
    right_presses: u32 = 0,
    time: f64 = 0,
    has_touch: bool = false,

    pub fn keyPressed(self: *const Input, k: Key) bool {
        return self.keys_pressed.contains(k);
    }

    /// Clear the per-frame edges, keeping held state.
    pub fn endFrame(self: *Input) void {
        self.pressed = false;
        self.released = false;
        self.scroll = .{};
        self.scroll_lines = 0;
        self.scroll_precise = false;
        self.zoom_delta = 1.0;
        self.keys_pressed = .initEmpty();
        self.left_presses = 0;
        self.right_presses = 0;
    }
};

// ---------------------------------------------------------------------------
// Fonts and text
// ---------------------------------------------------------------------------

/// egui sizes fonts by the em; ImGui by ascent - descent. For Ubuntu-Light
/// (UPM 1000, ascent 932, descent -189, line gap 28) an egui size `s` is an
/// ImGui size of `s * 1.121`, and egui's row height is `s * 1.149`.
pub const FontFace = struct {
    font: ?zgui.Font = null,
    em_to_px: f32,
    row_factor: f32,
};

pub const FontKind = enum { proportional, monospace };

pub const Galley = struct {
    size: Vec2,
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const Id = u64;

pub fn hashId(parent: Id, label: []const u8) Id {
    var h = std.hash.Wyhash.init(parent);
    h.update(label);
    return h.final();
}

pub fn hashIdInt(parent: Id, n: usize) Id {
    var h = std.hash.Wyhash.init(parent);
    h.update(std.mem.asBytes(&n));
    return h.final();
}

pub const Sense = struct {
    click: bool = false,
    drag: bool = false,
    pub const hover: Sense = .{};
    pub const clickable: Sense = .{ .click = true };
    pub const draggable: Sense = .{ .drag = true };
    pub const click_and_drag: Sense = .{ .click = true, .drag = true };
};

pub const Response = struct {
    id: Id = 0,
    rect: Rect = .{},
    hovered: bool = false,
    /// Pointer went down on this widget this frame.
    pressed: bool = false,
    /// Pointer is held down on this widget.
    is_pointer_down_on: bool = false,
    clicked: bool = false,
    drag_started: bool = false,
    dragged: bool = false,
    drag_stopped: bool = false,
    drag_delta: Vec2 = .{},
    interact_pointer: ?Vec2 = null,
    has_focus: bool = false,
    changed: bool = false,
    enabled: bool = true,

    pub fn markChanged(self: *Response) void {
        self.changed = true;
    }
};

const PanelMemory = struct { size: f32 };
const PopupState = struct { id: Id, anchor: Rect };

pub const Ctx = struct {
    gpa: std.mem.Allocator,
    /// Per-frame scratch (formatted strings).
    arena: std.heap.ArenaAllocator,
    input: Input = .{},
    screen: Rect = .{},
    pixels_per_point: f32 = 1.0,
    proportional: FontFace = .{ .em_to_px = 1.121, .row_factor = 1.149 },
    monospace: FontFace = .{ .em_to_px = 1.0, .row_factor = 1.0 },
    draw_main: ?zgui.DrawList = null,
    draw_over: ?zgui.DrawList = null,
    /// Layer currently drawn into.
    over: bool = false,

    active_id: ?Id = null,
    active_moved: bool = false,
    press_origin: Vec2 = .{},
    last_pointer: ?Vec2 = null,
    focus_id: ?Id = null,
    hovered_any: bool = false,

    popup: ?PopupState = null,
    popup_rect_prev: ?Rect = null,
    popup_rect: ?Rect = null,
    popup_opened_this_frame: bool = false,

    tooltip_id: ?Id = null,
    tooltip_text: []const u8 = "",
    tooltip_since: f64 = 0,
    tooltip_hover_id: ?Id = null,

    /// Remembered panel sizes (egui's panels use last frame's size).
    panels: std.AutoHashMapUnmanaged(Id, PanelMemory) = .empty,
    /// Generic persistent floats (scroll offsets, band handle index).
    memory: std.AutoHashMapUnmanaged(Id, f32) = .empty,

    /// Text edit state for number boxes.
    edit_id: ?Id = null,
    edit_buf: [64:0]u8 = [_:0]u8{0} ** 64,
    edit_started: bool = false,
    edit_committed: ?f64 = null,
    edit_commit_id: ?Id = null,

    /// Repaint requested (animations, edits).
    wants_repaint: bool = false,
    /// Style given to panels and roots (set per layout by the theme).
    style: Spacing = .{},
    text_sizes: TextStyleSizes = .{},
    /// Tests: every text and rect painted, with its clip rect.
    recorder: ?*std.ArrayList(Recorded) = null,

    pub fn init(gpa: std.mem.Allocator) Ctx {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Ctx) void {
        self.panels.deinit(self.gpa);
        self.memory.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn fmt(self: *Ctx, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), f, args) catch "";
    }

    /// Start a frame: `screen` in points, draw lists from ImGui (null in
    /// headless tests, where only layout and interaction run).
    pub fn beginFrame(self: *Ctx, screen: Rect, main: ?zgui.DrawList, over: ?zgui.DrawList) void {
        _ = self.arena.reset(.retain_capacity);
        self.screen = screen;
        self.draw_main = main;
        self.draw_over = over;
        self.over = false;
        self.hovered_any = false;
        self.popup_rect_prev = self.popup_rect;
        self.popup_rect = null;
        self.popup_opened_this_frame = false;
        self.tooltip_hover_id = null;
        self.wants_repaint = false;
        if (self.input.pressed) {
            if (self.input.pointer) |p| self.press_origin = p;
            self.active_moved = false;
        }
        if (self.active_id != null and self.input.pointer != null) {
            if (self.input.pointer.?.sub(self.press_origin).length() > 6.0) self.active_moved = true;
        }
    }

    pub fn endFrame(self: *Ctx) void {
        // Clicking outside an open popup closes it (egui menu behaviour).
        if (self.popup != null and self.input.pressed and !self.popup_opened_this_frame) {
            const inside = if (self.input.pointer) |p| (if (self.popup_rect) |r| r.contains(p) else false) or self.popup.?.anchor.contains(p) else false;
            if (!inside) self.popup = null;
        }
        if (self.popup != null and self.input.keyPressed(.escape) and self.edit_id == null) self.popup = null;
        if (self.popup == null) self.popup_rect = null;
        if (self.input.released or !self.input.down) self.active_id = null;
        self.last_pointer = self.input.pointer;
        self.drawTooltip();
        self.input.endFrame();
    }

    pub fn popupOpen(self: *const Ctx) bool {
        return self.popup != null;
    }

    pub fn wantsKeyboard(self: *const Ctx) bool {
        return self.edit_id != null;
    }

    fn blockedByPopup(self: *const Ctx, p: Vec2) bool {
        if (self.over) return false;
        if (self.popup_rect_prev) |r| if (self.popup != null and r.contains(p)) return true;
        return false;
    }

    /// Hit-test and update interaction state for a widget.
    pub fn interact(self: *Ctx, id: Id, rect: Rect, clip: Rect, sense: Sense, enabled: bool) Response {
        var r = Response{ .id = id, .rect = rect, .enabled = enabled };
        const p = self.input.pointer orelse return r;
        const visible = rect.intersect(clip);
        const inside = visible.isPositive() and visible.contains(p) and !self.blockedByPopup(p);
        if (inside) self.hovered_any = true;
        if (!enabled) return r;
        const interactive = sense.click or sense.drag;
        r.hovered = inside and (self.active_id == null or self.active_id.? == id);
        if (!interactive) return r;
        if (self.input.pressed and inside and self.active_id == null) {
            self.active_id = id;
            self.press_origin = p;
            self.active_moved = false;
            r.pressed = true;
            self.focus_id = id;
            r.interact_pointer = p;
        }
        if (self.active_id != null and self.active_id.? == id) {
            r.is_pointer_down_on = self.input.down or self.input.released;
            r.interact_pointer = p;
            if (sense.drag) {
                const last = self.last_pointer orelse p;
                r.drag_delta = p.sub(last);
                if (self.active_moved or !sense.click) {
                    r.dragged = self.input.down;
                    if (self.input.down and (r.pressed and !sense.click)) r.drag_started = true;
                }
                if (self.active_moved and self.input.down and self.memory.get(id ^ 0xd5) == null) {
                    r.drag_started = true;
                    self.memory.put(self.gpa, id ^ 0xd5, 1) catch {};
                }
            }
            if (self.input.released) {
                if (sense.click and !self.active_moved and inside) r.clicked = true;
                if (sense.drag and (self.active_moved or !sense.click)) r.drag_stopped = true;
                _ = self.memory.remove(id ^ 0xd5);
            }
        }
        r.has_focus = self.focus_id != null and self.focus_id.? == id;
        if (r.hovered and !self.input.down) self.tooltip_hover_id = id;
        return r;
    }

    // -- persistent memory ------------------------------------------------

    pub fn getMem(self: *Ctx, id: Id) ?f32 {
        return self.memory.get(id);
    }
    pub fn setMem(self: *Ctx, id: Id, value: f32) void {
        self.memory.put(self.gpa, id, value) catch {};
    }
    pub fn removeMem(self: *Ctx, id: Id) void {
        _ = self.memory.remove(id);
    }

    // -- tooltips ---------------------------------------------------------

    pub fn hoverText(self: *Ctx, r: Response, text: []const u8) void {
        if (!r.hovered or self.input.down) return;
        if (self.tooltip_id == null or self.tooltip_id.? != r.id) {
            self.tooltip_id = r.id;
            self.tooltip_since = self.input.time;
        }
        self.tooltip_text = self.arena.allocator().dupe(u8, text) catch "";
        self.wants_repaint = true;
    }

    fn drawTooltip(self: *Ctx) void {
        const id = self.tooltip_id orelse return;
        if (self.tooltip_hover_id == null or self.tooltip_hover_id.? != id) {
            self.tooltip_id = null;
            return;
        }
        if (self.input.time - self.tooltip_since < 0.5 or self.tooltip_text.len == 0) return;
        const p = self.input.pointer orelse return;
        const prev = self.over;
        self.over = true;
        defer self.over = prev;
        const size: f32 = 13.5;
        const g = self.measure(self.tooltip_text, size, .proportional, 360);
        var rect = Rect.fromMinSize(p.add(.{ .x = 12, .y = 18 }), g.size.add(.{ .x = 16, .y = 12 }));
        if (rect.max.x > self.screen.max.x) rect = rect.translate(.{ .x = self.screen.max.x - rect.max.x - 4 });
        if (rect.max.y > self.screen.max.y) rect = rect.translate(.{ .y = p.y - rect.max.y - 8 });
        const pnt = self.painter(self.screen, 1);
        pnt.rect(rect, 6, Color.rgb(23, 31, 40), Stroke.init(1, Color.rgb(124, 148, 168)));
        pnt.textWrapped(rect.min.add(.{ .x = 8, .y = 6 }), self.tooltip_text, size, Color.rgb(222, 231, 239), 360);
    }

    // -- text -------------------------------------------------------------

    fn face(self: *Ctx, kind: FontKind) *FontFace {
        return switch (kind) {
            .proportional => &self.proportional,
            .monospace => &self.monospace,
        };
    }

    /// Row height of egui text at `size` points.
    pub fn rowHeight(self: *Ctx, size: f32, kind: FontKind) f32 {
        return @round(size * self.face(kind).row_factor * 32.0) / 32.0;
    }

    /// Size of `text` at `size` (egui points). `wrap` <= 0 disables wrapping.
    pub fn measure(self: *Ctx, text: []const u8, size: f32, kind: FontKind, wrap: f32) Galley {
        const f = self.face(kind);
        const row = self.rowHeight(size, kind);
        if (text.len == 0) return .{ .size = .{ .x = 0, .y = row } };
        const font = f.font orelse {
            // Headless: an approximate advance so layout tests are meaningful.
            const w = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(text) catch text.len)) * size * 0.5;
            if (wrap > 0 and w > wrap) {
                const lines = @ceil(w / wrap);
                return .{ .size = .{ .x = wrap, .y = row * lines } };
            }
            return .{ .size = .{ .x = w, .y = row } };
        };
        // ImGui runs in physical pixels (see `Painter`).
        const k = self.pixels_per_point;
        zgui.pushFont(font, size * f.em_to_px * k);
        defer zgui.popFont();
        const s = zgui.calcTextSize(text, .{ .wrap_width = if (wrap > 0) wrap * k else -1.0 });
        const imgui_line = size * f.em_to_px * k;
        const lines = @max(@round(s[1] / imgui_line), 1.0);
        return .{ .size = .{ .x = s[0] / k, .y = row * lines } };
    }

    pub fn painter(self: *Ctx, clip: Rect, opacity: f32) Painter {
        return .{ .ctx = self, .clip = clip, .opacity = opacity };
    }

    fn drawList(self: *Ctx) ?zgui.DrawList {
        return if (self.over) self.draw_over else self.draw_main;
    }
};

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

pub const StrokeKind = enum { inside, middle, outside };

/// A painted shape, as seen by layout tests.
pub const Recorded = struct {
    kind: enum { text, rect },
    rect: Rect,
    clip: Rect,
    /// Text content (arena memory; valid for the frame).
    text: []const u8 = "",
};

pub const Painter = struct {
    ctx: *Ctx,
    clip: Rect,
    opacity: f32 = 1.0,

    pub fn withClip(self: Painter, clip: Rect) Painter {
        var p = self;
        p.clip = self.clip.intersect(clip);
        return p;
    }

    /// ImGui is driven in physical pixels so its anti-aliasing fringe is
    /// one pixel wide, like egui's feathering; the kit works in points.
    fn k(self: Painter) f32 {
        return self.ctx.pixels_per_point;
    }

    fn px(self: Painter, v: Vec2) [2]f32 {
        return .{ v.x * self.k(), v.y * self.k() };
    }

    fn col(self: Painter, c: Color) u32 {
        return (if (self.opacity < 1.0) c.gammaMultiply(self.opacity) else c).u32v();
    }

    fn record(self: Painter, kind: @TypeOf(@as(Recorded, undefined).kind), r: Rect, txt: []const u8) void {
        const rec = self.ctx.recorder orelse return;
        rec.append(self.ctx.gpa, .{ .kind = kind, .rect = r, .clip = self.clip, .text = txt }) catch {};
    }

    fn begin(self: Painter) ?zgui.DrawList {
        const dl = self.ctx.drawList() orelse return null;
        if (!self.clip.isPositive()) return null;
        dl.pushClipRect(.{ .pmin = self.px(self.clip.min), .pmax = self.px(self.clip.max), .intersect_with_current = false });
        return dl;
    }

    pub fn rectFilled(self: Painter, r: Rect, rounding: f32, c: Color) void {
        self.rectFilledCorners(r, rounding, c, .{});
    }

    pub fn rectFilledCorners(self: Painter, r: Rect, rounding: f32, c: Color, flags: zgui.DrawFlags) void {
        if (c.isTransparent()) return;
        self.record(.rect, r, "");
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        const lo = self.px(r.min);
        const hi = self.px(r.max);
        dl.addRectFilled(.{ .pmin = .{ @round(lo[0]), @round(lo[1]) }, .pmax = .{ @round(hi[0]), @round(hi[1]) }, .col = self.col(c), .rounding = rounding * self.k(), .flags = flags });
    }

    pub fn rectStroke(self: Painter, r: Rect, rounding: f32, s: Stroke, kind: StrokeKind) void {
        if (s.width <= 0 or s.color.isTransparent()) return;
        self.record(.rect, if (kind == .outside) r.expand(s.width) else r, "");
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        const off: f32 = switch (kind) {
            .inside => s.width * 0.5,
            .middle => 0,
            .outside => -s.width * 0.5,
        };
        // ImGui's AddRect already insets its path by half a pixel.
        const rr = r.shrink(off - 0.5 / self.k());
        dl.addRect(.{ .pmin = self.px(rr.min), .pmax = self.px(rr.max), .col = self.col(s.color), .rounding = @max(rounding - off, 0) * self.k(), .thickness = s.width * self.k() });
    }

    /// Fill and inside stroke, like egui's `painter.rect(.., StrokeKind::Inside)`.
    pub fn rect(self: Painter, r: Rect, rounding: f32, fill: Color, s: Stroke) void {
        self.rectFilled(r, rounding, fill);
        self.rectStroke(r, rounding, s, .inside);
    }

    pub fn line(self: Painter, a: Vec2, b: Vec2, s: Stroke) void {
        if (s.color.isTransparent()) return;
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        // egui snaps axis-aligned strokes so they cover whole pixels: an
        // even pixel width centres on a pixel edge, an odd one on a pixel
        // centre. ImGui then adds half a pixel to every line; undo that.
        var p1 = self.px(a);
        var p2 = self.px(b);
        const wpx = s.width * self.k();
        const odd = @mod(@round(wpx), 2.0) == 1.0;
        const snap = struct {
            fn f(v: f32, o: bool) f32 {
                return if (o) @floor(v) + 0.5 else @round(v);
            }
        }.f;
        if (a.y == b.y) {
            p1[1] = snap(p1[1], odd);
            p2[1] = p1[1];
        } else if (a.x == b.x) {
            p1[0] = snap(p1[0], odd);
            p2[0] = p1[0];
        }
        dl.addLine(.{ .p1 = .{ p1[0] - 0.5, p1[1] - 0.5 }, .p2 = .{ p2[0] - 0.5, p2[1] - 0.5 }, .col = self.col(s.color), .thickness = wpx });
    }

    pub fn hline(self: Painter, x0: f32, x1: f32, y: f32, s: Stroke) void {
        self.line(.{ .x = x0, .y = y }, .{ .x = x1, .y = y }, s);
    }

    pub fn polyline(self: Painter, pts: []const Vec2, s: Stroke, closed: bool) void {
        if (s.color.isTransparent() or pts.len < 2) return;
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        var buf: [16][2]f32 = undefined;
        const n = @min(pts.len, buf.len);
        for (pts[0..n], 0..) |p, i| buf[i] = self.px(p);
        dl.addPolyline(buf[0..n], .{ .col = self.col(s.color), .thickness = s.width * self.k(), .flags = .{ .closed = closed } });
    }

    pub fn circleFilled(self: Painter, c: Vec2, radius: f32, color: Color) void {
        if (color.isTransparent()) return;
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        dl.addCircleFilled(.{ .p = self.px(c), .r = radius * self.k(), .col = self.col(color), .num_segments = 0 });
    }

    pub fn circleStroke(self: Painter, c: Vec2, radius: f32, s: Stroke) void {
        if (s.color.isTransparent()) return;
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        dl.addCircle(.{ .p = self.px(c), .r = radius * self.k(), .col = self.col(s.color), .num_segments = 0, .thickness = s.width * self.k() });
    }

    pub fn circle(self: Painter, c: Vec2, radius: f32, fill: Color, s: Stroke) void {
        self.circleFilled(c, radius, fill);
        self.circleStroke(c, radius, s);
    }

    /// Draw a galley-less single line of text with its top-left at `pos`.
    pub fn textAt(self: Painter, pos: Vec2, str: []const u8, size: f32, kind: FontKind, c: Color) void {
        if (str.len == 0 or c.isTransparent()) return;
        if (self.ctx.recorder != null) self.record(.text, Rect.fromMinSize(pos, self.ctx.measure(str, size, kind, 0).size), self.ctx.arena.allocator().dupe(u8, str) catch "");
        const f = self.ctx.face(kind);
        const font = f.font orelse return;
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        const p = self.px(pos);
        dl.addTextExtendedUnformatted(.{ @round(p[0]), @round(p[1]) }, self.col(c), str, .{ .font = font, .font_size = size * f.em_to_px * self.k() });
    }

    /// egui `painter.text`: anchor `pos` per `anchor`; returns the text rect.
    pub fn text(self: Painter, pos: Vec2, anchor: Align2, str: []const u8, size: f32, c: Color) Rect {
        return self.textKind(pos, anchor, str, size, .proportional, c);
    }

    pub fn textKind(self: Painter, pos: Vec2, anchor: Align2, str: []const u8, size: f32, kind: FontKind, c: Color) Rect {
        const g = self.ctx.measure(str, size, kind, 0);
        const r = anchor.anchorRect(pos, g.size);
        self.textAt(r.min, str, size, kind, c);
        return r;
    }

    pub fn textWrapped(self: Painter, pos: Vec2, str: []const u8, size: f32, c: Color, wrap: f32) void {
        if (str.len == 0) return;
        if (self.ctx.recorder != null) self.record(.text, Rect.fromMinSize(pos, measureWrapped(self.ctx, str, size, wrap)), self.ctx.arena.allocator().dupe(u8, str) catch "");
        const f = self.ctx.face(.proportional);
        const font = f.font orelse return;
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        // ImGui line height is the font size; egui's adds the line gap. Draw
        // line by line so wrapped paragraphs keep egui's spacing.
        const font_px = size * f.em_to_px * self.k();
        const row = self.ctx.rowHeight(size, .proportional);
        var y = pos.y;
        var rest = str;
        while (rest.len > 0) {
            const n = wrapPrefix(self.ctx, rest, size, wrap);
            const line_text = std.mem.trimRight(u8, rest[0..n], " ");
            const p = self.px(.{ .x = pos.x, .y = y });
            dl.addTextExtendedUnformatted(.{ @round(p[0]), @round(p[1]) }, self.col(c), line_text, .{ .font = font, .font_size = font_px });
            rest = std.mem.trimLeft(u8, rest[n..], " ");
            y += row;
        }
    }

    /// Draw a texture (an ImGui texture id, e.g. a WebGPU texture view).
    pub fn image(self: Painter, tex: u64, r: Rect, uv0: Vec2, uv1: Vec2) void {
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        zoxel_AddImage(dl, tex, &self.px(r.min), &self.px(r.max), &uv0.arr(), &uv1.arr(), self.col(Color.white));
    }

    pub fn imageQuad(self: Painter, tex: u64, p: [4]Vec2, uv: [4]Vec2) void {
        const dl = self.begin() orelse return;
        defer dl.popClipRect();
        var pts: [8]f32 = undefined;
        var uvs: [8]f32 = undefined;
        for (0..4) |i| {
            pts[i * 2] = p[i].x * self.k();
            pts[i * 2 + 1] = p[i].y * self.k();
            uvs[i * 2] = uv[i].x;
            uvs[i * 2 + 1] = uv[i].y;
        }
        zoxel_AddImageQuad(dl, tex, &pts, &uvs, self.col(Color.white));
    }
};

// See imgui_shim.cpp: zgui's own AddImage bindings mis-pass the texture id.
extern fn zoxel_AddImage(dl: zgui.DrawList, tex: u64, pmin: *const [2]f32, pmax: *const [2]f32, uvmin: *const [2]f32, uvmax: *const [2]f32, col: u32) void;
extern fn zoxel_AddImageQuad(dl: zgui.DrawList, tex: u64, p: *const [8]f32, uv: *const [8]f32, col: u32) void;

/// Bytes of `text` that fit on one line of `wrap` width, breaking at spaces.
pub fn wrapPrefix(ctx: *Ctx, text: []const u8, size: f32, wrap: f32) usize {
    if (wrap <= 0 or ctx.measure(text, size, .proportional, 0).size.x <= wrap) {
        if (std.mem.indexOfScalar(u8, text, '\n')) |nl| return nl + 1;
        return text.len;
    }
    var best: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') return i + 1;
        if (text[i] == ' ') {
            if (ctx.measure(text[0..i], size, .proportional, 0).size.x <= wrap) best = i + 1 else break;
        }
    }
    if (best == 0) {
        // No space fits: break inside the word, at a codepoint boundary.
        var cut: usize = 0;
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepointSlice()) |cp| {
            const next = cut + cp.len;
            if (ctx.measure(text[0..next], size, .proportional, 0).size.x > wrap and cut > 0) break;
            cut = next;
        }
        return @max(cut, 1);
    }
    return best;
}

/// Size of `text` wrapped to `wrap` the way `textWrapped` draws it.
pub fn measureWrapped(ctx: *Ctx, text: []const u8, size: f32, wrap: f32) Vec2 {
    const row = ctx.rowHeight(size, .proportional);
    if (wrap <= 0) return ctx.measure(text, size, .proportional, 0).size;
    var w: f32 = 0;
    var lines: f32 = 0;
    var rest = text;
    while (rest.len > 0) {
        const n = wrapPrefix(ctx, rest, size, wrap);
        const line_text = std.mem.trimRight(u8, rest[0..n], " \n");
        w = @max(w, ctx.measure(line_text, size, .proportional, 0).size.x);
        rest = std.mem.trimLeft(u8, rest[n..], " ");
        lines += 1;
    }
    return .{ .x = w, .y = row * @max(lines, 1) };
}

// ---------------------------------------------------------------------------
// Layout (egui semantics)
// ---------------------------------------------------------------------------

pub const Dir = enum { top_down, left_to_right, right_to_left };

pub const Layout = struct {
    dir: Dir = .top_down,
    /// Cross-axis alignment of items.
    cross: Align = .min,
    /// Stretch items across the cross axis (top-down: full width).
    cross_justify: bool = false,

    pub const top_down: Layout = .{};
    pub fn leftToRight(a: Align) Layout {
        return .{ .dir = .left_to_right, .cross = a };
    }
    pub fn rightToLeft(a: Align) Layout {
        return .{ .dir = .right_to_left, .cross = a };
    }
    pub fn topDown(a: Align) Layout {
        return .{ .dir = .top_down, .cross = a };
    }
    pub fn isHorizontal(l: Layout) bool {
        return l.dir != .top_down;
    }
};

pub const Spacing = struct {
    item: Vec2 = .{ .x = 8, .y = 8 },
    button_padding: Vec2 = .{ .x = 10, .y = 5 },
    interact_y: f32 = 28,
    icon_spacing: f32 = 4,
    menu_margin: f32 = 12,
};

pub const TextStyleSizes = struct {
    body: f32 = 13.5,
    button: f32 = 13.0,
    heading: f32 = 17.0,
    small: f32 = 12.0,
};

/// A region that places items one after another, like `egui::Ui`.
pub const Ui = struct {
    ctx: *Ctx,
    id: Id,
    max_rect: Rect,
    /// Where the next item goes. Top-down: `min` is the next top-left.
    /// Horizontal: `min.x`/`max.x` is the next left/right edge, `min.y`..
    /// `max.y` the row band.
    cursor: Rect,
    /// Bounds of what has been placed.
    min_rect: Rect,
    layout: Layout,
    spacing: Spacing,
    text: TextStyleSizes = .{},
    enabled: bool = true,
    clip: Rect,
    /// Wrap labels at the available width (egui `wrap_mode = Wrap`).
    wrap_labels: bool = false,
    placed_any: bool = false,

    pub fn root(ctx: *Ctx, id: []const u8, rect: Rect, layout: Layout) Ui {
        return init(ctx, hashId(0, id), rect, layout, ctx.style, ctx.text_sizes, ctx.screen);
    }

    fn init(ctx: *Ctx, id: Id, rect: Rect, layout: Layout, spacing: Spacing, text_sizes: TextStyleSizes, clip: Rect) Ui {
        var u = Ui{
            .ctx = ctx,
            .id = id,
            .max_rect = rect,
            .cursor = rect,
            .min_rect = undefined,
            .layout = layout,
            .spacing = spacing,
            .text = text_sizes,
            .clip = clip,
        };
        u.min_rect = switch (layout.dir) {
            .right_to_left => Rect.fromMinSize(.{ .x = rect.max.x, .y = rect.min.y }, .{}),
            else => Rect.fromMinSize(rect.min, .{}),
        };
        return u;
    }

    pub fn painter(self: *const Ui) Painter {
        return self.ctx.painter(self.clip, if (self.enabled) 1.0 else 0.5);
    }

    pub fn painterAt(self: *const Ui, r: Rect) Painter {
        return self.painter().withClip(r);
    }

    pub fn makeId(self: *const Ui, label: []const u8) Id {
        return hashId(self.id, label);
    }

    pub fn availableRect(self: *const Ui) Rect {
        return switch (self.layout.dir) {
            .top_down => Rect.fromMinMax(.{ .x = self.max_rect.min.x, .y = self.cursor.min.y }, self.max_rect.max),
            .left_to_right => Rect.fromMinMax(.{ .x = self.cursor.min.x, .y = self.max_rect.min.y }, self.max_rect.max),
            .right_to_left => Rect.fromMinMax(self.max_rect.min, .{ .x = self.cursor.max.x, .y = self.max_rect.max.y }),
        };
    }

    pub fn availableWidth(self: *const Ui) f32 {
        return @max(self.availableRect().width(), 0);
    }

    pub fn availableHeight(self: *const Ui) f32 {
        return @max(self.availableRect().height(), 0);
    }

    pub fn setMinWidth(self: *Ui, w: f32) void {
        const want = self.max_rect.min.x + w;
        if (self.min_rect.max.x < want) self.min_rect.max.x = want;
    }

    pub fn setWidth(self: *Ui, w: f32) void {
        self.max_rect.max.x = self.max_rect.min.x + w;
        self.setMinWidth(w);
        if (self.cursor.max.x > self.max_rect.max.x and self.layout.dir != .right_to_left) self.cursor.max.x = self.max_rect.max.x;
    }

    pub fn setMinHeight(self: *Ui, h: f32) void {
        const want = self.max_rect.min.y + h;
        if (self.min_rect.max.y < want) self.min_rect.max.y = want;
    }

    const Placement = struct { frame: Rect, widget: Rect };

    /// egui `Layout::next_frame` + `align_size_within_rect`: the frame an
    /// item occupies and the widget rect inside it. Centre-aligned layouts
    /// stretch the frame across the cross axis (full row height in a
    /// centred row, full width in a centred column), so rows always take
    /// at least their height.
    fn place(self: *Ui, desired: Vec2) Placement {
        const avail = self.availableRect();
        switch (self.layout.dir) {
            .top_down => {
                const fw = if (self.layout.cross == .center or self.layout.cross_justify) @max(desired.x, avail.width()) else desired.x;
                const w = if (self.layout.cross_justify) avail.width() else desired.x;
                const frame = Rect.fromMinSize(avail.min, .{ .x = fw, .y = desired.y });
                const x = switch (self.layout.cross) {
                    .min => avail.min.x,
                    .center => avail.center().x - w * 0.5,
                    .max => avail.max.x - w,
                };
                return .{ .frame = frame, .widget = Rect.fromMinSize(.{ .x = x, .y = frame.min.y }, .{ .x = w, .y = desired.y }) };
            },
            .left_to_right, .right_to_left => {
                const band_top = self.cursor.min.y;
                const fh = if (self.layout.cross == .center) @max(self.cursor.height(), desired.y) else desired.y;
                const band_h = @max(self.cursor.height(), desired.y);
                const y = switch (self.layout.cross) {
                    .min => band_top,
                    .center => band_top + (band_h - desired.y) * 0.5,
                    .max => band_top + band_h - desired.y,
                };
                const x = if (self.layout.dir == .left_to_right) self.cursor.min.x else self.cursor.max.x - desired.x;
                return .{
                    .frame = Rect.fromMinSize(.{ .x = x, .y = band_top }, .{ .x = desired.x, .y = fh }),
                    .widget = Rect.fromMinSize(.{ .x = x, .y = y }, desired),
                };
            },
        }
    }

    fn nextFrame(self: *Ui, desired: Vec2) Rect {
        return self.place(desired).widget;
    }

    fn advance(self: *Ui, r: Rect) void {
        switch (self.layout.dir) {
            .top_down => self.cursor.min.y = r.max.y + self.spacing.item.y,
            .left_to_right => {
                self.cursor.min.x = r.max.x + self.spacing.item.x;
                if (r.max.y > self.cursor.max.y) self.cursor.max.y = r.max.y;
            },
            .right_to_left => {
                self.cursor.max.x = r.min.x - self.spacing.item.x;
                if (r.max.y > self.cursor.max.y) self.cursor.max.y = r.max.y;
            },
        }
        self.min_rect = self.min_rect.unionWith(r);
        self.placed_any = true;
    }

    /// Allocate exactly `desired`; returns the item rect.
    pub fn allocate(self: *Ui, desired: Vec2) Rect {
        const pl = self.place(desired);
        self.advance(pl.frame);
        return pl.widget;
    }

    /// Allocate and hit-test.
    pub fn allocateResponse(self: *Ui, desired: Vec2, id: Id, sense: Sense) Response {
        const r = self.allocate(desired);
        return self.ctx.interact(id, r, self.clip, sense, self.enabled);
    }

    pub fn interact(self: *Ui, r: Rect, id: Id, sense: Sense) Response {
        return self.ctx.interact(id, r, self.clip, sense, self.enabled);
    }

    /// egui `add_space`: moves the cursor and extends the used rect to it
    /// (including the spacing left after the previous item).
    pub fn addSpace(self: *Ui, amount: f32) void {
        switch (self.layout.dir) {
            .top_down => {
                self.cursor.min.y += amount;
                self.min_rect.max.y = @max(self.min_rect.max.y, self.cursor.min.y);
            },
            .left_to_right => {
                self.cursor.min.x += amount;
                self.min_rect.max.x = @max(self.min_rect.max.x, self.cursor.min.x);
            },
            .right_to_left => {
                self.cursor.max.x -= amount;
                self.min_rect.min.x = @min(self.min_rect.min.x, self.cursor.max.x);
            },
        }
        self.placed_any = true;
    }

    /// A child placed at the cursor with the remaining space.
    pub fn child(self: *Ui, layout: Layout) Ui {
        return self.childSized(self.availableRect().size(), layout);
    }

    /// `allocate_ui_with_layout(size, layout)`: a child with this max size.
    pub fn childSized(self: *Ui, sz: Vec2, layout: Layout) Ui {
        const avail = self.availableRect();
        var rect: Rect = undefined;
        switch (self.layout.dir) {
            .top_down => rect = Rect.fromMinSize(avail.min, .{ .x = @min(sz.x, avail.width()), .y = sz.y }),
            .left_to_right => {
                const f = self.nextFrame(.{ .x = sz.x, .y = sz.y });
                rect = f;
            },
            .right_to_left => rect = self.nextFrame(.{ .x = sz.x, .y = sz.y }),
        }
        var c = init(self.ctx, hashIdInt(self.id, @as(usize, @intFromFloat(@abs(rect.min.x * 7 + rect.min.y * 13)))), rect, layout, self.spacing, self.text, self.clip);
        c.enabled = self.enabled;
        c.wrap_labels = self.wrap_labels;
        return c;
    }

    /// Child at an explicit rect (does not advance this Ui).
    pub fn childAt(self: *Ui, rect: Rect, layout: Layout) Ui {
        var c = init(self.ctx, hashIdInt(self.id, @as(usize, @intFromFloat(@abs(rect.min.x * 7 + rect.min.y * 13)))), rect, layout, self.spacing, self.text, self.clip);
        c.enabled = self.enabled;
        c.wrap_labels = self.wrap_labels;
        return c;
    }

    /// Advance past a finished child (allocates its used bounds).
    pub fn endChild(self: *Ui, c: *const Ui) void {
        var used = c.min_rect;
        if (!c.placed_any) {
            used = Rect.fromMinSize(c.max_rect.min, .{ .x = c.min_rect.width(), .y = c.min_rect.height() });
        }
        // egui allocates the child's min rect, widened to its declared size
        // for fixed-size children.
        self.advance(used);
    }

    /// Advance past a child, reserving its full max rect.
    pub fn endChildFull(self: *Ui, c: *const Ui) void {
        self.advance(c.max_rect.unionWith(c.min_rect));
    }

    /// `ui.horizontal`: a left-to-right row, centred, of interact height.
    pub fn horizontal(self: *Ui) Ui {
        var row = self.childSized(.{ .x = self.availableWidth(), .y = self.spacing.interact_y }, Layout.leftToRight(.center));
        row.cursor.max.y = row.cursor.min.y + self.spacing.interact_y;
        return row;
    }

    pub fn horizontalTop(self: *Ui) Ui {
        var row = self.childSized(.{ .x = self.availableWidth(), .y = self.spacing.interact_y }, Layout.leftToRight(.min));
        row.cursor.max.y = row.cursor.min.y + self.spacing.interact_y;
        return row;
    }

    /// `ui.with_layout(right_to_left(Center))` inside a row: the remaining
    /// part of the row, filled from the right.
    pub fn rightToLeft(self: *Ui) Ui {
        const avail = self.availableRect();
        var c = self.childAt(Rect.fromMinMax(.{ .x = avail.min.x, .y = self.cursor.min.y }, .{ .x = avail.max.x, .y = self.cursor.max.y }), Layout.rightToLeft(.center));
        c.cursor = c.max_rect;
        return c;
    }

    /// Split the available width into `n` equal top-down columns.
    pub fn columns(self: *Ui, comptime n: usize) [n]Ui {
        const avail = self.availableRect();
        const gap = self.spacing.item.x;
        const w = (avail.width() - gap * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n));
        var cols: [n]Ui = undefined;
        for (0..n) |i| {
            const x = avail.min.x + @as(f32, @floatFromInt(i)) * (w + gap);
            cols[i] = self.childAt(Rect.fromMinSize(.{ .x = x, .y = avail.min.y }, .{ .x = w, .y = avail.height() }), Layout.top_down);
            cols[i].id = hashIdInt(self.id, 1000 + i);
        }
        return cols;
    }

    pub fn endColumns(self: *Ui, cols: []const Ui) void {
        var h: f32 = 0;
        for (cols) |c| h = @max(h, c.min_rect.max.y - c.max_rect.min.y);
        const avail = self.availableRect();
        self.advance(Rect.fromMinSize(avail.min, .{ .x = avail.width(), .y = h }));
    }

    // -- frames -----------------------------------------------------------

    /// egui `Frame::show`: content is laid out inside the margin and stroke;
    /// `endFrame` advances past it. The fill and stroke are painted before
    /// the content using the size the frame had last frame (ImGui draw lists
    /// cannot insert shapes behind ones already added), so a frame whose
    /// size changes is right one frame later, like egui's panels.
    pub fn beginFrame(self: *Ui, name: []const u8, f: Frame) FrameScope {
        const id = self.makeId(name);
        const outer = self.availableRect();
        const m = f.inner_margin;
        const sw = f.stroke.width;
        const inner = Rect.fromMinMax(
            .{ .x = outer.min.x + m.left + sw, .y = outer.min.y + m.top + sw },
            .{ .x = outer.max.x - m.right - sw, .y = outer.max.y - m.bottom - sw },
        );
        // Content inherits the parent layout; in a row, items centre on the
        // row band less the margins (the frame itself sits at the band top).
        var c = self.childAt(inner, self.layout);
        c.id = id;
        const w = self.ctx.getMem(id ^ 0xf3);
        const h = self.ctx.getMem(id ^ 0xf4);
        if (w != null and h != null) {
            const x0 = if (self.layout.dir == .right_to_left) outer.max.x - w.? else outer.min.x;
            const r = Rect.fromMinSize(.{ .x = x0, .y = outer.min.y }, .{ .x = w.?, .y = h.? });
            const p = self.painter();
            p.rectFilled(r, f.rounding, f.fill);
            p.rectStroke(r, f.rounding, f.stroke, .inside);
        }
        return .{ .ui = c, .frame = f, .id = id };
    }

    pub fn endFrame(self: *Ui, scope: *FrameScope) Rect {
        const f = scope.frame;
        const m = f.inner_margin;
        const sw = f.stroke.width;
        const content = scope.ui.min_rect;
        const outer = Rect.fromMinMax(
            .{ .x = content.min.x - m.left - sw, .y = content.min.y - m.top - sw },
            .{ .x = content.max.x + m.right + sw, .y = content.max.y + m.bottom + sw },
        );
        const pw = self.ctx.getMem(scope.id ^ 0xf3);
        const ph = self.ctx.getMem(scope.id ^ 0xf4);
        if (pw == null or ph == null or pw.? != outer.width() or ph.? != outer.height()) {
            self.ctx.setMem(scope.id ^ 0xf3, outer.width());
            self.ctx.setMem(scope.id ^ 0xf4, outer.height());
            self.ctx.wants_repaint = true;
        }
        self.advance(outer);
        return outer;
    }

    /// Set the remaining height a horizontal row's items centre in.
    pub fn setRowHeight(self: *Ui, h: f32) void {
        self.cursor.max.y = self.cursor.min.y + h;
    }
};

pub const Margin = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,
    pub fn same(m: f32) Margin {
        return .{ .left = m, .right = m, .top = m, .bottom = m };
    }
    pub fn symmetric(x: f32, y: f32) Margin {
        return .{ .left = x, .right = x, .top = y, .bottom = y };
    }
    pub fn sumX(m: Margin) f32 {
        return m.left + m.right;
    }
    pub fn sumY(m: Margin) f32 {
        return m.top + m.bottom;
    }
};

pub const Frame = struct {
    fill: Color = Color.transparent,
    stroke: Stroke = .{},
    rounding: f32 = 0,
    inner_margin: Margin = .{},
};

pub const FrameScope = struct {
    ui: Ui,
    frame: Frame,
    id: Id,
};

// ---------------------------------------------------------------------------
// Panels (egui TopBottomPanel / SidePanel / CentralPanel)
// ---------------------------------------------------------------------------

/// The space left for panels; panels carve pieces off it.
pub const PanelArea = struct {
    rect: Rect,
};

pub const PanelSide = enum { top, bottom, left, right };

pub const Panel = struct {
    side: PanelSide,
    id: Id,
    rect: Rect,
    ui: Ui,
    frame: Frame,
    separator: bool,
    exact: ?f32,
};

/// Begin a panel on `side` of `area`. Height (or width) comes from `exact`
/// or from last frame's content, as egui panels do.
pub fn beginPanel(ctx: *Ctx, area: *PanelArea, side: PanelSide, name: []const u8, frame: Frame, exact: ?f32) Panel {
    const id = hashId(0x9a11e1, name);
    const remembered = if (ctx.panels.get(id)) |m| m.size else 0;
    const extent = exact orelse remembered;
    const a = area.rect;
    const rect = switch (side) {
        .top => Rect.fromMinSize(a.min, .{ .x = a.width(), .y = extent }),
        .bottom => Rect.fromMinMax(.{ .x = a.min.x, .y = a.max.y - extent }, a.max),
        .left => Rect.fromMinSize(a.min, .{ .x = extent, .y = a.height() }),
        .right => Rect.fromMinMax(.{ .x = a.max.x - extent, .y = a.min.y }, a.max),
    };
    // Background first, so content draws over it.
    ctx.painter(ctx.screen, 1).rectFilled(rect, 0, frame.fill);
    const m = frame.inner_margin;
    var inner = Rect.fromMinMax(.{ .x = rect.min.x + m.left, .y = rect.min.y + m.top }, .{ .x = rect.max.x - m.right, .y = rect.max.y - m.bottom });
    // Top/bottom panels lay out from the top with the full remaining height
    // available; the measured content height becomes next frame's size.
    if (side == .top or side == .bottom) {
        inner.max.y = @max(inner.max.y, inner.min.y);
        if (exact == null) inner.max.y = inner.min.y + @max(a.height() - m.sumY(), 0);
    }
    var u = Ui.init(ctx, id, inner, Layout.top_down, ctx.style, ctx.text_sizes, rect);
    u.clip = rect;
    return .{ .side = side, .id = id, .rect = rect, .ui = u, .frame = frame, .separator = true, .exact = exact };
}

pub fn endPanel(ctx: *Ctx, area: *PanelArea, p: *Panel) void {
    const m = p.frame.inner_margin;
    const content = p.ui.min_rect;
    const measured: f32 = switch (p.side) {
        .top, .bottom => content.max.y - p.ui.max_rect.min.y + m.sumY(),
        .left, .right => content.max.x - p.ui.max_rect.min.x + m.sumX(),
    };
    if (p.exact == null) {
        const prev = if (ctx.panels.get(p.id)) |mm| mm.size else 0;
        const size = @round(@max(measured, 0));
        if (size != prev) ctx.wants_repaint = true;
        ctx.panels.put(ctx.gpa, p.id, .{ .size = size }) catch {};
    }
    // egui draws a 1px separator line on the panel's inner edge.
    const s = Stroke.init(1, Color.rgb(48, 62, 76));
    const pnt = ctx.painter(ctx.screen, 1);
    const extent = p.exact orelse (if (ctx.panels.get(p.id)) |mm| mm.size else 0);
    // Half the stroke inside the panel, as egui places it.
    if (p.separator) switch (p.side) {
        .top => pnt.hline(p.rect.min.x, p.rect.max.x, p.rect.min.y + extent - 0.5, s),
        .bottom => pnt.hline(p.rect.min.x, p.rect.max.x, p.rect.max.y - extent + 0.5, s),
        .left => pnt.line(.{ .x = p.rect.min.x + extent - 0.5, .y = p.rect.min.y }, .{ .x = p.rect.min.x + extent - 0.5, .y = p.rect.max.y }, s),
        .right => pnt.line(.{ .x = p.rect.max.x - extent + 0.5, .y = p.rect.min.y }, .{ .x = p.rect.max.x - extent + 0.5, .y = p.rect.max.y }, s),
    };
    switch (p.side) {
        .top => area.rect.min.y += extent,
        .bottom => area.rect.max.y -= extent,
        .left => area.rect.min.x += extent,
        .right => area.rect.max.x -= extent,
    }
}

/// The central panel: the rest of the area.
pub fn centralPanel(ctx: *Ctx, area: *PanelArea, name: []const u8, frame: Frame) Ui {
    const rect = area.rect;
    ctx.painter(ctx.screen, 1).rectFilled(rect, 0, frame.fill);
    const m = frame.inner_margin;
    const inner = Rect.fromMinMax(.{ .x = rect.min.x + m.left, .y = rect.min.y + m.top }, .{ .x = rect.max.x - m.right, .y = rect.max.y - m.bottom });
    var u = Ui.init(ctx, hashId(0xce17a1, name), inner, Layout.top_down, ctx.style, ctx.text_sizes, rect);
    u.clip = rect;
    return u;
}

// ---------------------------------------------------------------------------
// Tests (headless: no fonts, no draw lists)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "top-down allocation advances by size plus spacing" {
    var ctx = Ctx.init(testing.allocator);
    defer ctx.deinit();
    ctx.beginFrame(Rect.fromMinSize(.{}, .{ .x = 400, .y = 300 }), null, null);
    var u = Ui.root(&ctx, "t", Rect.fromMinSize(.{ .x = 10, .y = 10 }, .{ .x = 200, .y = 200 }), Layout.top_down);
    const a = u.allocate(.{ .x = 50, .y = 20 });
    const b = u.allocate(.{ .x = 60, .y = 30 });
    try testing.expectEqual(@as(f32, 10), a.min.y);
    try testing.expectEqual(@as(f32, 38), b.min.y);
    try testing.expectEqual(@as(f32, 68), u.min_rect.max.y);
    ctx.endFrame();
}

test "horizontal rows centre items and right-to-left fills from the right" {
    var ctx = Ctx.init(testing.allocator);
    defer ctx.deinit();
    ctx.beginFrame(Rect.fromMinSize(.{}, .{ .x = 400, .y = 300 }), null, null);
    var u = Ui.root(&ctx, "t", Rect.fromMinSize(.{}, .{ .x = 300, .y = 200 }), Layout.top_down);
    var row = u.horizontal();
    const a = row.allocate(.{ .x = 40, .y = 20 });
    try testing.expectEqual(@as(f32, 4), a.min.y);
    var rtl = row.rightToLeft();
    const b = rtl.allocate(.{ .x = 50, .y = 28 });
    try testing.expectEqual(@as(f32, 300), b.max.x);
    const c = rtl.allocate(.{ .x = 30, .y = 28 });
    try testing.expectEqual(@as(f32, 242), c.max.x);
    row.endChildFull(&rtl);
    u.endChild(&row);
    try testing.expectEqual(@as(f32, 36), u.cursor.min.y);
    ctx.endFrame();
}

test "panels remember their content size" {
    var ctx = Ctx.init(testing.allocator);
    defer ctx.deinit();
    for (0..2) |_| {
        ctx.beginFrame(Rect.fromMinSize(.{}, .{ .x = 400, .y = 300 }), null, null);
        var area = PanelArea{ .rect = ctx.screen };
        var p = beginPanel(&ctx, &area, .top, "bar", .{ .inner_margin = Margin.symmetric(16, 8) }, null);
        _ = p.ui.allocate(.{ .x = 10, .y = 28 });
        endPanel(&ctx, &area, &p);
        ctx.endFrame();
    }
    ctx.beginFrame(Rect.fromMinSize(.{}, .{ .x = 400, .y = 300 }), null, null);
    var area = PanelArea{ .rect = ctx.screen };
    var p = beginPanel(&ctx, &area, .top, "bar", .{ .inner_margin = Margin.symmetric(16, 8) }, null);
    try testing.expectEqual(@as(f32, 44), p.rect.height());
    _ = p.ui.allocate(.{ .x = 10, .y = 28 });
    endPanel(&ctx, &area, &p);
    try testing.expectEqual(@as(f32, 44), area.rect.min.y);
    ctx.endFrame();
}

test "click requires press and release on the widget without dragging" {
    var ctx = Ctx.init(testing.allocator);
    defer ctx.deinit();
    const r = Rect.fromMinSize(.{ .x = 10, .y = 10 }, .{ .x = 50, .y = 20 });
    ctx.input.pointer = .{ .x = 20, .y = 20 };
    ctx.input.pressed = true;
    ctx.input.down = true;
    ctx.beginFrame(Rect.fromMinSize(.{}, .{ .x = 100, .y = 100 }), null, null);
    var resp = ctx.interact(1, r, ctx.screen, Sense.clickable, true);
    try testing.expect(resp.pressed and !resp.clicked);
    ctx.endFrame();
    ctx.input.down = false;
    ctx.input.released = true;
    ctx.beginFrame(Rect.fromMinSize(.{}, .{ .x = 100, .y = 100 }), null, null);
    resp = ctx.interact(1, r, ctx.screen, Sense.clickable, true);
    try testing.expect(resp.clicked);
    ctx.endFrame();
}
