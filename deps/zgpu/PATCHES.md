# Local patches to zgpu

Upstream: <https://github.com/zig-gamedev/zgpu> at
`b582a62c13af1a8228f72c47ea2eaa21259760eb` (copied unchanged in the commit
that vendored it; `git log -p -- deps/zgpu` shows every change since).

The patches only affect `os.tag == .emscripten`; native (Dawn) builds compile
the same code paths as upstream.

## `src/wgpu.zig`: enum values for Emscripten's `webgpu.h`

zgpu's enums carry Dawn's values. Emscripten 4.0.3's built-in `webgpu.h`
(`-sUSE_WEBGPU=1`) numbers 14 enums differently (for example
`TextureFormat.rgba16_float`, `FilterMode`, `AddressMode`, `CompareFunction`),
so the browser received the wrong formats and samplers. Each affected enum is
now `switch (emscripten) { true => ..., false => <upstream> }`. Dawn-only
members get unique sentinel values `0x7FFF00xx` in the Emscripten branch.

Regenerate or check with (paths from the repository root):

```sh
H=$EMSDK/upstream/emscripten/cache/sysroot/include/webgpu/webgpu.h
python3 web/tools/zgpu-fix-emscripten-enums.py deps/zgpu/src/wgpu.zig "$H" --write
python3 web/tools/zgpu-enum-diff.py deps/zgpu/src/wgpu.zig "$H"   # all "OK"
```

The fixer rewrites plain enums only. Upstream already had a wrong
`switch (emscripten)` branch for `BlendOperation` (`min`/`max`), which was
corrected by hand to 4 and 5; the diff tool checks both kinds.

## `src/zgpu.zig`: use the page's pre-created device

`GraphicsContext.create` on Emscripten calls `emscripten_webgpu_get_device()`
instead of `requestAdapter`/`requestDevice`. Those are asynchronous in the
browser and upstream spins with `emscripten_sleep`, which needs `-sASYNCIFY`
(larger, slower wasm). The page's JavaScript requests the adapter and device
in `preRun` and sets `Module.preinitializedWebGPUDevice`; see `web/shell.html`.
The shared tail of `create` moved into `finishCreate`.

The application must export a no-op `wgpuDeviceTick` (Emscripten has none);
only `GraphicsContext.destroy` would call it, and that never runs in the page.
