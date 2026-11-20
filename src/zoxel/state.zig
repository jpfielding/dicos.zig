//! Decomposed UI state, handed to the drawing code so it can mutate viewer
//! state without borrowing the whole `App`:
//!
//! - `VolumeLibrary`: loaded layers and threat selection.
//! - `TransferState`: transfer preset, bands and the edit debounce.
//! - `RenderSettings`: plain-data 3D render parameters.
//! - `UiActions`: transient requests drained after each frame.

const std = @import("std");
const camera_mod = @import("camera.zig");
const volume_mod = @import("volume.zig");
const transfer = @import("transfer.zig");
const slice_view = @import("slice_view.zig");
const layout = @import("ui/layout.zig");
const kit = @import("ui/kit.zig");

pub const Quality = enum { fast, medium, high };

/// A named volume layer loaded from a DICOS file.
pub const VolumeLayer = struct {
    /// Display name (file stem), owned.
    name: []u8,
    volume: volume_mod.Volume,

    pub fn deinit(self: *VolumeLayer, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.volume.deinit(gpa);
    }
};

pub const VolumeLibrary = struct {
    volumes: std.ArrayList(VolumeLayer) = .empty,
    /// Layer uploaded to the 3D renderer.
    active_3d_index: ?usize = null,
    /// Path (or picked name) of the open study, owned.
    loaded_path: ?[]u8 = null,
    /// Global toggle for detection boxes.
    show_threats: bool = true,
    selected_threat: ?usize = null,

    pub fn deinit(self: *VolumeLibrary, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.volumes.deinit(gpa);
        if (self.loaded_path) |p| gpa.free(p);
        self.loaded_path = null;
    }

    pub fn clear(self: *VolumeLibrary, gpa: std.mem.Allocator) void {
        for (self.volumes.items) |*l| l.deinit(gpa);
        self.volumes.clearRetainingCapacity();
    }

    pub fn get(self: *VolumeLibrary, i: usize) ?*VolumeLayer {
        return if (i < self.volumes.items.len) &self.volumes.items[i] else null;
    }

    pub fn isEmpty(self: *const VolumeLibrary) bool {
        return self.volumes.items.len == 0;
    }

    /// File name of the loaded path (after the last separator).
    pub fn fileName(self: *const VolumeLibrary) ?[]const u8 {
        const p = self.loaded_path orelse return null;
        const trimmed = std.mem.trimRight(u8, p, "/\\");
        const idx = std.mem.lastIndexOfAny(u8, trimmed, "/\\");
        return if (idx) |i| trimmed[i + 1 ..] else trimmed;
    }
};

pub const TransferState = struct {
    preset: transfer.TransferPreset = .monochrome,
    bands: transfer.Bands = transfer.defaultBands(),
    bands_changed: bool = false,
    /// Debounce deadline (seconds, input clock) for band edits.
    bands_debounce_deadline: ?f64 = null,

    /// The Materials preset uses the retained band edits.
    pub fn current(self: *const TransferState) transfer.TransferFunction {
        if (self.preset == .default) return transfer.TransferFunction.fromBands(&self.bands);
        return transfer.TransferFunction.fromPreset(self.preset);
    }
};

pub const RenderSettings = struct {
    window_center: f32 = 32768.0,
    window_width: f32 = 65536.0,
    density_threshold: f32 = 0.0,
    quality: Quality = .high,
    ambient: f32 = 0.65,
    diffuse: f32 = 0.8,
    specular: f32 = 0.3,
    /// Attenuate distant samples to clarify overlapping surfaces.
    depth_cue: f32 = 0.35,
    /// Global opacity for the 3D view and the 2D composite.
    global_opacity: f32 = 0.25,
};

pub const LoadRequest = union(enum) {
    /// A file or directory path (native).
    path: []u8,
};

pub const UiActions = struct {
    /// Path picked by an Open button (owned by the action).
    file_to_load: ?[]u8 = null,
    /// Open a file picker / folder picker this frame (handled by the app so
    /// the platform layer, not the UI, owns dialogs).
    pick_file: bool = false,
    pick_folder: bool = false,
    upload_3d_index: ?usize = null,
    preset_changed: bool = false,
};

pub const UiState = struct {
    camera: camera_mod.Camera,
    viewport: kit.Rect = kit.Rect.nothing,
    fit_camera: bool = false,
    volume_extent: camera_mod.Vec3 = camera_mod.Vec3.one,
    show_slice_locator: bool = true,
    cutaway: bool = false,
    reverse_cutaway: bool = false,
    /// "Focus slice": the 2D slice fills the workspace.
    slice_expanded: bool = false,
    /// "Focus volume": the 3D view fills the workspace.
    focus_volume: bool = false,
    layout: layout.Layout = .desktop,
    phone_tab: layout.PhoneTab = .slice,
    sheet_open: bool = true,
    focus_adjust_open: bool = false,
    volume_page: layout.VolumePage = .camera,
    slice_page: layout.SlicePage = .slice,
    bands_open: bool = false,
    selected_band: usize = 1,
    /// Touch: one-finger drag (and the arrow buttons) pan instead of orbit.
    drag_pans: bool = false,

    library: VolumeLibrary = .{},
    transfer: TransferState = .{},
    settings: RenderSettings = .{},
    actions: UiActions = .{},

    slice_view: slice_view.SliceView = .{},
    /// Size of the current slice texture in pixels, when one exists.
    slice_texture_size: ?[2]usize = null,
    slice_dirty: bool = false,

    /// File name being loaded in the background, owned.
    loading_file: ?[]u8 = null,
    /// Last load error, owned; shown in the study panel.
    load_error: ?[]u8 = null,
    /// Whether the platform can pick folders (native desktop).
    can_pick_folder: bool = true,

    pub fn init(camera: camera_mod.Camera) UiState {
        return .{ .camera = camera };
    }

    pub fn deinit(self: *UiState, gpa: std.mem.Allocator) void {
        self.library.deinit(gpa);
        if (self.loading_file) |f| gpa.free(f);
        if (self.load_error) |e| gpa.free(e);
        if (self.actions.file_to_load) |f| gpa.free(f);
    }

    pub fn setLoadError(self: *UiState, gpa: std.mem.Allocator, msg: ?[]const u8) void {
        if (self.load_error) |e| gpa.free(e);
        self.load_error = if (msg) |m| gpa.dupe(u8, m) catch null else null;
    }

    /// Keep cached composite pixels in sync with the shared opacity.
    pub fn syncCompositeOpacity(self: *UiState) void {
        if (self.slice_view.alpha_scale != self.settings.global_opacity) {
            self.slice_view.alpha_scale = self.settings.global_opacity;
            if (self.slice_view.composite) self.slice_dirty = true;
        }
    }

    /// Whether the 3D volume is on screen.
    pub fn volumeVisible(self: *const UiState) bool {
        if (self.library.isEmpty() or self.slice_expanded) return false;
        return !self.layout.isCompact() or self.focus_volume or self.phone_tab == .view3d;
    }
};

test "opacity changes invalidate composites but not single slices" {
    var state = UiState.init(.{});
    state.slice_dirty = false;
    state.settings.global_opacity = 0.4;
    state.syncCompositeOpacity();
    try std.testing.expect(!state.slice_dirty);
    try std.testing.expectEqual(@as(f32, 0.4), state.slice_view.alpha_scale);
    state.slice_view.composite = true;
    state.settings.global_opacity = 0.7;
    state.syncCompositeOpacity();
    try std.testing.expect(state.slice_dirty);
    state.slice_dirty = false;
    state.syncCompositeOpacity();
    try std.testing.expect(!state.slice_dirty);
}

test "returning to materials preserves edited bands" {
    var st = TransferState{ .preset = .default };
    st.bands[2].color = .{ 255, 0, 255 };
    const edited = st.current();
    const stock = transfer.TransferFunction.fromPreset(.default);
    try std.testing.expect(!std.mem.eql(u8, std.mem.asBytes(&edited.data), std.mem.asBytes(&stock.data)));
    st.preset = .monochrome;
    const mono = transfer.TransferFunction.fromPreset(.monochrome);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&st.current().data), std.mem.asBytes(&mono.data)));
    st.preset = .default;
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&st.current().data), std.mem.asBytes(&edited.data)));
}
