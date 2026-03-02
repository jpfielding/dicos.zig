# jpegli

Pure Zig implementation of JPEG Lossless (ITU-T T.81 Annex H) encoder and decoder.

## Features

- **Lossless compression** using differential pulse code modulation (DPCM)
- **Predictors 1-7** supported for optimal compression
- **Huffman entropy coding** for prediction residuals
- **8-bit and 16-bit** grayscale images
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.4.70`
- **Allocator-aware**: All memory allocation goes through `std.mem.Allocator`
- **Pure Zig**: No external codec dependencies

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.4.70` (JPEG Lossless, Non-Hierarchical, Process 14 SV1)

## Usage

### Encoding

```zig
const std = @import("std");
const jpegli = @import("jpegli");

// Encode with predictor 1 (left neighbor)
const pixels: []const u16 = &.{ 100, 200, 300, 400 };
const compressed = try jpegli.encode.encode(allocator, pixels, 2, 2);
defer allocator.free(compressed);
```

### Decoding

```zig
const jpegli = @import("jpegli");

const result = try jpegli.decode.decode(allocator, compressed, 2, 2);
defer allocator.free(result[0]); // pixel data
const pixels = result[0];
const width = result[1];
const height = result[2];
```

## Predictors

JPEG Lossless defines 7 predictors based on up to three neighboring samples:

```
      Rc  Rb
      Ra   x
```

Where:
- **Ra** = sample immediately to the left of `x`
- **Rb** = sample immediately above `x`
- **Rc** = sample diagonally above-left of `x` (above Ra, left of Rb)

| Selection | Formula | Name |
|-----------|---------|------|
| 1 | Ra | Left |
| 2 | Rb | Above |
| 3 | Rc | Above-left |
| 4 | Ra + Rb - Rc | Linear interpolation |
| 5 | Ra + (Rb - Rc) / 2 | Weighted left + half vertical gradient |
| 6 | Rb + (Ra - Rc) / 2 | Weighted above + half horizontal gradient |
| 7 | (Ra + Rb) / 2 | Average of left and above |

The default encoding uses predictor 1 (left neighbor). For the first row,
prediction uses the previous sample in scan order. For the first pixel,
prediction uses `2^(precision-1)` as the initial value.

## JPEG Lossless Stream Format

```
SOI  - Start of Image (0xFFD8)
SOF3 - Start of Frame, Lossless Huffman (0xFFC3)
       Precision, height, width, components
DHT  - Define Huffman Table (0xFFC4)
       Table class, table ID, code counts, code values
SOS  - Start of Scan (0xFFDA)
       Component selector, predictor selection, point transform
[entropy-coded DPCM differences]
EOI  - End of Image (0xFFD9)
```

The SOF3 marker (0xFFC3) distinguishes JPEG Lossless from other JPEG modes.
The entropy-coded segment contains Huffman-coded prediction residuals, where
each residual is the difference between the actual pixel value and the
predicted value from the selected predictor.

### Huffman Coding

The encoder builds an optimal Huffman table from the histogram of DPCM
difference categories. Each difference value is encoded as a category code
(number of additional bits needed) followed by the additional bits that
identify the exact value within that category.

For 16-bit images, categories range from 0 to 16, where category `k` represents
differences in the range `[-(2^k - 1), -2^(k-1)] union [2^(k-1), 2^k - 1]`.

## Public Types and Functions

### `encode.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `encode` | `fn(Allocator, []const u16, u32, u32) CodecError![]u8` | Encode 16-bit pixels to JPEG Lossless bitstream |
| `CodecError` | `error` | `InvalidData`, `DimensionMismatch`, `OutOfMemory` |

### `decode.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `decode` | `fn(Allocator, []const u8, u32, u32) CodecError!struct{[]u16, u32, u32}` | Decode JPEG Lossless bitstream to 16-bit pixels |
| `CodecError` | `error` | `InvalidData`, `DimensionMismatch`, `Unsupported`, `EndOfStream`, `OutOfMemory` |

### `huffman.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `HuffmanTable` | `struct` | Huffman table for JPEG lossless coding |
| `buildTable` | function | Build optimal Huffman table from symbol frequencies |

### `scan.zig`

Scan-level encode/decode functions for SOS segment processing, including
DPCM prediction computation and entropy-coded data bit I/O.

### Root (`jpegli`)

| Symbol | Type | Description |
|--------|------|-------------|
| `TRANSFER_SYNTAX_UID` | `[]const u8` | `"1.2.840.10008.1.2.4.70"` |
| `huffman` | module | Huffman table construction and coding |
| `scan` | module | Scan-level encode/decode |
| `encode` | module | Full encoder pipeline |
| `decode` | module | Full decoder pipeline |

## Module Structure

```
jpegli/
  root.zig      Public API, TRANSFER_SYNTAX_UID constant, module re-exports
  encode.zig    Encoder: DPCM prediction + Huffman table building + bitstream output
  decode.zig    Decoder: Marker parsing + Huffman decoding + DPCM reconstruction
  huffman.zig   Huffman table construction, code generation, and symbol coding
  scan.zig      Scan-level encode/decode (SOS segment processing)
```

## Tests

Run the jpegli tests:

```sh
zig build test
```

The module includes 33 tests covering:

- Huffman table construction and code generation
- Single-symbol and multi-symbol Huffman coding
- Scan-level encode/decode round-trips
- Full pipeline encode/decode round-trips (small images, gradients, flat images)
- All 7 predictor modes
- 16-bit precision handling
- Edge cases (1x1 images, single-row images, maximum pixel values)
- Marker parsing validation (SOI, SOF3, DHT, SOS, EOI)
- Error handling for malformed bitstreams

## References

- ITU-T Rec. T.81 | ISO/IEC 10918-1 (JPEG), Annex H (Lossless Mode)
- DICOM Transfer Syntax: `1.2.840.10008.1.2.4.70` (JPEG Lossless, First-Order Prediction, Process 14 SV1)
