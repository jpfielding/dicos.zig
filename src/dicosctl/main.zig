const std = @import("std");
const dicos = @import("dicos");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const command = args.next() orelse {
        printUsage();
        std.process.exit(1);
    };

    if (std.mem.eql(u8, command, "dump")) {
        const file_path = args.next() orelse {
            std.debug.print("error: dump requires a file path\n", .{});
            std.process.exit(1);
        };
        cmdDump(allocator, file_path) catch |e| {
            std.debug.print("error: {}\n", .{e});
            std.process.exit(1);
        };
    } else if (std.mem.eql(u8, command, "info")) {
        const file_path = args.next() orelse {
            std.debug.print("error: info requires a file path\n", .{});
            std.process.exit(1);
        };
        cmdInfo(allocator, file_path) catch |e| {
            std.debug.print("error: {}\n", .{e});
            std.process.exit(1);
        };
    } else {
        std.debug.print("error: unknown command '{s}'\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn printUsage() void {
    std.debug.print(
        \\dicosctl -- DICOS command-line tool
        \\
        \\Usage:
        \\  dicosctl dump <file.dcs>   Dump all metadata as JSON
        \\  dicosctl info <file.dcs>   Print human-readable summary
        \\
    , .{});
}

fn openDataset(allocator: std.mem.Allocator, path: []const u8) !dicos.Dataset {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(data);
    return dicos.reader.parseBytes(allocator, data);
}

fn cmdDump(allocator: std.mem.Allocator, path: []const u8) !void {
    var ds = try openDataset(allocator, path);
    defer ds.deinit();

    std.debug.print("{{\n", .{});

    var iter = ds.elements.iterator();
    var first = true;
    while (iter.next()) |entry| {
        const elem = entry.value_ptr;
        if (!first) std.debug.print(",\n", .{});
        first = false;

        const tag_name = elem.tag_val.name();
        if (tag_name.len > 0) {
            std.debug.print("  \"{s}\": ", .{tag_name});
        } else {
            std.debug.print("  \"({X:0>4},{X:0>4})\": ", .{ elem.tag_val.group, elem.tag_val.element });
        }

        const vr_bytes = elem.vr.asBytes();
        std.debug.print("{{\"vr\": \"{s}\", ", .{&vr_bytes});

        switch (elem.value) {
            .str => |s| std.debug.print("\"Value\": \"{s}\"}}", .{s}),
            .strings => |values| {
                std.debug.print("\"Value\": [", .{});
                for (values, 0..) |s, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("\"{s}\"", .{s});
                }
                std.debug.print("]}}", .{});
            },
            .u16_val => |v| std.debug.print("\"Value\": {}}}", .{v}),
            .u16s => |vs| {
                std.debug.print("\"Value\": [", .{});
                for (vs, 0..) |v, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{}", .{v});
                }
                std.debug.print("]}}", .{});
            },
            .u32_val => |v| std.debug.print("\"Value\": {}}}", .{v}),
            .i16_val => |v| std.debug.print("\"Value\": {}}}", .{v}),
            .i32_val => |v| std.debug.print("\"Value\": {}}}", .{v}),
            .f32_val => |v| std.debug.print("\"Value\": {d}}}", .{v}),
            .f64_val => |v| std.debug.print("\"Value\": {d}}}", .{v}),
            .f32s => |vs| {
                std.debug.print("\"Value\": [", .{});
                for (vs, 0..) |v, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{d}", .{v});
                }
                std.debug.print("]}}", .{});
            },
            .f64s => |vs| {
                std.debug.print("\"Value\": [", .{});
                for (vs, 0..) |v, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{d}", .{v});
                }
                std.debug.print("]}}", .{});
            },
            .bytes => |b| std.debug.print("\"Length\": {}}}", .{b.len}),
            .sequence => |items| std.debug.print("\"vr\": \"SQ\", \"Items\": {}}}", .{items.len}),
            .pixel_data => |pd| std.debug.print("\"Encapsulated\": {}, \"Frames\": {}}}", .{ pd.is_encapsulated, pd.frames.len }),
        }
    }

    std.debug.print("\n}}\n", .{});
}

fn cmdInfo(allocator: std.mem.Allocator, path: []const u8) !void {
    var ds = try openDataset(allocator, path);
    defer ds.deinit();

    std.debug.print("File: {s}\n", .{path});
    std.debug.print("Elements: {}\n", .{ds.len()});

    if (ds.getString(dicos.tag.MODALITY)) |mod| {
        std.debug.print("Modality: {s}\n", .{mod});
    }

    const rows_val = ds.rows();
    const cols_val = ds.columns();
    if (rows_val > 0 and cols_val > 0) {
        std.debug.print("Dimensions: {}x{}\n", .{ cols_val, rows_val });
    }

    const frames = ds.numberOfFrames();
    if (frames > 1) {
        std.debug.print("Frames: {}\n", .{frames});
    }

    std.debug.print("Bits Allocated: {}\n", .{ds.bitsAllocated()});

    const ts = ds.transferSyntax();
    std.debug.print("Transfer Syntax: {s} ({s})\n", .{ ts.getName(), ts.getUid() });

    if (ds.getString(dicos.tag.SOP_CLASS_UID)) |sop| {
        std.debug.print("SOP Class: {s}\n", .{sop});
    }

    if (ds.getString(dicos.tag.SOP_INSTANCE_UID)) |sop| {
        std.debug.print("SOP Instance: {s}\n", .{sop});
    }

    if (ds.getString(dicos.tag.PATIENT_NAME)) |name_str| {
        std.debug.print("Patient Name: {s}\n", .{name_str});
    }

    if (ds.getString(dicos.tag.SERIES_DESCRIPTION)) |desc| {
        std.debug.print("Series: {s}\n", .{desc});
    }

    if (ds.getString(dicos.tag.MANUFACTURER)) |mfr| {
        std.debug.print("Manufacturer: {s}\n", .{mfr});
    }

    if (ds.getString(dicos.tag.MANUFACTURER_MODEL_NAME)) |model| {
        std.debug.print("Model: {s}\n", .{model});
    }
}
