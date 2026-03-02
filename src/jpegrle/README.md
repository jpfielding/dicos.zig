# jpegrle

Pure Zig implementation of DICOM RLE (Run Length Encoding) using PackBits compression.

## Features

- **Lossless compression** using PackBits algorithm
- **16-bit grayscale images** with byte-plane separation for improved compression
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.5`
- **Allocator-aware**: All memory allocation goes through `std.mem.Allocator`
- **Pure Zig**: No external codec dependencies

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.5` (RLE Lossless)

## Usage

### Encoding

```zig
const std = @import("std");
const jpegrle = @import("jpegrle");

const pixels: []const u16 = &.{ 100, 200, 300, 400 };
var buf = std.ArrayList(u8).init(allocator);
defer buf.deinit();
try jpegrle.encode.encode(allocator, pixels, 2, 2, buf.writer().any());
```

### Decoding

```zig
const jpegrle = @import("jpegrle");

// Width and height must be provided (not stored in RLE stream)
const result = try jpegrle.decode.decode(allocator, compressed_data, 2, 2);
defer result.deinit(allocator);

// result.pixels contains the decoded u16 values
// result.width and result.height echo the provided dimensions
```

## RLE Algorithm

DICOM RLE uses the PackBits algorithm, a simple run-length encoding scheme
that compresses data by replacing repeated byte sequences with a control byte
and a single copy of the repeated value.

| Control Byte (i8) | Action |
|--------------------|--------|
| 0 to 127 | Copy next (n+1) bytes literally |
| -1 to -127 | Repeat next byte (-n+1) times |
| -128 | No operation (padding) |

### 16-bit Image Handling

For 16-bit grayscale images, pixels are split into two segments:
1. **Segment 1**: High bytes of all pixels
2. **Segment 2**: Low bytes of all pixels

This byte-plane separation improves compression because adjacent high bytes
often have similar values. For example, a row of 16-bit pixels where values
change slowly will have many identical high bytes, producing long runs that
PackBits compresses efficiently.

## DICOM RLE Format

```
Header (64 bytes):
  Bytes 0-3:   Number of segments (u32 LE)
  Bytes 4-7:   Offset to segment 1
  Bytes 8-11:  Offset to segment 2
  ...
  Bytes 60-63: Offset to segment 15 (if present)

Segments:
  [PackBits compressed data for segment 1]
  [PackBits compressed data for segment 2]
  ...
```

The header always occupies 64 bytes regardless of the number of segments.
Up to 15 segment offsets can be stored (bytes 4-63, four bytes each).

## Public Types and Functions

### `encode.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `encode` | `fn(Allocator, []const u16, u32, u32, AnyWriter) EncodeError!void` | Encode 16-bit pixels to DICOM RLE |
| `EncodeError` | `error` | `DimensionMismatch`, `InvalidData`, `IoError`, `OutOfMemory` |

### `decode.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `decode` | `fn(Allocator, []const u8, u32, u32) DecodeError!DecodeResult` | Decode DICOM RLE to 16-bit pixels |
| `DecodeResult` | `struct` | `{ pixels: []u16, width: u32, height: u32 }` with `deinit(Allocator)` |
| `DecodeError` | `error` | `InvalidData`, `DimensionMismatch`, `Unsupported`, `OutOfMemory` |

### `packbits.zig`

Low-level PackBits compress and decompress functions operating on raw byte slices.

### Root (`jpegrle`)

| Symbol | Type | Description |
|--------|------|-------------|
| `TRANSFER_SYNTAX_UID` | `[]const u8` | `"1.2.840.10008.1.2.5"` |
| `packbits` | module | Low-level PackBits operations |
| `encode` | module | RLE encoder |
| `decode` | module | RLE decoder |

## Module Structure

```
jpegrle/
  root.zig       Public API, TRANSFER_SYNTAX_UID constant, module re-exports
  encode.zig     Encoder: pixel byte-plane splitting + PackBits compression
  decode.zig     Decoder: PackBits decompression + pixel byte-plane reassembly
  packbits.zig   PackBits run-length encoding/decoding
```

## Tests

Run the jpegrle tests:

```sh
zig build test
```

The module includes 29 tests covering:

- PackBits encode/decode round-trips (literal runs, repeated runs, mixed data)
- 16-bit encode/decode round-trips (small images, gradient patterns)
- Edge cases (single pixel, empty planes, maximum run lengths)
- Header parsing validation (segment counts, offsets)
- Dimension mismatch error handling

## References

- DICOM Part 5, Section 8.2.2 / Annex G (RLE Compression)
- DICOM Transfer Syntax: `1.2.840.10008.1.2.5` (RLE Lossless)
- Apple PackBits compression format
