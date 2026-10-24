# T290Metal.bundle — Metal driver on Mesa GLES 3.1 (phase 3)

`T290MetalDevice` (NSPrincipalClass) implements `MTLDevice` and the objects
CoreAnimation needs on the tablet's Mesa/Freedreno GLES 3.1 context, the same
libOSMesa and IOSurface import the EAGL bridge uses.

| file | contents |
|---|---|
| `gl.m` | log (`/private/var/tmp/t290metal.log` + kernel log), Mesa loading, the single GL worker thread, streaming ring buffer, pixel formats, `MTLFunctionConstantValues` recording |
| `resources.m` | buffers (CPU memory, uploaded per draw), textures (GL storage; IOSurfaces imported directly when the pitch is a multiple of 64 px, else CPU copy with write-back), samplers, depth/stencil, shared events |
| `library.m` | metallib parsing, functions with constants, AIR -> GLSL via `airglc` (cached per constant set), GL program linking with explicit bindings, render/compute pipelines |
| `device.m` | the device: limits (Apple3 family), factories |
| `commands.m` | command buffers (GL thread, fence, completion handlers), render/blit/compute encoders |
| `mtltest.m` | hardware test, see below |

Conventions: Metal clip space is drawn with y negated (in the translated vertex
shader), so GL texture memory has Metal's row order; viewports and scissors
keep Metal's y and winding flips. The driver defines `T290_FRAG_Y(y)` as `y`
and `T290_DFDY(x)` as `-dFdy(x)` for the translated shaders. Uniform names are
program-wide in GL, so the vertex stage's buffers/textures get a `V` prefix.
Unknown selectors are logged (`unimplemented -[...]`, `device lacks ...`) and
answered with 0 instead of raising.

Not done yet: constexpr sampler decoding (linear/clamp for now), pixel-
coordinate samplers, compute SSBO write-back, MSAA (sample count 1 only),
per-attachment blending, BGRA10_XR formats, heaps, argument buffers, binary
archives, texture view swizzles, persistent shader cache.

Build (WSL): `t290/metal/llvm-ios/build-llvm.sh`, `t290/metal/compiler/build-ios.sh`,
then `t290/metal/driver/build-bundle.sh` -> `~/t290-toolchain/build-metal/`
(`T290Metal.bundle/`, `mtltest`, `SHA256SUMS`).

`mtltest [BUNDLE]` loads the bundle like Metal (principal class,
`-initWithAcceleratorPort:options:`) and checks real pixels: buffer contents,
BGRA8 upload/readback, clear passes (BGRA8, R8), texture and buffer blits,
IOSurface render targets (direct import and CPU copy), a draw with
CoreAnimation's `std_vert0_lpf` + `attachment_clear_frag_lpf` that must cover
exactly the top-left quadrant (orientation), and the time to specialize and
link `fixed_vert_lph_spc` + `fixed_frag_lph_cpf` on the device. Exit 0 only if
everything passes; log in `/private/var/tmp/t290mtltest.log` and stdout.
