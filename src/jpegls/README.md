# JPEG-LS Codec

Pure Zig implementation of JPEG-LS (ITU-T T.87 / ISO/IEC 14495-1) encoder and
decoder. Port of the Rust `pure_jpegls` 2.1.0 crate (`dicos.rs`); for the same
input and options the encoder emits byte-identical streams.

## Conformance scope

This module emits **conformant ITU-T T.87 streams**. Supported: LSE ID=1
presets (MAXVAL/T1/T2/T3/RESET) honored on decode, run mode, near-lossless,
sample precision `2..=16`, for:

- **Single-component** images (`Nf = 1`) — `encode` / `decode`, and
  `encodeImage` / `decodeImage`.
- **Multi-component planar** images (`ILV = 0`: a shared frame header, then one
  scan per component, e.g. RGB) — `encodeImage` / `decodeImage`.
  `decodeImage` accepts 1 or 3 components; `encodeImage` accepts the same counts.

Rejected: line- and sample-interleaved scans (`ILV = 1/2`), restart markers
inside a scan (`RSTn`), LSE mapping tables, and component subsampling
(`error.Unsupported`); a non-zero point transform or an impossible scan
component count (`error.InvalidData`). A `DRI` segment on its own is tolerated
and skipped. Interop is verified against third-party `.jls` fixtures when
present (see `testdata/interop/README.md`) and, opt-in, against CharLS decoding
our planar RGB output.

### Profiles

- `Profile.t87` (default) — ITU-T T.87 conformant output.
- `Profile.legacy_go` — reproduces the frozen 1.0.0 / Go-compatible bytes
  (T.81-style `0xFF00` stuffing, no run mode, uncapped Golomb); lossless only.

Near-lossless and explicit precision are set through `EncodeOptions` via
`encodeWithOptions`; `DecodeOptions` selects the decode profile.

## Features

- **Lossless and near-lossless** compression using the LOCO-I algorithm
- **Context-based adaptive prediction** with Median Edge Detection (MED)
- **Golomb-Rice entropy coding** with adaptive parameter selection
- **Run-length mode** for efficient coding of uniform regions
- **Grayscale and planar multi-component** (e.g. RGB, `ILV = 0`) images,
  precision `2..=16`
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.4.80`
- **Pure Zig**: no external codec dependencies; explicit allocators throughout

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.4.80` (JPEG-LS Lossless)

## Usage

The module is exposed by `build.zig` as `jpegls`.

### Encoding

Encoders write to any `*std.Io.Writer` (flushed on success); the allocator is
used only for line buffers.

```zig
const jpegls = @import("jpegls");

var pixels: [256]u16 = undefined;
for (&pixels, 0..) |*p, i| p.* = @intCast(i);

var out = std.Io.Writer.Allocating.init(allocator);
defer out.deinit();
try jpegls.encode(allocator, &pixels, 16, 16, &out.writer);
const compressed = out.written();
```

### Decoding

```zig
const decoded = try jpegls.decode(allocator, compressed, 16, 16);
defer allocator.free(decoded);
```

### Options and diagnostics

```zig
var diag: jpegls.Diagnostic = .{};
try jpegls.encodeWithOptions(allocator, &pixels, 16, 16, .{
    .near = 2,              // near-lossless bound
    .precision = 12,        // explicit precision (null = derive, at least 8)
    .profile = .t87,        // or .legacy_go
    .diagnostic = &diag,    // optional error detail
}, &out.writer);

const legacy = try jpegls.decodeWithOptions(allocator, old_bytes, w, h, .{ .profile = .legacy_go });
```

On error, `diag.message()` holds the same text the Rust `Display` impl
produces, and the structured fields (`name`/`value`/`allowed`,
`expected`/`actual`, `offset`, `marker`) mirror the Rust error variants'
payloads.

### Planar multi-component (e.g. RGB)

`encodeImage` / `decodeImage` take and return **component-planar** samples
(all of component 0, then component 1, ...). `decodeImage` reads the geometry
from the codestream and returns it with the frame metadata.

`decodeImage` limits the output sample buffer to 64 MiB by default. Use
`decodeImageWithOptions` with `.{ .max_decoded_bytes = n }` to select a
different budget; every component counts toward this limit, and it is checked
before allocating.

```zig
var planar: [3 * 256]u16 = undefined; // R, G, B planes
for (&planar, 0..) |*p, i| p.* = @intCast(i % 256);

var rgb = std.Io.Writer.Allocating.init(allocator);
defer rgb.deinit();
try jpegls.encodeImage(allocator, &planar, 16, 16, 3, .{}, &rgb.writer);

var img = try jpegls.decodeImage(allocator, rgb.written());
defer img.deinit(allocator);
// img.width == 16, img.height == 16, img.components == 3
// std.mem.eql(u16, img.samples, &planar)
```

## Errors

`CodecError` mirrors the Rust `CodecError` variants:

| Error | Meaning |
|-------|---------|
| `Io` | the output writer failed |
| `InvalidData` | malformed or inconsistent codestream |
| `Unsupported` | valid feature not implemented (ILV 1/2, RSTn, mapping tables, subsampling) |
| `DimensionMismatch` | sample count does not match the geometry |
| `Truncated` | the scan ended (marker / end of data / corrupt code) before all samples decoded |
| `InvalidParameter` | caller or in-stream parameter out of range |
| `Marker` | a marker was hit inside the entropy-coded scan (internal; surfaces as `Truncated`/`Unsupported`) |
| `OutOfMemory` | allocator failure (line buffers / `decode` output) |

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

### Context Modeling

The encoder maintains 365 regular contexts plus 2 run-mode contexts, each
with adaptive A/B/C/N statistics that are updated after every sample. These
statistics drive both the bias cancellation and the Golomb-Rice parameter
selection, allowing the codec to adapt to local image characteristics.

## Supported Image Types

| Pixel Type | Precision | Components | Description |
|------------|-----------|------------|-------------|
| `u16` | `2..=16` bits | 1 (`Nf = 1`, `ILV = 0`) | single-component grayscale |
| `u16` | `2..=16` bits | 3 (`Nf = 3`, `ILV = 0`) | planar multi-component, e.g. RGB |

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
(SOS + scan repeat once per component for planar, ILV = 0, multi-component)
EOI   - End of Image (0xFFD9)
```

## Architecture

```
src/jpegls/
  root.zig       # Public API (encode*, decode*, Profile, options, TRANSFER_SYNTAX_UID)
  options.zig    # Profile, EncodeOptions, DecodeOptions, DecodeImageOptions
  error.zig      # CodecError + Diagnostic
  encode.zig     # Encoder: prediction + context + Golomb-Rice output
  decode.zig     # Decoder: marker parsing, LSE presets, scan reconstruction
  predictor.zig  # MED predictor and clamping
  context.zig    # Context modeling with adaptive A/B/C/N statistics
  run_mode.zig   # Run-length mode + shared sample arithmetic
  bitstream.zig  # T.87 bit I/O (single-bit stuffing, limited Golomb)
  legacy.zig     # Frozen 1.0.0 / Go-compatible coder (do not modify)
  tests/         # Ported Rust integration tests, Rust byte-parity, fuzz smoke
  testdata/      # Legacy fixtures, fuzz regressions, parity manifest, interop
```

## Testing

`zig build test` (or `zig test src/jpegls/root.zig`, since the module has no
imports). The suite ports every Rust unit and integration test, plus:

- `tests/parity.zig` — 849 encoder outputs (T.87 across precisions 2..=16 and
  NEAR 0/1/3, default `encode`, LegacyGo, 3-component `encodeImage`) must
  hash identically to the Rust crate's (`testdata/parity_manifest.txt`).
- `tests/fuzz_smoke.zig` — deterministic, bounded ports of the Rust
  `cargo fuzz` targets and their oracles.
- CharLS-dependent tests skip (`error.SkipZigTest`) unless fixtures are
  present / `DICOS_CHARLS_INTEROP=1` is set.

## References

- ITU-T Rec. T.87 | ISO/IEC 14495-1 (JPEG-LS baseline)
- M. Weinberger, G. Seroussi, G. Sapiro, "The LOCO-I Lossless Image Compression Algorithm:
  Principles and Standardization into JPEG-LS", IEEE Trans. Image Processing, 2000
- DICOM Transfer Syntax: `1.2.840.10008.1.2.4.80` (JPEG-LS Lossless)
