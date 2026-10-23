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

## Further 3D/Metal search, 2026-10-23

Read the current primary sources again, pinned independently of the first
review (the HackiOS history has no common ancestor with the earlier pin).

- [HackiOS Metal frontend](https://github.com/oosexgang/hackios-xnu-userland/blob/a79ff0772a3454fd1ef127e181e5b3bce6c9ce18/userland/src/redwoodmetal.m)
  and [Gallium/AIR API](https://github.com/oosexgang/hackios-xnu-userland/blob/a79ff0772a3454fd1ef127e181e5b3bce6c9ce18/tools/mesa/air/air_metal.h).
  Experimental device/buffer/compute/render objects plus AIR->NIR->ir3,
  using Gallium directly, not Vulkan. Potentially relevant to A5xx, but not
  tested there. Their Mesa25.0.7 additions are absent from our24.2.8 build;
  RedwoodGPU IO ABI, IOSurface import,16.5 private Metal SPI and A504 caps
  require separate adaptation/validation. Source explicitly omits heaps,
  blit encoders, events, multisample resolve and viewport rectangles. AIR
  compiler counts are not a percentage of a working Metal driver. The AIR
  document's older 'runtime not started' paragraphs are superseded by source.
  Latest eagl.c is byte-identical to the earlier reviewed copy; no new simple
  GLES fix appeared in that update.
- [UniXNU NativeMetal](https://github.com/UniXNU/NativeMetal/tree/c6d29caad6d880cc8204ebe3bc34d77479a3255d)
  and [runtime architecture](https://unixnu.com/drivers/native-adreno).
  Project reports Metal-composited desktop on A740/sheng. Uses
  metal2vulkan->SPIR-V->Turnip->NativeAdreno; not a drop-in A504 driver.
  [Mesa documentation](https://docs.mesa3d.org/drivers/freedreno.html)
  explicitly excludes A5xx from Turnip. Frontend resource lifetime, fences,
  IOSurface/scanout and pipeline-cache designs remain useful references.
- [ios-topaz](https://github.com/MakrSas/ios-topaz/tree/e4772911e116ab4ab6c4ac1f38e6106fefe8b483)
  now contains userland/gpu sources and IOSurface client-address patches.
  Its README still says those GPU patches are pending publication, so inspect
  the pinned tree rather than treating the README as the complete inventory.
  This is an A610 port; literal cache addresses differ even for16.7.16.

No ready SM-T290/A504 iOS Metal driver was found in these checked projects.
Our existing FD504 GLI polygon/texture pixels already run on the real GPU;
remaining system-compositor functions45/28 are separately observed gaps.
Research copies/source hashes: dl/driver-refs/review-20261023/sources.json,
18 files/1276038B outside git. Downloaded sources were read, not executed.
