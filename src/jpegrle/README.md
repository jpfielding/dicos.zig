# DICOM RLE Codec

Pure Zig implementation of DICOM RLE (Run Length Encoding) using PackBits
compression. Port of the Rust `jpegrle` crate (2.1.0).

## Features

- **Lossless compression** using PackBits algorithm
- **8-bit and 16-bit** grayscale images
- **Byte-plane separation** for 16-bit images (improved compression)
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.5`
- **Pure Zig**: No external codec dependencies, explicit allocators, no hidden allocation
- **Hardened decoder**: width x height is capped at 2^28 pixels before any
  allocation, segment offsets are bounds-checked, and PackBits output
  pre-allocation is bounded by what the input can expand to

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.5` (RLE Lossless)

## Usage

Import the module (wired in `build.zig` as `jpegrle`):

```zig
const jpegrle = @import("jpegrle");
```

### Encoding

```zig
// Caller owns the returned bytes.
const pixels = [_]u16{ 100, 200, 300, 400 };
const compressed = try jpegrle.encode(allocator, &pixels, 2, 2);
defer allocator.free(compressed);
```

### Decoding

```zig
// Width and height must be provided (not stored in RLE stream)
const res = try jpegrle.decode(allocator, compressed, 2, 2);
defer res.deinit(allocator);
// res.pixels, res.width, res.height
```

### Errors

`jpegrle.CodecError` mirrors the Rust `CodecError`: `Io`, `InvalidData`,
`Unsupported`, `DimensionMismatch`, `Truncated`, `InvalidParameter`,
`OutOfMemory`. Zig error sets cannot carry payloads, so the details the Rust
variants carry (parameter name/value/allowed range, truncation offset and
context, expected/actual pixel counts, message) are reported through an
optional `jpegrle.Diagnostics` out-parameter via `decodeDiag` / `encodeDiag`.

## RLE Algorithm

DICOM RLE uses the PackBits algorithm, a simple run-length encoding scheme
that compresses data by replacing repeated byte sequences with a control byte
and a single copy of the repeated value.

| Control Byte | Action |
|--------------|--------|
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

## Supported Image Types

| Pixel Type | Segments | Description |
|------------|----------|-------------|
| `u8` | 1 | 8-bit grayscale pixels (decode widens to `u16`) |
| `u16` | 2 | High/low byte planes |

## DICOM RLE Format

```
Header (64 bytes):
  Bytes 0-3:   Number of segments (uint32 LE)
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
Up to 15 segment offsets can be stored (bytes 4-63, four bytes each). Each
segment is padded to even length.

## Architecture

```
jpegrle/
  root.zig            # Public API (encode, decode, TRANSFER_SYNTAX_UID)
  encode.zig          # Encoder: pixel splitting + PackBits compression
  decode.zig          # Decoder: PackBits decompression + pixel reassembly
  packbits.zig        # PackBits run-length encoding/decoding
  error.zig           # CodecError set and Diagnostics
  mutation_test.zig   # Corruption robustness tests (truncation, bit flips)
```

## Rust parity

For identical input the encoder emits byte-identical output to the Rust
`jpegrle` 2.1.0 crate, and the decoder reproduces the Rust error classification
(`Truncated` with offset/context, `InvalidData`, `Unsupported`,
`DimensionMismatch`, `InvalidParameter`).

## References

- DICOM Part 5, Section 8.2.2 / Annex G (RLE Compression)
- DICOM Transfer Syntax: `1.2.840.10008.1.2.5` (RLE Lossless)
- Apple PackBits compression format
