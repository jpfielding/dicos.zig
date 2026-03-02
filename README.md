# dicos.zig

A pure-Zig library and toolkit for working with **DICOS** (Digital Imaging and
Communication in Security) files. DICOS is the NEMA IIC 1 standard used by
security screening equipment (CT scanners, X-ray systems) to encode volumetric
and projection image data. It is closely related to DICOM but tailored for
aviation and checkpoint security workflows.

This project implements the NEMA IIC 1 v04-2023 specification and provides:

- A core parsing library for reading and writing DICOS datasets and pixel data.
- Four standalone lossless compression codecs (no DICOS dependency).
- A CLI tool (`dicosctl`) for inspecting files from the terminal.
- A GPU-accelerated volume viewer (`zoxel`) with 3D ray-casting and 2D slice
  display.

Ported from [dicos.rs](../dicos.rs). Pure Zig -- no C dependencies.

## Project Components

### dicos -- Core Library

The `dicos` module parses DICOS/DICOM binary files into an in-memory `Dataset`
of typed elements. It handles explicit and implicit VR transfer syntaxes,
encapsulated pixel data, and multi-frame volumes. Codec modules are wired in
through the codec registry so downstream consumers only pay for what they use.

### Compression Codecs

Pure Zig implementations of the lossless image compression formats used by
DICOS and DICOM. Each codec is a standalone module with **zero dependency on
`dicos`**, so they can be used independently in any imaging pipeline.

| Module | Standard | Algorithm | Use Case |
|--------|----------|-----------|----------|
| **jpeg2k** | ITU-T T.800 | Wavelet (DWT + EBCOT) | Excellent compression ratio |
| **jpegli** | ITU-T T.81 Annex H | DPCM (Process 14 SV1) | Traditional lossless JPEG |
| **jpegls** | ISO/IEC 14495-1 / ITU-T T.87 | LOCO-I | Very efficient, near-entropy |
| **jpegrle** | DICOM Part 5 Section 8.1.1 | PackBits RLE | Simple run-length encoding |

### dicosctl -- CLI Inspector

A command-line tool for quick inspection of DICOS files.

### zoxel -- GPU Volume Viewer

A three-panel desktop application for visualizing 3D CT volumes and 2D slices
from DICOS files. Uses zig-gamedev ecosystem (zgpu for GPU ray-casting, zgui
for the UI).

```text
+------------+------------------------+------------------------+
| Sidebar    |   3D Volume View       |   2D Slice View        |
|            |   (GPU ray-caster)     |   (CPU rendered)       |
| Metadata   |                        |                        |
| Layers     +------------------------+------------------------+
| Threats    | Quality | Opacity      | Volume: [dropdown]     |
|            | Preset  | Bands        | View:   [dropdown]     |
|            | Lighting | WC/WW       | Composite [x]          |
|            |                        | W/L: __ W/W: __        |
|            |                        | Slice: [slider]        |
+------------+------------------------+------------------------+
```

- **Left sidebar** -- file open, metadata display, volume layer toggles,
  rendering quality, transfer function presets (Bands / Threat / Monochrome),
  material band sliders, and Phong lighting controls.
- **Center panel** -- GPU ray-cast 3D volume rendering with arcball camera
  (left-drag to rotate, scroll to zoom, axial/coronal/sagittal preset views).
- **Right panel** -- CPU-rendered 2D slice viewer with orientation selector,
  window/level controls, slice index slider, and MIP composite toggle.

Requires a GPU with Vulkan, Metal, or DX12 support.

## Project Structure

```
dicos.zig/
  build.zig             # Build system
  build.zig.zon         # Package manifest
  testdata/             # Public-safe synthetic fixtures
  src/
    dicos/              # Core DICOS library (11 files)
    jpegrle/            # RLE PackBits codec (standalone)
    jpegls/             # JPEG-LS codec (standalone)
    jpegli/             # JPEG Lossless codec (standalone)
    jpeg2k/             # JPEG 2000 codec (standalone)
    dicosctl/           # CLI inspector
    zoxel/              # GPU-accelerated volume viewer
```

## Dependency Graph

```
jpegrle ----+
jpegls  ----|  (standalone, zero dicos dependency)
jpegli  ----|
jpeg2k  ----+
                dicos --> uses codec modules via codec_registry
                  |       includes dicosctl executable
                  |
           zoxel --> dicos + zig-gamedev (zgpu, zgui, zglfw, zmath)
```

## Building

```sh
# Build the entire workspace
zig build

# Run all tests
zig build test

# Build and run dicosctl
zig build && ./zig-out/bin/dicosctl info testdata/bag_ct.dcs

# Build and run zoxel
zig build && ./zig-out/bin/zoxel testdata/bag_ct.dcs
```

## Usage

### dicosctl

```sh
# Print a human-readable summary of a DICOS file
./zig-out/bin/dicosctl info scan.dcs

# Example output:
#   File: scan.dcs
#   Elements: 42
#   Modality: CT
#   Dimensions: 512x512
#   Frames: 256
#   Bits Allocated: 16
#   Transfer Syntax: JPEG-LS Lossless (1.2.840.10008.1.2.4.80)
#   SOP Class: 1.2.840.10008.5.1.4.1.1.501.2.1
#   Manufacturer: L3 Technologies
#   Model: CX100

# Dump all metadata as JSON
./zig-out/bin/dicosctl dump scan.dcs
```

### zoxel

```sh
# Launch with an empty viewport
./zig-out/bin/zoxel

# Load a single DICOS file directly
./zig-out/bin/zoxel scan.dcs

# Load a directory of single-frame .dcs files as one volume
./zig-out/bin/zoxel /path/to/slices/
```

**Mouse controls:**

| Action | Effect |
|--------|--------|
| Left-drag in 3D view | Rotate volume (arcball) |
| Scroll wheel | Zoom in/out |

**Transfer function presets:**

| Preset | Description |
|--------|-------------|
| Default | Five-band material: Air (transparent), Organic (orange), Inorganic (green), Metal (blue), Dense (dark blue) |
| Threat | Red monochrome for threat highlighting |
| Mono | Grayscale density mapping |

## References

- [NEMA IIC 1 -- DICOS Standard](https://www.nema.org/standards/view/Digital-Imaging-and-Communications-in-Security)
- [DICOM Standard](https://www.dicomstandard.org/)
- [suyashkumar/dicom (Go reference)](https://github.com/suyashkumar/dicom)
- [Stratovan DICOS/DICOM format](https://www.stratovan.com/products/dicos)
- [JPEG-LS (ISO/IEC 14495-1)](https://en.wikipedia.org/wiki/Lossless_JPEG#JPEG-LS)
- [JPEG 2000 (ITU-T T.800)](https://en.wikipedia.org/wiki/JPEG_2000)
- [JPEG Lossless (ITU-T T.81 Annex H)](https://en.wikipedia.org/wiki/Lossless_JPEG)
- [DICOM RLE (Part 5 Section 8.1.1)](https://dicom.nema.org/medical/dicom/current/output/chtml/part05/sect_8.2.html)

## Acknowledgements

Built with [Claude Code](https://claude.ai/claude-code) by Anthropic.
