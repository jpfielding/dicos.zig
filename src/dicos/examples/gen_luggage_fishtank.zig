//! Generate a synthetic DICOS CT volume that depicts luggage with a fish tank.
//!
//! Port of the Rust example `examples/gen-luggage-fishtank.rs`; for the same
//! arguments it writes a byte-identical file. The output intentionally uses
//! neutral/public-safe metadata values.
//!
//!   zig build gen-luggage-fishtank -- --size 64,64,48 --out /tmp/x.dcs

const std = @import("std");
const dicos = @import("dicos");

const tag = dicos.tag;
const Dataset = dicos.Dataset;
const Element = dicos.Element;
const Allocator = std.mem.Allocator;

/// This generator's own implementation-class UID (example-local, not a
/// registered standard identifier).
const IMPL_CLASS_UID = "1.2.826.0.1.3680043.8.498.999.1";

const Args = struct {
    out: []const u8 = "testdata/synthetic/luggage_fishtank_ct.dcs",
    size: [3]usize = .{ 256, 256, 160 }, // x,y,z
    seed: u64 = 20260225,
    with_noise: bool = true,
    include_threat_tags: bool = true,
};

const BBox = struct {
    min: [3]usize,
    max: [3]usize,
};

/// Upper bound on generated voxels (4 GiB of u16): refuse absurd sizes up
/// front instead of attempting the allocation.
const MAX_VOXELS: usize = 1 << 31;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var err_msg: [256]u8 = undefined;
    const args = parseArgs(argv[1..], &err_msg) catch |e| switch (e) {
        error.Help => {
            printHelp();
            return;
        },
        error.Invalid => fail("{s}", .{std.mem.sliceTo(&err_msg, 0)}),
    };
    run(gpa, args) catch |e| fail("{s}", .{@errorName(e)});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("error: " ++ fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
    std.process.exit(1);
}

fn run(gpa: Allocator, args: Args) !void {
    const voxels, const fish_tank = try synthesizeVolume(gpa, args.size, args.seed, args.with_noise);
    defer gpa.free(voxels);

    var ds = try buildDataset(gpa, voxels, args.size, fish_tank, args.include_threat_tags);
    defer ds.deinit();

    if (std.fs.path.dirname(args.out)) |dir| std.fs.cwd().makePath(dir) catch {};
    const file = try std.fs.cwd().createFile(args.out, .{});
    defer file.close();
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(&buf);
    const bytes = try dicos.write(&fw.interface, &ds);
    try fw.interface.flush();

    var obuf: [512]u8 = undefined;
    var ow = std.fs.File.stdout().writer(&obuf);
    try ow.interface.print("Wrote {s} ({d} bytes) [{d}x{d}x{d}]\n", .{ args.out, bytes, args.size[0], args.size[1], args.size[2] });
    try ow.interface.flush();
}

const ArgError = error{ Help, Invalid };

fn invalid(buf: *[256]u8, comptime fmt: []const u8, args: anytype) ArgError {
    const s = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch buf[0 .. buf.len - 1];
    buf[s.len] = 0;
    return error.Invalid;
}

fn parseArgs(argv: []const [:0]u8, err_buf: *[256]u8) ArgError!Args {
    var args: Args = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const flag: []const u8 = argv[i];
        const value: ?[]const u8 = if (i + 1 < argv.len) argv[i + 1] else null;
        if (std.mem.eql(u8, flag, "--out")) {
            args.out = value orelse return invalid(err_buf, "missing value for --out", .{});
            i += 1;
        } else if (std.mem.eql(u8, flag, "--size")) {
            args.size = try parseSize(value orelse return invalid(err_buf, "missing value for --size", .{}), err_buf);
            i += 1;
        } else if (std.mem.eql(u8, flag, "--seed")) {
            const v = value orelse return invalid(err_buf, "missing value for --seed", .{});
            args.seed = parseU64(v) orelse return invalid(err_buf, "invalid --seed: {s}", .{v});
            i += 1;
        } else if (std.mem.eql(u8, flag, "--with-noise")) {
            args.with_noise = try parseOnOff("--with-noise", value orelse return invalid(err_buf, "missing value for --with-noise", .{}), err_buf);
            i += 1;
        } else if (std.mem.eql(u8, flag, "--include-threat-tags")) {
            args.include_threat_tags = try parseOnOff("--include-threat-tags", value orelse return invalid(err_buf, "missing value for --include-threat-tags", .{}), err_buf);
            i += 1;
        } else if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) {
            return error.Help;
        } else {
            return invalid(err_buf, "unknown argument: {s}", .{flag});
        }
    }
    return args;
}

/// Rust `str::parse::<u64>()` semantics (optional '+', digits only).
fn parseU64(s: []const u8) ?u64 {
    return dicos.types.parseIntStrict(u64, s);
}

fn parseSize(s: []const u8, err_buf: *[256]u8) ArgError![3]usize {
    if (std.mem.count(u8, s, ",") != 2) return invalid(err_buf, "invalid --size '{s}', expected x,y,z", .{s});
    var out: [3]usize = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        out[i] = dicos.types.parseIntStrict(usize, dicos.types.trimWhitespace(part)) orelse
            return invalid(err_buf, "invalid integer in --size: {s}", .{part});
    }
    for (out) |v| if (v < 32) return invalid(err_buf, "--size values must be >= 32 in each axis for this generator", .{});
    if (out[0] > std.math.maxInt(u16) or out[1] > std.math.maxInt(u16)) {
        return invalid(err_buf, "--size x and y must be at most {d} (DICOM ROWS/COLUMNS u16 limit); got x={d}, y={d}", .{ std.math.maxInt(u16), out[0], out[1] });
    }
    // Zig-port guard: the Rust example would just attempt the allocation.
    const voxels = std.math.mul(usize, out[0], out[1]) catch return invalid(err_buf, "--size is too large", .{});
    const total = std.math.mul(usize, voxels, out[2]) catch return invalid(err_buf, "--size is too large", .{});
    if (total > MAX_VOXELS) return invalid(err_buf, "--size is too large ({d} voxels, max {d})", .{ total, MAX_VOXELS });
    return out;
}

fn parseOnOff(flag: []const u8, value: []const u8, err_buf: *[256]u8) ArgError!bool {
    if (std.mem.eql(u8, value, "on")) return true;
    if (std.mem.eql(u8, value, "off")) return false;
    return invalid(err_buf, "{s} expects on|off, got '{s}'", .{ flag, value });
}

fn printHelp() void {
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    w.interface.writeAll(
        \\dicos-gen-luggage-fishtank
        \\Generate a synthetic DICOS CT sample with a fish tank inside luggage.
        \\
        \\Options:
        \\  --out <path>                   Output file path
        \\  --size <x,y,z>                 Volume size (default: 256,256,160)
        \\  --seed <u64>                   Noise seed (default: 20260225)
        \\  --with-noise <on|off>          Enable noise (default: on)
        \\  --include-threat-tags <on|off> Include Group 4010 ROI tags (default: on)
        \\
    ) catch {};
    w.interface.flush() catch {};
}

fn synthesizeVolume(gpa: Allocator, size: [3]usize, seed: u64, with_noise: bool) !struct { []u16, BBox } {
    const sx, const sy, const sz = size;
    const data = try gpa.alloc(u16, sx * sy * sz);
    errdefer gpa.free(data);

    // Global background.
    @memset(data, 450);

    // Luggage body and shell.
    const luggage: BBox = .{
        .min = .{ sx / 8, sy / 8, sz / 6 },
        .max = .{ sx - sx / 8 - 1, sy - sy / 8 - 1, sz - sz / 6 - 1 },
    };
    fillBox(data, size, luggage, 1800);
    paintShell(data, size, luggage, 3, 6200);

    // Fish tank in luggage center.
    const fish_tank: BBox = .{
        .min = .{ sx / 3, sy / 3, sz / 3 },
        .max = .{ sx * 2 / 3, sy * 2 / 3, sz * 2 / 3 },
    };
    fillBox(data, size, fish_tank, 11200); // water

    // Air gap near top of tank.
    const air_gap: BBox = .{
        .min = .{ fish_tank.min[0] + 2, fish_tank.min[1] + 2, fish_tank.max[2] - 4 },
        .max = .{ fish_tank.max[0] - 2, fish_tank.max[1] - 2, fish_tank.max[2] - 2 },
    };
    fillBox(data, size, air_gap, 900);

    // Glass wall.
    paintShell(data, size, fish_tank, 2, 26000);

    // Simple fish ellipsoids.
    paintEllipsoid(data, size, .{ sx * 46 / 100, sy * 47 / 100, sz * 47 / 100 }, .{ sx / 28, sy / 36, sz / 48 }, 14500);
    paintEllipsoid(data, size, .{ sx * 56 / 100, sy * 54 / 100, sz * 44 / 100 }, .{ sx / 32, sy / 42, sz / 54 }, 15000);

    // A few clutter blocks in the luggage around the tank.
    fillBox(data, size, .{ .min = .{ sx / 5, sy / 5, sz / 3 }, .max = .{ sx / 4, sy * 2 / 5, sz / 2 } }, 7800);
    fillBox(data, size, .{ .min = .{ sx * 3 / 4, sy / 4, sz / 3 }, .max = .{ sx * 4 / 5, sy * 3 / 7, sz / 2 } }, 9200);

    if (with_noise) addSeededNoise(data, seed);
    return .{ data, fish_tank };
}

fn fillBox(data: []u16, size: [3]usize, b: BBox, value: u16) void {
    const sx, const sy, _ = size;
    var z = b.min[2];
    while (z <= b.max[2]) : (z += 1) {
        var y = b.min[1];
        while (y <= b.max[1]) : (y += 1) {
            const row = z * sx * sy + y * sx;
            @memset(data[row + b.min[0] .. row + b.max[0] + 1], value);
        }
    }
}

fn paintShell(data: []u16, size: [3]usize, b: BBox, thickness: usize, value: u16) void {
    const sx, const sy, _ = size;
    var z = b.min[2];
    while (z <= b.max[2]) : (z += 1) {
        var y = b.min[1];
        while (y <= b.max[1]) : (y += 1) {
            const row = z * sx * sy + y * sx;
            var x = b.min[0];
            while (x <= b.max[0]) : (x += 1) {
                if (x - b.min[0] < thickness or b.max[0] - x < thickness or
                    y - b.min[1] < thickness or b.max[1] - y < thickness or
                    z - b.min[2] < thickness or b.max[2] - z < thickness)
                {
                    data[row + x] = value;
                }
            }
        }
    }
}

fn paintEllipsoid(data: []u16, size: [3]usize, center: [3]usize, radius: [3]usize, value: u16) void {
    const sx, const sy, const sz = size;
    const cx, const cy, const cz = center;
    const rx, const ry, const rz = radius;
    if (rx == 0 or ry == 0 or rz == 0) return;

    const z_max = @min(cz + rz, sz - 1);
    const y_max = @min(cy + ry, sy - 1);
    const x_max = @min(cx + rx, sx - 1);
    var z = cz -| rz;
    while (z <= z_max) : (z += 1) {
        var y = cy -| ry;
        while (y <= y_max) : (y += 1) {
            const row = z * sx * sy + y * sx;
            var x = cx -| rx;
            while (x <= x_max) : (x += 1) {
                const dx = (toF64(x) - toF64(cx)) / toF64(rx);
                const dy = (toF64(y) - toF64(cy)) / toF64(ry);
                const dz = (toF64(z) - toF64(cz)) / toF64(rz);
                if (dx * dx + dy * dy + dz * dz <= 1.0) data[row + x] = value;
            }
        }
    }
}

fn toF64(v: usize) f64 {
    return @floatFromInt(v);
}

fn addSeededNoise(data: []u16, seed: u64) void {
    var x: u64 = seed ^ 0x9E37_79B9_7F4A_7C15;
    for (data) |*voxel| {
        // Xorshift-style deterministic PRNG (wrapping shifts, as in Rust).
        x ^= x << 7;
        x ^= x >> 9;
        x ^= x << 8;
        const noise: i32 = @as(i32, @intCast(x & 0x1F)) - 15; // [-15, +16]
        const v: i32 = @as(i32, voxel.*) + noise;
        voxel.* = @intCast(std.math.clamp(v, 0, std.math.maxInt(u16)));
    }
}

fn buildDataset(gpa: Allocator, voxels: []const u16, size: [3]usize, fish_tank: BBox, include_threat_tags: bool) !Dataset {
    const sx, const sy, const sz = size;
    const now_date = "20260225";
    const now_time = "120000.000000";

    const sop_instance_uid = "1.2.826.0.1.3680043.8.498.999.1001";
    const study_uid = "1.2.826.0.1.3680043.8.498.999.2001";
    const series_uid = "1.2.826.0.1.3680043.8.498.999.3001";
    const frame_uid = "1.2.826.0.1.3680043.8.498.999.4001";

    var ds = Dataset.init(gpa);
    errdefer ds.deinit();

    // File Meta Information.
    try ds.putString(tag.MEDIA_STORAGE_SOP_CLASS_UID, .UI, dicos.uid.DICOS_CT_IMAGE_STORAGE);
    try ds.putString(tag.MEDIA_STORAGE_SOP_INSTANCE_UID, .UI, sop_instance_uid);
    try ds.putString(tag.TRANSFER_SYNTAX_UID, .UI, dicos.transfer.EXPLICIT_VR_LITTLE_ENDIAN);
    try ds.putString(tag.IMPLEMENTATION_CLASS_UID, .UI, IMPL_CLASS_UID);
    try ds.putString(tag.IMPLEMENTATION_VERSION_NAME, .SH, "DICOSRS_2026A");

    // SOP + study + series.
    try ds.putString(tag.SOP_CLASS_UID, .UI, dicos.uid.DICOS_CT_IMAGE_STORAGE);
    try ds.putString(tag.SOP_INSTANCE_UID, .UI, sop_instance_uid);
    try ds.putString(tag.MODALITY, .CS, "CT");
    {
        const image_type = [_][]const u8{ "ORIGINAL", "PRIMARY", "AXIAL" };
        const values = try gpa.alloc([]const u8, image_type.len);
        var made: usize = 0;
        errdefer {
            for (values[0..made]) |v| gpa.free(v);
            gpa.free(values);
        }
        while (made < image_type.len) : (made += 1) values[made] = try gpa.dupe(u8, image_type[made]);
        try ds.insert(Element.init(tag.IMAGE_TYPE, .CS, .{ .strings = values }));
    }
    try ds.putString(tag.PRESENTATION_INTENT_TYPE, .CS, "FOR PRESENTATION");

    try ds.putString(tag.STUDY_INSTANCE_UID, .UI, study_uid);
    try ds.putString(tag.SERIES_INSTANCE_UID, .UI, series_uid);
    try ds.putString(tag.FRAME_OF_REFERENCE_UID, .UI, frame_uid);

    try ds.putString(tag.STUDY_DATE, .DA, now_date);
    try ds.putString(tag.SERIES_DATE, .DA, now_date);
    try ds.putString(tag.CONTENT_DATE, .DA, now_date);
    try ds.putString(tag.INSTANCE_CREATION_DATE, .DA, now_date);
    try ds.putString(tag.STUDY_TIME, .TM, now_time);
    try ds.putString(tag.SERIES_TIME, .TM, now_time);
    try ds.putString(tag.CONTENT_TIME, .TM, now_time);
    try ds.putString(tag.INSTANCE_CREATION_TIME, .TM, now_time);

    try ds.putString(tag.STUDY_DESCRIPTION, .LO, "Synthetic Luggage Scan");
    try ds.putString(tag.SERIES_DESCRIPTION, .LO, "Luggage with Fish Tank (Synthetic)");
    try ds.putString(tag.PATIENT_NAME, .PN, "UNKNOWN^OBJECT");
    try ds.putString(tag.PATIENT_ID, .LO, "PUBLIC-DEMO-001");
    try ds.putString(tag.MANUFACTURER, .LO, "GenericVendor");
    try ds.putString(tag.MANUFACTURER_MODEL_NAME, .LO, "DemoScanner");
    try ds.putString(tag.STATION_NAME, .SH, "LAB_STATION");
    try ds.putString(tag.DEVICE_SERIAL_NUMBER, .LO, "SN-000000");
    try ds.putString(tag.SOFTWARE_VERSIONS, .LO, "dicos.rs-demo");

    // Image Pixel Module.
    try ds.putU16(tag.SAMPLES_PER_PIXEL, .US, 1);
    try ds.putString(tag.PHOTOMETRIC_INTERPRETATION, .CS, "MONOCHROME2");
    try ds.putU16(tag.ROWS, .US, @intCast(sy));
    try ds.putU16(tag.COLUMNS, .US, @intCast(sx));
    try ds.putU16(tag.BITS_ALLOCATED, .US, 16);
    try ds.putU16(tag.BITS_STORED, .US, 16);
    try ds.putU16(tag.HIGH_BIT, .US, 15);
    try ds.putU16(tag.PIXEL_REPRESENTATION, .US, 0);
    var nbuf: [32]u8 = undefined;
    try ds.putString(tag.NUMBER_OF_FRAMES, .IS, try std.fmt.bufPrint(&nbuf, "{d}", .{sz}));

    // Basic CT spatial/display tags.
    try ds.putString(tag.PIXEL_SPACING, .DS, "1.0\\1.0");
    try ds.putString(tag.SLICE_THICKNESS, .DS, "1.0");
    try ds.putString(tag.SPACING_BETWEEN_SLICES, .DS, "1.0");
    try ds.putString(tag.IMAGE_ORIENTATION_PATIENT, .DS, "1\\0\\0\\0\\1\\0");
    try ds.putString(tag.IMAGE_POSITION_PATIENT, .DS, "0\\0\\0");
    try ds.putString(tag.RESCALE_INTERCEPT, .DS, "0");
    try ds.putString(tag.RESCALE_SLOPE, .DS, "1");
    try ds.putString(tag.RESCALE_TYPE, .LO, "US");
    try ds.putString(tag.WINDOW_CENTER, .DS, "12000");
    try ds.putString(tag.WINDOW_WIDTH, .DS, "28000");
    try ds.putString(tag.WINDOW_CENTER_WIDTH_EXPLANATION, .LO, "DEFAULT");
    try ds.putString(tag.VOI_LUT_FUNCTION, .CS, "LINEAR");

    if (include_threat_tags) {
        const items = try gpa.alloc(Dataset, 1);
        items[0] = Dataset.init(gpa);
        // Hand ownership to `ds` first so every later failure frees it.
        try ds.insert(Element.init(tag.THREAT_ROI_SEQUENCE, .SQ, .{ .sequence = items }));
        const roi = &items[0];
        var bbuf: [96]u8 = undefined;
        try roi.putString(tag.BOUNDING_BOX_TOP_LEFT, .DS, try std.fmt.bufPrint(&bbuf, "{d}\\{d}\\{d}", .{ fish_tank.min[0], fish_tank.min[1], fish_tank.min[2] }));
        try roi.putString(tag.BOUNDING_BOX_BOTTOM_RIGHT, .DS, try std.fmt.bufPrint(&bbuf, "{d}\\{d}\\{d}", .{ fish_tank.max[0], fish_tank.max[1], fish_tank.max[2] }));
        try roi.putString(tag.POTENTIAL_THREAT_OBJECT_ID, .LO, "OOI-1");
        try roi.putString(tag.THREAT_CATEGORY_DESCRIPTION, .LO, "Aquarium");
        try roi.putString(tag.THREAT_CONFIDENCE_SCORE, .DS, "0.97");
        try roi.putString(tag.OOI_LABEL, .LO, "FISH_TANK");
        try roi.putString(tag.ALARM_DECISION, .CS, "ALARM");
        try ds.putU16(tag.NUMBER_OF_ALARM_OBJECTS, .US, 1);
    }

    // Native uncompressed pixel data, as raw little-endian bytes.
    const pixel_bytes = try gpa.alloc(u8, voxels.len * 2);
    for (voxels, 0..) |p, i| std.mem.writeInt(u16, pixel_bytes[i * 2 ..][0..2], p, .little);
    try ds.insert(Element.init(tag.PIXEL_DATA, .OW, .{ .bytes = pixel_bytes }));

    return ds;
}

test "generator output round-trips through the reader" {
    const a = std.testing.allocator;
    const size = [3]usize{ 32, 32, 32 };
    const voxels, const tank = try synthesizeVolume(a, size, 7, true);
    defer a.free(voxels);
    var ds = try buildDataset(a, voxels, size, tank, true);
    defer ds.deinit();
    const bytes = try dicos.writer.writeToBytes(a, &ds, .{});
    defer a.free(bytes);
    var rt = try dicos.parseBytes(a, bytes);
    defer rt.deinit();
    try std.testing.expectEqual(@as(u32, 32), rt.numberOfFrames());
    try std.testing.expectEqual(@as(usize, 32 * 32 * 32), rt.pixelData().?.totalPixels());
    try std.testing.expect(rt.get(tag.THREAT_ROI_SEQUENCE) != null);
}
