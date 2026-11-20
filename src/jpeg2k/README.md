# JPEG 2000 Codec

Pure Zig implementation of JPEG 2000 Part-1 (ITU-T T.800 / ISO/IEC 15444-1)
encoder and decoder. Port of the Rust `pure_jpeg2k` crate **2.1.0**; for the
same input and options the encoder emits byte-identical codestreams.

## Conformance scope (2.x)

This module emits **conformant ITU-T T.800 lossless codestreams** within an
explicit profile. Everything legal-but-unsupported is **rejected loudly** via a
validated support matrix rather than mis-encoded.

Supported: 1 tile, 1 component (**unsigned 16-bit**), reversible 5/3 DWT, LRCP
progression, 1 layer, `cb_style = 0`, zero grid origins, code-block exponents
`2..=10` (sum ≤ 12). Configurable decomposition levels and code-block size.

Rejected as `error.Unsupported`: multiple tiles or components, non-16-bit or
signed precision, MCT ≠ 0, progression ≠ LRCP, layers ≠ 1, `cb_style ≠ 0`,
transform ≠ 5/3, non-zero origins, `POC/COC/QCC/RGN/PPM/PPT/PLM/PLT`, `SOP/EPH`,
multiple tile-parts, and geometries needing more than one precinct per
resolution (a resolution wider or taller than 2^15).

Interop is verified against **OpenJPEG** (`opj_compress`/`opj_decompress`) in
both directions (see `tests/interop.zig`).

### Legacy (1.0.0 / Go) files

1.0.0 shipped a non-conformant raw-DWT format. Those files remain decodable via
`DecodeOptions{ .legacy = LegacyPolicy }`: `decode()` uses `.auto` (decode
standard, fall back to the legacy fingerprint: all-zero QCD exponents plus a
`[w u16, h u16, w·h i32]` payload), and `.standard_only` / `.legacy_only` are
available. Use `.standard_only` for untrusted, transfer-syntax-tagged data.

The legacy path is compiled in by default (Rust feature `legacy-decode`). An
application can drop it by declaring `pub const jpeg2k_legacy_decode = false;`
in its root source file; `.auto` then behaves as `.standard_only` and
`.legacy_only` returns `error.Unsupported`.

## Features

- **Lossless compression** using 5/3 reversible discrete wavelet transform (DWT)
- **EBCOT tier-1 block coding** with the MQ arithmetic coder
- **MQ arithmetic coder** (ITU-T T.800 Annex C, normative/OpenJPEG convention)
- **Tier-2 packets** with tag trees and `Lblock` length signalling (T.800 B.10)
- **Configurable decomposition levels** and code-block sizes
- **Single-component unsigned 16-bit** grayscale images
- **DICOS/DICOM compatible**: Transfer Syntax `1.2.840.10008.1.2.4.90`
- **Allocator-aware**: every allocation goes through a caller `std.mem.Allocator`
- **Pure Zig**: no external codec dependencies

## Transfer Syntax

DICOM UID: `1.2.840.10008.1.2.4.90` (JPEG 2000 Lossless)

## Usage

### Encoding

```zig
const std = @import("std");
const jpeg2k = @import("jpeg2k");

var pixels: [64]u16 = undefined;
for (&pixels, 0..) |*p, i| p.* = @intCast(i * 1000);

var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();
try jpeg2k.encode(gpa, &pixels, 8, 8, &out.writer); // default options
const compressed = out.written();
```

### Encoding with Custom Options

```zig
try jpeg2k.encodeWithOptions(gpa, &pixels, 8, 8, .{
    .tile_width = 0, // 0 = single tile (whole image); non-zero is Unsupported
    .tile_height = 0,
    .cb_width_exp = 6, // code-block width: 2^6 = 64
    .cb_height_exp = 6, // code-block height: 2^6 = 64
    .num_decomp_levels = 5, // DWT decomposition levels
}, &out.writer);
```

`encode*` writes the whole codestream to the `std.Io.Writer` but does not
flush it; flush buffered writers yourself.

### Decoding

```zig
var img = try jpeg2k.decode(gpa, compressed, 8, 8); // 0, 0 = trust SIZ
defer img.deinit(gpa);
// img.pixels: []u16 (row-major), img.width, img.height

var strict = try jpeg2k.decodeWithOptions(gpa, compressed, 0, 0, .{ .legacy = .standard_only });
defer strict.deinit(gpa);
```

### Errors

`jpeg2k.CodecError` mirrors the Rust `CodecError`:

| Zig | Rust | Meaning |
|-----|------|---------|
| `error.IoError` | `Io` | output writer failed, or a marker segment was truncated |
| `error.InvalidData` | `InvalidData` | malformed codestream or out-of-range option |
| `error.Unsupported` | `Unsupported` | legal T.800 outside the support matrix |
| `error.DimensionMismatch` | `DimensionMismatch` | pixel count / caller dims disagree |
| `error.OutOfMemory` | (abort) | allocation failure |

The set is a subset of `dicos.CodecError`, so it coerces without mapping. Zig
errors carry no payload; the Rust message for each return site is kept as a
comment next to it.

## Supported Image Types

| Pixel Type | Precision | Components | Description |
|------------|-----------|------------|-------------|
| `u16` | 16-bit unsigned | 1 | 16-bit grayscale (the only conformant profile) |

## Architecture

```
jpeg2k/
  root.zig        # Public API (encode, decode, Jpeg2kOptions, TRANSFER_SYNTAX_UID)
  error.zig       # CodecError
  codestream.zig  # Codestream reader/writer, support matrix, legacy policy
  markers.zig     # JPEG 2000 marker constants and segment structures
  bitstream.zig   # Byte-level (and bit-level) I/O utilities
  geometry.zig    # Resolution / band / precinct / code-block geometry (B.5-B.7)
  dwt.zig         # 5/3 reversible DWT (conformant + frozen legacy)
  tile.zig        # Tile-component pipeline (DWT <-> tier-1 <-> tier-2)
  ebcot.zig       # EBCOT tier-1 block coder (shared encode/decode state machine)
  mq.zig          # MQ binary adaptive arithmetic coder
  tagtree.zig     # Tag-tree codec (B.10.2)
  packet.zig      # Tier-2 packet headers (B.10)
  legacy.zig      # FROZEN 1.0.0 raw-DWT tile decoder
  rct.zig         # Reversible Color Transform (unused: single component)
  tests/          # mutation, legacy_fixtures, interop, parity
  testdata/       # legacy + OpenJPEG fixtures, Rust parity table
```

### Processing Pipeline

1. **DC level shift** -- unsigned 16-bit samples minus 2^15
2. **DWT** -- 5/3 reversible lifting (columns then rows), LL/HL/LH/HH per level
3. **Quantization** -- none (reversible); QCD carries `eps_b = 16 + log2(gain)`, `G = 2`
4. **EBCOT Tier-1** -- each code-block coded with SPP / MRP / cleanup passes via MQ
5. **EBCOT Tier-2** -- one LRCP packet per resolution (tag trees, pass counts, lengths)
6. **Codestream** -- markers and a single tile-part

## JPEG 2000 Codestream Format

```
SOC  - Start of Codestream (0xFF4F)
SIZ  - Image and Tile Size (0xFF51)
COD  - Coding Style Default (0xFF52)
QCD  - Quantization Default (0xFF5C)
SOT  - Start of Tile-part (0xFF90)
SOD  - Start of Data (0xFF93; legacy files use 0xFFD3)
[tile-part data: LRCP packets]
EOC  - End of Codestream (0xFFD9)
```

## Testing

```sh
zig build test                        # all modules (Debug)
zig test src/jpeg2k/root.zig          # this module only
zig test -OReleaseSafe src/jpeg2k/root.zig   # full 6125-case parity matrix
```

All Rust unit and integration tests are ported (`proptest` cases become
fixed-seed loops with the same case counts). `tests/parity.zig` replays a
digest table produced by the Rust crate (`testdata/parity_rust.txt`, one line
`w h nl cbw cbh kind len fnv1a64` per case over dims {1,2,5,13,64,130,200}²,
levels {0,1,2,5,8}, code-blocks {(2,2),(6,6),(4,5),(10,2),(3,7)}, 5 pixel
patterns); Debug runs every 5th case. The OpenJPEG tool tests return
`error.SkipZigTest` when `opj_compress` / `opj_decompress` are not found.

## Resource limits

Decoding caps `Xsiz·Ysiz` at 2^28 samples (as the Rust crate). A *valid*
all-zero image compresses to a few bytes, so payload size cannot bound the
allocation: trusting SIZ (`width = height = 0`) on untrusted input can allocate
~1.5 GiB for a maximal image. Pass the expected dimensions, or pre-check SIZ,
when the input is hostile.

## References

- ITU-T Rec. T.800 | ISO/IEC 15444-1 (JPEG 2000 Part-1 Core Coding)
- ITU-T Rec. T.800 Annex C (MQ Arithmetic Coder)
- D. Taubman and M. Marcellin, "JPEG2000: Image Compression Fundamentals,
  Standards and Practice", Kluwer Academic Publishers, 2002
- DICOM Transfer Syntax: `1.2.840.10008.1.2.4.90` (JPEG 2000 Lossless)
