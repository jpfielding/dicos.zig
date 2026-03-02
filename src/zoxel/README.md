# zoxel

GPU-accelerated DICOS volume viewer with 3D ray-casting and 2D slice viewing.

Renders 3D CT volumes from DICOS files using wgpu ray-casting with an
immediate-mode UI control panel. Supports multi-volume loading, five-band
material classification transfer functions for security screening
visualization, and CPU-rendered 2D slice/composite projection views.

This is the Zig port of the `roxel` Rust viewer, targeting the zig-gamedev
ecosystem (zgpu, zgui, zglfw) for GPU and UI integration.

> **Note**: This is currently a placeholder implementation. The full GPU
> pipeline requires zig-gamedev dependencies (zgpu, zgui, zglfw) which will
> be added to `build.zig.zon` when available. The volume loading, camera,
> transfer function, and slice view logic are fully implemented and tested.

## Layout

```
+----------+----------------------+----------------------+
| Sidebar  |   3D Volume View     |   2D Slice View      |
|          |   (ray-caster)       |   (CPU rendered)     |
| Metadata |                      |                      |
| Layers   +----------------------+----------------------+
| Threats  | Quality | Opacity    | Volume: [dropdown]   |
|          | Preset | Bands       | View:   [dropdown]   |
|          | Lighting | WC/WW     | Composite [x]        |
|          |                      | W/L: __ W/W: __      |
|          |                      | Slice: [slider]      |
+----------+----------------------+----------------------+
```

## Running

```sh
# Build
zig build

# Launch with empty viewport (use File > Open to load)
./zig-out/bin/zoxel

# Load a single DICOS file
./zig-out/bin/zoxel scan.dcs

# Load a directory of .dcs files as separate volume layers
./zig-out/bin/zoxel /path/to/slices/
```

Release mode is recommended for interactive use -- debug builds are
noticeably slower during ray marching:

```sh
zig build -Doptimize=ReleaseFast
```

### Single File Loading

When a single `.dcs` or `.dcm` file is provided, its frames are extracted into
one 3D volume. Multi-frame files produce a volume with depth equal to the frame
count. Single-frame files produce a 1-slice volume.

### Directory Loading (Multi-Volume)

When a directory is provided, each `.dcs`/`.dcm` file in the directory becomes
a separate named volume layer. Files are sorted alphabetically. Each layer
appears in the sidebar's Layers section with its own enable/disable checkbox
and a "3D" button to upload that specific volume to the GPU renderer.

## Controls

### Mouse

| Action | Effect |
|--------|--------|
| **Left-drag** in the 3D viewport | Rotate the volume (arcball camera) |
| **Scroll wheel** | Zoom in/out (clamped 0.5x - 5.0x) |

### Camera Presets

| Preset | View |
|--------|------|
| **Axial** | Top-down (azimuth=0, elevation=0) |
| **Coronal** | Front view (azimuth=0, elevation=-pi/2) |
| **Sagittal** | Side view (azimuth=pi/2, elevation=0) |

## Panel Descriptions

### Left Sidebar

The left sidebar provides file loading and volume management.

| Section | Controls |
|---------|----------|
| **File** | "Open file..." button (filters `.dcs`/`.dcm`), "Open folder..." button for directory loading |
| **Metadata** | Volume dimensions (XxYxZ), modality string, volume count |
| **Layers** | Per-layer checkbox (enable/disable) and "3D" upload button (visible when multiple volumes are loaded) |
| **View** | Axial / Coronal / Sagittal camera preset buttons |

### Right Panel (2D Slice View)

The right panel displays a CPU-rendered 2D slice from the loaded volume.
No GPU is required for this panel.

| Control | Description |
|---------|-------------|
| **Volume** dropdown | Select which loaded volume to view (multi-volume mode) |
| **View** dropdown | Slice orientation: Axial (XY), Coronal (XZ), Sagittal (YZ) |
| **Composite View** checkbox | Toggle MIP (Maximum Intensity Projection) mode |
| **W/L** slider | Window center (0 - 65535) |
| **W/W** slider | Window width (1 - 65536) |
| **Slice** slider | Slice index within the chosen orientation (hidden in composite mode) |

### Bottom Panel (3D Rendering Controls)

The bottom panel contains 3D rendering controls.

#### Rendering

| Control | Description |
|---------|-------------|
| **Quality** | Low / Medium / High / Ultra ray-march step size |
| **WC** slider | Window center for 3D rendering (0 - 65535) |
| **WW** slider | Window width for 3D rendering (1 - 65536) |
| **Opacity** slider | Global alpha scale (0.0 - 1.0) |
| **Density** slider | Density threshold cutoff (0.0 - 1.0) |

#### Transfer Function

| Control | Description |
|---------|-------------|
| **Preset** buttons | Default (Bands) / Threat / Monochrome |
| **Band thresholds** | Per-band density sliders (Default preset only) |
| **Band alpha** | Per-band opacity sliders (Default preset only) |

#### Lighting

| Control | Description |
|---------|-------------|
| **Ambient** slider | Ambient light intensity (0.0 - 1.0, default 0.4) |
| **Diffuse** slider | Diffuse light intensity (0.0 - 1.0, default 0.6) |
| **Specular** slider | Specular highlight intensity (0.0 - 1.0, default 0.2) |

## Transfer Function Presets

| Preset | Description | Behavior |
|--------|-------------|----------|
| **Default** | Five-band material classification | Five color bands with per-band thresholds and opacity. Density-based gradient interpolation within each band. |
| **Threat** | Red monochrome for threat highlighting | Transparent below density ~700, red ramp above with opacity 0.03 - 0.20. |
| **Monochrome** | Grayscale density mapping | Linear grayscale ramp from black to 67% white, with linear alpha ramp to 50%. |

### Default Material Bands

| Band | Name | Threshold | Color (RGB) | Description |
|------|------|-----------|-------------|-------------|
| 0 | Air | 8000 | 250, 200, 110 | Transparent, density cutoff |
| 1 | Organic | 15000 | 230, 150, 50 | Orange -- low-Z materials |
| 2 | Inorganic | 20000 | 80, 200, 40 | Green -- medium-Z materials |
| 3 | Metal | 25000 | 15, 165, 200 | Blue -- high-Z materials |
| 4 | Dense | 30000 | 40, 48, 180 | Dark blue -- very dense materials |

Thresholds are tuned for raw CT density data (0 - 30000 range). Within each
band, a brightness gradient (0.85 - 1.15) and an opacity ramp are applied
based on position within the band using an interpolated opacity map.

## Public Types and Functions

### `volume.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `Volume` | `struct` | 3D voxel grid with metadata (dimensions, modality, W/L, rescale) |
| `Volume.loadFile` | `fn(Allocator, []const u8) !Volume` | Load volume from a DICOS file path |
| `Volume.sample` | `fn(*const Volume, usize, usize, usize) u16` | Sample voxel at (x, y, z) |
| `Volume.deinit` | `fn(*Volume) void` | Free all owned memory |
| `ThreatBox` | `struct` | Bounding box for a detected threat object |

### `camera.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `Camera` | `struct` | Arcball camera with orbit, zoom, and pan |
| `Camera.position` | `fn(Camera) Vec3` | Compute camera position in world space |
| `Camera.forward` | `fn(Camera) Vec3` | Forward direction toward target |
| `Camera.right` | `fn(Camera) Vec3` | Right vector |
| `Camera.up` | `fn(Camera) Vec3` | Up vector |
| `Camera.rotate` | `fn(*Camera, f32, f32) void` | Rotate by delta azimuth/elevation |
| `Camera.zoom` | `fn(*Camera, f32) void` | Zoom by multiplicative factor (clamped 0.5 - 5.0) |
| `Camera.panPixels` | `fn(*Camera, f32, f32) void` | Pan target in view space |
| `Camera.setAxial` | `fn(*Camera) void` | Preset: top-down view |
| `Camera.setCoronal` | `fn(*Camera) void` | Preset: front view |
| `Camera.setSagittal` | `fn(*Camera) void` | Preset: side view |
| `Vec3` | `struct` | 3D vector with add, sub, scale, normalize, cross operations |

### `transfer_fn.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `TransferFunction` | `struct` | 1024-entry RGBA lookup table |
| `TransferFunction.fromBands` | `fn([]const ColorBand) TransferFunction` | Generate from material bands |
| `TransferFunction.threat` | `fn() TransferFunction` | Red monochrome threat preset |
| `TransferFunction.monochrome` | `fn() TransferFunction` | Grayscale density preset |
| `TransferFunction.fromPreset` | `fn(TransferPreset) TransferFunction` | Generate from named preset |
| `TransferFunction.asRgbaU8` | `fn(*const TransferFunction) [4096]u8` | Convert to packed RGBA u8 for GPU upload |
| `TransferPreset` | `enum` | `default`, `threat`, `monochrome` |
| `ColorBand` | `struct` | Name, color, threshold, transparency, alpha |
| `defaultBands` | `fn() [5]ColorBand` | Default five-band security screening bands |
| `TRANSFER_SIZE` | `usize` | 1024 entries |

### `slice_view.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `SliceView` | `struct` | State for 2D slice/projection panel |
| `SliceView.renderSlice` | `fn(*const SliceView, Allocator, *const Volume) ![]u8` | Render slice as RGBA pixels |
| `SliceView.updateForVolume` | `fn(*SliceView, *const Volume) void` | Update slice bounds for volume |
| `Orientation` | `enum` | `axial`, `coronal`, `sagittal` |

### `renderer.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `VolumeRenderer` | `struct` | GPU pipeline state (placeholder) |
| `Uniforms` | `extern struct` | Per-frame uniform data for ray-casting shader |
| `Quality` | `enum` | `low`, `medium`, `high`, `ultra` with step sizes |

### `app.zig`

| Symbol | Type | Description |
|--------|------|-------------|
| `App` | `struct` | Main application state: camera, volumes, slice view, transfer preset |
| `App.loadPath` | `fn(*App, []const u8) !void` | Load a DICOS file into the viewer |

## Architecture

```
zoxel/
  main.zig             Entry point, argument parsing
  app.zig              Application state, multi-volume loading, UI layout
  renderer.zig         GPU render pipeline, uniform buffer, texture management
  raycast.wgsl         WGSL fragment shader: ray-box, volume sampling, transfer fn,
                        Phong lighting, alpha blending
  overlay_lines.wgsl   WGSL shader for overlay line rendering
  camera.zig           Arcball camera (orbit, zoom, pan, preset views)
  transfer_fn.zig      Material color bands, transfer function generation
  volume.zig           DICOS file loading, volume extraction, metadata
  slice_view.zig       CPU 2D slice renderer (single slice + MIP composite)
```

### Rendering Pipeline

1. **Load** -- Parse DICOS file via the `dicos` module, extract pixel data
   across all frames into a `Volume` struct (u16 voxels, 0 - 65535).

2. **Gradient computation** -- Compute per-voxel gradients on CPU using central
   differences. Each voxel becomes 4 normalized u16 channels:
   `[density, grad_x+0.5, grad_y+0.5, grad_z+0.5]` packed as Rgba16Unorm.

3. **Volume upload** -- Upload the packed data as an Rgba16Unorm 3D texture
   to the GPU. Dimensions match the volume exactly.

4. **Transfer function upload** -- Generate a 1024-entry RGBA lookup table from
   the selected preset or user-modified bands. Upload as an Rgba32Float 1D
   texture.

5. **Per-frame rendering**:
   - Update uniform buffer with camera position/orientation, window/level,
     lighting parameters, step size, and Z-scale factor.
   - Draw a full-screen triangle (3 vertices, no vertex buffers).
   - Fragment shader ray-marches from camera through the volume bounding box:
     - Ray-box intersection to find entry/exit distances.
     - Step through the volume sampling the 3D texture with trilinear filtering.
     - Apply window/level normalization and density threshold clipping.
     - Look up color and alpha from the 1D transfer function texture.
     - Compute Phong lighting (ambient + diffuse + specular) using
       pre-computed gradients as surface normals.
     - Front-to-back alpha blending, early termination at alpha > 0.98.

6. **2D slice rendering** -- Runs on CPU independently of the GPU pipeline.
   Samples the volume along the selected orientation and applies window/level
   normalization to produce a grayscale RGBA image.

### Quality Levels

The ray-march step size adapts to quality setting:

| Quality | Step Size | Description |
|---------|-----------|-------------|
| **Low** | 0.004 | Coarse steps, faster frame rate |
| **Medium** | 0.002 | Balanced (default) |
| **High** | 0.001 | Fine steps, higher fidelity |
| **Ultra** | 0.0005 | Finest steps, highest fidelity |

Maximum 4096 steps per ray.

## GPU Requirements

Will require a GPU with wgpu support when zig-gamedev dependencies are added:

| Platform | Backend |
|----------|---------|
| macOS | Metal (automatic) |
| Linux | Vulkan |
| Windows | Vulkan or DX12 |

The shader requires:
- 3D texture sampling with trilinear filtering
- 1D texture sampling for the transfer function
- Rgba16Unorm (volume) and Rgba32Float (transfer function) texture support

## Dependencies

| Module | Purpose |
|--------|---------|
| `dicos` | DICOS file parsing and codec support |
| zgpu (planned) | GPU compute and rendering |
| zglfw (planned) | Window creation and event handling |
| zgui (planned) | Immediate-mode UI |

## Tests

Run the zoxel tests:

```sh
zig build test
```

The module includes 12 tests covering:

- Camera default state and target position
- Camera position computation at default angles
- Zoom clamping (0.5x - 5.0x bounds)
- Rotation elevation clamping (prevents gimbal lock)
- Pan target displacement
- Transfer function default band count and transparency
- Transfer function table size (1024 entries)
- Air band transparency verification
- Dense band opacity verification
- Threat preset transparency below threshold
- Monochrome gradient linearity
- Preset round-trip (all presets generate valid tables)

## References

- [NEMA DICOS Standard](https://www.nema.org/standards/view/Digital-Imaging-and-Communications-in-Security) -- NEMA IIC 1 v04-2023
- [wgpu](https://wgpu.rs/) -- Safe and portable GPU abstraction
- [zig-gamedev](https://github.com/zig-gamedev/zig-gamedev) -- Game development ecosystem for Zig
