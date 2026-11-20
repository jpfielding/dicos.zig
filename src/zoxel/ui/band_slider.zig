//! Transfer-band threshold strip: one handle between each pair of bands
//! (port of roxel `ui/band_slider.rs`).

const std = @import("std");
const kit = @import("kit.zig");
const theme = @import("theme.zig");
const transfer = @import("../transfer.zig");

const Ui = kit.Ui;
const Vec2 = kit.Vec2;
const Rect = kit.Rect;
const Color = kit.Color;
const Stroke = kit.Stroke;

pub fn draw(ui: *Ui, bands: []transfer.ColorBand) bool {
    if (bands.len < 2) {
        _ = theme.label(ui, "Need at least two bands", .{});
        return false;
    }
    const ctx = ui.ctx;
    const max_density: f32 = @max(@as(f32, @floatFromInt(bands[bands.len - 1].threshold)), 1.0);
    const touch = theme.isTouch(ui);
    const radius: f32 = if (touch) 11 else 6;
    const id = ui.makeId("band_strip");
    var resp = ui.allocateResponse(.{ .x = @max(ui.availableWidth(), 180), .y = if (touch) 96 else 84 }, id, kit.Sense.click_and_drag);
    const rect = resp.rect;
    const p = ui.painterAt(rect);
    const track = Rect.fromMinMax(
        .{ .x = rect.min.x + radius + 2, .y = rect.max.y - (if (touch) @as(f32, 44) else 38) },
        .{ .x = rect.max.x - radius - 2, .y = rect.max.y - (if (touch) @as(f32, 28) else 26) },
    );
    const handle_count = bands.len - 1;
    const mem_id = id ^ 0xba4d;

    if ((resp.pressed or resp.clicked) and resp.interact_pointer != null) {
        const px = resp.interact_pointer.?.x;
        var nearest: usize = 0;
        var best = std.math.inf(f32);
        for (bands[0..handle_count], 0..) |b, i| {
            const d = @abs(px - toX(track, max_density, @floatFromInt(b.threshold)));
            if (d < best) {
                best = d;
                nearest = i;
            }
        }
        ctx.setMem(mem_id, @floatFromInt(nearest));
    }
    var changed = false;
    if ((resp.is_pointer_down_on or resp.clicked) and resp.interact_pointer != null) {
        if (ctx.getMem(mem_id)) |f| {
            const active: usize = @intFromFloat(f);
            var value: i32 = toValue(track, max_density, resp.interact_pointer.?.x);
            const lower: i32 = if (active == 0) 0 else bands[active - 1].threshold;
            const upper: i32 = if (active + 1 < handle_count) bands[active + 1].threshold else @intFromFloat(max_density);
            value = std.math.clamp(value, lower, upper);
            if (bands[active].threshold != value) {
                bands[active].threshold = @intCast(value);
                changed = true;
            }
        }
    }
    if (ctx.input.released) ctx.removeMem(mem_id);
    if (changed) {
        transfer.clampBandThresholds(bands);
        resp.markChanged();
    }

    p.rectFilled(track, 3, theme.FILL_INACTIVE);
    for (bands, 0..) |b, i| {
        const start: f32 = if (i == 0) 0 else @floatFromInt(bands[i - 1].threshold);
        const end: f32 = if (i == bands.len - 1) max_density else @floatFromInt(b.threshold);
        const sx = toX(track, max_density, start);
        const ex = toX(track, max_density, end);
        if (ex <= sx) continue;
        var c = Color.rgb(b.color[0], b.color[1], b.color[2]);
        if (b.is_transparent) c = c.gammaMultiply(0.25);
        p.rectFilled(Rect.fromMinMax(.{ .x = sx, .y = track.min.y }, .{ .x = ex, .y = track.max.y }), 2, c);
        if (ex - sx > 36) {
            _ = p.text(.{ .x = (sx + ex) * 0.5, .y = track.max.y + radius + 1 }, kit.Align2.center_top, b.name, 12, theme.TEXT);
        }
    }
    const active_now: ?usize = if (ctx.getMem(mem_id)) |f| @intFromFloat(f) else null;
    for (bands[0..handle_count], 0..) |b, i| {
        const hx = toX(track, max_density, @floatFromInt(b.threshold));
        const center = Vec2.v(hx, track.center().y);
        const active = active_now != null and active_now.? == i and resp.is_pointer_down_on;
        const stroke_color = if (active) theme.ACCENT else Color.gray(180);
        p.circleFilled(center, radius, theme.BG);
        p.circleStroke(center, radius, Stroke.init(1.5, stroke_color));
        _ = p.textKind(.{ .x = hx, .y = track.min.y - radius + 1 }, kit.Align2.center_bottom, ctx.fmt("{d}", .{b.threshold}), 11, .monospace, theme.TEXT);
    }
    return changed;
}

fn toX(track: Rect, max_density: f32, value: f32) f32 {
    return track.min.x + (value / max_density) * track.width();
}

fn toValue(track: Rect, max_density: f32, x: f32) i32 {
    const t = std.math.clamp((x - track.min.x) / track.width(), 0, 1);
    return @intFromFloat(@round(t * max_density));
}
