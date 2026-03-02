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

**CT** -- 3D volume data from baggage/cargo CT scanners. Multi-frame images with slice position and orientation metadata. Typical bit depth is 16-bit unsigned.

```zig
const dicos = @import("dicos");

const file = try std.fs.cwd().openFile("ct_volume.dcs", .{});
defer file.close();
var buf_reader = std.io.bufferedReader(file.reader());
var ds = try dicos.reader.parse(allocator, buf_reader.reader());
defer ds.deinit();

std.debug.assert(std.mem.eql(u8, ds.modality(), "CT"));
std.debug.print("Slices: {}\n", .{ds.numberOfFrames()});
std.debug.print("Dimensions: {}x{}\n", .{ ds.columns(), ds.rows() });
```

**DX** -- 2D projection images from X-ray line scanners. May include multi-energy views (low/high energy) for material discrimination.

```zig
var ds = try dicos.reader.parse(allocator, buf_reader.reader());
defer ds.deinit();

std.debug.print("Image: {}x{} @ {} bits\n", .{
    ds.columns(), ds.rows(), ds.bitsAllocated(),
});
```

**TDR** -- Threat Detection Reports containing automated threat detection results. No pixel data; instead contains sequences of threat ROIs, alarm decisions, and confidence scores.

```zig
var ds = try dicos.reader.parse(allocator, buf_reader.reader());
defer ds.deinit();

if (ds.getString(dicos.tag.ALARM_DECISION)) |decision| {
    std.debug.print("Alarm: {s}\n", .{decision});
}
if (ds.get(dicos.tag.THREAT_ROI_SEQUENCE)) |elem| {
    if (elem.value == .sequence) {
        std.debug.print("Threats detected: {}\n", .{elem.value.sequence.len});
    }
}
```

**AIT** -- Personnel screening images from full-body scanners (e.g., millimeter wave). Typically single-frame grayscale images.

## Transfer Syntaxes

The library supports all standard DICOM transfer syntaxes used in DICOS:

| Transfer Syntax | UID | Compressed | Codec Module |
|-----------------|-----|------------|--------------|
| Implicit VR Little Endian | `1.2.840.10008.1.2` | No | -- |
| Explicit VR Little Endian | `1.2.840.10008.1.2.1` | No | -- |
| Explicit VR Little Endian Extended | `1.2.840.10008.1.2.1.64` | No | -- |
| Explicit VR Big Endian (Retired) | `1.2.840.10008.1.2.2` | No | -- |
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
const dicos = @import("dicos");

const ts = dicos.TransferSyntax.init(dicos.transfer.JPEG_LS_LOSSLESS);
std.debug.assert(ts.isEncapsulated());
std.debug.assert(ts.isJpegLs());
std.debug.assert(ts.isExplicitVr());
std.debug.print("{s}\n", .{ts.getName()}); // "JPEG-LS Lossless"
```

## Library Usage

Add `dicos` as a module dependency in your `build.zig`:

```zig
const dicos_mod = b.addModule("dicos", .{
    .root_source_file = b.path("path/to/dicos/src/dicos/root.zig"),
});
your_module.addImport("dicos", dicos_mod);
```

### Reading a DICOS File

```zig
const std = @import("std");
const dicos = @import("dicos");

const file = try std.fs.cwd().openFile("scan.dcs", .{});
defer file.close();
var buf_reader = std.io.bufferedReader(file.reader());
var ds = try dicos.reader.parse(allocator, buf_reader.reader());
defer ds.deinit();

std.debug.print("Modality: {s}\n", .{ds.modality()});
std.debug.print("Dimensions: {}x{}\n", .{ ds.columns(), ds.rows() });
std.debug.print("Frames: {}\n", .{ds.numberOfFrames()});
std.debug.print("Bits Allocated: {}\n", .{ds.bitsAllocated()});
std.debug.print("Transfer Syntax: {s}\n", .{ds.transferSyntax().getName()});
```

### Parsing from a Byte Slice

```zig
const data: []const u8 = // ... DICOS file bytes
var ds = try dicos.reader.parseBytes(allocator, data);
defer ds.deinit();
```

### Accessing Data Elements

```zig
const dicos = @import("dicos");

var ds = try dicos.reader.parse(allocator, buf_reader.reader());
defer ds.deinit();

// String elements
if (ds.getString(dicos.tag.PATIENT_NAME)) |name| {
    std.debug.print("Patient: {s}\n", .{name});
}
if (ds.getString(dicos.tag.MANUFACTURER)) |manufacturer| {
    std.debug.print("Manufacturer: {s}\n", .{manufacturer});
}

// Numeric elements
if (ds.getU16(dicos.tag.ROWS)) |rows| {
    std.debug.print("Rows: {}\n", .{rows});
}

// Iterate all elements
var iter = ds.elements.iterator();
while (iter.next()) |entry| {
    const elem = entry.value_ptr;
    std.debug.print("{} {s}\n", .{ elem.tag_val, elem.vr.asBytes() });
}
```

### Working with Pixel Data

```zig
const dicos = @import("dicos");

var ds = try dicos.reader.parse(allocator, buf_reader.reader());
defer ds.deinit();

if (ds.pixelData()) |pd| {
    std.debug.print("Frames: {}\n", .{pd.numFrames()});
    std.debug.print("Compressed: {}\n", .{pd.isCompressed()});

    if (!pd.isCompressed()) {
        // Native pixel data -- access raw u16 values
        if (try pd.flatData(allocator)) |pixels| {
            defer allocator.free(pixels);
            std.debug.print("Total pixels: {}\n", .{pixels.len});
        }
    }
}
```

### Building and Writing Datasets

```zig
const dicos = @import("dicos");

var ds = dicos.Dataset.init(allocator);
defer ds.deinit();

try ds.putString(dicos.tag.PATIENT_NAME, .PN, "DOE^JOHN");
try ds.putString(dicos.tag.MODALITY, .CS, "CT");
try ds.putU16(dicos.tag.ROWS, .US, 512);
try ds.putU16(dicos.tag.COLUMNS, .US, 512);
try ds.putU16(dicos.tag.BITS_ALLOCATED, .US, 16);

const out_file = try std.fs.cwd().createFile("output.dcs", .{});
defer out_file.close();
const bytes_written = try dicos.writer.write(allocator, &ds, out_file.writer());
std.debug.print("Wrote {} bytes\n", .{bytes_written});
```

### Using Codecs for Compressed Pixel Data

```zig
const dicos = @import("dicos");

// Look up a codec by name
if (dicos.codec_registry.codecByName("jpeg-ls")) |codec| {
    std.debug.print("Codec: {s}\n", .{codec.getName()});
    std.debug.print("TS UID: {s}\n", .{codec.getTransferSyntaxUid()});
}

// Look up a codec by transfer syntax UID
if (dicos.codec_registry.codecForTransferSyntax(dicos.transfer.RLE_LOSSLESS)) |codec| {
    std.debug.print("Found codec: {s}\n", .{codec.getName()});
}

// Sniff a codec from compressed data magic bytes
if (dicos.codec_registry.sniffCodec(compressed_data)) |codec| {
    std.debug.print("Detected: {s}\n", .{codec.getName()});
}

// Decode a compressed frame
var decoded = try codec.decode(compressed_data, width, height, allocator);
defer decoded.deinit();

// Encode a frame
var buf = std.ArrayList(u8).init(allocator);
defer buf.deinit();
try codec.encode(pixel_data, width, height, buf.writer().any());
```

## CLI Usage (dicosctl)

Build the CLI:

```sh
zig build
```

### dump -- Serialize metadata as JSON

```sh
$ dicosctl dump scan.dcs
{
  "FileMetaInformationGroupLength": {"vr": "UL", "Value": 186},
  "TransferSyntaxUID": {"vr": "UI", "Value": "1.2.840.10008.1.2.4.80"},
  "Modality": {"vr": "CS", "Value": "CT"},
  "Rows": {"vr": "US", "Value": 512},
  "Columns": {"vr": "US", "Value": 512},
  "BitsAllocated": {"vr": "US", "Value": 16},
  "PixelData": {"vr": "OW", "Encapsulated": true, "Frames": 300}
}
```

### info -- Human-readable summary

```sh
$ dicosctl info scan.dcs
File: scan.dcs
Elements: 47
Modality: CT
Dimensions: 512x512
Frames: 300
Bits Allocated: 16
Transfer Syntax: JPEG-LS Lossless (1.2.840.10008.1.2.4.80)
SOP Class: 1.2.840.10008.5.1.4.1.1.501.1
SOP Instance: 1.2.276.0.7230010.3.1.4.1234567890.1234.1234567890
Manufacturer: Smiths Detection
Model: HI-SCAN 10080 XCT
```

## Public Types and Functions

### Root Exports (`dicos`)

| Symbol | Type | Description |
|--------|------|-------------|
| `Tag` | `packed struct(u32)` | DICOM tag with group and element fields |
| `Vr` | `enum(u16)` | Value Representation (31 variants) |
| `TransferSyntax` | `struct` | Transfer Syntax identified by UID string |
| `Dataset` | `struct` | Ordered collection of DICOM data elements |
| `Element` | `struct` | Single data element (tag + VR + value) |
| `Value` | `union(enum)` | Typed value stored in a data element |
| `PixelData` | `struct` | Native or encapsulated pixel data |
| `Frame` | `struct` | Single frame of pixel data |
| `GrayImage` | `fn(T) type` | Comptime-generic row-major pixel buffer |
| `Codec` | `struct` | Vtable interface for lossless image codecs |
| `CodecError` | `error` | Codec operation error set |
| `DicosError` | `error` | DICOS file operation error set |

### Submodules

| Module | Description |
|--------|-------------|
| `tag` | Tag constants for standard DICOM/DICOS data elements (groups 0002-7FE0, 4010, 6100) |
| `vr` | Value Representation type definitions (all 31 VRs) with encoding property queries |
| `transfer` | Transfer Syntax UID constants and `TransferSyntax` type with property queries |
| `types` | Core types: `Dataset`, `Element`, `Value`, `PixelData`, `Frame` |
| `reader` | DICOS Part 10 file parser (preamble, DICM magic, meta info, dataset) |
| `writer` | DICOS Part 10 file writer (Explicit VR Little Endian) |
| `codec` | `Codec` vtable interface for lossless 16-bit grayscale image compression |
| `codec_registry` | Codec lookup by name, transfer syntax UID, or magic-byte sniffing |
| `img` | `GrayImage(T)` comptime-generic row-major pixel buffer type |
| `err` | `CodecError` and `DicosError` error sets |

### Key `Dataset` Methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `init` | `fn(Allocator) Dataset` | Create an empty dataset |
| `deinit` | `fn(*Dataset) void` | Free all owned memory |
| `insert` | `fn(*Dataset, Element) !void` | Insert or replace an element |
| `get` | `fn(*const Dataset, Tag) ?*const Element` | Look up element by tag |
| `remove` | `fn(*Dataset, Tag) bool` | Remove element by tag |
| `getString` | `fn(*const Dataset, Tag) ?[]const u8` | Get string value |
| `getU16` | `fn(*const Dataset, Tag) ?u16` | Get u16 value |
| `getU32` | `fn(*const Dataset, Tag) ?u32` | Get u32 value |
| `getI32` | `fn(*const Dataset, Tag) ?i32` | Get i32 value |
| `getF64` | `fn(*const Dataset, Tag) ?f64` | Get f64 value |
| `putString` | `fn(*Dataset, Tag, Vr, []const u8) !void` | Insert string element |
| `putU16` | `fn(*Dataset, Tag, Vr, u16) !void` | Insert u16 element |
| `putU32` | `fn(*Dataset, Tag, Vr, u32) !void` | Insert u32 element |
| `rows` | `fn(*const Dataset) u16` | Rows (0028,0010), default 0 |
| `columns` | `fn(*const Dataset) u16` | Columns (0028,0011), default 0 |
| `modality` | `fn(*const Dataset) []const u8` | Modality (0008,0060), default "" |
| `numberOfFrames` | `fn(*const Dataset) u32` | NumberOfFrames, default 1 |
| `bitsAllocated` | `fn(*const Dataset) u16` | BitsAllocated, default 16 |
| `transferSyntax` | `fn(*const Dataset) TransferSyntax` | Transfer syntax from (0002,0010) |
| `pixelData` | `fn(*const Dataset) ?*const PixelData` | Pixel data if present |

## Module Structure

```
dicos.zig/
  build.zig              Zig build configuration (modules, executables, tests)
  build.zig.zon          Package manifest
  src/
    dicos/               Core library
      root.zig           Module root, public re-exports
      tag.zig            ~120 tag constants (groups 0002, 0008, 0010, 0018,
                          0020, 0028, 4010, 6100, 7FE0, FFFE)
      vr.zig             Vr enum (31 variants), encoding queries
      transfer.zig       TransferSyntax type, 14 UID constants
      types.zig          Dataset, Element, Value, PixelData, Frame
      reader.zig         Part 10 parser (implicit/explicit VR, encapsulated)
      writer.zig         Part 10 writer (explicit VR little endian)
      codec.zig          Codec vtable (encode, decode, getName, getTransferSyntaxUid)
      codec_registry.zig Codec registration and lookup functions
      img.zig            GrayImage(T) comptime-generic pixel buffer
      error.zig          CodecError, DicosError
    dicosctl/            CLI tool
      main.zig           dicosctl binary (dump, info subcommands)
    jpegrle/             RLE PackBits codec (DICOM Part 5 Annex G)
    jpegli/              JPEG Lossless codec (ITU-T T.81 Annex H, DPCM)
    jpegls/              JPEG-LS codec (ISO/IEC 14495-1, LOCO-I)
    jpeg2k/              JPEG 2000 codec (ITU-T T.800, wavelet)
    zoxel/               3D volume viewer (wgpu + zgui)
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

All codec modules provide lossless 16-bit grayscale encode/decode through the `Codec` vtable:

| Codec | Standard | Module | Transfer Syntax UID |
|-------|----------|--------|---------------------|
| RLE PackBits | DICOM Part 5 Annex G | `jpegrle` | `1.2.840.10008.1.2.5` |
| JPEG-LS | ISO/IEC 14495-1 (LOCO-I) | `jpegls` | `1.2.840.10008.1.2.4.80` |
| JPEG Lossless | ITU-T T.81 Annex H (DPCM) | `jpegli` | `1.2.840.10008.1.2.4.70` |
| JPEG 2000 | ITU-T T.800 (Wavelet) | `jpeg2k` | `1.2.840.10008.1.2.4.90` |

The codec registry provides three ways to resolve a codec:

1. **By name** -- `codec_registry.codecByName("jpeg-ls")`
2. **By transfer syntax UID** -- `codec_registry.codecForTransferSyntax(uid)`
3. **By magic bytes** -- `codec_registry.sniffCodec(data)` (heuristic, checks JPEG/RLE signatures)

## Value Representations

All 31 standard DICOM Value Representations are supported:

| Category | VRs |
|----------|-----|
| **String** | AE, AS, CS, DA, DS, DT, IS, LO, LT, PN, SH, ST, TM, UC, UI, UR, UT |
| **Binary** | AT, FL, FD, OB, OD, OF, OL, OW, SL, SS, UL, UN, US |
| **Sequence** | SQ |

Long-form VRs (4-byte length field): OB, OD, OF, OL, OW, SQ, UC, UN, UR, UT.

## Tests

Run all unit tests:

```sh
zig build test
```

The `dicos` module includes tests for:

- Dataset insert, get, remove, and iteration
- Value type conversions (u16, u32, i32, f64, string)
- Transfer syntax property queries (explicit VR, little endian, encapsulated)
- Tag formatting and name lookup
- VR encoding property queries (string, binary, long-form)
- GrayImage creation, pixel access, row access
- Codec registry lookup (by name, transfer syntax, magic bytes)
- Reader/writer round-trip verification

Total test count across all submodules: 262 tests in 31 files.

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
