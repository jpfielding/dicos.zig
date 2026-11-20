//! Background volume loading (port of roxel `loader.rs`).
//!
//! Parsing, codec decode, threat sidecar merging, GPU packing and centre of
//! mass are CPU-heavy, so the whole pipeline runs off the render thread when
//! the platform has threads; the render thread only uploads the result. The
//! existing study stays visible until a load completes. Without threads (the
//! browser) a request runs on the main thread one frame after it is queued,
//! so the "Loading…" state is drawn first.
//!
//! Loading works from in-memory bytes; paths are thin wrappers that read
//! bytes through `platform.zig`.

const std = @import("std");
const platform = @import("platform.zig");
const adapter = @import("dicos_adapter.zig");
const volume_mod = @import("volume.zig");

const Volume = volume_mod.Volume;
pub const NamedBytes = adapter.NamedBytes;

pub const LoadSource = union(enum) {
    /// A file or directory on disk (native only). Owned.
    path: []u8,
    /// In-memory `(name, bytes)` files, e.g. from a browser picker. The
    /// largest is the CT volume; the rest are offered as threat sidecars.
    bytes: struct { name: []u8, files: []OwnedFile },

    pub fn displayName(self: *const LoadSource) []const u8 {
        return switch (self.*) {
            .path => |p| p,
            .bytes => |b| b.name,
        };
    }

    pub fn deinit(self: *LoadSource, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .path => |p| gpa.free(p),
            .bytes => |b| {
                for (b.files) |f| {
                    gpa.free(f.name);
                    gpa.free(f.bytes);
                }
                gpa.free(b.files);
                gpa.free(b.name);
            },
        }
    }
};

pub const OwnedFile = struct { name: []u8, bytes: []u8 };

/// One named layer, packed for the GPU off the render thread.
pub const LoadedLayer = struct {
    name: []u8,
    volume: Volume,
    packed_buf: []u16,
    center_of_mass: [3]f32,

    pub fn deinit(self: *LoadedLayer, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.volume.deinit(gpa);
        gpa.free(self.packed_buf);
    }
};

pub const LoadOutcome = struct {
    /// Display path (owned).
    path: []u8,
    result: union(enum) {
        loaded: []LoadedLayer,
        /// User-facing message (owned).
        failed: []u8,
    },

    pub fn deinit(self: *LoadOutcome, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        switch (self.result) {
            .loaded => |layers| {
                for (layers) |*l| l.deinit(gpa);
                gpa.free(layers);
            },
            .failed => |m| gpa.free(m),
        }
    }
};

/// One load at a time; `request` is ignored while one is in flight.
pub const VolumeLoader = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// Display path of the load in flight (owned).
    in_flight: ?[]u8 = null,
    done: ?LoadOutcome = null,
    thread: ?std.Thread = null,
    /// Threadless: the queued request and whether a frame was drawn since.
    pending: ?LoadSource = null,
    pending_frame_drawn: bool = false,
    use_thread: bool = platform.has_threads,

    pub fn init(gpa: std.mem.Allocator) VolumeLoader {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *VolumeLoader) void {
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.done) |*d| d.deinit(self.gpa);
        if (self.pending) |*p| p.deinit(self.gpa);
        if (self.in_flight) |p| self.gpa.free(p);
    }

    /// Start loading `source` (takes ownership). Ignored while busy.
    pub fn request(self: *VolumeLoader, source: LoadSource) void {
        var src = source;
        if (self.in_flight != null) {
            src.deinit(self.gpa);
            return;
        }
        self.in_flight = self.gpa.dupe(u8, src.displayName()) catch {
            src.deinit(self.gpa);
            return;
        };
        // Comptime guard: single-threaded targets cannot compile Thread.spawn.
        if (platform.has_threads and self.use_thread) {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            const boxed = self.gpa.create(LoadSource) catch {
                src.deinit(self.gpa);
                self.finish(failedOutcome(self.gpa, "", "Out of memory"));
                return;
            };
            boxed.* = src;
            self.thread = std.Thread.spawn(.{}, worker, .{ self, boxed }) catch {
                // No thread: run inline rather than fail.
                const outcome = loadOutcome(self.gpa, boxed);
                boxed.deinit(self.gpa);
                self.gpa.destroy(boxed);
                self.finish(outcome);
                return;
            };
        } else {
            self.pending = src;
            self.pending_frame_drawn = false;
        }
    }

    fn worker(self: *VolumeLoader, src: *LoadSource) void {
        const outcome = loadOutcome(self.gpa, src);
        src.deinit(self.gpa);
        self.gpa.destroy(src);
        self.finish(outcome);
    }

    fn finish(self: *VolumeLoader, outcome: LoadOutcome) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.done) |*old| old.deinit(self.gpa);
        self.done = outcome;
    }

    /// A completed outcome, if any (caller owns it). Non-blocking.
    pub fn poll(self: *VolumeLoader) ?LoadOutcome {
        if (!self.use_thread) {
            if (self.pending) |*p| {
                if (!self.pending_frame_drawn) {
                    self.pending_frame_drawn = true;
                    return null;
                }
                const outcome = loadOutcome(self.gpa, p);
                p.deinit(self.gpa);
                self.pending = null;
                self.finish(outcome);
            }
        }
        self.mutex.lock();
        const got = self.done;
        self.done = null;
        self.mutex.unlock();
        if (got != null) {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            if (self.in_flight) |p| self.gpa.free(p);
            self.in_flight = null;
        }
        return got;
    }

    /// Display path of the load in flight.
    pub fn loading(self: *const VolumeLoader) ?[]const u8 {
        return self.in_flight;
    }
};

fn failedOutcome(gpa: std.mem.Allocator, path: []const u8, msg: []const u8) LoadOutcome {
    return .{
        .path = gpa.dupe(u8, path) catch &.{},
        .result = .{ .failed = gpa.dupe(u8, msg) catch &.{} },
    };
}

/// Run the full CPU pipeline for `source`.
pub fn loadOutcome(gpa: std.mem.Allocator, source: *const LoadSource) LoadOutcome {
    const path = source.displayName();
    const layers = switch (source.*) {
        .path => |p| if (platform.isDir(p)) loadDirectory(gpa, p) else loadSingleFile(gpa, p),
        .bytes => |b| loadBytes(gpa, b.files),
    } catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}", .{describe(e)}) catch "load failed";
        std.log.warn("Failed to load {s}: {s}", .{ path, msg });
        return failedOutcome(gpa, path, msg);
    };
    return .{ .path = gpa.dupe(u8, path) catch &.{}, .result = .{ .loaded = layers } };
}

pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "permission denied",
        error.IsDir => "is a directory",
        error.FileTooBig => "file is too large",
        error.NoFilesSelected => "No files selected",
        error.NoDicosFiles => "No .dcs or .dcm files found",
        error.NoReadableVolumes => "No readable DICOS volumes found",
        else => adapter.describe(e),
    };
}

fn finishLayer(gpa: std.mem.Allocator, name: []const u8, vol: Volume) !LoadedLayer {
    var v = vol;
    errdefer v.deinit(gpa);
    const packed_buf = try v.packForGpu(gpa);
    errdefer gpa.free(packed_buf);
    return .{ .name = try gpa.dupe(u8, platform.stem(name)), .volume = v, .packed_buf = packed_buf, .center_of_mass = v.centerOfMass() };
}

fn dims(v: *const Volume) [3]usize {
    return .{ v.dim_x, v.dim_y, v.dim_z };
}

/// One layer from in-memory files: the largest is the CT, the rest are
/// searched for threat sidecars.
pub fn loadBytes(gpa: std.mem.Allocator, files: []const OwnedFile) ![]LoadedLayer {
    if (files.len == 0) return error.NoFilesSelected;
    var ct: usize = 0;
    for (files, 0..) |f, i| if (f.bytes.len > files[ct].bytes.len) {
        ct = i;
    };
    var vol = try adapter.loadVolumeBytes(gpa, files[ct].bytes);
    errdefer vol.deinit(gpa);
    var others: std.ArrayList(NamedBytes) = .empty;
    defer others.deinit(gpa);
    for (files, 0..) |f, i| if (i != ct) try others.append(gpa, .{ .name = f.name, .bytes = f.bytes });
    var side = try adapter.threatSidecarsFromBytes(gpa, others.items, dims(&vol));
    defer volume_mod.freeThreats(gpa, &side);
    const added = try volume_mod.mergeUniqueThreats(gpa, &vol.threats, &side);
    if (added > 0) std.log.info("Loaded {d} threat box(es) from sidecar files", .{added});
    const out = try gpa.alloc(LoadedLayer, 1);
    errdefer gpa.free(out);
    out[0] = try finishLayer(gpa, files[ct].name, vol);
    return out;
}

/// Threat sidecars next to a file or in a directory: files whose stem
/// contains "threat" (case-insensitive).
fn sidecarsFromDir(gpa: std.mem.Allocator, dir: []const u8, d: [3]usize) !volume_mod.ThreatList {
    const names = platform.listFiles(gpa, dir) catch return .empty;
    defer platform.freeNames(gpa, names);
    var files: std.ArrayList(NamedBytes) = .empty;
    defer {
        for (files.items) |f| gpa.free(f.bytes);
        files.deinit(gpa);
    }
    for (names) |n| {
        if (!adapter.isThreatSidecarName(n)) continue;
        const full = try platform.joinPath(gpa, dir, n);
        defer gpa.free(full);
        const bytes = platform.readFile(gpa, full) catch continue;
        files.append(gpa, .{ .name = n, .bytes = bytes }) catch {
            gpa.free(bytes);
            continue;
        };
    }
    return adapter.threatSidecarsFromBytes(gpa, files.items, d);
}

/// One file as one layer, merging threat sidecars from its directory.
pub fn loadSingleFile(gpa: std.mem.Allocator, path: []const u8) ![]LoadedLayer {
    const bytes = try platform.readFile(gpa, path);
    defer gpa.free(bytes);
    var vol = try adapter.loadVolumeBytes(gpa, bytes);
    errdefer vol.deinit(gpa);
    if (platform.dirName(path)) |dir| {
        var side = try sidecarsFromDir(gpa, dir, dims(&vol));
        defer volume_mod.freeThreats(gpa, &side);
        const added = try volume_mod.mergeUniqueThreats(gpa, &vol.threats, &side);
        if (added > 0) std.log.info("Loaded {d} threat box(es) from sidecar files", .{added});
    }
    std.log.info("Loaded 1 volume from {s}", .{path});
    const out = try gpa.alloc(LoadedLayer, 1);
    errdefer gpa.free(out);
    out[0] = try finishLayer(gpa, path, vol);
    return out;
}

fn isDicosName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.ascii.eqlIgnoreCase(ext, ".dcs") or std.ascii.eqlIgnoreCase(ext, ".dcm");
}

/// Each readable `.dcs`/`.dcm` file in a directory as its own layer (no
/// stacking). Sidecars merge into layers matching the largest volume.
pub fn loadDirectory(gpa: std.mem.Allocator, dir: []const u8) ![]LoadedLayer {
    const names = try platform.listFiles(gpa, dir);
    defer platform.freeNames(gpa, names);
    var vols: std.ArrayList(struct { name: []const u8, vol: Volume, moved: bool = false }) = .empty;
    defer {
        for (vols.items) |*v| if (!v.moved) v.vol.deinit(gpa);
        vols.deinit(gpa);
    }
    var any = false;
    for (names) |n| {
        if (!isDicosName(n)) continue;
        any = true;
        const full = try platform.joinPath(gpa, dir, n);
        defer gpa.free(full);
        const bytes = platform.readFile(gpa, full) catch |e| {
            std.log.warn("Skipping {s}: {s}", .{ full, @errorName(e) });
            continue;
        };
        defer gpa.free(bytes);
        const vol = adapter.loadVolumeBytes(gpa, bytes) catch |e| {
            std.log.warn("Skipping {s}: {s}", .{ full, describe(e) });
            continue;
        };
        std.log.info("  {s} -> {d}x{d}x{d} ({s})", .{ n, vol.dim_x, vol.dim_y, vol.dim_z, vol.modality });
        try vols.append(gpa, .{ .name = n, .vol = vol });
    }
    if (!any) return error.NoDicosFiles;
    if (vols.items.len == 0) return error.NoReadableVolumes;
    var largest = dims(&vols.items[0].vol);
    for (vols.items) |v| {
        const d = dims(&v.vol);
        if (d[0] *| d[1] *| d[2] > largest[0] *| largest[1] *| largest[2]) largest = d;
    }
    var side = try sidecarsFromDir(gpa, dir, largest);
    defer volume_mod.freeThreats(gpa, &side);
    for (vols.items) |*v| {
        if (!std.mem.eql(usize, &dims(&v.vol), &largest)) continue;
        var copy: volume_mod.ThreatList = .empty;
        for (side.items) |t| try copy.append(gpa, try t.clone(gpa));
        _ = try volume_mod.mergeUniqueThreats(gpa, &v.vol.threats, &copy);
        copy.deinit(gpa);
    }
    std.log.info("Loaded {d} volume layers from {s}", .{ vols.items.len, dir });
    const out = try gpa.alloc(LoadedLayer, vols.items.len);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |*l| l.deinit(gpa);
        gpa.free(out);
    }
    for (vols.items) |*v| {
        // finishLayer owns the volume from here, on success or failure.
        v.moved = true;
        out[made] = try finishLayer(gpa, v.name, v.vol);
        made += 1;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn pollBlocking(l: *VolumeLoader) !LoadOutcome {
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        if (l.poll()) |o| return o;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

test "nonexistent file yields failed outcome and loading clears" {
    var l = VolumeLoader.init(testing.allocator);
    defer l.deinit();
    try testing.expect(l.loading() == null);
    l.request(.{ .path = try testing.allocator.dupe(u8, "/definitely/does/not/exist.dcs") });
    try testing.expectEqualStrings("/definitely/does/not/exist.dcs", l.loading().?);
    var o = try pollBlocking(&l);
    defer o.deinit(testing.allocator);
    try testing.expect(o.result == .failed);
    try testing.expect(o.result.failed.len > 0);
    try testing.expect(l.loading() == null);
}

test "second request while in flight is ignored" {
    var l = VolumeLoader.init(testing.allocator);
    defer l.deinit();
    l.request(.{ .path = try testing.allocator.dupe(u8, "/definitely/does/not/exist_a.dcs") });
    l.request(.{ .path = try testing.allocator.dupe(u8, "/definitely/does/not/exist_b.dcs") });
    try testing.expectEqualStrings("/definitely/does/not/exist_a.dcs", l.loading().?);
    var o = try pollBlocking(&l);
    defer o.deinit(testing.allocator);
    try testing.expectEqualStrings("/definitely/does/not/exist_a.dcs", o.path);
    try testing.expect(l.poll() == null);
}

test "threadless loader defers one frame" {
    var l = VolumeLoader.init(testing.allocator);
    l.use_thread = false;
    defer l.deinit();
    l.request(.{ .path = try testing.allocator.dupe(u8, "/nope.dcs") });
    try testing.expect(l.poll() == null);
    var o = l.poll().?;
    defer o.deinit(testing.allocator);
    try testing.expect(o.result == .failed);
}

test "bytes source with no files fails" {
    const r = loadBytes(testing.allocator, &.{});
    try testing.expectError(error.NoFilesSelected, r);
}
