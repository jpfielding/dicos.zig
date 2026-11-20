//! dicosctl -- DICOS command-line tool (port of the Rust `dicosctl`).
//!
//! - `dump [-c|--compact] <FILE>` -- all metadata as JSON (pretty by default)
//! - `info <FILE>` -- a human-readable summary
//!
//! Output is byte-compatible with the Rust tool: JSON object keys are sorted
//! (serde_json's default BTreeMap), floats use serde_json/ryu formatting, and
//! argument errors follow clap's wording and exit code 2.

const std = @import("std");
const dicos = @import("dicos");

const Dataset = dicos.Dataset;
const Element = dicos.Element;
const Allocator = std.mem.Allocator;

/// Rust's env_logger defaults to `error`, so parse warnings stay silent.
pub const std_options: std.Options = .{ .log_level = .err };

const top_help =
    \\DICOS command-line tool
    \\
    \\Usage: dicosctl <COMMAND>
    \\
    \\Commands:
    \\  dump  Dump all metadata as JSON
    \\  info  Print a human-readable summary of the file
    \\  help  Print this message or the help of the given subcommand(s)
    \\
    \\Options:
    \\  -h, --help  Print help
    \\
;

const dump_help =
    \\Dump all metadata as JSON
    \\
    \\Usage: dicosctl dump [OPTIONS] <FILE>
    \\
    \\Arguments:
    \\  <FILE>  Path to the DICOS (.dcs) file
    \\
    \\Options:
    \\  -c, --compact  Emit compact (single-line) JSON instead of pretty-printed
    \\  -h, --help     Print help
    \\
;

const info_help =
    \\Print a human-readable summary of the file
    \\
    \\Usage: dicosctl info <FILE>
    \\
    \\Arguments:
    \\  <FILE>  Path to the DICOS (.dcs) file
    \\
    \\Options:
    \\  -h, --help  Print help
    \\
;

const help_help =
    \\Print this message or the help of the given subcommand(s)
    \\
    \\Usage: dicosctl help [COMMAND]...
    \\
    \\Arguments:
    \\  [COMMAND]...  Print help for the subcommand(s)
    \\
;

const Command = union(enum) {
    dump: struct { file: []const u8, compact: bool },
    info: struct { file: []const u8 },
};

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    const cmd = parseArgs(argv[1..]) orelse return; // help or usage error already handled

    const result = switch (cmd) {
        .dump => |d| cmdDump(gpa, d.file, !d.compact),
        .info => |i| cmdInfo(gpa, i.file),
    };
    result catch |e| {
        var buf: [512]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        w.interface.print("error: {s}\n", .{last_error_message.slice()}) catch {};
        if (last_error_message.len == 0) w.interface.print("error: {s}\n", .{@errorName(e)}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
}

// ---------------------------------------------------------------------------
// Argument parsing (clap-compatible messages for the common cases)
// ---------------------------------------------------------------------------

fn writeAllTo(file: std.fs.File, bytes: []const u8) void {
    var buf: [1024]u8 = undefined;
    var w = file.writer(&buf);
    w.interface.writeAll(bytes) catch {};
    w.interface.flush() catch {};
}

fn usageError(comptime fmt: []const u8, args: anytype, usage: []const u8) noreturn {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("error: " ++ fmt ++ "\n\nUsage: {s}\n\nFor more information, try '--help'.\n", args ++ .{usage}) catch {};
    w.interface.flush() catch {};
    std.process.exit(2);
}

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help");
}

fn parseArgs(args: []const [:0]u8) ?Command {
    if (args.len == 0) {
        writeAllTo(std.fs.File.stderr(), top_help);
        std.process.exit(2);
    }
    const sub = args[0];
    const rest = args[1..];
    if (isHelp(sub)) {
        writeAllTo(std.fs.File.stdout(), top_help);
        return null;
    }
    if (std.mem.eql(u8, sub, "help")) {
        if (rest.len == 0) {
            writeAllTo(std.fs.File.stdout(), top_help);
        } else if (std.mem.eql(u8, rest[0], "dump")) {
            writeAllTo(std.fs.File.stdout(), dump_help);
        } else if (std.mem.eql(u8, rest[0], "info")) {
            writeAllTo(std.fs.File.stdout(), info_help);
        } else if (std.mem.eql(u8, rest[0], "help")) {
            writeAllTo(std.fs.File.stdout(), help_help);
        } else {
            usageError("unrecognized subcommand '{s}'", .{rest[0]}, "dicosctl <COMMAND>");
        }
        return null;
    }
    if (std.mem.eql(u8, sub, "dump")) return parseSub(rest, true);
    if (std.mem.eql(u8, sub, "info")) return parseSub(rest, false);
    if (sub.len > 1 and sub[0] == '-') {
        usageError("unexpected argument '{s}' found", .{sub}, "dicosctl <COMMAND>");
    }
    usageError("unrecognized subcommand '{s}'", .{sub}, "dicosctl <COMMAND>");
}

fn parseSub(args: []const [:0]u8, is_dump: bool) ?Command {
    const usage_full = if (is_dump) "dicosctl dump [OPTIONS] <FILE>" else "dicosctl info <FILE>";
    var file: ?[]const u8 = null;
    var compact = false;
    var positional_only = false;
    for (args) |a| {
        if (!positional_only and a.len > 1 and a[0] == '-') {
            if (std.mem.eql(u8, a, "--")) {
                positional_only = true;
                continue;
            }
            if (isHelp(a)) {
                writeAllTo(std.fs.File.stdout(), if (is_dump) dump_help else info_help);
                return null;
            }
            if (is_dump and std.mem.eql(u8, a, "--compact")) {
                if (compact) usageError("the argument '--compact' cannot be used multiple times", .{}, usage_full);
                compact = true;
                continue;
            }
            // Clustered short flags, e.g. `-c` or `-ch`.
            if (a[1] != '-') {
                for (a[1..]) |ch| switch (ch) {
                    'h' => {
                        writeAllTo(std.fs.File.stdout(), if (is_dump) dump_help else info_help);
                        return null;
                    },
                    'c' => if (is_dump) {
                        if (compact) usageError("the argument '--compact' cannot be used multiple times", .{}, usage_full);
                        compact = true;
                    } else usageError("unexpected argument '-c' found\n\n  tip: to pass '-c' as a value, use '-- -c'", .{}, usage_full),
                    else => usageError("unexpected argument '-{c}' found\n\n  tip: to pass '-{c}' as a value, use '-- -{c}'", .{ ch, ch, ch }, usage_full),
                };
                continue;
            }
            usageError("unexpected argument '{s}' found\n\n  tip: to pass '{s}' as a value, use '-- {s}'", .{ a, a, a }, usage_full);
        }
        if (file != null) usageError("unexpected argument '{s}' found", .{a}, usage_full);
        file = a;
    }
    const f = file orelse {
        const usage_missing = if (!is_dump) "dicosctl info <FILE>" else if (compact) "dicosctl dump --compact <FILE>" else "dicosctl dump <FILE>";
        usageError("the following required arguments were not provided:\n  <FILE>", .{}, usage_missing);
    };
    return if (is_dump) .{ .dump = .{ .file = f, .compact = compact } } else .{ .info = .{ .file = f } };
}

// ---------------------------------------------------------------------------
// Errors (Rust prints `error: {e}` using the error's Display text)
// ---------------------------------------------------------------------------

var last_error_message: dicos.err.Message = .{};

fn osErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied, error.PermissionDenied => "Permission denied (os error 13)",
        error.IsDir => "Is a directory (os error 21)",
        error.NameTooLong => "File name too long (os error 63)",
        error.NotDir => "Not a directory (os error 20)",
        else => @errorName(e),
    };
}

fn openDataset(gpa: Allocator, path: []const u8) !Dataset {
    const file = std.fs.cwd().openFile(path, .{}) catch |e| {
        last_error_message = dicos.err.Message.init("{s}", .{osErrorText(e)});
        return e;
    };
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(&buf);
    var diag: dicos.Diagnostic = .{};
    var res = dicos.reader.parseWithOptions(gpa, &fr.interface, .{ .diagnostic = &diag }) catch |e| {
        if (e == error.IoError and fr.err != null) {
            // Read failures surface through the parser as DicosError::Io.
            last_error_message = dicos.err.Message.init("I/O error: {s}", .{osErrorText(fr.err.?)});
        } else {
            last_error_message = dicos.err.Message.init("{f}", .{diag});
        }
        return e;
    };
    gpa.free(res.warnings);
    res.warnings = &.{};
    return res.dataset;
}

// ---------------------------------------------------------------------------
// dump
// ---------------------------------------------------------------------------

fn cmdDump(gpa: Allocator, path: []const u8, pretty: bool) !void {
    var ds = try openDataset(gpa, path);
    defer ds.deinit();
    var buf: [64 * 1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    var jw: JsonWriter = .{ .w = &w.interface, .pretty = pretty };
    try writeDataset(gpa, &jw, &ds);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}

/// Minimal serde_json-compatible writer (PrettyFormatter with 2-space
/// indent, or CompactFormatter).
const JsonWriter = struct {
    w: *std.Io.Writer,
    pretty: bool,
    depth: usize = 0,

    fn newlineIndent(self: *JsonWriter) !void {
        if (!self.pretty) return;
        try self.w.writeByte('\n');
        try self.w.splatByteAll(' ', self.depth * 2);
    }

    fn beginObject(self: *JsonWriter) !void {
        try self.w.writeByte('{');
        self.depth += 1;
    }

    /// `first` selects whether a separating comma is needed.
    fn key(self: *JsonWriter, k: []const u8, first: bool) !void {
        if (!first) try self.w.writeByte(',');
        try self.newlineIndent();
        try writeString(self.w, k);
        try self.w.writeAll(if (self.pretty) ": " else ":");
    }

    fn endObject(self: *JsonWriter, empty: bool) !void {
        self.depth -= 1;
        if (!empty) try self.newlineIndent();
        try self.w.writeByte('}');
    }

    fn beginArray(self: *JsonWriter) !void {
        try self.w.writeByte('[');
        self.depth += 1;
    }

    fn arrayItem(self: *JsonWriter, first: bool) !void {
        if (!first) try self.w.writeByte(',');
        try self.newlineIndent();
    }

    fn endArray(self: *JsonWriter, empty: bool) !void {
        self.depth -= 1;
        if (!empty) try self.newlineIndent();
        try self.w.writeByte(']');
    }
};

/// serde_json string escaping: `"`, `\`, and control characters (short
/// escapes for \b \f \n \r \t, otherwise lowercase `\u00XX`).
fn writeString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0C => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        if (esc == null and c >= 0x20) continue;
        try w.writeAll(s[start..i]);
        if (esc) |e| try w.writeAll(e) else try w.print("\\u{x:0>4}", .{c});
        start = i + 1;
    }
    try w.writeAll(s[start..]);
    try w.writeByte('"');
}

/// serde_json number output for an f64 (ryu `format64`); non-finite -> null.
fn writeF64(w: *std.Io.Writer, v: f64) std.Io.Writer.Error!void {
    if (!std.math.isFinite(v)) return w.writeAll("null");
    var tmp: [64]u8 = undefined;
    // Zig's `{e}` yields the shortest round-trip digits: "-d.ddde[-]x".
    // 64 bytes always fit a shortest f64 in scientific form.
    const sci = std.fmt.bufPrint(&tmp, "{e}", .{v}) catch unreachable;
    var rest = sci;
    if (rest[0] == '-') {
        try w.writeByte('-');
        rest = rest[1..];
    }
    const e_pos = std.mem.indexOfScalar(u8, rest, 'e').?;
    const exp10 = std.fmt.parseInt(isize, rest[e_pos + 1 ..], 10) catch unreachable;
    var digit_buf: [32]u8 = undefined;
    var nd: usize = 0;
    for (rest[0..e_pos]) |c| if (c != '.') {
        digit_buf[nd] = c;
        nd += 1;
    };
    var digits = digit_buf[0..nd];
    // Normalize mantissa 0 (handled by ryu as "0.0").
    if (std.mem.allEqual(u8, digits, '0')) return w.writeAll("0.0");
    while (digits.len > 1 and digits[digits.len - 1] == '0') digits = digits[0 .. digits.len - 1];
    const length: isize = @intCast(digits.len);
    const kk = exp10 + 1; // 10^(kk-1) <= v < 10^kk
    const k = kk - length; // v = digits * 10^k
    if (k >= 0 and kk <= 16) {
        try w.writeAll(digits);
        try w.splatByteAll('0', @intCast(k));
        try w.writeAll(".0");
    } else if (kk > 0 and kk <= 16) {
        const p: usize = @intCast(kk);
        try w.writeAll(digits[0..p]);
        try w.writeByte('.');
        try w.writeAll(digits[p..]);
    } else if (kk > -5 and kk <= 0) {
        try w.writeAll("0.");
        try w.splatByteAll('0', @intCast(-kk));
        try w.writeAll(digits);
    } else if (length == 1) {
        try w.print("{s}e{d}", .{ digits, kk - 1 });
    } else {
        try w.print("{c}.{s}e{d}", .{ digits[0], digits[1..], kk - 1 });
    }
}

fn formatTag(buf: []u8, t: dicos.Tag) []const u8 {
    const n = t.name();
    if (n.len > 0) return n;
    return std.fmt.bufPrint(buf, "({X:0>4},{X:0>4})", .{ t.group, t.element }) catch unreachable;
}

const KeyedElement = struct { key: []const u8, elem: *const Element };

const JsonError = std.Io.Writer.Error || Allocator.Error;

fn writeDataset(gpa: Allocator, jw: *JsonWriter, ds: *const Dataset) JsonError!void {
    const elems = ds.iter();
    const keys_storage = try gpa.alloc([11]u8, elems.len);
    defer gpa.free(keys_storage);
    var entries = try gpa.alloc(KeyedElement, elems.len);
    defer gpa.free(entries);
    for (elems, 0..) |*e, i| entries[i] = .{ .key = formatTag(&keys_storage[i], e.tag), .elem = e };
    // serde_json::Map is a BTreeMap<String, _>: bytewise key order; on a
    // duplicate key the later insert wins.
    std.sort.insertion(KeyedElement, entries, {}, struct {
        fn lt(_: void, a: KeyedElement, b: KeyedElement) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    var n: usize = 0;
    for (entries, 0..) |e, i| {
        if (i + 1 < entries.len and std.mem.eql(u8, e.key, entries[i + 1].key)) continue;
        entries[n] = e;
        n += 1;
    }
    entries = entries[0..n];

    try jw.beginObject();
    for (entries, 0..) |e, i| {
        try jw.key(e.key, i == 0);
        try writeElement(gpa, jw, e.elem);
    }
    try jw.endObject(entries.len == 0);
}

fn writeElement(gpa: Allocator, jw: *JsonWriter, e: *const Element) JsonError!void {
    const w = jw.w;
    try jw.beginObject();
    switch (e.value) {
        .bytes => |b| {
            try jw.key("Length", true);
            try w.print("{d}", .{b.len});
        },
        .pixel_data => |*pd| {
            try jw.key("Encapsulated", true);
            try w.writeAll(if (pd.isCompressed()) "true" else "false");
            try jw.key("Frames", false);
            try w.print("{d}", .{pd.numFrames()});
            try jw.key("vr", false);
            try writeString(w, "OW");
            return jw.endObject(false);
        },
        .sequence => |items| {
            try jw.key("Value", true);
            try jw.beginArray();
            for (items, 0..) |*item, i| {
                try jw.arrayItem(i == 0);
                try writeDataset(gpa, jw, item);
            }
            try jw.endArray(items.len == 0);
            try jw.key("vr", false);
            try writeString(w, "SQ");
            return jw.endObject(false);
        },
        else => {
            try jw.key("Value", true);
            try writeScalarValue(jw, &e.value);
        },
    }
    try jw.key("vr", false);
    try writeString(w, e.vr.name());
    try jw.endObject(false);
}

fn writeScalarValue(jw: *JsonWriter, v: *const dicos.Value) std.Io.Writer.Error!void {
    const w = jw.w;
    switch (v.*) {
        .str => |s| try writeString(w, s),
        .u16_val => |x| try w.print("{d}", .{x}),
        .u32_val => |x| try w.print("{d}", .{x}),
        .i16_val => |x| try w.print("{d}", .{x}),
        .i32_val => |x| try w.print("{d}", .{x}),
        // json! widens f32 to f64 before formatting.
        .f32_val => |x| try writeF64(w, x),
        .f64_val => |x| try writeF64(w, x),
        inline .strings, .u16s, .f32s, .f64s => |items, t| {
            try jw.beginArray();
            for (items, 0..) |item, i| {
                try jw.arrayItem(i == 0);
                switch (t) {
                    .strings => try writeString(w, item),
                    .u16s => try w.print("{d}", .{item}),
                    .f32s, .f64s => try writeF64(w, item),
                    else => unreachable,
                }
            }
            try jw.endArray(items.len == 0);
        },
        .bytes, .sequence, .pixel_data => unreachable,
    }
}

// ---------------------------------------------------------------------------
// info
// ---------------------------------------------------------------------------

fn cmdInfo(gpa: Allocator, path: []const u8) !void {
    var ds = try openDataset(gpa, path);
    defer ds.deinit();
    var buf: [4096]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    const tag = dicos.tag;

    try w.print("File: {s}\n", .{path});
    try w.print("Elements: {d}\n", .{ds.len()});
    if (ds.getString(tag.MODALITY)) |m| try w.print("Modality: {s}\n", .{m});
    if (ds.rows()) |rows| if (ds.columns()) |cols| {
        if (rows > 0 and cols > 0) try w.print("Dimensions: {d}x{d}\n", .{ cols, rows });
    };
    const frames = ds.numberOfFrames();
    if (frames > 1) try w.print("Frames: {d}\n", .{frames});
    if (ds.bitsAllocated()) |bits| try w.print("Bits Allocated: {d}\n", .{bits});
    const ts = ds.transferSyntax();
    try w.print("Transfer Syntax: {s} ({s})\n", .{ ts.name(), ts.uid });
    if (ds.getString(tag.SOP_CLASS_UID)) |s| try w.print("SOP Class: {s}\n", .{s});
    if (ds.getString(tag.SOP_INSTANCE_UID)) |s| try w.print("SOP Instance: {s}\n", .{s});
    if (ds.getString(tag.PATIENT_NAME)) |s| try w.print("Patient Name: {s}\n", .{s});
    if (ds.getString(tag.SERIES_DESCRIPTION)) |s| try w.print("Series: {s}\n", .{s});
    if (ds.getString(tag.MANUFACTURER)) |s| try w.print("Manufacturer: {s}\n", .{s});
    if (ds.getString(tag.MANUFACTURER_MODEL_NAME)) |s| try w.print("Model: {s}\n", .{s});
    try w.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectF64(expected: []const u8, v: f64) !void {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeF64(&w, v);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "serde_json float formatting" {
    try expectF64("1.0", 1.0);
    try expectF64("-1024.0", -1024.0);
    try expectF64("0.0", 0.0);
    try expectF64("0.1", 0.1);
    try expectF64("2.5", 2.5);
    try expectF64("100.0", 100.0);
    try expectF64("0.00001", 1e-5);
    try expectF64("1e-6", 1e-6);
    try expectF64("1.5e-7", 1.5e-7);
    try expectF64("1e21", 1e21);
    try expectF64("1e16", 1e16);
    try expectF64("1000000000000000.0", 1e15);
    try expectF64("1.2345678901234568e17", 123456789012345680.0);
    try expectF64("0.10000000149011612", @as(f32, 0.1));
    try expectF64("null", std.math.nan(f64));
}

test "serde_json string escaping" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeString(&w, "a\"b\\c\n\x01\x7f\u{e9}");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\u0001\x7f\u{e9}\"", w.buffered());
}
