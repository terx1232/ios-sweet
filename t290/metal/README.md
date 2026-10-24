# Metal for the SM-T290 (Adreno 504) — plan and recon

Goal: CoreAnimation (backboardd) renders through Metal, as on a real iPad,
instead of its incomplete GLES path (`t290/eagl`), whose missing functions
(20, 28, 40, 45, 89, ...) keep surfacing as UI defects.

## Recon (2026-10-24, iPadOS 16.7.16 root image)

How Metal finds a driver (strings in Metal.framework / IOGPU.framework):
`MTLRegisterDevices` matches IOKit services of class **`IOAcceleratorES`**,
reads their properties **`MetalPluginName`** (bundle
`/System/Library/Extensions/<name>.bundle`) and **`MetalPluginClassName`**,
and creates the device with `-initWithAcceleratorPort:options:`.
Apple's A9 driver: `AGXMetalA9.bundle`, `NSPrincipalClass AGXPrincipalDevice`
(code in the shared cache), base class `IOGPUMetalDevice`.
backboardd today already looks up `IOAcceleratorES`/`AGXAccelerator` (~300
lookups per boot) and finds none, so CA uses its GLES renderer.

CoreAnimation shaders: `QuartzCore.framework/default.metallib` (1 MB, 141
functions: 39 vertex, 95 fragment, 7 kernel; `Apple metal version 31001.722`,
triple `air64-apple-ios16.7.0`) plus precompiled `default.pipelinelib` per Apple
GPU generation (useless here). Layer compositing uses the uber shaders
`fixed_vert_*`/`fixed_frag_*`, specialized with function constants
(`fc_image_function0/1`, `fc_plane_count0/1` (YCbCr), `fc_blend_function`,
`fc_color_opcodes0/1`, `fc_framebuffer_fetch`, `fc_extended_range`, ...).
Others: blur (downsample/narrow_blur/variable_blur), shadows (`asg_*`),
paths/strokes, gradients (axial/radial/conic), clears/blits, APL dimming.
`_lpf`/`_lph` = float/half variants.

**Open-source `llvm-dis-14` reads the AIR bitcode** (checked on
`std_vert0_lpf`): plain LLVM IR with `air.*` intrinsics, address spaces for
buffers/constants, and function-constant globals.

## Architecture

1. **Kernel:** a service of class `IOAcceleratorES` (subclass registered next
   to SweetGPU) with `MetalPluginName = T290Metal`,
   `MetalPluginClassName = T290MetalDevice`. Nothing else in the kernel: the
   driver keeps using SweetGPU through Mesa.
2. **`/System/Library/Extensions/T290Metal.bundle`**: ObjC classes conforming
   to `MTLDevice`, `MTLCommandQueue`, `MTLCommandBuffer`,
   `MTLRenderCommandEncoder`, `MTLBlitCommandEncoder`, `MTLBuffer`,
   `MTLTexture` (incl. IOSurface-backed), `MTLLibrary`, `MTLFunction`,
   `MTLRenderPipelineState`, `MTLSamplerState`, `MTLDepthStencilState`,
   events/fences — the subset CoreAnimation calls (to be listed from
   QuartzCore's selector references). Implemented on the Mesa GLES 3.1
   context that already works on the tablet (same IOSurface import, sync and
   Freedreno path as the EAGL bridge). Reports an A9-class feature set and
   **no** framebuffer fetch, so CA picks its portable pipeline variants.
3. **Shaders, offline on the PC:** AIR (LLVM IR) -> GLSL ES 3.10 translator
   (`airgl`), one template per metallib function; function constants become
   `#define`s; control flow structured or emitted as a block state machine.
   The bundle ships the templates keyed by metallib UUID + function name;
   `newFunctionWithName:constantValues:` fills the constants and compiles with
   Mesa. Unknown libraries (apps) fail cleanly.
4. **Switch:** once the device works, backboardd runs without the EAGL bridge;
   CA chooses Metal by itself because a device exists.

## Phases (each verified before the next)

1. `airgl` translator on the PC for all 141 QuartzCore functions; compile the
   output with Mesa (software) in WSL; pixel tests for std/fixed/blur shaders
   against hand-computed results.
2. Selector inventory: every Metal selector QuartzCore/UIKit call (shared
   cache selector refs + a logging proxy device on the tablet).
3. `T290Metal.bundle` minimal: device, queue, buffers, textures, one render
   pipeline, present to an IOSurface; standalone test app on the tablet
   (like `eagltest`), real pixels.
4. Kernel `IOAcceleratorES` node; backboardd on Metal with a guard that keeps
   the GLES bridge as fallback until the Metal test passes.
5. Remaining CA features (blur, shadows, paths, YCbCr, compute), performance.

Not in scope: arbitrary third-party Metal apps (would need an on-device AIR
compiler), ray tracing, mesh shaders, Apple GPU tile features.
