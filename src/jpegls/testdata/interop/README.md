# Third-party interop fixtures

`tests/interop.zig` decodes every `*.jls` here and compares it with a
same-stem `.pgm` (binary P5, 8-bit or 16-bit big-endian). A `-nearN` stem
suffix (e.g. `ct-near2.jls`) allows `|decoded - expected| <= N` per sample.
With no `.jls` files present (the checked-in state) the test is skipped.

The test reads this directory relative to the working directory
(`zig build test` runs from the repository root); set `JPEGLS_INTEROP_DIR` to
use another location.

Producing fixtures with CharLS (`charlstool` / the CharLS sample app) or
pillow-jpls, from a source image `foo.pgm`:

```sh
# pillow-jpls (pip install pillow-jpls)
python3 -c "import pillow_jpls, PIL.Image as I; I.open('foo.pgm').save('foo.jls')"
```

For a near-lossless fixture, encode with the tool's NEAR option (see its
documentation), name it `foo-nearN.jls`, and copy the source to `foo-nearN.pgm`.

The encode direction (CharLS decoding this codec's planar RGB output) is
covered by `tests/charls_encode_interop.zig`, gated on `DICOS_CHARLS_INTEROP=1`.
