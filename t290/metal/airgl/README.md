# airgl — QuartzCore AIR shaders to GLSL ES 3.10 (phase 1 of t290/metal)

Pipeline (WSL, LLVM 14):

1. Split `QuartzCore.framework/default.metallib` into 141 bitcode modules,
   `llvm-dis-14` each (see t290/metal/README.md).
2. `airopt.sh`: drop the `air64` triple, force-inline everything
   (`alwaysinline`), sroa/instcombine/simplifycfg -> `~/air/opt/mNNN.ll`.
3. `airgl.py`: textual LLVM IR -> GLSL ES 3.10 template + JSON reflection.
   Function constants stay macros (`FC<i>`, `FCDEF<i>`) for the driver.
   Memory: constant buffers -> std140 UBO of uvec4 words, read-only device
   buffers -> R32UI texture buffers (freedreno a5xx has no vertex SSBOs),
   written device buffers -> SSBO, globals/allocas -> uint arrays.
   Run-time pointer/texture choices (`select`/`phi` of pointers, decided by
   function constants) become index-selected alternatives. Programmable
   blending inputs read a driver-provided copy of the attachment (`T290_FB<n>`).
   Vertex outputs use `T290_Q_<key>` so the driver can match the fragment
   shader's `flat`. Metal clip z/y conventions are converted in the shader.
4. `run_all.py`: translate all modules and compile each with Mesa
   (EGL surfaceless, GLES 3.2).
5. `airinterp.py` + `difftest.py`: reference interpreter of the same IR vs the
   GLSL on software Mesa, random buffers/textures/varyings/function constants,
   RGBA32F targets, pixel comparison.

Status 2026-10-24: 136/141 translate and compile; the 5 others need Apple-GPU
features (imageblocks, SIMD groups) the driver will not advertise. Difftest:
89/95 fragment shaders match the interpreter; fixed_frag run pending.
`fixed_frag_*` (948 blocks, real loops with constant-dependent trip counts)
becomes a block-dispatch loop and ~1 MB of GLSL: compile time on the A53 is a
known risk. Vertex and compute shaders are not difftested yet.
