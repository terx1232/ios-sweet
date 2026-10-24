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

Status 2026-10-24 (end of phase 1):

- 136/141 translate and compile with Mesa. The other 5 need Apple-GPU-only
  features (imageblocks: tile_downsample_1/2/4/8; SIMD groups:
  compute_apl_fast); the driver will not advertise them.
- Difftests (random buffers, textures, varyings, function constants):
  vertex 39/39, fragment 91/93 (inplace_copy_* write textures: interpreter
  lacks image writes), specialized fixed_frag float+half 24/24 (spectest.py).
  Reference results that are NaN (division by zero for nonsense random
  constants, also undefined in Metal) count as don't-care.
  Two bugs found by the tests and fixed: INT_MIN literal in GLSL, and in the
  reference interpreter's bitcast.
- **Uber shaders must be specialized per pipeline.** Unspecialized
  fixed_frag is ~1 MB GLSL (948 blocks, loops with constant-dependent trip
  counts) and Mesa needs >7 GB to compile it (OOM in WSL). `specialize.py`
  substitutes the function constants, runs the static initializer inside the
  entry and re-optimizes with LLVM (globalopt/gvn/sccp/full unroll): fixed_frag
  becomes 7-51 KB of acyclic GLSL in 0.5-1 s.
- `fc_generic = 1` (constant 0) is CA's run-time-config path (reads
  FragmentShaderConfig from a buffer) and cannot be specialized: the driver
  must read that buffer at draw time and use the matching specialized
  pipeline instead.
- Open decision for phase 3: where specialization runs. Either LLVM on the
  tablet (port airgl to C++ on llvm::Module, cross-build LLVM 14 for iOS
  arm64: a real on-device Metal compiler, also usable for app shaders) or an
  offline cache of the constant sets CA actually requests (logged by the
  driver).
