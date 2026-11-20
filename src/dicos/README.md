# dicos

A Zig library and CLI toolkit for working with **DICOS** (Digital Imaging and Communications in Security) files. Provides reading, writing, codec support, and inspection of DICOS/DICOM files used in baggage scanning, cargo inspection, and personnel screening equipment.

Implements the **NEMA IIC 1 v04-2023** standard.

## What is DICOS?

DICOS (Digital Imaging and Communications in Security) is a file format and communication standard for security screening equipment. It is based on the medical imaging standard DICOM (Digital Imaging and Communications in Medicine) but extended with security-specific modules for threat detection, automated decision-making, and object-of-interest classification.

DICOS is maintained by NEMA (National Electrical Manufacturers Association) and is used by TSA, customs agencies, and security screening vendors worldwide. Equipment such as X-ray baggage scanners, CT scanners, and personnel screening portals produce DICOS files.

Key differences from DICOM:

- **Group 4010** tags for Automated Threat Detection (ATD), threat ROIs, alarm decisions, and object-of-interest classification
- **Group 6100** tags for energy-discriminating detector data
- Security-specific SOP Classes (CT, DX, TDR, AIT)
- Screening workflow modules (itinerary, OOI owner, transport classification)

## File Structure

A DICOS file follows the DICOM Part 10 binary layout:

```
+--------------------------------------------+
|  128-byte preamble (unused, all zeros)      |
+--------------------------------------------+
|  4 bytes: "DICM" magic number              |
+--------------------------------------------+
|  File Meta Information (Group 0002)         |
|    Always Explicit VR Little Endian         |
|    Contains: Transfer Syntax UID,           |
|              SOP Class UID, etc.            |
+--------------------------------------------+
|  Dataset Elements (Groups 0008-7FDF)        |
|    Encoded per the Transfer Syntax          |
|    Patient, Study, Series, Equipment,       |
|    Image Pixel, CT/DX params, ATD data...   |
+--------------------------------------------+
|  Pixel Data (7FE0,0010)                     |
|    Native: raw u16 pixel values             |
|    Encapsulated: compressed frame fragments  |
+--------------------------------------------+
```

Each data element is encoded as:

```
+---------+---------+--------+---------+
|  Group  | Element |   VR   |  Value  |
| (2 bytes)| (2 bytes)| (2 bytes)| (variable)|
+---------+---------+--------+---------+
```

## Supported Modalities

DICOS defines four primary imaging modalities, each with its own SOP Class:

| Modality | Description | SOP Class UID |
|----------|-------------|---------------|
| **CT** | Computed Tomography | `1.2.840.10008.5.1.4.1.1.501.1` |
| **DX** | Digital X-Ray (Projection) | `1.2.840.10008.5.1.4.1.1.501.2.1` |
| **TDR** | Threat Detection Report | `1.2.840.10008.5.1.4.1.1.501.3` |
| **AIT** | Advanced Imaging Technology (Personnel) | `1.2.840.10008.5.1.4.1.1.501.4` |

The CT SOP Class UID is available as `dicos.uid.DICOS_CT_IMAGE_STORAGE`.

**CT** -- 3D volume data from baggage/cargo CT scanners. Multi-frame images with slice position and orientation metadata. Typical bit depth is 16-bit unsigned.

```zig
const std = @import("std");
const dicos = @import("dicos");

const file = try std.fs.cwd().openFile("ct_volume.dcs", .{});
defer file.close();
var buf: [64 * 1024]u8 = undefined;
var fr = file.reader(&buf);
var ds = try dicos.parse(allocator, &fr.interface);
defer ds.deinit();

std.debug.assert(std.mem.eql(u8, ds.modality(), "CT"));
std.debug.print("Slices: {d}\n", .{ds.numberOfFrames()});
std.debug.print("Dimensions: {?d}x{?d}\n", .{ ds.columns(), ds.rows() });
```

**DX** -- 2D projection images from X-ray line scanners. May include multi-energy views (low/high energy) for material discrimination.

```zig
var ds = try dicos.parseBytes(allocator, file_bytes);
defer ds.deinit();
std.debug.print("Image: {?d}x{?d} @ {?d} bits\n", .{ ds.columns(), ds.rows(), ds.bitsAllocated() });
```

**TDR** -- Threat Detection Reports containing automated threat detection results. No pixel data; instead contains sequences of threat ROIs, alarm decisions, and confidence scores.

```zig
var ds = try dicos.parseBytes(allocator, file_bytes);
defer ds.deinit();

if (ds.getString(dicos.tag.ALARM_DECISION)) |decision| {
    std.debug.print("Alarm: {s}\n", .{decision});
}
if (ds.get(dicos.tag.THREAT_ROI_SEQUENCE)) |elem| switch (elem.value) {
    .sequence => |items| std.debug.print("Threats detected: {d}\n", .{items.len}),
    else => {},
};
```

**AIT** -- Personnel screening images from full-body scanners (e.g., millimeter wave). Typically single-frame grayscale images.

## Transfer Syntaxes

The library supports all standard DICOM transfer syntaxes used in DICOS:

| Transfer Syntax | UID | Compressed | Codec Module |
|-----------------|-----|------------|--------------|
| Implicit VR Little Endian | `1.2.840.10008.1.2` | No | -- |
| Explicit VR Little Endian | `1.2.840.10008.1.2.1` | No | -- |
| Explicit VR Little Endian Extended | `1.2.840.10008.1.2.1.64` | No | -- |
| Explicit VR Big Endian (Retired) | `1.2.840.10008.1.2.2` | No | -- (rejected by the reader) |
| RLE Lossless | `1.2.840.10008.1.2.5` | Yes | `jpegrle` |
| JPEG Lossless (Process 14) | `1.2.840.10008.1.2.4.57` | Yes | `jpegli` |
| JPEG Lossless First-Order (Process 14, SV1) | `1.2.840.10008.1.2.4.70` | Yes | `jpegli` |
| JPEG-LS Lossless | `1.2.840.10008.1.2.4.80` | Yes | `jpegls` |
| JPEG-LS Near-Lossless | `1.2.840.10008.1.2.4.81` | Yes | `jpegls` |
| JPEG 2000 Lossless | `1.2.840.10008.1.2.4.90` | Yes | `jpeg2k` |
| JPEG 2000 | `1.2.840.10008.1.2.4.91` | Yes | `jpeg2k` |
| JPEG Baseline (Process 1) | `1.2.840.10008.1.2.4.50` | Yes | -- |
| JPEG Extended (Process 2 & 4) | `1.2.840.10008.1.2.4.51` | Yes | -- |
| Deflated Explicit VR Little Endian | `1.2.840.10008.1.2.1.99` | Yes | -- |

```zig
const transfer = dicos.transfer;

const ts = transfer.TransferSyntax.init(transfer.JPEG_LS_LOSSLESS);
std.debug.assert(ts.isEncapsulated());
std.debug.assert(ts.isJpegLs());
std.debug.assert(ts.isExplicitVr());
std.debug.print("{f}\n", .{ts}); // "JPEG-LS Lossless" (also ts.name(); ts.uid is the UID)
```

## Library Usage

Add `dicos` as a module import in your `build.zig`:

```zig
const dicos_mod = b.dependency("dicos_zig", .{}).module("dicos");
exe.root_module.addImport("dicos", dicos_mod);
```

All allocation is explicit: a `Dataset` owns its values and frees them with
the allocator it was created with (`ds.deinit()`).

### Reading a DICOS File

`parse` reads from any `*std.Io.Reader`; `parseBytes` is a convenience for
an in-memory file.

```zig
const file = try std.fs.cwd().openFile("scan.dcs", .{});
defer file.close();
var buf: [64 * 1024]u8 = undefined;
var fr = file.reader(&buf);
var ds = try dicos.parse(allocator, &fr.interface);
defer ds.deinit();

std.debug.print("Modality: {s}\n", .{ds.modality()});
std.debug.print("Dimensions: {?d}x{?d}\n", .{ ds.columns(), ds.rows() });
std.debug.print("Frames: {d}\n", .{ds.numberOfFrames()});
std.debug.print("Bits Allocated: {?d}\n", .{ds.bitsAllocated()});
std.debug.print("Transfer Syntax: {f}\n", .{ds.transferSyntax()});
```

`rows()`, `columns()`, `bitsAllocated()` and `pixelRepresentation()` return
`?u16` (no invented defaults); `numberOfFrames()` defaults to 1 as DICOM
defines.

### Limits, Warnings and Diagnostics

| Function | Behavior |
|----------|----------|
| `parse(a, r)` | 1 GB per-element limit; warnings logged via `std.log` (scope `.dicos`) |
| `parseWithLimit(a, r, max)` | custom per-element limit; warnings logged |
| `parseWithWarnings(a, r)` | returns `ParseResult{ dataset, warnings }` |
| `parseWithWarningsAndLimit(a, r, max)` | both |
| `reader.parseWithOptions(a, r, .{ .max_element_bytes, .diagnostic })` | the general form |

Zig errors carry no payload, so the data the Rust variants carry
(`Truncated { offset, context }`, `UnexpectedTag { expected, got, context }`,
...) is delivered through an optional `*dicos.Diagnostic`, which formats with
`{f}` to the same text as the Rust `Display`:

```zig
var diag: dicos.Diagnostic = .{};
var res = dicos.reader.parseWithOptions(allocator, &fr.interface, .{
    .max_element_bytes = 1 << 20,
    .diagnostic = &diag,
}) catch |e| {
    std.debug.print("{s}: {f}\n", .{ @errorName(e), diag }); // e.g. "Truncated: truncated at byte 133 (element tag)"
    return e;
};
defer res.deinit();
for (res.warnings) |w| std.debug.print("warning: {f}\n", .{w});
```

`ParseWarning` is `odd_pixel_data_length`, `pixel_count_mismatch` or
`bits_allocated_missing`. Hostile input is bounded: per-element limit, element
bodies read incrementally (a lying length allocates no more than ~2x the
bytes actually present before failing as `Truncated`), nesting capped at
`reader.MAX_NESTING_DEPTH` (64), Basic Offset Table reservation capped, and
overlapping BOT windows rejected (`InvalidFile`) rather than duplicating data.

### Accessing Data Elements

```zig
var ds = try dicos.parseBytes(allocator, file_bytes);
defer ds.deinit();

// String elements (first value when multi-valued)
if (ds.getString(dicos.tag.PATIENT_NAME)) |name| std.debug.print("Patient: {s}\n", .{name});
// All values of a multi-valued string ("A\B" -> ["A", "B"])
if (ds.getStrs(dicos.tag.IMAGE_TYPE)) |parts| for (parts) |p| std.debug.print("{s}\n", .{p});
// Numeric elements
if (ds.getU16(dicos.tag.ROWS)) |rows| std.debug.print("Rows: {d}\n", .{rows});
if (ds.getF64(dicos.tag.RESCALE_INTERCEPT)) |b| std.debug.print("Intercept: {d}\n", .{b});

// Iterate all elements in ascending tag order
for (ds.iter()) |elem| {
    std.debug.print("{f} {f}: {f}\n", .{ elem.tag, elem.vr, elem.value });
}
```

### Working with Pixel Data

`PixelData` is a tagged union: `.native` (decoded `u16` frames) or
`.encapsulated` (compressed frame items plus the Basic Offset Table). Raw
fixed-length pixel bytes are normalized to `.native` by the reader using
Rows, Columns, NumberOfFrames and BitsAllocated (8-bit samples are one per
byte).

```zig
if (ds.pixelData()) |pd| {
    std.debug.print("Frames: {d}, compressed: {}\n", .{ pd.numFrames(), pd.isCompressed() });
    if (pd.nativeFrame(0)) |frame0| std.debug.print("Frame 0 pixels: {d}\n", .{frame0.len});
    if (try pd.flatData(allocator)) |all| {
        defer allocator.free(all);
        std.debug.print("Total pixels: {d}\n", .{all.len});
    }
    if (pd.encapsulatedFrame(0)) |bitstream| std.debug.print("Item 0: {d} bytes\n", .{bitstream.len});
}
```

### Building and Writing Datasets

```zig
var ds = dicos.Dataset.init(allocator);
defer ds.deinit();
try ds.putString(dicos.tag.PATIENT_NAME, .PN, "DOE^JOHN");
try ds.putString(dicos.tag.MODALITY, .CS, "CT");
try ds.putU16(dicos.tag.ROWS, .US, 512);
try ds.putU16(dicos.tag.COLUMNS, .US, 512);
try ds.putU16(dicos.tag.BITS_ALLOCATED, .US, 16);

const out = try std.fs.cwd().createFile("output.dcs", .{});
defer out.close();
var wbuf: [64 * 1024]u8 = undefined;
var fw = out.writer(&wbuf);
const bytes_written = try dicos.write(&fw.interface, &ds);
try fw.interface.flush();
```

The writer always emits Explicit VR Little Endian with a recomputed
(0002,0000) group length, injects a Transfer Syntax UID when absent, rewrites
an Implicit VR Little Endian UID to Explicit (compressed UIDs are kept),
writes native pixels according to BitsAllocated (8-bit samples must fit in a
byte, odd lengths padded), and rebuilds the Basic Offset Table from the
items actually written (an empty BOT stays empty). It does not allocate;
`writer.writeToBytes(allocator, &ds, .{})` returns an owned buffer and
`writer.writePart10(w, &ds, .{ .diagnostic = &diag })` reports validation
details.

### Using Codecs for Compressed Pixel Data

```zig
const registry = dicos.codec_registry;

// Look up a codec by name or transfer syntax (by-value `?Codec`)
if (registry.codecByName("jpeg-ls")) |codec| {
    std.debug.print("Codec: {s} ({s})\n", .{ codec.name, codec.transfer_syntax_uid });
}

// Decode a compressed frame; the transfer syntax selects the codec and an
// unknown syntax is always error.UnsupportedTransferSyntax (no sniffing).
const pixels = try registry.decodeFrame(allocator, compressed, width, height, dicos.transfer.JPEG_2000_LOSSLESS, null);
defer allocator.free(pixels);

// Content sniffing, when no transfer syntax is available
const sniffed = try registry.decodeFrameSniffed(allocator, compressed, width, height, null);
defer allocator.free(sniffed);

// Encode through the Codec interface
var img = dicos.GrayImage(u16).fromData(allocator, 512, 512, pixel_slice).?; // takes ownership
defer img.deinit();
var aw: std.Io.Writer.Allocating = .init(allocator);
defer aw.deinit();
try registry.codecByName("rle").?.encode(&img, &aw.writer, allocator);
```

Registry encodes always use each codec's defaults so the advertised transfer
syntax UID is truthful for the bytes produced. Registry JPEG 2000 decodes use
`LegacyPolicy.standard_only` (transfer-syntax-tagged data is untrusted); decode
pre-2.0 archives with `jpeg2k.decode` directly. Backend failures surface as
`error.Backend` with the backend name and original error in a
`CodecDiagnostic` (`codec.decodeDiag` / `encodeDiag`).

## Build Options (Rust feature flags)

| Option | Default | Description |
|--------|---------|-------------|
| `-Ddicos-rle=<bool>` | true | RLE PackBits codec (`jpegrle`) in the registry |
| `-Ddicos-jpegls=<bool>` | true | JPEG-LS codec (`jpegls`) |
| `-Ddicos-jpegli=<bool>` | true | JPEG Lossless codec (`jpegli`) |
| `-Ddicos-jpeg2k=<bool>` | true | JPEG 2000 codec (`jpeg2k`) |

A disabled codec's module is never imported; its lookups return `null`.

## CLI Usage (dicosctl)

```sh
zig build -Doptimize=ReleaseSafe   # installs zig-out/bin/dicosctl
```

Output matches the Rust `dicosctl` byte for byte (JSON keys are sorted, as
serde_json's default map does).

### dump -- Serialize metadata as JSON

Pretty-printed by default; `-c`/`--compact` emits a single line.

```sh
$ dicosctl dump fish.dcs
{
  "BitsAllocated": {
    "Value": 16,
    "vr": "US"
  },
  "Columns": {
    "Value": 64,
    "vr": "US"
  },
  ...
  "PixelData": {
    "Encapsulated": false,
    "Frames": 48,
    "vr": "OW"
  },
  ...
}
```

Unnamed tags are keyed as `"(GGGG,EEEE)"`, raw binary values report their
`"Length"`, and sequences nest their items under `"Value"`. Pipe through `jq`:

```sh
dicosctl dump scan.dcs | jq '.Modality.Value'
dicosctl dump scan.dcs | jq 'keys'
```

### info -- Human-readable summary

```sh
$ dicosctl info fish.dcs
File: fish.dcs
Elements: 55
Modality: CT
Dimensions: 64x64
Frames: 48
Bits Allocated: 16
Transfer Syntax: Explicit VR Little Endian (1.2.840.10008.1.2.1)
SOP Class: 1.2.840.10008.5.1.4.1.1.501.1
SOP Instance: 1.2.826.0.1.3680043.8.498.999.1001
Patient Name: UNKNOWN^OBJECT
Series: Luggage with Fish Tank (Synthetic)
Manufacturer: GenericVendor
Model: DemoScanner
```

## Synthetic Fixture (gen-luggage-fishtank)

```sh
zig build gen-luggage-fishtank -- --size 64,64,48 --out testdata/synthetic/luggage_fishtank_ct.dcs
```

Options: `--out <path>`, `--size <x,y,z>` (default 256,256,160, each >= 32),
`--seed <u64>`, `--with-noise on|off`, `--include-threat-tags on|off`. For
the same arguments the output is byte-identical to the Rust example.

## Public Types and Functions

### Root Exports (`dicos`)

| Export | Kind |
|--------|------|
| `Dataset`, `Element`, `Value`, `PixelData` | core types (`types.zig`) |
| `Tag`, `Vr`, `TransferSyntax` | identifiers |
| `GrayImage(T)` | pixel buffer |
| `Codec`, `CodecError`, `CodecDiagnostic` | codec interface |
| `DicosError`, `Diagnostic` | file errors and their details |
| `ParseWarning`, `ParseResult` | non-fatal parse findings |
| `parse`, `parseWithLimit`, `parseWithWarnings`, `parseWithWarningsAndLimit`, `parseBytes` | reader entry points |
| `write` | writer entry point |

### Submodules

`err`, `tag`, `vr`, `transfer`, `uid`, `img`, `types`, `reader`, `writer`,
`codec`, `codec_registry`.

### Key `Dataset` Methods

| Method | Returns |
|--------|---------|
| `init(allocator)` / `deinit()` / `clone()` | lifecycle (deep copy) |
| `insert(elem)` | replaces and frees an existing element; always takes ownership |
| `get(tag)` / `getPtr(tag)` / `remove(tag)` / `contains(tag)` | element access (`remove` hands the element to the caller) |
| `len()` / `isEmpty()` / `iter()` / `tags()` | size and ordered iteration |
| `getString`, `getStrs`, `getU16`, `getU32`, `getI32`, `getF64` | typed accessors |
| `rows`, `columns`, `bitsAllocated`, `pixelRepresentation` | `?u16` |
| `numberOfFrames` | `u32`, default 1 |
| `modality`, `transferSyntax`, `isEncapsulated`, `pixelData` | convenience |
| `putString`, `putU16`, `putU32` | builders |
| `eql(other)`, `{f}` formatting | structural equality, Rust `Display` |

## Module Structure

```
src/
  dicos/
    root.zig               Module root, public re-exports
    tag.zig                Tag type, ~190 tag constants, name lookup
    vr.zig                 Vr enum (31 variants), encoding queries
    transfer.zig           TransferSyntax, 14 UID constants
    uid.zig                SOP Class UID constants
    types.zig              Dataset, Element, Value, PixelData
    reader.zig             Part 10 parser (implicit/explicit VR, sequences, encapsulated)
    reader/test_util.zig   Wire-format builders for tests
    reader/tests.zig       Reader tests
    writer.zig             Part 10 writer (explicit VR little endian, non-allocating)
    codec.zig              Codec vtable
    codec_registry.zig     Adapters, lookup, sniffing, decodeFrame
    img.zig                GrayImage(T)
    error.zig              CodecError, DicosError, Diagnostic, CodecDiagnostic
    tests/                 Round-trip property tests, bag_ct sample tests
    examples/gen_luggage_fishtank.zig
  dicosctl/main.zig        dicosctl (dump, info)
```

## DICOS-Specific Tags

All DICOS-specific tags are defined in the `tag` module. The primary DICOS groups are:

### Group 4010 -- ATD / Threat Detection

| Constant | Tag | Name |
|----------|-----|------|
| `ALARM_DECISION` | (4010,100A) | AlarmDecision |
| `OOI_TYPE` | (4010,1012) | OOIType |
| `NUMBER_OF_ALARM_OBJECTS` | (4010,1014) | NumberOfAlarmObjects |
| `ATD_ASSESSMENT_SEQUENCE` | (4010,1015) | ATDAssessmentSequence |
| `THREAT_CONFIDENCE_SCORE` | (4010,1016) | ThreatConfidenceScore |
| `ATD_ASSESSMENT_PROBABILITY` | (4010,1017) | ATDAssessmentProbability |
| `ATD_ABILITY` | (4010,1001) | ATDAbility |
| `POTENTIAL_THREAT_OBJECT_ID` | (4010,1006) | PotentialThreatObjectID |
| `THREAT_ROI_SEQUENCE` | (4010,1020) | ThreatROISequence |
| `THREAT_ROI_TYPE` | (4010,1009) | ThreatROIType |
| `BOUNDING_BOX_TOP_LEFT` | (4010,1023) | BoundingBoxTopLeft |
| `BOUNDING_BOX_BOTTOM_RIGHT` | (4010,1024) | BoundingBoxBottomRight |
| `BOUNDING_POLYGON` | (4010,101D) | BoundingPolygon |
| `THREAT_CATEGORY_DESCRIPTION` | (4010,1028) | ThreatCategoryDescription |
| `PTO_SEQUENCE` | (4010,1010) | PTOSequence |
| `PTO_REPRESENTATION_SEQUENCE` | (4010,1011) | PTORepresentationSequence |

### Group 4010 -- DX Energy Discrimination

| Constant | Tag | Name |
|----------|-----|------|
| `LOW_ENERGY_DETECTOR` | (4010,0001) | LowEnergyDetector |
| `HIGH_ENERGY_DETECTOR` | (4010,0002) | HighEnergyDetector |
| `DETECTOR_BIN_NUMBER` | (4010,0003) | DetectorBinNumber |
| `LOWER_ENERGY` | (4010,0005) | LowerEnergy |
| `ENERGY_RESOLUTION` | (4010,0006) | EnergyResolution |
| `HIGHER_ENERGY` | (4010,0007) | HigherEnergy |

### Group 4010 -- OOI / Itinerary

| Constant | Tag | Name |
|----------|-----|------|
| `OOI_OWNER_ID` | (4010,1030) | OOIOwnerID |
| `OOI_OWNER_NAME` | (4010,1031) | OOIOwnerName |
| `OOI_ID` | (4010,1034) | OOIID |
| `OOI_LABEL` | (4010,1037) | OOILabel |
| `FLIGHT_NUMBER` | (4010,1040) | FlightNumber |
| `DEPARTURE_AIRPORT` | (4010,1043) | DepartureAirport |
| `ARRIVAL_AIRPORT` | (4010,1044) | ArrivalAirport |
| `CARRIER_NAME` | (4010,1045) | CarrierName |

### Group 6100 -- Series Energy

| Constant | Tag | Name |
|----------|-----|------|
| `SERIES_ENERGY` | (6100,0030) | SeriesEnergy |
| `SERIES_ENERGY_DESCRIPTION` | (6100,0031) | SeriesEnergyDescription |


## Compression Support

All codec modules provide lossless 16-bit grayscale encode/decode through the `Codec` interface:

| Codec | Standard | Module | Build option | Transfer Syntax UID |
|-------|----------|--------|--------------|---------------------|
| RLE PackBits | DICOM Part 5 Annex G | `jpegrle` | `dicos-rle` | `1.2.840.10008.1.2.5` |
| JPEG-LS | ISO/IEC 14495-1 (LOCO-I) | `jpegls` | `dicos-jpegls` | `1.2.840.10008.1.2.4.80` |
| JPEG Lossless | ITU-T T.81 Annex H (DPCM) | `jpegli` | `dicos-jpegli` | `1.2.840.10008.1.2.4.70` |
| JPEG 2000 | ITU-T T.800 (Wavelet) | `jpeg2k` | `dicos-jpeg2k` | `1.2.840.10008.1.2.4.90` |

The codec registry provides three ways to resolve a codec:

1. **By name** -- `codec_registry.codecByName("jpeg-ls")` (case-insensitive aliases)
2. **By transfer syntax UID** -- `codec_registry.codecForTransferSyntax(uid)`
3. **By signature** -- `codec_registry.sniffCodec(data)`: JPEG 2000 codestream `FF 4F`, or a bounded JPEG marker walk to the first SOF (`FF F7` JPEG-LS, `FF C3` JPEG Lossless). RLE and JP2 boxes are never sniffed.

## Value Representations

All 31 standard DICOM Value Representations are supported:

| Category | VRs |
|----------|-----|
| **String** | AE, AS, CS, DA, DS, DT, IS, LO, LT, PN, SH, ST, TM, UC, UI, UR, UT |
| **Binary** | AT, FL, FD, OB, OD, OF, OL, OW, SL, SS, UL, UN, US |
| **Sequence** | SQ |

Long-form VRs (4-byte length field): OB, OD, OF, OL, OW, SQ, UC, UN, UR, UT.


## Tests

```sh
zig build test              # everything (dicos, codecs, dicosctl, example)
zig build test-dicos        # dicos only
zig build test-dicos-tools  # dicosctl JSON formatting + example round-trip
```

The dicos tests port every Rust unit test (tag, vr, transfer, img, types,
reader, writer, codec registry), the property tests of
`tests/roundtrip_prop.rs` (deterministic `std.Random` seeds, 100 cases per
property), and `tests/synthetic_luggage_example.rs`. All use
`std.testing.allocator` for leak detection. Tests that read
`testdata/bag_ct.dcs` skip when it is absent or an un-fetched Git LFS pointer;
`DICOS_TESTDATA=<dir>` points them elsewhere.

## References

- [NEMA DICOS Standard](https://www.nema.org/standards/view/Digital-Imaging-and-Communications-in-Security) -- NEMA IIC 1 v04-2023
- [DICOM Standard](https://www.dicomstandard.org/) -- PS3.5 Data Structures and Encoding, PS3.10 Media Storage
- [DICOS/DICOM Format Overview (Stratovan)](https://www.stratovan.com/products/dicos)
- [JPEG-LS (Wikipedia)](https://en.wikipedia.org/wiki/Lossless_JPEG#JPEG-LS) -- ISO/IEC 14495-1 LOCO-I algorithm
- [JPEG 2000 (Wikipedia)](https://en.wikipedia.org/wiki/JPEG_2000) -- ITU-T T.800 wavelet compression
- [DICOM RLE Encoding](https://dicom.nema.org/medical/dicom/current/output/chtml/part05/sect_g.2.html) -- Part 5 Annex G PackBits
- [TSA DICOS Resources](https://www.tsa.gov/for-industry/dicos) -- TSA DICOS program information

## License

Licensed under MIT OR Apache-2.0.
