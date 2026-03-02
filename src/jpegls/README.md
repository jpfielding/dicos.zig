# jpegls

Pure Zig implementation of JPEG-LS (ITU-T T.87 / ISO/IEC 14495-1) encoder and decoder.

## Features

- **Lossless compression** using the LOCO-I algorithm
- **Context-based adaptive prediction** with Median Edge Detection (MED)
- **Golomb-Rice entropy coding** with adaptive parameter selection
- **Run-length mode** for efficient coding of uniform regions
- **8-bit and 16-bit** grayscale images
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.4.80`
- **Allocator-aware**: All memory allocation goes through `std.mem.Allocator`
- **Pure Zig**: No external codec dependencies

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.4.80` (JPEG-LS Lossless)

## Usage

### Encoding

```zig
const std = @import("std");
const jpegls = @import("jpegls");

const pixels: []const u16 = // ... row-major 16-bit pixel buffer
const compressed = try jpegls.encode.encode(allocator, pixels, 16, 16);
defer allocator.free(compressed);
```

### Decoding

```zig
const jpegls = @import("jpegls");

const result = try jpegls.decode.decode(allocator, compressed, 16, 16);
defer allocator.free(result[0]); // pixel data
const pixels = result[0];
const width = result[1];
const height = result[2];
```

## JPEG-LS Algorithm

JPEG-LS uses the LOCO-I (LOw COmplexity LOssless COmpression for Images) algorithm:

1. **Edge detection** using local gradients to classify the coding context
2. **Context modeling** based on neighboring pixel relationships
3. **Adaptive prediction** using the Median Edge Detector (MED)
4. **Golomb-Rice coding** for prediction residuals with adaptive k parameter
5. **Run-length encoding** for uniform regions where all local gradients are zero

### Prediction Context

```
      c  b  d
      a  x
```

Where `x` is the current sample being encoded, and `a`, `b`, `c`, `d` are
neighboring samples used for prediction and context determination:

- **a** = sample immediately to the left
- **b** = sample immediately above
- **c** = sample diagonally above-left
- **d** = sample diagonally above-right

### Median Edge Detector (MED)

The MED predictor selects among three prediction modes based on local gradients:

```
if c >= max(a, b):
    predict = min(a, b)      -- vertical edge detected
elif c <= min(a, b):
    predict = max(a, b)      -- horizontal edge detected
else:
    predict = a + b - c      -- no dominant edge
```

This adaptive prediction captures both horizontal and vertical edges efficiently,
which is critical for medical/security imaging where images contain sharp
boundaries between materials.

### Context Modeling

The encoder maintains 365 regular contexts plus 2 run-mode contexts, each
with adaptive A/B/C/N statistics that are updated after every sample. These
statistics drive both the bias cancellation and the Golomb-Rice parameter
selection, allowing the codec to adapt to local image characteristics.

### Golomb-Rice Coding

Prediction residuals are coded using Golomb-Rice codes parameterized by `k`:
- The quotient `q = residual >> k` is coded in unary
- The remainder `r = residual & ((1 << k) - 1)` is coded in `k` binary bits
- The parameter `k` is adaptively selected per-context from the running statistics

### Run-Length Mode

When all local gradients (Q1, Q2, Q3) are zero, the encoder enters run-length
mode. Consecutive pixels identical to the reconstruction value of `a` are counted
and coded using Golomb codes, which is highly efficient for uniform image regions
common in security screening backgrounds.

## JPEG-LS Stream Format

```
SOI   - Start of Image (0xFFD8)
SOF55 - Start of Frame, JPEG-LS (0xFFF7)
        Precision, height, width, components
LSE   - JPEG-LS Preset Parameters (0xFFF8, optional)
        Custom MAXVAL, T1, T2, T3, RESET thresholds
SOS   - Start of Scan (0xFFDA)
        Component selector, Near parameter (0 = lossless)
[entropy-coded image data]
EOI   - End of Image (0xFFD9)
```

## Public Types and Functions

### `encode.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `encode` | `fn(Allocator, []const u16, u32, u32) CodecError![]u8` | Encode 16-bit pixels to JPEG-LS bitstream |

### `decode.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `decode` | `fn(Allocator, []const u8, u32, u32) CodecError!struct{[]u16, u32, u32}` | Decode JPEG-LS bitstream to 16-bit pixels |

### `context.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `ContextModel` | `struct` | Manages 365 regular contexts + 2 run contexts with A/B/C/N statistics |

### `predictor.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `predictMed` | `fn(i32, i32, i32) i32` | Median Edge Detector prediction |
| `clampVal` | `fn(i32, i32) i32` | Clamp prediction to valid range |

### `bitstream.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `BitWriter` | `struct` | Bit-level output with JPEG byte-stuffing |
| `BitReader` | `struct` | Bit-level input with JPEG byte-stuffing |
| `CodecError` | `error` | `InvalidData`, `DimensionMismatch`, `OutOfMemory`, `EndOfStream`, `Unsupported` |

### `run_mode.zig`

Run-length mode encoding and decoding for uniform regions.

### Root (`jpegls`)

| Symbol | Type | Description |
|--------|------|-------------|
| `TRANSFER_SYNTAX_UID` | `[]const u8` | `"1.2.840.10008.1.2.4.80"` |
| `bitstream` | module | Bit-level I/O utilities |
| `context` | module | Context modeling with adaptive statistics |
| `predictor` | module | MED predictor and gradient computation |
| `run_mode` | module | Run-length mode for uniform regions |
| `encode` | module | Full encoder pipeline |
| `decode` | module | Full decoder pipeline |

## Module Structure

```
jpegls/
  root.zig        Public API, TRANSFER_SYNTAX_UID constant, module re-exports
  encode.zig      Encoder: prediction + context + Golomb-Rice output
  decode.zig      Decoder: Golomb-Rice input + context + reconstruction
  predictor.zig   MED predictor and gradient computation
  context.zig     Context modeling with adaptive A/B/C/N statistics
  run_mode.zig    Run-length mode for uniform regions
  bitstream.zig   Bit-level I/O utilities with JPEG byte-stuffing
```

## Tests

Run the jpegls tests:

```sh
zig build test
```

The module includes 51 tests covering:

- Bitstream read/write round-trips (single bits, multi-bit values, byte-stuffing)
- Context initialization and statistics updates
- MED predictor correctness (horizontal edge, vertical edge, smooth gradient)
- Golomb-Rice coding round-trips with various k parameters
- Run-length mode encode/decode (short runs, long runs, maximum runs)
- Full pipeline encode/decode round-trips (small images, gradients, random data)
- 16-bit precision handling (full u16 range, near-maximum values)
- Edge cases (1x1 images, single-row images, single-column images)
- Marker parsing validation (SOI, SOF55, SOS, LSE, EOI)
- Dimension mismatch and malformed data error handling

## References

- ITU-T Rec. T.87 | ISO/IEC 14495-1 (JPEG-LS baseline)
- M. Weinberger, G. Seroussi, G. Sapiro, "The LOCO-I Lossless Image Compression Algorithm:
  Principles and Standardization into JPEG-LS", IEEE Trans. Image Processing, 2000
- DICOM Transfer Syntax: `1.2.840.10008.1.2.4.80` (JPEG-LS Lossless)
