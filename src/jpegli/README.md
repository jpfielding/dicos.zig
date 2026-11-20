# JPEG Lossless Codec (jpegli)

Pure Zig implementation of JPEG Lossless (ITU-T T.81 Annex H) encoder and
decoder. Port of the Rust `jpegli` crate (2.1.0).

## Conformance scope (2.1.0)

This module emits **conformant ITU-T T.81 Process 14 SV1** (non-hierarchical,
first-order) lossless streams for **single-component** images. Supported:
predictors **1-7**, **point transform** (reduced-domain coding), and
**restart intervals** (row-aligned per H.1.1 -- the DRI value is a multiple of
the image width). Precision `2..=16`. Interop is verified against
**libjpeg-turbo >= 3.0** (`cjpeg -lossless` / `djpeg`).

Encoder tuning is via `EncodeOptions{ .predictor, .point_transform,
.restart_interval_rows, .precision }` through `encodeWithOptions`; plain
`encode` uses predictor 1, no point transform, no restarts, 16-bit. Note: the
`.70` transfer syntax specifically means predictor 1, so registry encodes pin
defaults to keep the emitted UID truthful.

## Features

- **Lossless compression** using differential pulse code modulation (DPCM)
- **Predictors 1-7** supported for optimal compression
- **Point transform** and **row-aligned restart intervals**
- **Huffman entropy coding** for prediction residuals
- **Single-component** grayscale images, precision `2..=16`
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.4.70`
- **Pure Zig**: No external codec dependencies, explicit allocators, no hidden allocation
- **Hardened decoder**: bounded allocation (declared size is checked against the input
  size and a 2^28-pixel cap before allocating), strict truncation detection, strict
  restart-marker sequencing

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.4.70` (JPEG Lossless, Non-Hierarchical, Process 14 SV1)

## Usage

Import the module (wired in `build.zig` as `jpegli`):

```zig
const jpegli = @import("jpegli");
```

### Encoding

```zig
// Encode with predictor 1 (left neighbor); caller owns the returned bytes.
const pixels = [_]u16{ 100, 200, 300, 400 };
const compressed = try jpegli.encode(allocator, &pixels, 2, 2);
defer allocator.free(compressed);

// Explicit options
const opts = jpegli.EncodeOptions{ .predictor = 4, .restart_interval_rows = 2, .precision = 12 };
const with_opts = try jpegli.encodeWithOptions(allocator, &pixels, 2, 2, opts);
defer allocator.free(with_opts);
```

### Decoding

```zig
const res = try jpegli.decode(allocator, compressed, 2, 2);
defer res.deinit(allocator);
// res.pixels, res.width, res.height
```

### Errors

`jpegli.CodecError` mirrors the Rust `CodecError`: `Io`, `InvalidData`,
`Unsupported`, `DimensionMismatch`, `Truncated`, `InvalidParameter`,
`OutOfMemory`. Zig error sets cannot carry payloads, so the details the Rust
variants carry (parameter name/value/allowed range, truncation offset and
context, expected/actual pixel counts, message) are reported through an
optional `jpegli.Diagnostics` out-parameter via `decodeDiag` /
`encodeWithOptionsDiag`.

```zig
var diag = jpegli.Diagnostics{};
_ = jpegli.encodeWithOptionsDiag(allocator, &pixels, 2, 2, .{ .predictor = 9 }, &diag) catch |e| {
    // e == error.InvalidParameter; diag.parameter == "predictor"
};
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
| 5 | Ra + ((Rb - Rc) >> 1) | Weighted left + half vertical gradient |
| 6 | Rb + ((Ra - Rc) >> 1) | Weighted above + half horizontal gradient |
| 7 | (Ra + Rb) >> 1 | Average of left and above |

The halving in predictors 5-7 is an arithmetic shift (floor), as T.81 H.1.2.1
and libjpeg-turbo define it. (The Rust 2.1.0 crate uses truncating `/ 2` for
predictors 5 and 6, which differs for negative odd differences and makes its
psv 5/6 streams incompatible with libjpeg-turbo; see the parity note below.)

The default encoding uses predictor 1 (left neighbor). For the first row,
prediction uses the previous sample in scan order. For the first pixel,
prediction uses 2^(precision-1) as the initial value. After a restart marker,
prediction restarts exactly as at the start of the scan.

## Supported Image Types

| Pixel Type | Precision | Components | Description |
|------------|-----------|------------|-------------|
| `u16` | `2..=16` bits | 1 (`Nf = 1`) | single-component grayscale |

## JPEG Lossless Stream Format

```
SOI  - Start of Image (0xFFD8)
APP0 - JFIF header (encoder only; decoder skips APPn)
SOF3 - Start of Frame, Lossless Huffman (0xFFC3)
       Precision, height, width, components
DHT  - Define Huffman Table (0xFFC4)
       Table class, table ID, code counts, code values
DRI  - Define Restart Interval (0xFFDD), only with restart_interval_rows > 0
SOS  - Start of Scan (0xFFDA)
       Component selector, predictor selection, point transform
[entropy-coded DPCM differences, RSTn between restart intervals]
EOI  - End of Image (0xFFD9)
```

The SOF3 marker (0xFFC3) distinguishes JPEG Lossless from other JPEG modes.
The entropy-coded segment contains Huffman-coded prediction residuals, where
each residual is the difference between the actual pixel value and the
predicted value from the selected predictor. Category 16 (the modular
difference 32768) carries no appended bits (Table H.2).

## Architecture

```
jpegli/
  root.zig            # Public API (encode, encodeWithOptions, decode, TRANSFER_SYNTAX_UID)
  encode.zig          # Encoder: option validation, markers, DPCM + Huffman output
  decode.zig          # Decoder: marker parsing, validation, DPCM reconstruction
  huffman.zig         # Huffman table construction and coding
  scan.zig            # Scan-level encode/decode, bit I/O, predictors, restarts
  error.zig           # CodecError set and Diagnostics
  mutation_test.zig   # Corruption robustness tests (truncation, bit flips, RST order)
  interop_test.zig    # libjpeg-turbo interop (embedded fixtures + live cjpeg/djpeg)
  testdata/           # cjpeg-produced fixtures and source PGMs (see testdata/README.md)
```

## Testing

`zig build test` runs the unit, mutation and interop tests. Interop tests that
shell out to `cjpeg`/`djpeg` (searched in `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin`; libjpeg-turbo >= 3.0 for lossless) skip with `error.SkipZigTest`
when the tools are absent or too old. The fixture decode test always runs.

## Rust parity

For identical input and options the encoder emits byte-identical output to the
Rust `jpegli` 2.1.0 crate for predictors 1-4 and 7 (all precisions, point
transforms and restart intervals tested), and for predictors 5 and 6 whenever
the halved difference is non-negative or even. Predictors 5/6 with a negative
odd `Rb - Rc` / `Ra - Rc` differ because of the Rust truncating division noted
above; with Rust changed to `>> 1` the outputs are byte-identical.

## References

- ITU-T Rec. T.81 | ISO/IEC 10918-1 (JPEG), Annex H (Lossless Mode)
- DICOM Transfer Syntax: `1.2.840.10008.1.2.4.70` (JPEG Lossless, First-Order Prediction, Process 14 SV1)
