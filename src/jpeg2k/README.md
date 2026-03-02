# jpeg2k

Pure Zig implementation of JPEG 2000 Part-1 (ITU-T T.800 / ISO/IEC 15444-1) encoder and decoder.

## Features

- **Lossless compression** using 5/3 reversible discrete wavelet transform (DWT)
- **EBCOT tier-1 block coding** with embedded truncation
- **MQ arithmetic coder** (ITU-T T.800 Annex C)
- **Configurable decomposition levels** and code-block sizes
- **8-bit and 16-bit** grayscale images
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.4.90`
- **Allocator-aware**: All memory allocation goes through `std.mem.Allocator`
- **Pure Zig**: No external codec dependencies

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.4.90` (JPEG 2000 Lossless)

## Usage

### Encoding

```zig
const std = @import("std");
const jpeg2k = @import("jpeg2k");

const pixels: []const u16 = // ... row-major 16-bit pixel buffer
const opts = jpeg2k.codestream.Jpeg2kOptions{};
const compressed = try jpeg2k.codestream.encode(allocator, pixels, 8, 8, &opts);
defer allocator.free(compressed);
```

### Encoding with Custom Options

```zig
const jpeg2k = @import("jpeg2k");

const opts = jpeg2k.codestream.Jpeg2kOptions{
    .tile_width = 0,           // 0 = single tile (whole image)
    .tile_height = 0,
    .cb_width_exp = 6,         // Code-block width: 2^6 = 64
    .cb_height_exp = 6,        // Code-block height: 2^6 = 64
    .num_decomp_levels = 5,    // DWT decomposition levels
};
const compressed = try jpeg2k.codestream.encode(allocator, pixels, width, height, &opts);
defer allocator.free(compressed);
```

### Decoding

```zig
const jpeg2k = @import("jpeg2k");

const result = try jpeg2k.codestream.decode(allocator, compressed, 8, 8);
defer allocator.free(result[0]); // pixel data
const pixels = result[0];
const width = result[1];
const height = result[2];
```

## Processing Pipeline

The encoder processes an image through these stages:

1. **Tiling** -- Partition the image into tiles (default: single tile)
2. **RCT** -- Reversible Color Transform (identity for single-component grayscale)
3. **DWT** -- 5/3 reversible wavelet transform via lifting, producing LL/LH/HL/HH subbands at each decomposition level
4. **Quantization** -- Identity (no quantization) for lossless mode
5. **EBCOT Tier-1** -- Code each code-block independently using three coding passes (significance, refinement, cleanup) with the MQ coder
6. **EBCOT Tier-2** -- Organize coded data into packets and layers
7. **Codestream** -- Write markers and tile-part data

### 5/3 Reversible DWT

The discrete wavelet transform uses the Le Gall 5/3 filter with the lifting scheme:

```
Forward:
  d[n] = x[2n+1] - floor((x[2n] + x[2n+2]) / 2)       (predict)
  s[n] = x[2n]   + floor((d[n-1] + d[n] + 2) / 4)      (update)

Inverse:
  x[2n]   = s[n] - floor((d[n-1] + d[n] + 2) / 4)      (undo update)
  x[2n+1] = d[n] + floor((x[2n] + x[2n+2]) / 2)        (undo predict)
```

The transform is applied first to rows, then to columns, producing four subbands (LL, LH, HL, HH) at each decomposition level. The LL subband is recursively decomposed for multi-level transforms.

### EBCOT Block Coding

Each code-block (default 64x64) in each subband is independently coded using three bit-plane coding passes:

1. **Significance Propagation** -- Code bits of samples that have at least one significant neighbor
2. **Magnitude Refinement** -- Refine previously significant samples
3. **Cleanup** -- Code remaining samples using the MQ arithmetic coder

### MQ Arithmetic Coder

The MQ coder is a binary adaptive arithmetic coder specified in ITU-T T.800 Annex C. It maintains per-context probability estimates that adapt to the data being coded, providing near-optimal compression for the binary decisions in EBCOT.

## JPEG 2000 Codestream Format

```
SOC  - Start of Codestream (0xFF4F)
SIZ  - Image and Tile Size (0xFF51)
       Image dimensions, tile dimensions, component count, precisions
COD  - Coding Style Default (0xFF52)
       Progression order, decomposition levels, code-block size, transform
QCD  - Quantization Default (0xFF5C)
       Quantization style, step sizes per subband
SOT  - Start of Tile-part (0xFF90)
       Tile index, tile-part length
SOD  - Start of Data (0xFF93)
[tile-part coded data: packets containing EBCOT code-block bitstreams]
EOC  - End of Codestream (0xFFD9)
```

Multiple SOT/SOD pairs may appear for multi-tile images. Each tile-part
contains packet data organized by progression order.

## Public Types and Functions

### `codestream.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `encode` | `fn(Allocator, []const u16, u32, u32, *const Jpeg2kOptions) CodecError![]u8` | Encode 16-bit pixels to JPEG 2000 codestream |
| `decode` | `fn(Allocator, []const u8, u32, u32) CodecError!struct{[]u16, u32, u32}` | Decode JPEG 2000 codestream to 16-bit pixels |
| `Jpeg2kOptions` | `struct` | Encoding options (tile size, code-block size, decomposition levels) |
| `CodecError` | `error` | `InvalidData`, `DimensionMismatch`, `OutOfMemory`, `EndOfStream`, `Unsupported` |

### `Jpeg2kOptions` Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `tile_width` | `u32` | `0` | Tile width (0 = single tile, whole image) |
| `tile_height` | `u32` | `0` | Tile height (0 = single tile, whole image) |
| `cb_width_exp` | `u8` | `6` | Code-block width exponent (2^6 = 64) |
| `cb_height_exp` | `u8` | `6` | Code-block height exponent (2^6 = 64) |
| `num_decomp_levels` | `u8` | `5` | Number of DWT decomposition levels |

### `dwt.zig`

5/3 reversible discrete wavelet transform using the lifting scheme. Forward and inverse transforms operating on i32 coefficient arrays.

### `ebcot.zig`

EBCOT block coding (Tier-1 and Tier-2). Significance propagation, magnitude refinement, and cleanup passes using the MQ coder.

### `mq.zig`

MQ binary adaptive arithmetic coder as specified in ITU-T T.800 Annex C. Maintains per-context probability estimates with the standard state transition table.

### `markers.zig`

JPEG 2000 marker constants and segment structures (SIZ, COD, QCD, SOT, etc.).

### `tile.zig`

Tile-level encoding and decoding, including DWT application, subband partitioning, and code-block iteration.

### `bitstream.zig`

Byte-level I/O utilities for reading and writing the codestream.

### `rct.zig`

Reversible Color Transform (identity for single-component grayscale).

### Root (`jpeg2k`)

| Symbol | Type | Description |
|--------|------|-------------|
| `TRANSFER_SYNTAX_UID` | `[]const u8` | `"1.2.840.10008.1.2.4.90"` |
| `bitstream` | module | Byte-level I/O utilities |
| `mq` | module | MQ arithmetic coder |
| `rct` | module | Reversible Color Transform |
| `markers` | module | Marker constants and segment structures |
| `dwt` | module | 5/3 reversible DWT |
| `ebcot` | module | EBCOT block coding |
| `tile` | module | Tile-level encode/decode |
| `codestream` | module | Codestream reader/writer, public encode/decode API |

## Module Structure

```
jpeg2k/
  root.zig          Public API, TRANSFER_SYNTAX_UID constant, module re-exports
  codestream.zig    Codestream reader/writer, top-level encode/decode functions
  markers.zig       JPEG 2000 marker constants and segment structures
  bitstream.zig     Byte-level I/O utilities
  dwt.zig           5/3 reversible discrete wavelet transform (lifting scheme)
  tile.zig          Tile-level encoding and decoding
  rct.zig           Reversible Color Transform (identity for grayscale)
  mq.zig            MQ binary adaptive arithmetic coder
  ebcot.zig         EBCOT block coding (Tier-1 and Tier-2)
```

## Tests

Run the jpeg2k tests:

```sh
zig build test
```

The module includes 48 tests covering:

- DWT forward/inverse round-trips (1D and 2D, single and multi-level)
- MQ coder encode/decode round-trips (single bits, sequences, multiple contexts)
- MQ probability adaptation verification
- EBCOT coding pass correctness (significance, refinement, cleanup)
- Tile-level encode/decode round-trips
- Marker reading and writing (SIZ, COD, QCD, SOT)
- Full codestream encode/decode round-trips (small images, gradients, constant images)
- RCT forward/inverse identity
- Configurable decomposition levels and code-block sizes
- Edge cases (minimum size images, maximum pixel values, single-tile vs multi-tile)
- Error handling for malformed codestreams

## References

- ITU-T Rec. T.800 | ISO/IEC 15444-1 (JPEG 2000 Part-1 Core Coding)
- ITU-T Rec. T.800 Annex C (MQ Arithmetic Coder)
- D. Taubman and M. Marcellin, "JPEG2000: Image Compression Fundamentals,
  Standards and Practice", Kluwer Academic Publishers, 2002
- DICOM Transfer Syntax: `1.2.840.10008.1.2.4.90` (JPEG 2000 Lossless)
