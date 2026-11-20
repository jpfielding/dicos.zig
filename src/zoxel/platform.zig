//! Platform layer: everything that differs between the native desktop build
//! and a future wasm32-emscripten browser build lives here.
//!
//! Native: files and directories through std.fs, file/folder pickers by
//! shelling out (`osascript` on macOS, `zenity` elsewhere), a worker thread
//! for loading, environment variables. Emscripten: no folders, no pickers
//! (the page hands bytes in), no threads — callers check the `has_*` flags
//! and the loader falls back to running on the main thread.

const std = @import("std");
const builtin = @import("builtin");

pub const is_web = builtin.os.tag == .emscripten or builtin.os.tag == .wasi or builtin.cpu.arch.isWasm();

/// A worker thread may run the load pipeline.
pub const has_threads = !is_web and !builtin.single_threaded;
/// Paths and directories can be read.
pub const has_filesystem = !is_web;
/// A native dialog can pick a folder.
pub const has_folder_picker = !is_web;

/// Largest file the viewer will read (guards against runaway reads).
pub const max_file_bytes: usize = 4 << 30;

pub fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!has_filesystem) return error.Unsupported;
    return std.fs.cwd().readFileAlloc(gpa, path, max_file_bytes);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (!has_filesystem) return error.Unsupported;
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
}

pub fn isDir(path: []const u8) bool {
    if (!has_filesystem) return false;
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

/// Regular files in `dir` (names only, sorted). Caller frees with `freeNames`.
pub fn listFiles(gpa: std.mem.Allocator, dir_path: []const u8) ![][]u8 {
    if (!has_filesystem) return error.Unsupported;
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var names: std.ArrayList([]u8) = .empty;
    errdefer freeNames(gpa, names.items);
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    const out = try names.toOwnedSlice(gpa);
    std.mem.sort([]u8, out, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

pub fn freeNames(gpa: std.mem.Allocator, names: []const []u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

pub fn joinPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ dir, name });
}

pub fn dirName(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

pub fn baseName(path: []const u8) []const u8 {
    return std.fs.path.basename(std.mem.trimRight(u8, path, "/"));
}

/// File name without its extension.
pub fn stem(name: []const u8) []const u8 {
    const base = baseName(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

pub fn getenv(name: []const u8) ?[]const u8 {
    if (is_web) return null;
    return std.posix.getenv(name);
}

// ---------------------------------------------------------------------------
// File dialogs (native: osascript on macOS, zenity elsewhere)
// ---------------------------------------------------------------------------

pub const PickKind = enum { file, folder };

/// Show a blocking native picker; returns the chosen path (owned) or null.
pub fn pick(gpa: std.mem.Allocator, kind: PickKind) ?[]u8 {
    if (is_web) return null;
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => switch (kind) {
            .file => &.{ "osascript", "-e", "POSIX path of (choose file with prompt \"Open a DICOS file\" of type {\"dcs\", \"dcm\", \"public.data\"})" },
            .folder => &.{ "osascript", "-e", "POSIX path of (choose folder with prompt \"Open a DICOS study folder\")" },
        },
        else => switch (kind) {
            .file => &.{ "zenity", "--file-selection", "--title=Open a DICOS file", "--file-filter=DICOS | *.dcs *.dcm *.DCS *.DCM", "--file-filter=All files | *" },
            .folder => &.{ "zenity", "--file-selection", "--directory", "--title=Open a DICOS study folder" },
        },
    };
    const res = std.process.Child.run(.{ .allocator = gpa, .argv = argv, .max_output_bytes = 64 * 1024 }) catch |e| {
        std.log.warn("file dialog unavailable ({s}): {s}", .{ argv[0], @errorName(e) });
        return null;
    };
    defer gpa.free(res.stderr);
    defer gpa.free(res.stdout);
    switch (res.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \r\n");
    if (trimmed.len == 0) return null;
    // osascript folder paths end with '/'.
    const clean = if (trimmed.len > 1) std.mem.trimRight(u8, trimmed, "/") else trimmed;
    return gpa.dupe(u8, clean) catch null;
}

/// Show a fatal error to the user (native dialog when possible).
pub fn showFatal(msg: []const u8) void {
    std.debug.print("zoxel: {s}\n", .{msg});
    if (is_web or builtin.os.tag != .macos) return;
    var buf: [2048]u8 = undefined;
    var clean: [1024]u8 = undefined;
    const n = @min(msg.len, clean.len);
    for (msg[0..n], 0..) |c, i| clean[i] = if (c == '"' or c == '\\') '\'' else c;
    const script = std.fmt.bufPrint(&buf, "display alert \"zoxel\" message \"{s}\" as critical", .{clean[0..n]}) catch return;
    var child = std.process.Child.init(&.{ "osascript", "-e", script }, std.heap.page_allocator);
    _ = child.spawnAndWait() catch {};
}

test "stem and base name" {
    try std.testing.expectEqualStrings("ct", stem("/a/b/ct.dcs"));
    try std.testing.expectEqualStrings("study", baseName("/a/study/"));
    try std.testing.expectEqualStrings("noext", stem("noext"));
}
