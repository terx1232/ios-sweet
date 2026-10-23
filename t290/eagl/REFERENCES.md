# Other XNU/iOS GPU ports reviewed 2026-10-23

## HackiOS (POCO X5 Pro / Adreno 642L)

Primary sources, pinned for repeatable comparison:

- [EAGL bridge](https://github.com/oosexgang/hackios-xnu-userland/blob/906425b75e02b4f99eb5d7bb1ef7c9583472d772/userland/src/eagl.c), MIT.
- [CA hook/reference](https://github.com/oosexgang/hackios-xnu-userland/blob/906425b75e02b4f99eb5d7bb1ef7c9583472d772/userland/src/inject.c), MIT; targets16.5, so its addresses are not portable.
- [IOSurface implementation](https://github.com/oosexgang/hackios-xnu-kernel/blob/8e61187098f2c26c5daee8f9f72b6416aa64b9ab/xnu/files/iokit/Kernel/MiniIOSurface.cpp).

Relevant differences:

- `IOSurfaceAddress` creation maps the client's existing memory. This is distinct from the optional WrapClientImage selector.
- `my_attachImage` handles alpha-first bytes in wrapped, format-less pictures.
- `blit_targets` avoids rendering directly into imported scanout memory when a pass also reads it.
- `plain_draw_begin` supplies programs for particular CA operations; copying function numbers requires checking our firmware.
- Shader handling covers pixel coordinates and full precision.

Our kernel `SweetSurface::create` path ignores `IOSurfaceAddress`, allocates and clears new memory. That is a concrete API gap. Three captured format0 inputs (surfaces32-34) contain only zeros. Their original creation dictionaries were not captured: the gap is a candidate explanation, not yet a confirmed cause of all missing UI.

Patch0136 now implements this contract independently: pinned original pages,
exact caller geometry, separate user mappings and read-only handling. The
bridge uses an owned aligned GPU backing rather than importing arbitrary
external pages. Hardware0136 ES2+ES3 client-memory regressions PASS; icons
now appear. The raw
format0 byte order has not been guessed or changed globally.

Before fixing it, preserve the caller's pitch/allocation, lifetime and cross-process mapping. External pages may not be physically contiguous; our GPU import path must handle that or use a GPU backing copy. Do not treat every format0 scratch target as alpha-first.

GLI comparison against their iOS16.5 table:337 normalized names match,8 additional entries are familiar aliases,7 late GLES1 offsets differ from our desktop SDK layout. Verify against installed16.7 before changing dispatch.

## NativeAdreno / UniXNU

[NativeAdreno](https://github.com/UniXNU/NativeAdreno/tree/b686b9054f57d393c80195b82568a09f8ca106a2), MIT, targets A740/sheng. Useful architectural reference for memory/fences; its board/GMU/register initialization is not a replacement for A504.

## Local reference copies

Read-only downloads are in `D:\test1\dl\driver-refs`, outside git. No reference build scripts or binaries were executed. The two HackiOS source blobs were checked against their pinned GitHub blob hashes. No upstream code has been copied into our driver by this review.

The follow-up `ca_passes.h` independently implements the two narrow missing
operations using this reference's findings, standard GLSL arithmetic and
our actual16.7 binary. Verified cache UUID9e40b2eb260c3af1ae45a1a551a8c1b9,
GLES vtable1d57df6e8. Native function reads context+0x10/state+0x10.
`color_matrix_function` at1884571c0 selects19/20 (premultiplied20) and
delivers4x5 floats at18845722c..188457258. Program loader at1884323c8
explicitly bypasses program creation for0x59. Runtime hook additionally
checks exact original function addresses. No reference16.5 address copied.
