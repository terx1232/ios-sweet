# ios-t290 — iPadOS 16 на Samsung Galaxy Tab A 8.0 (2019, SM-T290, `gtowifi`)

Порт по образцу [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet)
(XNU + неизменённый userland iOS 16 на Redmi Note 10 Pro). Локальная копия:
`D:\test1\ios-sweet`, его `NOTES.md` — подробный журнал того, как это делалось.

## Active handoff 2026-10-24 (night): Metal phase 1 done (airgl translator)

- `t290/metal/airgl/` (see its README): AIR -> GLSL ES 3.10 translator,
  reference interpreter, difftests. 136/141 QuartzCore shaders compile;
  difftests vertex 39/39, fragment 91/93, specialized fixed_frag 24/24.
- Key finding: uber shaders need per-pipeline LLVM specialization
  (fixed_frag 1 MB -> 7-51 KB); fc_generic=1 path needs config-buffer
  readback in the driver. Next decision: on-device LLVM vs offline cache.
- WSL working dirs: ~/air (split modules, opt/, glsl/, spec/), ~/dsc
  (shared-cache pieces). Running difftest on unspecialized fixed_frag
  OOM-kills WSL (needs `wsl --shutdown`); difftest.py now skips it.
- Tablet still runs GL bridge ui0146d with capture marker '2' (slow UI):
  stage trace "0" before normal use.

## Active handoff 2026-10-24 (evening): user chose a Metal driver

- User chose option 4 (own Metal driver) over finishing CA's GLES path.
  Recon and plan: `t290/metal/README.md`. Facts: Metal loads the bundle named
  by IOAcceleratorES properties MetalPluginName/MetalPluginClassName; CA's
  shaders are QuartzCore default.metallib (141 AIR functions, uber shaders
  with function constants); llvm-dis-14 reads the AIR (WSL ~/air, split
  modules m000..m140.bc + names.txt). Next: phase 1, AIR -> GLSL ES translator.
- ui0146d with capture marker '2' is still staged/booted state unknown:
  the user booted it but the capture run was not collected. Stage trace "0"
  again before normal use (capture mode slows the UI).

## Active handoff 2026-10-24 (afternoon): ui0146c finding, ui0146d built

- ui0146c booted (SD done 3/3; capture ios-t290/usb-captures/ui0146c/
  boot-20261024-104336-ui0146c). backboardd queried GL strings 0x1f03,
  **0x8a1e (Apple private extensions; bridge returned "")**, 0x1f01.
  CA function_supported: only **function 40 -> 0**; 3,5,7,14,17,18,26,32-36 -> 1.
  No EAGL respondsToSelector misses. No planar IOSurface binds at all.
- QuartzCore's extension checklist (DSC strings next to CA_DISABLE_WORKAROUNDS/
  CA_MAX_TEXTURE_UNITS): GL_APPLE_fence, texture_filter_cubic,
  **texture_ycbcr_basic_formats**, ycbcr_extended_formats, texture_xr,
  tile_order_rot, EXT_shader_framebuffer_fetch, ... Inference (not proven):
  function 40 = YCbCr path, disabled without ycbcr_basic_formats -> wallpaper
  (SpringBoard 3 x 1536x1536 '420f') never drawn -> black + dark vibrant text.
  DSC pieces extracted (with some 7z data errors) to WSL ~/dsc (iNode files).
- ui0146d: 0x8a1e now returns "GL_APPLE_texture_ycbcr_basic_formats" only.
  Planar binds: R8/RG8/LA8 per plane (existing), plus fallback when CA binds a
  whole 420f/420v surface as RGB(A): CPU BT.601 conversion into an RGBA
  mirror on seed change (read-only). yuvcheck.c PASS (dl/ui0146d).
  WSL build build-ui0146d PASS, dl/ui0146d.
- Audit frame on ui0146c (ios-t290/usb-captures/audit/105211.png, power-off
  screen): blur background OK, but the power glyph in the slider knob is RED
  STRIPES (an uploaded image read with wrong stride/format; not yet identified).
- **ui0146d STAGED with capture marker '2'** (4 ops: get log+bridge to
  dl/ui0146d/before, put bridge, put /private/var/tmp/t290eagl.trace="2"),
  SD readback SHA256 22ced304... MATCH. Capture mode streams upload/draw
  records with pixels over USB (slower UI). Next: boot, run
  dl/ui0146d/collect-live.py while the user visits home, power-off slider,
  Settings, Control Center; decode with t290/eagl/decode-capture.py.
  Afterwards stage trace marker "0" again.

## Active handoff 2026-10-24 (noon): ui0146b result, ui0146c diagnostics built

- ui0146b booted (SD request done 3/3; capture ios-t290/usb-captures/ui0146b/
  boot-20261024-102608-ui0146b). Function 28 replacement program created,
  45 drawn with the color-matrix program, no skips. Frame (portrait): widget,
  icons, dock OK; wallpaper still BLACK; labels/status text (77,38,76) dark
  purple = vibrant text derived from the missing wallpaper (guess). App
  Library icon in the dock has a stair-step edge. fps windows 12-132.
- Wallpaper: SpringBoard creates 3 x 1536x1536 '420f' (2 planes) surfaces;
  backboardd never calls texImageIOSurface for them (no plane/IOSurface logs)
  -> CA decides itself not to render YCbCr on this context.
- ui0146c (diagnostics only, always on, bounded): CA function_supported
  results once per function/result; GL strings queried; EAGL respondsToSelector
  misses; every IOSurface bind with non-RGBA/BGRA fourcc or planes.
  WSL build /home/kirill/t290-toolchain/build-ui0146c PASS, dl/ui0146c.
  ui0146b request result: done 3/3 (old log saved dl/ui0146b/before).
  **ui0146c STAGED** 3 ops (get log+bridge to dl/ui0146c/before, put bridge),
  SD readback SHA256 a5c0a640... MATCH. Next: boot with USB, run
  dl/ui0146c/collect-live.py, grep "supported 0", "EAGL probe", "GL string",
  "IOSurface ... fmt".
- Apps: Camera.app is in /Applications (hidden: no camera capability);
  TV, Music, Notes, Calendar, Mail, Maps, Clock, Books... are only in
  /private/var/staged_system_apps (never installed because Setup is skipped).

## Active handoff 2026-10-24 (morning): ui0146b — CA functions 45 and 28

- ui0146a WAS booted (capture ios-t290/usb-captures/ui0146a/boot-20261024-010247-ui0146a,
  SD request done 6/6). Guard PASS incl. inverse-mask repair; bridge 82-118 fps
  windows. Decoded frame: home screen with icons and dock, but BLACK instead of
  wallpaper, icon labels and status bar PURPLE instead of white.
- Log: programless CA function 45 skipped with uniform 0 = 5 x vec4 (saturation/
  brightness color matrix, same layout as function 20) -> wallpaper/vibrant text
  passes missing; function 28 skipped with uniform 0 = 4 x vec2 texture offsets
  (1 and 3 texels in x/y) -> blur step (dock/folders/Control Center).
- ui0146b (ca_passes.h, ca_shaders.h): 45 uses the function-20 color-matrix
  program; 28 uses a new 16-tap blur (each offset in 4 diagonal directions,
  averaged). Parameters remembered per CA context like 20. Weights of CA's own
  blur are not known (approximation). Software-Mesa ES2/ES3 tests PASS incl.
  new blur check; WSL build /home/kirill/t290-toolchain/build-ui0146b PASS.
  dl/ui0146b: bridge SHA256 in dl/ui0146b/SHA256SUMS; eagltest unchanged on device.
- SD request STAGED 3 ops (get log+old bridge to dl/ui0146b/before, put bridge),
  readback SHA256 57cb48ff... MATCH. No recovery written (0146 stays).
  Next: boot, USB capture, check that "skipped" for 28/45 is gone, frame shows
  wallpaper and white labels.

## Active handoff2026-10-24:0146 UI capture, ui0146a bridge ready

- User reports0146 has not frozen so far; prioritizes missing/corrupt UI
  throughout the system. Capture ios-t290/usb-captures/0146/
  boot-20261024-004652-0146:147 log records, full F3072064B/I121B. Screen
  captured lock screen black with purple Press home text (orientation rotated).
  No observed GPU timeout/quarantine; graphics sample used28966376B,
  peak144617068B/denied0. This is limited observation, not long-term stability.
- Guard ES2/ES3 passed,137x13778884-byte client textures now accepted.
  Actual shader95 compile failure: coord_arg undeclared; program96 link fails,
  repeated GL0x502 after use_program_object_ARB. Programless functions20/89
  handled,45/28 still skipped; failed native function6 loses inverse mask.
  Prior ca-passes1/log012 has complete corresponding shader85 trace: clamp
  texcoord1_0 against undeclared coord_arg, color*s0*(1-s1.a). No Apple dump
  copied into git; independently written minimal fixture used for tests.
- ui0146a ca_shader_compat.h only repairs that observed pattern after compiler
  error explicitly reports coord_arg undeclared. Adds lowpvec4 declaration,
  retries, initializes normalized full-image bounds at link, restores prior
  GL program; caller clamp uniforms can override. No versioned GLSL or generic
  missing-variable rewriting; no arbitrary replacement for28/45. Missing
  caller subrectangle bounds remain a limitation. Bounded uniforms/texture IDs
  for28/45 and four failed shader sources logged to guide later fixes.
- Local build /home/kirill/t290-toolchain/build-ui0146a PASS:275 explicit GLI
  signatures,975 adapters, ARM64 iOS16.0, ad-hoc SHA256 pages/entitlements.
  ES2/ES3 software Mesa tests PASS: original copy/color matrix regression,
  actual compiler failure+retry/helper, left/right alpha mask pixels, explicit
  clamp override, refusal cases. New device guard tests real GLI hooks and
  link-state restoration; fake-GPU pixels explicitly not asserted.
- dl/ui0146a bridge SHA256
  064a10edcaa0d8df061be0df11b4031cfaf1cffaabc0782e6a51d34e04736b51;
  eagltest72071e9e448ac5d4cb309372218e0ffd9d61a4b9c8b85d00b0ec426373c7dee3.
  User returnedAndroid+USB. First stage.ps1 passed model check then ADB
  disconnected at previous-request -Result before any write. Retry succeeded:
  dl/ui0146a/stage.ps1 recovered prior request, staged3GET+3PUT, old bridge/
  test/trace backup, install new bridge/test and trace0; full SD readback check.
  Request51039746B, complete SD readback prefix SHA256 PASS; sd-staged.json
  records hash/build. Request staged, not consumed; GET backups available
  after next boot via -Result. No recovery written. Next manual boot then
  USB capture dl/ui0146a/collect-live.py of guard,
  inverse-mask compile/link repair, skipped-pass parameters and new errors.
  User's whole-interface correctness objective remains unfinished.

## Prior0146 kernel installation

- User explicitly approved recovery0146. Guard flash-0146.ps1
  -WriteApproved exit0; complete preflight,64MiB write and full partition
  readback SHA2569efbdee020b4c877f3f0864c0c89c64da7d7c9793cf5a3d5b2f6b1871a7368e8
  PASS. flash-0146-result.json saved alongside0145 backup. No reboot sent.
  Next manual recovery-menu boot; capture via dl/t290-stability/collect-live0146.py.

- User reported0145 frozen. NativeUSB COM7 remained live; capture saved in
  ios-t290/usb-captures/0145/boot-20261024-003258-0145,106 log records
  (log004 partial48764B; others retain packet status), full F3072064B/I121B.
  Screenshot Safari blank start page in landscape. No observed kernel panic.
- Actual GPU fault: seq17744 first timeout, fence17737 stuck, CB0FSR0x202,
  FAR0x10ae4600; later queuedseq17821 but fence still17737. Kernel/HID/USB/
  KXTJ3 continue.0145 prevents endless single wait but cannot recover this
  GPU fault. Graphics used26838968B/peak65725332B/cap536870912B/denied0:
  quota exhaustion is not supported by this sample. EAGL guard passed.
  Bridge reports11..39.9 rendered frames/s in300-frame windows; these are
  not measured panel refresh rates. Preserve30Hz setting, no60FPS claim.
- Actual rejected137x137 client textures request78884 bytes =576*136+548:
  valid final-pixel extent without final-row28B padding. Prior layout required
 78912.0146 accepts this exact extent for wrapped single-plane rows only;
  78883 still rejected, no extension of caller memory. Automatic sizes keep
  full stride*height. Planar explicit size validation remains strict. Bridge
  uses aligned owned backing for all client memory and copies only rowBytes.
-0146 additionally enforces a conservative global submitted-fence wait
  before freeing/unmapping buffers (previously solely caller responsibility),
  serialized with same-client Submit. Timeout returns without releasing
  memory. Timed-out clientClose retains client/buffers until reboot (no GPU
  reset/recovery implemented). Imported BOs now retain SweetSurface, preserving
  both lifetime and shared graphics quota until actual release. This closes
  real unsafe lifetime paths; actual FAR fault's allocation is not identified,
  so no claim that its cause or system freezes are fully fixed.
- New actual release/clientClose ASan/UBSan test PASS: timeout leaves mapping/
  reservation intact, success frees once, imported surface retained/released,
  prepared indices removed, repeated timed-out close retains client once.
  Layout test covers exact78884/one-byte-short78883. Existing layout/budget/
  wait checks PASS. FourARM64 files compile, full relink, known shim/DTB,
  payload roundtrip/reverse-patch PASS; QEMU60s no_panic_observed/glyph0.
- dl/k-t290-0146/recovery-0146.img64MiB SHA256
  9efbdee020b4c877f3f0864c0c89c64da7d7c9793cf5a3d5b2f6b1871a7368e8;
  kernel8da260792d945460cd1b7a8726dde018bc4b64e0a2becfaad833357508526191.
  Graphics bridge/eagltest unchanged0139. No SD request staged. BT paused.
- User returnedAndroid+USB. Backup0145 local/device hash verified in
  ios-t290/backup-20261024-stability0146/recovery-before-0146.img,
  SHAfbff4649a6c8fe58d3f792869e6393eae2c4773b0ab8f01291b6faeb820571d2.
  Final0146 pushed; guarded read-only flash-0146.ps1 preflight PASS.
 0146 now explicitly approved and installed, full readback result above.
  Next manual boot and reproduce Safari+rotation.
  Capture fault and retaining-busy-buffer logs; further fault mapping history
  or GPU recovery may be needed if fault persists.
- Helpers dl/t290-stability/*0146*, baseline0145 files saved there.
  WSL stability0146{,-objects}/qa0146. Patch0146 builds on0145.

## Prior0145 installation handoff

- Android USB reconnected after user action. Guard flash-0145.ps1
  -WriteApproved exit0: complete preflight PASS,64MiB write and full partition
  SHA256 readback fbff4649a6c8fe58d3f792869e6393eae2c4773b0ab8f01291b6faeb820571d2
  PASS. flash-0145-result.json saved alongside verified0144 backup.
  No reboot command sent. Next manual recovery-menu boot and USB capture.

- User explicitly approved writing recovery0145. Guard invoked with
  -WriteApproved but failed at FIRST command getprop: adb no devices.
  No write occurred. Windows sees Samsung USB modem COM6, no ADB device.
  Asked user to reconnect Android USB. Approval persists; rerun guarded
  flash-0145.ps1 -WriteApproved after connection returns, verify full readback,
  then ask manual iPadOS boot. No additional write approval needed for0145.

- User paused Bluetooth and prioritizes faster UI/stability. Do not assume
  GPU hardware is the proven cause of the prior CoreAnimation waits.
- Actual0144 capture: ios-t290/usb-captures/0144/boot-20261024-001048-0144,
  175 log files, frame3072064B/info121B. Firmware files image=0 metadata=0
  (full size/hash checks pass), no hardware load/authentication. Actual GPU
  core clock400MHz. Motion/RTC/HID/memory corrections retained.
- Android returned; SD request recovered with -Result: done4ops/ok2. Both
  old-file GETs are ENOENT; both PUTs succeeded6574080/7324B. No new SD
  request required for0145; graphics bridge remains0139.
-0145 patch shares512MiB graphics budget between owned GPU buffers and
  owned/pinned surfaces (imports not counted twice), selector10 and process
  sample telemetry; map failures unwind reserved VA. Prepared handles4096
  use dynamic allocation and remove freed indices. IOSurface mapping moved
  outside global table lock. Fence waits use real deadlines capped5s and
  yield after initial1ms spin. This does not reset/recover a hung GPU.
- Failed surface logs now show INPUT allocation, pitch and offset; previous
  allocSize0 was an output field and did not prove caller requested zero.
  Final review found possible zero elementWidth in failure diagnostics;
  guarded before division. Final4ARM64 compile/link/pack and reverse-patch
  check PASS; final QEMU60s no_panic_observed/unknown_glyphs0. Hardware
  GPU behavior is not exercised by QEMU. Do not flash older0145.
- Layout ASan/UBSan PASS; budget ASan/UBSan PASS including160000 concurrent
  pairs; actual wait function tests PASS (zero/delayed/UINTMAX/wrap/notready).
  Final image/kernel SHA256 below supersede the initial0145 build.
-0144 full64MiB backup ios-t290/backup-20261024-stability0145/
  recovery-before-0145.img SHA256
  5c4453da28d39e406b4d5589cdce7a1c0cde1a07ba3fbd03168e5314246f7adc.
  Final0145 push and guarded read-only preflight PASS (model, partition,
  size, local/device image hash, backup and current partition hash).
  Image64MiB SHA256
  fbff4649a6c8fe58d3f792869e6393eae2c4773b0ab8f01291b6faeb820571d2;
  kernel26608e6f647b6f0571e51c8c32f55533a17615ebc68c08f46fc8fbcf01a6173d.
  Guard backup directory/flash-0145.ps1.0145 now explicitly approved;
  initial connection failure resolved; installation result recorded above.
- Helpers dl/t290-stability, build stability0145{,-objects},qa0145.
  Bootargs remove t290btprobe/t290btscm/t290btfiles; retain RTC offset,
  accelerometer, existing GPU clock and framebuffer30Hz.60FPS unverified.
  Preferences Wallet nil specifier and Photos missing root album remain
  separate unresolved application failures (see0142 findings below).

## Previous0144 installation handoff

- Actual0143 capture completed139 logs +F3072064B/I121B:
  ios-t290/usb-captures/0143/boot-20261023-235244-0143. SCM convention64,
  INFO selfquery1, PIL1/2/5/7 API-available1. WCNSS heap unused uncached0x20,
  cached-start=size0x2c000; tables13 and266 both-2. No controller commands/HCI.
  RTC correct, driverkitd6->64MB, GPU guard passes, USB/KXTJ3 client1 live.
- User returnedAndroid+USB. Read-only proxy inspection saved in
  dl/t290-bluetooth/android-proxy-{clocks,registers}.txt. L7 1800mV,
  crypto source100MHz, CMD0x80000000/CFG0x10f; crypto branches idle/off.
  Correct clock-gcc-8952.c supports gcc-sdm429 (already local dl/t290-usb).
  gcc-regs.h: CRYPTO_CMD0x16004/CBCR0x1601c/AXI0x16020/AHB0x16024;
  APPS_BRANCH_VOTE0x45004 bits2/1/0. Future proxy enable must preserve votes,
  configure verified source and wait boundedly. No BT clock/PMIC writes yet.
-0144 adds firmware_files.c (t290btfiles=1),60s delayed kernel worker.
  Queries actual PAS6 support with standard SMC64 PIL7(one scalar6), then
  checks exact vnode sizes and complete SHA256 for image6574080B and
  ORIGINAL metadata7324B. Hash constants verified against local manifest.
  No init/mem_setup/auth_reset, DMA/firmware memory writes, HCI or RF yet.
  Need next contiguous4K-aligned noncached metadata + proxy resources and
  proper PIL sequencing; do not call with ordinary heap metadata pointers.
-0144 two ARM64 objects compile PASS, patch reverse-check PASS, full link0,
  known shim/DTB and payload roundtrip PASS, QEMU60s no_panic_observed/
  unknown_glyphs0. Hardware file/PAS6 test NOT verified. Graphics/motion/
  memory/RTC0142 objects retained. No fix for prior UI freeze claimed.
- dl/k-t290-0144 recovery64MiB SHA256
  5c4453da28d39e406b4d5589cdce7a1c0cde1a07ba3fbd03168e5314246f7adc;
  kernel d1c17c45fd4d76dd0d613c53e5f709b4c0defc86e5199b6e8e4b993852644e71.
  Helpers dl/t290-bluetooth/*0144*, work bluetooth0144{,-objects},qa0144.
- SD4op request STAGED: GET previous /usr/lib/wcnss-t290-memory.bin/auth.bin
  into dl/k-t290-0144/before, PUT verified private image+metadata. These paths
  were not previously staged. Full40181404B request readback PASS SHA
  afcaeb708994ecd256afa9abf28f791d3dedff4cda50c5274ff2dfa53d0c241a.
  An initial verification read rounded DOWN to78479 sectors, missing156B;
  corrected ceil78480-sector read then exact payload prefix hash PASSED.
  Card contents unchanged by this verification correction. After boot, recover
  GETs with -Result before another request. SD request currently NOT consumed.
-0143 backup verified local/device/current partition in
  ios-t290/backup-20261024-bluetooth0144/recovery-before-0144.img,
  SHAe1796bf6...93222a.0144 image pushed; flash-0144.ps1 read-only preflight
  PASS. **0144 INSTALLED after explicit user approval.**
  flash-0144.ps1 -WriteApproved exit0; full64MiB partition SHA readback PASS
  5c4453da28d39e406b4d5589cdce7a1c0cde1a07ba3fbd03168e5314246f7adc.
  Result JSON saved in backup directory. No reboot command sent.
  Next manual recovery-menu boot.
  NativeUSB helpers collect-live/collect-more/wait-collect0144.py; inspect
  PAS6 support and firmware files image=0 metadata=0, plus XFER done4/4.

### Prior0143 preparation/history

## Latest steering: resume Bluetooth;0143 built, QEMU60s PASS

- User redirected work back to Bluetooth after0142 freeze investigation.
  Preserve system/app findings below. New0143 kernel probe reads both SMD
  allocation banks13/14/338 and266/138/202; reports private WCNSS heap free
  boundaries and checks channel reference-count + APPS/WCNSS edge6.
- Opt-in t290btscm=1 sends ONLY INFO/IS_CALL_AVAILABLE (service6/cmd1),
  self-detects SMC64/SMC32 then queries existence of PIL commands1/2/5/7.
  No PIL init/memsetup/auth/reset call, PMIC/clock write, FIFO/HCI or RF traffic.
  Bounded64 interrupted continuations preserve x6 cookie and original args;
  no ABI fallback/further queries after incomplete continuation.
  API existence alone does NOT prove PAS6 support or live firmware.
- ARM64 probe compile PASS, patch reverse-check PASS, full link0, known
  shim/DTB + payload roundtrip PASS. QEMU0143 completed60s: PID1 alive, no_panic_observed/unknown_glyphs0.
  dl/k-t290-0143 recovery64MiB SHA256
  e1796bf60e7ee75c9ff6fad21a48f57b0b1b447ff78c3ffd4fe8d51fb493222a;
  kernel ee5602e244c1a9d3ca4a073a03a2bb28598269f5d196e64b88fb2e348b74950f.
  Preserved0142 HID/memory/RTC objects and calibrated offset; graphics unchanged.
- User returnedAndroid+USB. Full0142 backup verified locally/currentpartition,
  SHA9a650cab...b5e1fb;0143 pushed/hash verified. Read-only preflight PASS.
  Guard script in
  ios-t290/backup-20261023-bluetooth0143. **0143 INSTALLED after explicit user approval.**
  flash-0143.ps1 -WriteApproved exit0; full64MiB partition readback PASS
  e1796bf60e7ee75c9ff6fad21a48f57b0b1b447ff78c3ffd4fe8d51fb493222a.
  Result JSON saved in backup directory. No reboot command sent.
  Next manual boot and nativeUSB capture with dl/t290-bluetooth/*collect*0143.py. No new SD update needed for this diagnostic.
  Helpers dl/t290-bluetooth/*0143*, WSL bluetooth0143{,-objects},qa0143.

###0142 freeze evidence saved before returning to Bluetooth

- User reports screen/power button unresponsive. NativeUSB and sensor samples
  continue; HID down/up events continue, no observed panic. Captured new
  log141..144 and frames234000/234106, byte-identical SHAa8bd6fbb...bf51f62,
  frozen Messages screen with dock visible.
- SMP samples2 and3 (120s apart) show same SpringBoard main-thread stack
  waiting in QuartzCore CA::Layer::mark_context_changed+0x1cc via switcher
  cacheAsynchronousRenderingSurfaces callback. Backboardd render thread5
  waits in IOKit io_connect_method under CA::OGL::GLContext::update_state;
  backdrop/point-conversion workers also blocked. Suggests graphics/CA lock
  dependency; exact kernel selector/lock cause NOT proven. Do not claim GPU
  hardware hang based on this alone. Safari main repeats dyld MachO load-command
  traversal address too. Original cache symbol helper dl/t290-system/hang0142.sh.
- No hang fix implemented. User expressly returned priority to Bluetooth.

## Active handoff:0142 hardware results, Settings/Photos failures now identified

-0142 actual boot/capture completed141 log chunks +F3072064B/I121B:
  ios-t290/usb-captures/0142/boot-20261023-233643-0142.
  Detail verification0142.txt there; latest frame-233820.png.
- RTC PASS raw23696203/offset1769073406/epoch1792769609 (2026-10-23UTC).
  SPU log spam0 (0141 had320). Driverkitd requested6MB->64MB twice, no
  driverkitd CRASH/fatal-memory event in observation window. No50MB watermark
  opt-in EINVAL. No observed panic. Long-term survival not established.
  EAGL exit0/Mesa enabled, motion verified sender/bridge+orientation3, USB live.
- User requested fixes for all these system errors; latest steering requested
  checking new logs. Confirmed application failures still need fixing:
  Preferences[204] SIGABRT NSInvalidArgumentException nil dictionary objects[3].
  FIRST THROW symbolicated against original cache with slide0x29cc4000:
  PreferencesUI -[PSUIPrefsListController passbookSpecifier]+0x178 at
  unslid0x2054daf78, specifiers+0xdd4 0x2054d9ac8. Investigate actual Wallet
  specifier missing dependency; do not globally drop nil dictionary entries.
- Photos MobileSlideShow[203] SIGABRT NSInternalInconsistencyException:
  PHCollectionList fetchRootAlbumCollectionListWithOptions returns0 items.
  PhotosUICore rootAlbumCollectionList block+0xb0 at0x1a56774e0.
  Investigate photolibraryd/root album DB initialization, no fabricated album.
-35 real137x137,bpr576 client-memory IOSurface create failures,size0 ->
  0xe00002c2, separate from deliberate test bpr480 rejection. Inspect producer
  properties; preserve allocation bounds safety. Filesystem/BindFS warnings
  persist. No claim all graphics/apps fixed. Bluetooth still deferred.
- Tablet in iPadOS0142, no new images/SD request/device changes. No collectors
  running now. Source commit5cf6600 recorded installed0142; symbol helpers
  dl/t290-system/{symbols,firstthrow}0142.sh, use wsl -u root for cache mount.

### 0142 preparation and installation history

## Active handoff:0142 INSTALLED, hardware test pending

- User requested fixing journal issues, Bluetooth deferred. Patch0142:
  T290 HID transport Embedded instead of incorrect AppleSPU; preserves sensor
  usage/product and0139 orientation path. No log suppression. Need hardware
  verification that AOP assertion spam ceases and rotation remains working.
- CONFIG_JETSAM disabled previously excluded two iOS legacy memory-limit
  commands, causing launchd50MB watermark EINVAL. Enable existing setter for
  T290 with normal auth/fatal/nonfatal handling; keep coalition APIs gated.
  Positive driverkitd limits below64MB receive bounded64MB floor only;
  all other tasks/default/larger limits unchanged. This is provisional until
  measured hardware survival/footprint. Fatal path now logs actual footprint
  and limit. No global disabling of protection/pressure handling.
- IOPlatformExpert calendar getter previously returned0. New RTC C module
  uses existing serialized observer SPMI reads, sid0/peripheral0x60 only,
  control0x6046 + counter0x6048..4b/carry check. No hardware writes/alarm changes.
  Gate t290rtc=1; calibrated t290rtc_offset=1769073406 in LOCAL bootargs.
  Android read stable raw23695729 vs Unix1792769135; Android stores wall
  correction separately. Reject invalid/overflow/2020..2099 range. Set-time
  adjusts only in-memory offset this boot. Recalibrate after counter reset or
  Android wall correction change. QEMU hardware reads disabled.
- Portable policy/RTC ASan/UBSan non-PIE tests PASS;5 ARM64 sources compile
  PASS; reverse-patch check PASS, full link0; known shim/DTB and payload
  roundtrip PASS; QEMU60s no_panic_observed/unknown_glyphs0. Check qa0142/fb.txt
  for PID1 liveness. Hardware SPU/date/driverkitd fixes NOT verified yet.
- dl/k-t290-0142: recovery64MiB SHA256
  9a650cab07eb7c777fe874104a0fe71be42b908210ce53c05532cd08a4b5e1fb;
  kernel a558c6866472eaa4b46c467a250af2b1aff64990061f5df66551c4f2a348fc08.
  Bridge0b6dab70...dd9b51/testb874b3fe...1979a remain unchanged0139.
- Android connected. Full0141 backup in ios-t290/backup-20261023-system0142/
  recovery-before-0142.img, SHA2ab7d974...e0e91 matches current partition.
  Image pushed/data/local/tmp/recovery-0142.img; flash-0142.ps1 read-only
  preflight PASS. **0142 INSTALLED after explicit user approval.**
  flash-0142.ps1 -WriteApproved exit0; full64MiB partition SHA256
  readback PASS9a650cab...b5e1fb. Result JSON saved in backup directory.
  No reboot command sent. No new SD userland request needed/staged.
- Next user manual recovery menu boot;
  dl/t290-system/{wait-collect,collect-live,collect-more}0142.py for nativeUSB.
  Check SWEET RTC epoch, MEM requested/applied/fatal logs, driverkitd and
  AppleSPU assertion count, touch/rotation. Then app tests. No all-fixed claim.
- Helpers dl/t290-system/{prepare,build,relink,pack,qemu}0142*; baseline0141
  copies there. DO NOT rerun prepare helper (would duplicate edits).
  WSL work system0142{,-objects},qa0142. Link keeps0141 BT/SD and0139 accel,
  new HID/IOPlatformExpert/memorystatus/SPMI/RTC objects. Source t290/system.
- Read-only original APFS remounted ROOT-owned via apfs-fuse -o ro at
  /home/kirill/sysos (use wsl -u root to access). No file modifications.

### Prior system journal review

## Latest steering: review system journal before more Bluetooth changes

- User asked to pause BT changes and inspect system logs. Read-only fresh
  nativeUSB appended log176(60256B),log177(empty),frame-231641.png to actual0141
  capture. Review saved there as system-review.txt. No device changes made.
- driverkitd SIG9 ns1/code7 now decoded against actual XNU build headers:
  OS_REASON_JETSAM / JETSAM_REASON_MEMORY_PERPROCESSLIMIT. It exceeded its
  per-process limit. This does not prove overall RAM exhaustion, nor explain
  Safari/Settings/Photos crashes (none launched/crashed in this capture).
-178 log chunks total: no other CRASH process/no panic(cpu observed.
  EAGL test exit0/Mesa enabled, live KXTJ3/USB and measured rotations continue.
 320 repeated AppleSPUKext liblog_aop AssertMacros:success line135 messages;
  cause/impact unknown. Also50MB Jetsam opt-in EINVAL, filesystem-info failures,
  persona startup warnings and sandbox privilege denials. Clock is1969-12-31.
- Current snapshot App Library landscape/icons/text with black background.
  SMP raw stacks alone do not establish a deadlock. Symbolicator cache mount
  /home/kirill/sysos absent; previous mapped_query.py exits IndexError, so no
  invented symbol names. No new source changes for Bluetooth yet.

## Active handoff 2026-10-23:0141 booted, WCNSS partition found

- Actual0141 capture complete: ios-t290/usb-captures/0141/
  boot-20261023-230940-0141:176 log replies plus F3072064B and I121B.
  SMEM version0xb0000,TOC0x434f5424/version1/7entries. WCNSS0/4
  partition offset0x5a000,size0x2c000,cacheline32; allocation item13 status-2.
  No panic found in captured text. EAGL test exit0/enabling Mesa, verified
  KXTJ3 sender, measured orientation3, live sensor/USB continues.
  driverkitd SIG9 reason1/code7 also present; cause not established.
- This does NOT prove firmware off. Reference SMD source supports secondary
  table266/control138/FIFO202 in addition to13/14/338.0141 only queried13.
  Need inspect266 and private heap usage before destructive/reset operations.
  Downstream reference saved outside git vendor-smd.c/smd_private.h;
  googlesource e38998faf70429357419a02f5850ceefe9e887b6/drivers/soc/qcom/smd.c.
- Added offline prepare_firmware.py/test_firmware.py,7 synthetic tests PASS.
  Validates ELF32 ARM, split metadata, header/range/overflow/overlap, relocation
  alignment, BSS, segment exact size and executable entry. No device access.
  Actual private wcnss firmware validated/prepared9 load segments into
  dl/t290-bluetooth/prepared-pronto-v1: memory6574080B SHA256
  3ff1ecc279b4b6894c1a6f607bdbc9cbc0a428a3cd255e4c055a411f8a68742e;
  ORIGINAL metadata7324B SHA256
  73c9cf39430fb1865c9342151dcba66355c5f542ba561f0a99905b84cc115faf.
  Physbase0x8ce00000,reserved7MiB,originalbase0x8d600000,entry0x8ce0191c.
  NO hardware load/authentication/reset/clock/PMIC commands performed.
- Next: complete SMD inventory including table266, verify cold-controller
  ownership; implement PAS6 init/mem_setup/auth_reset with exact SCM ABI,
  physical contiguous metadata/cache visibility and required proxy resources.
  Then channel handshake/HCI ReadLocalVersion; lastly iPadOS H4 integration.
  Firmware metadata must not be patched. No HCI/pairing claim yet.
- Tablet last in iPadOS, recovery0141 installed verifiedSHA2ab7d974...e0e91.
  No new recovery or SD request staged. No collectors currently running.
  Preserve motion0139/graphics; no DVFS work. Existing backup0140 retained.

### Prior0141 installation/preparation (actual boot result above)

### Historical handoff 2026-10-23:0141 INSTALLED, actual boot pending

- Actual0140 nativeUSB capture completed:
  ios-t290/usb-captures/0140/boot-20261023-230005-0140,
  136 log replies plus full framebuffer3072064B and info121B.
  SWEET BT allocation status=-3,size0. No HCI commands sent.
  EAGL guards pass/enabling Mesa; motion hook/sender and orientation1/3
  delivered, accelerometer client1 and live samples; USB continues.
  driverkitd SIG9 reason namespace1/code7 logged; cause not established.
- Found an implementation error:0140 parser selected private hosts0/3.
  Qualcomm downstream smem.h enum says DSPS3,WCNSS4.0141 selects0/4,
  tests explicitly reject3/accept4, logs TOC magic/version/count and
  bounded partition identities.0140 status cannot prove controller off.
  Primary ref/download outside git: vendor-smem.h/vendor-msm_smem.c
  in dl/t290-bluetooth; README links exact source revision.
-0141 portable parser ASan/UBSan non-PIE PASS20000 corrupt fixtures,
  two ARM64 objects compile PASS, patch reverse-check PASS, full link0,
  payload roundtrip and known shim/DTB PASS. QEMU60s no_panic_observed,
  unknown_glyphs0; real radio probe disabled in QEMU.
- dl/k-t290-0141 recovery64MiB SHA256
  2ab7d974cc62cbaa77c5c60a54bd68456ef9531b2b65dff9e1e32d03239e0e91;
  kernel9bdd7a5f2002681e0a5d0a030d8454e776de154dfbe51459078b0728d3478c83.
  Graphics bridge/test unchanged0139. Helpers dl/t290-bluetooth/*0141*;
  WSL work bluetooth0141{,-objects},qa0141/with-root.
- User returned to Android. Backup0140 local/device/current SHA verified and0141 pushed.
  ios-t290/backup-20261023-bluetooth0141/flash-0141.ps1 read-only preflight
  PASS; subsequent -WriteApproved exit0 after explicit user approval.
  Full64MiB partition readback PASS2ab7d974...e0e91, result JSON saved.
  Current0140 fullpartitionSHA confirmed76d4d840...00e70.
  **0141 INSTALLED/verified.** No SD userland update needed.
  Next user manual boot via recovery menu; collect with
  dl/t290-bluetooth/wait-collect0141.py then collect-more0141.py.
  Inspect TOC identity and WCNSS channel status. No reboot sent.
- Bluetooth still requires real HCI response/Pronto startup/firmware relocation,
  SMD ownership/handshake and iPadOS transport integration. No pairing claim.

### Previous0140 preparation/installation (actual boot result above)

### Historical handoff 2026-10-23: Bluetooth0140 INSTALLED, hardware boot pending

- 0139 real boot: user confirmed working auto rotation. NativeUSB logs
  ios-t290/usb-captures/0139/boot-20261023-202209-0139 confirm normal
  orientation manager hook, KXTJ3 sender and measured orientation delivery.
  SMP sampler emits samples on SD root. UI stability/app fixes UNPROVEN.
- 0139 SD request consumed8/8; prior GETs recovered into dl/k-t290-0139/before.
  No new SD request staged. Graphics/test stay0139 unchanged.
- Android BT enabled/ON via Qualcomm Pronto, SMD CMD CID7 / ACL CID8,
  8KiB half-FIFOs. Dumps/firmware outside git: dl/t290-bluetooth.
  Never access Android HAL-owned smd2/3 concurrently.
- e8bcb95 adds patch0140: bounded read-only APPS/WCNSS SMEM probe,
  0x86300000/1MiB, t290btprobe=1. No writes/firmware/PMIC/clocks/HCI.
  Stale metadata is NOT proof of live controller. PAS6/Pronto startup,
  relocated MDT firmware loading, SMD handshake/HCI and iPadOS service
  adaptation remain unfinished. No Bluetooth/pairing claim.
- Host parser ASan/UBSan PASS including cached traversal and20000 corrupt
  fixtures. Use -fno-pie -no-pie to avoid intermittent WSL ASan startup
  SIGSEGV. Two ARM64 objects compile PASS, patch reverse-check PASS,
  relink exit0, shim/DTB hashes and payload roundtrip PASS.
  QEMU60s PID1 alive5 messages, no_panic_observed/unknown_glyphs0.
  Hardware probe disabled in QEMU; this is not a Bluetooth hardware test.
- dl/k-t290-0140 recovery64MiB SHA256:
  76d4d840d86156494f6365dd922ebef7848080965a32062ef20fa90485f00e70.
  Kernel ffcebd8a21b60166f3e9c0d22aa6f41135f17c2b9dfbaf96f8378e3bee37fe7d.
  Bridge0b6dab70...dd9b51/testb874b3fe...1979a unchanged0139.
- Android connected. Image pushed /data/local/tmp/recovery-0140.img.
  Full current0139 backup ios-t290/backup-20261023-bluetooth0140/
  recovery-before-0140.img, local/device/current fullpartition hash
  1ef03e39d3861619fffc9a02a03ba8ea0446382b8f9a3c1323c5b5d77b93f259.
  flash-0140.ps1 -WriteApproved exit0 after explicit user approval.
  Full64MiB partition readback PASS76d4d840...00e70; result saved in
  backup directory/flash-0140-result.json. No reboot sent.
- Next: user manual boot via recovery menu;
  dl/t290-bluetooth/wait-collect0140.py and collect-more0140.py, inspect
  SWEET BT lines. Actual HCI response still required before claiming live BT.
- Helpers dl/t290-bluetooth/{build,relink,patch,pack,qemu}0140*.
  WSL work /home/kirill/t290-local-kernel/bluetooth0140{,-objects},qa0140.
  Preserved motion0139 HID/accel objects; graphics unchanged. No DVFS work.

### Historical0139 preparation (hardware result supersedes pending claims)

### Historical handoff 2026-10-23:0139 INSTALLED, next hardware boot pending

- 0139 INSTALLED after explicit user approval (2026-10-23). Guarded
  ios-t290/backup-20261023-motion0139/flash-0139.ps1 -WriteApproved exit0.
  Full64MiB recovery partition SHA256 readback PASS:
  1ef03e39d3861619fffc9a02a03ba8ea0446382b8f9a3c1323c5b5d77b93f259.
  Previous0138 fullbackup verified/retained in that directory. No reboot
  command sent. SD8op request staged/verified and not consumed yet.
  Next manual iPadOS boot; wait-collect0139.py/collect-more0139.py in
  dl/t290-motion target usb-captures/0139. Actual rotation/hang test pending.
- Kernel patch0139: labelled-pose axis map raw(-X,+Y,+Z), HID page0xff00/usage3
  (actual BKOrientationManager matcher), start existing process sampler on SD
  root (previously never called there). Boot sample targets now include
  SpringBoard/backboardd/Safari/Preferences/Photos. No clock changes.
- Added orientation.h/filter to EAGL bridge: exact runtime method/ivar ABI
  checks, only product-verified KXTJ3 registry sender, measured stable gravity
  -> normal BKOrientationManager updateDeviceOrientation:changeSource:.
  Separate serial worker, one pending job maximum, preserves normal rotation
  locks; never call its dispatch_sync entry on input callback/manager locks.
  Hook runtime and actual rotation NOT HARDWARE VERIFIED. Hang cause UNKNOWN.
- Actual filter ASan/UBSan PASS recorded poses, four rotations, flat/diagonal
  hold, debounce/jitter/invalid/stale samples. Three kernel ARM64 objects
  compile PASS, full relink exit0; patch reverse-check PASS. Bridge237 GLI
  signatures + ARM64/signatures/entitlements PASS. Final QEMU60s PASS, PID1
  alive6 messages, no_panic_observed/unknown_glyphs0, sensor disabled in QEMU.
- Artifacts dl/k-t290-0139: recovery1ef03e39d3861619fffc9a02a03ba8ea0446382b8f9a3c1323c5b5d77b93f259;
  kernel0bd09824be91b59c613ce9eda92cc242f90ec5c8d91275ba84d37f30f3e24858;
  bridge0b6dab70d7b2bf953efe5337d9a3ee98c7a4a90c653288c85e2cc9d4badd9b51;
  test unchanged b874b3fe...1979a. Known shim/DTB unchanged, payload roundtrip
  PASS. QEMU /home/kirill/t290-local-kernel/qa0139/with-root.
- New SD request8ops STAGED, old0137 GETs recovered first. GET old current
  library/test/trace/capture/log into dl/k-t290-0139/before, PUT new bridge/test
  plus marker0. Full84601858B readback PASS SHA
  76df46da5d162e2b25f8521e18d219a3382621070007cd0df421208d4fa3865b.
  Do not stage another request before recovering these GETs after next boot.
- Next: manual iPadOS boot, nativeUSB
  collect for0139, verify guard, motion hook installation and sensor sender,
  delivered orientation transitions, actual rotation/lock/touch. Inspect SMP
  stacks if UI freezes. Do NOT claim60FPS or app/hang fixes yet.
- Local build helpers dl/t290-motion/*0139*; objects motion0139-objects,
  full link /home/kirill/t290-local-kernel/motion0139. Bridge build-motion0139.

### 0138 hardware observations and earlier investigation

- 0138 ACTUAL SENSOR PASS, AUTO ROTATION STILL NOT WORKING. Native USB
  boot ios-t290/usb-captures/0138/boot-20261023-184523-0138: probe0/id0x35,
  samples change with tilt; clients0 initially then1 after backboardd starts.
  User reports UI/power unresponsive, but native USB L/F and live samples
  continue. No observed panic in collected text; cause of UI hang UNKNOWN.
- Two separately labelled pose recordings under that boot's poses directory:
  vertical-20261023-190910 and horizontal-camera-left (latest timestamp).
  Contains some old queued logs; use final stable samples, not whole-record
  averages. Vertical tail seq34750/34875 mostly +X, horizontal tail seq35625+
  mostly +Y. Earlier inferred sign-only correction is NOT sufficient; verify
  mapping against these labelled poses before changing axes.
- Reverse inspection actual pristine backboardd: BKOrientationManager init
  matcher at0x100079fe4 looks for page0xff00/usage3, unlike current standard
  Sensor/Accelerometer3D service. CMDeviceOrientationManager supplies rotation;
  raw acceleration alone is not yet wired to this path. No0139 source/image.
  Local read-only extracted binary and metadata scripts dl/t290-motion.
- Found missing hang sampler startup: sweet_sample_start called only from
  UFS/virtio, NOT sweet_sdhc SD root. Current sweetsample boot arg thus has
  no effect! Next kernel should start it in SD path and include SpringBoard
  in selected names. Userland normal orientation entry verified metadata:
  BKOrientationManager updateDeviceOrientation:changeSource: v32@0:8q16q24,
  DISPATCH_SYNC internally (never call it while holding input/manager locks).
  BKAccelerometerInterface processEvent:sender:dispatcher: returns q, arg2
  N^^{__IOHIDEvent}; ivar _lock_orientationManager offset0x20. Investigation
  only; no runtime hooks written. Preserve rotation locks if bridging it.

- User requested accelerometer-driven auto rotation; previous FPS/app task
  remains unfinished. Android ADB/root connected for read-only inspection.
- Recovery0137 installed with explicit approval; full64MiB SHA87100f2d...9ca576
  PASS. Native boot captured usb-captures/0137/boot-20261023-182250-0137 but
  collector drained early, insufficient guard/app evidence. SD update8/8 DONE;
  old GETs recovered to dl/k-t290-0137/before. No new SD request staged.
- Live sensor facts: KXTJ3, no gyro; msm8937/SoC354/MTP config bus4/0x0e/IRQ42,
  axes+Y,-X,+Z; FDT QUP0x078b8000 maps GPIO14/15, Linux bus disabled/SSC-owned.
  Persisted sns.reg contains matching KXTJ3 UUID and bus4/0x0e. All dumps
  dl/t290-motion outside git. See t290/motion/README.md for sources/limitations.
- Patch0138 adds opt-in bounded open-drain I2C and standard HID accelerometer
  service: checks WHO_AM_I before configuring25Hz +/-2g; restores pins on
  probe failure, stops after5 read errors. No rails/DSP commands. Actual
  sensor readings, iPadOS subscriber/matching and AUTO ROTATION NOT VERIFIED.
- Three ARM64 objects compile PASS, full relink exit0, patch reverse-check
  PASS. Final recovery SHA df03715d488c8216e7cb9c9f3b03d1610286acb84f7af6f7140d5c6f8acba979,
  kernel d046989990213a73aaf78143aa43553cd5b673abca9a3cee6e9e56b6d0d41c8d.
  Payload roundtrip PASS, shim/DTB unchanged. Graphics identical0137; only
  kernel needs testing. t290accel=1 opt-in boot arg, omitted under QEMU.
- Final QEMU60s PASS: /home/kirill/t290-local-kernel/qa0138-r1/with-root,
  result no_panic_observed/unknown_glyphs0, PID1 running plus6 still-alive
  messages. Sensor disabled in QEMU; NOT physical sensor or UI validation.
- 0138 INSTALLED after explicit user approval (2026-10-23). Guarded
  flash-0138.ps1 -WriteApproved exit0; full64MiB partition SHA256 readback
  df03715d488c8216e7cb9c9f3b03d1610286acb84f7af6f7140d5c6f8acba979 PASS.
  Previous0137 fullbackup retained in ios-t290/backup-20261023-accel0138.
  No reboot command sent. Next manual iPadOS boot with USB; collect via
  dl/t290-motion/wait-collect.py. Actual sensor and auto rotation pending.
- Helpers dl/t290-motion/{build.sh,relink0138.py,pack0138.sh,qemu0138-r1.sh,
  make-patch.py}; objects /home/kirill/t290-local-kernel/motion-objects, full
  link /home/kirill/t290-local-kernel/motion0138. Needs native USB collector
  for new0138 boot; first verify WHO_AM_I and samples/subscriber count, then
  confirm axes in known poses and trace userland orientation as needed.

### Earlier FPS/app observations (hardware retest pending)

- User explicitly postponed remaining UI effects/Metal and wants faster UI
  and apps to stop closing. Also explicitly dropped clock changes: DO NOT
  spend further work on matching Android clocks. Safari hangs; Preferences
  and MobileSlideShow abort immediately. Device last iPadOS/COM7. Earlier
  Android request for clocks is obsolete; no need to collect DVFS tables.
- Unfinished function45/28 work preserved outside git in
  dl/ca-passes2/wip-saved/{effects45-28.patch,source copies,state.json}; only
  compiled, no pixel tests, NOT installed. Restored sources to ca-passes1
  before the FPS/stability edits. Current installed version still ae5e269.
- Fresh native USB logs appended012..016 to same ca-passes1 boot folder.
  Native UseProgram GL_INVALID_OPERATION grows to256; added bounded shader
  compile/link failure logs to identify missing shader semantics. No new
  library installed. Current capture marker2 expensive; use marker0 for next
  performance test, retain guard. Bridge fps counter counts scanout-like GL
  flushes, NOT actual panel frames (reports~128 while panel~16). Suspect
  excess full-screen flush waits; synchronization change NOT implemented.
  Actual panel conversion~4.64ms, no demonstrated60fps yet.
- Concrete repeated failure at app transitions: client-memory137x137,
  pitch576, explicitAllocSize0 ->BadArgument. New patch0137 treats zero as
  automatic size like omitted size, while positive short lengths still fail.
  Host actual-layout ASan/UBSan PASS including137x137/78912 and short78911.
  Hardware guard changes BGRA client case to explicit0; REQUIRES0137, do not
  install that test on0136. Surface single-file ARM64 compile PASS; full
  local relink client0137 exit0. No partition written or approval requested.
  Build scripts dl/{build-fps-stability1.sh,relink0137.py,pack0137.sh}.
  New recovery packing started; outputs dl/k-t290-0137. Next verify image,
  QEMU smoke and backups before requesting each recovery partition write.
  New boot args add sweetscan Preferences/MobileSlideShow and sweetsample
  MobileSafari/Preferences/MobileSlideShow/backboardd for real failure causes.
- Packing subsequently PASS (fixed CRLF in helper):0137 image67108864B,
  SHA87100f2dbc7e3eeec6744e5e3c5f353051b61ca9897d9b54e6670c9fa79ca576.
  Shim/kernel_dtb unchanged, payload roundtrip PASS. Kernelf4c5706b...bb360;
  bridge9a960676...7ce8; testb874b3fe...1979a. Not staged/flashed/boot-tested;
  no QEMU run yet. Source f8c2327. Clock work explicitly cancelled by user.
- App crash symbolication: both SIGABRT uncaught C++/ObjC terminate through
  libdispatch. Photos stack includes PhotosUICore px_rootAlbumCollectionList;
  Settings includes FBS serial queue. Reasons not captured yet; do not claim
  surface fix establishes their cause. Crash slide0x2fc88000. Reader remains
  dl/gli/mapped_query.py, readonly cryptex mounted /home/kirill/sysos.

- **ca-passes1 BOOT VERIFIED, real GPU PASS ES2+ES3.** New request8/8;
  all five missing-program pixel/state cases pass in both APIs, testexit0,
  guard enabled Mesa. Backboardd hook installed with protection0, UUID/slots
  matched. Native primitive draw10 confirmed function20, replacementprogram8;
  output now alpha0..255 with10991 nonzero pixels (RGB0: intended alpha mask),
  versus allzero prior0136.112/112 capture records decoded,0 rejected.
  Live boot folder ios-t290/usb-captures/ca-passes1/boot-20261023-174248-0136-ca-passes1.
  Initial collection caught early xfer; append logs002..011, latest complete
  frame frame-174637.png. Home still black with purple text/white widgets.
  New native programless function45 atdraw43 (FBO1/800x1280, source15/2x62)
  and28 atdraw66. Function40 explicitly reports unsupported0. These remain
  unimplemented; no blanket copy/recolor applied. Device is now iPadOS/COM7.
  Current installed library/test hashes below; GET backups pending -Result.
  Source implementation committed/pushed ae5e269; working on next passes.

- **ca-passes1 USERLAND UPDATE STAGED, full SD readback PASS.** Android/root
  ADB appeared during work. Recovered old0136 request GETs first, complete8/8;
  files now in dl/k-t290-0136/before (old0135 capture/bridge/test/marker/log).
  Staged a new8op request: GET current0136 bridge/test/marker/capture/log
  into dl/ca-passes1/before, then PUT new bridge/test/marker2.84582914B,
  request SHA256 d8981a44e9755b78012299bb5cf176dbe565f7172b8bbb020d6adf5372f2dbcb.
  Script/results/manifests in dl/ca-passes1; keep launcher's test guard.
  Recovery unchanged0136. Requested user manual iPadOS boot; Android at
  staging completion. Recover new backup GETs with -Result before next update.
- **New implementation:** native CA draw/uniform hooks restricted to
  backboardd, exact16.7.16 UUID +4 original vtable pointer checks and private
  COW page. Shader replacements ONLY program0 functions89(textured) and
  20(premultiplied color matrix), native context-scoped parameters and safely
  read live vertex matrix. Preserve GL program/texture/arrays/blending state;
  skip feedback/unknown/missing parameters. function_supported result not
  changed, so remaining unsupported effects still need implementation.
  Capture reserved2 adds function+1; refusal/skip reasons logged.
- **Validation:** local Linux software-Mesa ACTUAL ES2.0 and ES3.0 pixels
  PASS for shipped shaders:4 color/alpha quadrants, pixel coords, color matrix
  columns/bias/clamp and clip transform. New real-device guard additionally
  covers copy, live-matrix change without GL uniform upload, matrix pass,
  feedback, unknown-op skip and program/unit/attribute state restoration.
  Hardware execution/UI improvement NOT yet tested. Local ARM64 iOS builds,
  237 GLI signatures and ad-hoc signature/entitlement validation PASS.
  Bridge547200B SHA ce9413da73c39b78944727e7931192178a4e158bca303b9faf2eb6ba7b32fafd;
  test87344B SHA ecfa3566cae1390138aa55a4b68ddbdb94fb9340629ac51a9e8272ddd57c3cd9.
  Sources/build-info retained in /home/kirill/t290-toolchain/build-ca-passes1.
  Next: drain USB on new boot; verify8/8, guardexit0, hook installed, native
  programless IDs and replacement outputs, then compare full screen. Do NOT
  claim background/text fixed from host tests alone. Content first, FPS next.

- **0136 BOOT VERIFIED.** Native USB capture in
  `ios-t290/usb-captures/ca-address1/boot-20261023-164443-0136`.
  SD request consumed8/8; new eagltest exit0 with real FD504 pixels in
  ES2+ES3, including original client pixels,480/512 strides, CPU updates,
  GPU publish/padding and immutable mappings. Guard enabled Mesa.
  User and screenshot confirm icons now visible, but background missing,
  text purple and broad UI defects remain. Source42/46/48 contain nonzero
  color+alpha, unlike zero-filled0135 inputs. No full UI fix claimed.
- Fixed capture decoder: concatenate USB log slices before splitting lines.
  A64KiB L packet can cut CAPDATA midline. Actual capture now143/143 valid
  records,0 rejected; fixture tests every text byte split and rejects missing
  chunks. Isolate boots; sequence IDs restart. The old SD backup GETs were
  subsequently recovered before staging ca-passes1 above.
- Concrete remaining failure: primitive draw10, FBO5/255x153, program0,
  nonempty input texture7, all-zero output. Purple already exists in an
  uploaded bitmap, so blanket swizzling/recoloring would be unjustified.
  Investigating missing CA GLES functions against pinned HackiOS source
  and our actual16.7 QuartzCore UUID9e40b2eb260c3af1ae45a1a551a8c1b9.
  Local readonly DSC restored via apfs-fuse at /home/kirill/sysos.
  Verified GLES vtable1d57df6e8; draw_elements slots1d57df7f8/1d57df800,
  targets1884316d0/18838591c; uniform slot1d57dfa80->1884321ac.
  Context+0x10 then state+0x10 function word matches actual disassembly.
  Subsequent rendering update prepared/staged above, not yet boot-tested.

- **RECOVERY0136 INSTALLED — user explicitly approved ("разпешаю").**
  Ran guarded `ios-t290/backup-20261023-gpu0136/flash-0136.ps1 -WriteApproved`.
  Confirmed SM-T290, recovery=mmcblk0p57/64MiB, current0135 hash, backup hash,
  local and device0136 image hashes before writing. dd64/64MiB +sync PASS.
  Full partition SHA256 readback PASS:
  a21119db2806b2b6f7cbd675c9bc940a32e981fcc1bfac7bd6008fdd8c222914.
  Result `ios-t290/backup-20261023-gpu0136/flash-0136-result.json`.
  First0136 boot and SD backup recovery subsequently completed above.
  Continue manual recovery-menu boots (avoid adb reboot recovery due known
  LK/misc loop). Preserve this recovery while testing the userland update.

- **0136 BUILD/PREPARATION (completed before approval above).**
  Image `dl/k-t290-0136/recovery-0136.img`,64MiB, SHA256
  a21119db2806b2b6f7cbd675c9bc940a32e981fcc1bfac7bd6008fdd8c222914.
  Copied to Android `/data/local/tmp/recovery-0136.img`; device SHA matches.
  Current recovery0135 hash d2ef0bbf... matches expected. Full64MiB backup
  `ios-t290/backup-20261023-gpu0136/recovery-before-0136.img`, same hash.
  User approval subsequently received and this image installed above.
- New kernel SHA6cb414adb3b8f5c20f1893c45b45932a34b73e636ae7f6ccf8b90c34e4eeb056;
  bridge41ec7ae792a114cf597015d705aaaf34d252a672fd44c9b184f74ba722fea1b6;
  test e9817a6843586fd0069d6122add94a6cc94ad895d72f7d507826f107d9315c7f.
  Same known0135 shim, DTBs, payload ADT and complete boot arguments,
  includingcpus4/native800x1280/t290usb2. Payload/image round-trip PASS.
- **BUILD PATH:** GitHub dispatch refused HTTP422 "Actions has been disabled
  for this repository"; permission API still enabled:true, workflow active,
  repo enabled, admin:true. No new run created; retained39796561147 intact.
  Did not change settings/create another repo. Instead built ld64-956.6
  cctools-port904de2a71d4da6a9b30d2efaf912a10ddc7d9ddb in WSL. Reused
  verified0135 archive, replaced SweetSurface/SweetGPU/SweetFramebuffer.
  Built firehose from Apple libdispatch1415.140.2 cdb61e93e803, LLVM17.0.6
  freestanding profile runtime (raw version8 matches0135). Reused isolated
  original48B stack probe after disassembly verified internal branches only.
  Apple binary inputs/support blob remain OUTSIDE git. Full recipe/logs in
  dl/ca-address1/{build-host-linker.sh,build-support.sh,relink.py,pack-image.sh};
  native tree /home/kirill/t290-local-kernel; original source tree fps0135.
  All local compiles MUST use -mcpu=cortex-a53, NOT only -march=armv8-a:
  Linux clang defaults macOS arm64 to Apple M1 and can emit LSE regardless.
  Initial QEMU caught a firehose CAS; fixed flags and rebuilt. Profile runtime
  also uses -mgeneral-regs-only. Link succeeds with no undefined symbols.
- QEMU final Cortex-A53/1CPU/90s: no_panic_observed,0 unknown glyphs,
  reached load_init_program attempts. NOT evidence PID1 or UI completed.
  Original0135 control30s also no_panic, still at Skywalk tests. Logs/screens
  in /home/kirill/t290-local-kernel/qemu-*-20261023. Real GPU tests NOT RUN.
  Actual layout ASan/UBSan tests PASS; after one host-ASan startup SIGSEGV,
  fixed host executable to non-PIE and repeated3/3 PASS. Three kernel files
  compile to objects PASS; bridge221 GLI/signature checks PASS.
- **SD REQUEST STAGED8ops, not consumed:** GET current bridge/test/marker/
  capture file/log FIRST into dl/k-t290-0136/before; then PUT new bridge,
  new test and marker2.84580866B, full readback PASS, SHA256
  c00a107e8682b620538bbde0f42741e304669811996b21dceb30ac0e64999154.
  sd-staged.json/xfer-manifest.json saved. Keep existing t290launch guard.
  New tests require0136; booting0135 with them should fall back to CPU.
  After approved flash, verify full partition SHA then user manual boot;
  drain USB L immediately, inspect client-memory alias/publish/readonly
  cases in ES2+ES3 and exit0. Only then judge actual UI and captured pixels.
  Recover GET backups with -Result on Android before replacing request.
- Latest13:22 USB logs decoded separately (new boot/cursor replay, no mixed
  record IDs): dl/ca-capture1/decoded-live-132254,67 valid records, again three
  all-zero120x120 source images32-34. Creation properties still unknown, so
  IOSurfaceAddress remains a candidate visual cause, not a proved UI fix.
  Android pstore saved ios-t290/logs/ca-capture1-return/dmesg.bin; no new
  panic line observed in this tail. Prior zero-time fault remains unresolved.

- **0136 CLIENT-MEMORY IMPLEMENTATION (not installed).** User requested a
  new version using the other-port findings; Android/root ADB connected.
  Recovered ca-capture1 SD backups with -Result: done5/5, previous bridge,
  marker and log saved in dl/ca-capture1/before. No pending unconsumed PUTs.
  New patch0136 maps/pins IOSurfaceAddress, preserves caller pitch/size,
  refuses undersized/unsupported ranges, maps a unique user alias, supports
  read-only providers, balances prepare/complete and task lifetime. SweetGPU
  selector9 identifies wrapped/read-only surfaces; direct GPU import of them
  is refused. Bridge uses owned aligned backing, seed updates and row copies;
  immutable sources cannot be render targets. No blanket format0 swizzle.
  Actual layout function host test under ASan/UBSan PASS; local cross-compile
  SweetSurface/SweetGPU/SweetFramebuffer PASS3/3. ARM64 bridge/test builds,
  221 GLI signatures and code-signature checks PASS. Hardware regressions
  add original-pixel preservation, unaligned480/512 rows, CPU updates,
  read-only source surviving original unmap, GPU publish and padding guards.
  They have NOT run on tablet. Full kernel/image build next; guard retained.
  Requires new recovery, which must be prepared/verified before asking the
  user to approve its partition write. Current device remains0135/capture1.

- **OTHER-PORT REVIEW + LIVE CAPTURE (2026-10-23).** User asked to research
  other iOS phone drivers. Read pinned HackiOS userland906425b75e02 + kernel
  8e61187098f2, NativeAdreno b686b9054f57; see eagl/REFERENCES.md for URLs,
  compatibility findings and next implementation constraints. Source blobs
  verified; remote build scripts/binaries NOT run. No borrowed code copied.
- Found a concrete gap: kernel SweetSurface layout/create ignores
  IOSurfaceAddress and always allocates/zeros new pixels. Other port maps
  the original client memory. Live captures of format0,120x120 inputs32/33/34
  are entirely zero, including RGB and alpha. Need verify their creation
  properties or test the address contract before claiming root cause.
  Fix requires preserving client pitch/size/lifetime, handling noncontiguous
  GPU memory (or a padded copy), and appropriate alpha-first conversion for
  wrapped inputs. Do NOT reinterpret every format0 GPU scratch target.
- Device was already iPadOS while researching, so drained live USB at
  ios-t290/usb-captures/ca-capture1/boot-20261023-131003/. Request done5/5,
  eagltestexit0, capture enabled. All received USB packets complete inclF.
  141 CAPBEGINs;69 checksummed records decoded,72 rejected. Inspection of
  CAPDATA lengths (~239B maximum) shows kernel MESSAGE truncation despite
  complete USB packets, not evidence all those records had USB drops.
  Valid kinds:37 state,15 draw,14 upload,3 source inputs. Decoded manifest
  dl/ca-capture1/decoded. Old records cannot distinguish clears from actual
  primitives: a program0 record alone does NOT prove a program-less draw.
- **CAPTURE2 BUILT, NOT STAGED.** Chunk180 (was760); shader log chunks160
  (was600). Added operation tags for primitives/clear/blit. Parser understands
  tags, older records remain unknown. 211GLI ABI/ARM64/iOS16/signatures PASS,
 10s. Fixture proves180-character chunks survive256-byte truncation and
  clear/primitives metadata is decoded. Artifact dl/ca-capture2 bridge
  f7a129cda8545b98197c9414150f0db6d4adcccfa8853e00fa4836e6fe9f9b0c;
  test unchanged8a957c2c..., current device bridge d3d4f9da... marker2.
  No rendering workaround enabled. Current SD request consumed but -Result
  backup bridge/marker/log still needs Android recovery before overwriting.
  Priority next: investigate/fix IOSurfaceAddress, using other port as a
  reference; do not repeat generic passed pixel tests or blindly swap A740.

- **CA-CAPTURE1 STAGED (2026-10-23), awaiting manual iPadOS boot.** Android
  root ADB ready. cpu-icons1 request confirmed done3/3, old test/log GETs
  recovered. New request: backup bridge/marker/log GETs first, then ONLY
  bridge d3d4f9da... + marker2 PUTs.5ops,50926594B; full SD readback PASS.
  Request SHA256 699bb64ead8cf4b150665c4d8a907ce20d0c2600b6ef7ea46ccdb7c1f6ed141b.
  dl/ca-capture1/sd-staged.json + xfer-manifest.json. Code7355d35. Existing
  test8a957c2c..., Mesa, recovery0135 and clocks unchanged. Guard must PASS.
  Saved pstore at ios-t290/logs/cpu-icons-return/; no panic line found in
  these saved tails (does not establish stability fault fixed).
- NEXT: after manual boot immediately drain USB L (64+ replies if needed,
  retain incomplete wire/text), collect F, decode CAPBEGIN/CAPDATA with
  t290/eagl/decode-capture.py --logs LOG_DIR DECODED_DIR. Use ONE BOOT per
  log folder: record numbers restart in each process/boot. Watch for
  "real compositor capture enabled" and CAPTURE/CAPBEGIN; report missing
  records from stream-status.json. Inspect actual source/alpha/FBO outputs
  before choosing a workaround. No visual correction established yet.

- **CPU-ICONS1 REAL GPU PASS (2026-10-23).** USB COM7, xfer done3/3.
  Both ES2/ES3: format0/inferredRGBA and BGRA, stride512, rounds0/1,
  all4 quadrants including alpha match exactly:32 samples, error0. Guard
  exit0 enables Mesa. Captures ios-t290/usb-captures/cpu-icons1/: initial
  logs0/1/2 complete; early F is console, NOT UI. follow0 complete, follow1
  missing1024 bytes (raw retained). screen-follow.png is actual lock screen,
  still black with purple "Press home to open". No UI fix found. Captured
  paths show correct CPU->GPU updates and half attributes, not a whole-CA
  correctness proof. Stop adding generic tests; inspect actual passes.
- User asked what causes it: exact cause remains unknown. Next diagnostic
  captures real inputs/results instead of calling missing content a solved
  format/clock issue. Added opt-in capture.h, marker'2' (backboardd ONLY),
  15MiB/256-record file /private/var/tmp/t290eagl-capture.bin: bounded CPU
  TexImage/SubImage payloads with unpack layout/offsets, IOSurface input
  bytes, small-FBO post-draw RGBA readbacks, one completed surface1, GL
  blend/scissor state and uniform values. Restores pack/PBO/read-FBO state.
  Readbacks synchronize GPU and can hide ordering bugs; not a benchmark or
  rendering fix. Input IOSurface snapshots have no added producer fence.
- Same records compressed via Foundation NSData zlib, base64 CAPBEGIN/
  CAPDATA streamed into kernel/USB L log (2MiB encoded budget). Each record
  includes raw/packed size and FNV32; decoder rejects lost/corrupt records.
  File fallback remains if USB loses critical chunks. Drain up to64+ L
  replies until empty, preserve partial bytes, then:
  python t290/eagl/decode-capture.py --logs USB_LOG_DIR DECODED_DIR.
  Outputs capture.bin, manifest.json, stream-status.json, raw payloads,
  RGBA/alpha PNGs, uniform/state values. Inspect first disappearing/empty
  stage, do not infer cause from a test PASS alone.
- **CA-CAPTURE1 BUILD (now staged above).** Local ARM64/iOS16/code-signature pages/
  test entitlements/211 GLI CALL signatures PASS,10s. New decoder fixtures
  PASS: paddedBGRA, A8, float16, GLstate, signed coordinates, truncated tail,
  corrupt header; zlib framed/raw USB streams, missing chunks and bad FNV.
  /home/kirill/t290-toolchain/build-ca-capture1 and dl/ca-capture1/.
  Bridge d3d4f9da80fb1523b3bafb6767b72e0b947c30a64363174dff8f63de91606153;
  test unchanged8a957c2c..., marker trace-marker.txt contains2. Capture mode
  itself has NOT run on tablet. Current installed bridge009be071..., marker1.
  ADB absent (tablet iPadOS). Next Android: -Result cpu-icons1 request to
  recover old test/log; back up current bridge/log/marker and stage ONLY new
  bridge+marker2. Full SD readback, manual boot, immediate robust USB L drain
  and F snapshot. Keep existing eagltest guard; no recovery/Mesa/clock change.

- **2026-10-23 CPU-ICONS1 STAGED, awaiting manual iPadOS boot.** Android root
  ADB ready. ca-half1 request confirmed done5/5; previous bridge/test/log
  backups recovered. New request ONLY puts test c46d0b4, with old-test/log
  GET backups scheduled first to dl/cpu-icons1/before. Three ops,33682768B;
  full SD readback PASS. Request SHA256
  13e9daa569dd1d07c11a5db72f1cd71bc34422901a7f9bf08fb1bbd23682f521;
  test8a957c2c0bf4761f9087e16297a847759af5afafe03dfac334d2ce4218b3578d.
  Manifest dl/cpu-icons1/sd-staged.json + xfer-manifest.json. Recovery0135,
  Mesa, bridge009be071... and trace marker unchanged. Next manual boot:
  immediately capture native USB L/F; look for CPU icon inferred-RGBA/BGRA,
  stride512, rounds0/1, quadrants0-3 in ES2 and ES3, actual pixel values.
  Failure80-85 must keep guard CPU fallback; do not bypass. No UI fix claimed.
- Saved latest Android pstore ios-t290/logs/ca-half-return/{console,dmesg}.bin.
  Non-monotonic time last_dispatch0x2d3d1368b ctime0, sched_prim.c796, CPU3.
  Another occurrence of the unresolved zero-time fault; not fixed by tests.

- **2026-10-23 CA-HALF1 HARDWARE PASS.** User in iPadOS, native COM7.
  ca-half1/log0 USB packet missing512 bytes, raw/text preserved; log1-4
  complete. Xfer5/5 consumed. All four half-vbo48 and half-client48-indexed
  colors match within1 in BOTH ES2/ES3; test exit0, launcher enables Mesa.
  Full frame saved ca-half1/screen.{t290,png}, still black with purple text.
  Actual CA attrib0 float4, attrib1 half4 normalized, stride48, client memory;
  safe VM reads work, first colors(1,1,1,1). Later purple color is already
  in client data(~.12,.06,.12,.4), not proof of GPU color corruption.
  No captured post-call GL error or missing slot. Half vertices not culprit
  in covered draws. Does not establish texture pixels or blend correctness.
- User asked about matching Android clocks. Live CPUCLK cfg0x501, PLL mode7,
  L0x59: sourceA53, div1, 89*19.2=1708.8MHz; 4/4 cores online. GPU logged
  400MHz. Stock fdt.dts cpufreq table ends0x1ec300kHz=2016MHz; GPU bin0
  max0x26be3680=650MHz (other bins lower). Full Android-like DVFS/CPR/thermal
  policy absent. CPU boost path raisesS5 to885mV; GPU only200/400GPLL0dividers
  currently supported. Do not change just a frequency constant or report
  max table values as actual live clocks. No clock/recovery changes made.
- **CPU ICON TEST (now staged above):** CPU-written real icon surfaces 120x120,
  format0/inferredRGBA and BGRA, actual kernel512-byte rows, quadrant colors
  + alpha, two CPU updates while keeping the same GPU import bound. Prior
  CPU-update coverage was padded LA08; row-layout tests primarily GPU writes.
  This tests direct imports/cache visibility before a workaround is chosen.
  211 GLI calls ABI PASS, ARM64/iOS16/signature/entitlements PASS,10s local.
  /home/kirill/t290-toolchain/build-cpu-icons1, Windows dl/cpu-icons1/eagltest
  SHA256 8a957c2c0bf4761f9087e16297a847759af5afafe03dfac334d2ce4218b3578d.
  Bridge hash identical to installed009be071..., no new bridge needed.
  Next Android: -Result currentca-half1 saves old bridge/test/log; stage
  ONLY this test with backup GETs, full SD readback, manual boot+USB log.
  Guard remains enabled. No workaround or UI/FPS improvement claimed.

- **2026-10-23 CA-HALF1 STAGED, awaiting manual iPadOS boot.** Android USB
  enumerated but ADB initially absent; restarting server with ADB_LIBUSB=0
  restored root connection. Previous ca-color1 request confirmed done3/3;
  its old-test/log GET backups recovered. Staged ae44121 test + diagnostic
  bridge (hashes below), with GETs of current test/bridge/log BEFORE PUTs.
  Five ops, 50995232 bytes. Full SD readback PASS; request SHA256
  dd819329e1dda04f13c4353d988447085e51e8fcee3548088fd035d02878f317.
  Manifest dl/ca-half1/sd-staged.json, saved xfer-manifest.json. Recovery0135,
  Mesa and trace marker unchanged. Next boot must execute guard; immediately
  drain USB L and collect F. If pass, inspect actual CA attribute client
  bytes/type/stride and post-call errors; if failure, preserve failing pixels.
- Latest Android pstore saved ios-t290/logs/ca-color-return/{console,dmesg}.bin.
  Another recount.c414 zero-time panic on CPU2 (0 >= 0x396b87a31). Confirms
  stability problem is not confined to CPU0; no timer workaround applied.

- **2026-10-23 CA-COLOR HARDWARE PASS; EXACT CLIENT FORMAT READY.**
  USB ca-color1/follow-0.txt: constant colors, normalized-u8 colors and
  offscreen composition all match expected pixels in ES2 and ES3, error0,
  test exit0. t290launch enables the bridge. Screenshot ca-color1-live/
  screen.png still shows white widget blocks, missing icons and purple text.
  New live log0/1 complete; log2 missing1536 bytes, preserved raw. No fix yet.
- Disassembly of the installed CA GLContext::init_client_state (0x18843647c)
  shows position4f offset0, color4 half-float (0x140b), normalized1 offset32,
  texcoords2f offsets16/24, stride48, including client-memory arrays. Do not
  mistake previous u8/VBO-only tests for coverage of this path. New tests
  add half-vbo48 and half-client48-indexed, four colors each; not yet run.
- Added bounded attribute state/constant/client-byte tracing. Client bytes
  use vm_read_overwrite, never an unchecked dereference; only trace marker
  enables it. Fixed post-call checks to use actual *_ARB GLI names for
  vertex pointer/enable (previous unsuffixed names matched no adapters).
  No driver/precision workaround enabled.
- Local build /home/kirill/t290-toolchain/build-ca-half1 PASS (8s): ARM64,
  iOS16, code signature pages and entitlements; 200 explicit test CALL ABI
  signatures verified. New checker rejects intentionally wrong DrawElements
  slot66 (correct67). Generated attribute error checks verified.
  Windows artifacts dl/ca-half1: bridge
  009be0719bbd0a940ff7e172a8cdc9fefbe86b5703fa0fa2d0885e88b4274d65;
  test b0155069081460370001a9a42ec96f22de39d0c1a5d18599c24b0db4b18cfa43.
  Staged and verified as described above. Manual boot must run these tests
  before enabling the bridge. Keep t290launch guard intact.
  No recovery/kernel/Mesa changes or destructive-write approval needed.

- **2026-10-23 CA-COLOR TEST READY, content priority unchanged.** Added
  test_ca_color: CA-like highp matrix/position + lowp color varying,
  constant vertex colors and normalized interleaved u8 attributes (white,
  green, mixed RGB and half alpha), then GPU offscreen-FBO->texture->FBO
  pass. GLI active_texture slot checked as 342 (not 374); matrix620,
  vertex_attrib4f485, buffer_data646. Returns 70-76 with actual failing
  samples logged. Existing guard must still check real pixels.
  Local ARM64 compile/sign/page hashes/entitlements PASS in 9s. Not yet
  executed on tablet. No established precision/driver fix claimed.
- User returned Android for installation. Previous trace request done 4/4.
  Staged ONLY eagltest (library, trace marker and recovery unchanged), with
  GET backups of old test/log to dl/ca-color1/before. Full 33682768-byte SD
  readback PASS; request SHA256
  1bb7aaf3d0186b06dd8c16968bc99cacdef04842223d1c5e216a89b5b24da944;
  test 3a7e192d25ffc6470cd6981697d85e43b212070494214cfa69361a4b78eba22a.
  Manifest dl/ca-color1/sd-staged.json. Next manual iPadOS boot + immediate
  USB L log drain and F screenshot. If guard fails, inspect CA color samples
  and do NOT bypass it. If tests pass, continue captured real-CA state tests.
- USB tooling now preserves PacketTimeout.wire; probe saves complete/raw
  packets and incomplete replies. Viewer also saves partial packets. Port
  selection filters stale registry instances against currently present
  SERIALCOMM names. Recorded full 3072064-byte frame with 7777-byte chunks
  PASS; known partial log retains all 64576 bytes and raises timeout PASS;
  Android does not select stale iPadOS COM7 PASS. Python syntax check PASS.

- **TRACE RECOVERED (2026-10-23):** first USB L block timed out and was not
  retained by the initial strict reader. Returned Android pstore recovered
  diagnostic sources/state: ios-t290/logs/elements-trace1/{console.txt,trace.txt,
  console-ramoops-0.bin}; 441 selected lines. SD trace request done 4/4.
  Recount zero-time panic repeated (0 >= 0x171dc4e82). No visual fix yet.
- User rebooted iPadOS again. Saved USB logs robustly, including incomplete
  raw packets, at ios-t290/usb-captures/elements-trace2/. log-2 is missing
  1024 bytes; log-3 is a complete 65600-byte wire packet with 407 TRACE
  markers. Complete 3072064-byte frame.raw/frame.png captured.
  Home screen: white widget shapes and dock visible, icon content missing,
  text dark purple. This is not just a lock-screen interaction problem.
- Trace: no GL errors/missing slots seen, viewport and color write mask
  plausible, level-0 textures defined with max level 0 (except real mip
  chains max8/9). Actual CA shaders use lowp vertex_color varying,
  vertex_matrix, texture transforms and multi-pass composition. Alpha
  shaders explicitly read t0.a, so the earlier raw ALPHA expectation fix
  does not itself explain remaining UI loss. Need targeted CA-like tests
  for vertex-color/normalized attributes/matrix and intermediate passes.
  Mesa 24.2.8 has FD_MESA_DEBUG=nofp16 and IR3_SHADER_DEBUG=nofp16 for a
  controlled precision experiment; NOT enabled or verified yet. Do not
  state precision lowering is the established cause.
- User asked whether switching to a custom Metal driver would help. Current
  tree has no Metal backend; long-term GPU.md already mentions AIR->NIR->ir3.
  This is a separate API/compiler/resource/submission project. Preserve
  current content-first work unless the user explicitly switches scope.

- Latest return-to-Android pstore saved ios-t290/logs/elements-usb-return/
  console.bin: recount.c:414 assertion lhs->rsn_time_mach >= rhs->rsn_time_mach,
  0 >= 0x24f4072ff, CPU0. Confirms a second zero-time snapshot panic; USB
  disconnect was followed by Android. Keep content-diagnosis priority, but
  capture next trace early before this separate stability fault recurs.

- **PRIORITY CHANGED BY USER: restore missing content first, FPS later.**
  Last A8-corrected boot passed ALL real ES2/ES3 pixel tests including white
  glyphs, ASTC, float layers. t290launch injected backboardd; GPU UI active.
  User reports widespread disappearing content, not just individual icons.
  Raw logs ios-t290/logs/a8-fps1: bridge flush rates vary 4.6-112.2/s and are
  NOT panel FPS. GPU waits 1.8-4.7 ms; kernel convert ~4.2 ms. Long intervals
  outside GL include idle/display-off, not proven pure CPU rendering cost.
  Kernel also panicked: Non-monotonic time last_dispatch 0x164c9d216 ctime 0.
  Investigate separately; do not hide the panic/assertion or claim FPS fixed.
- **USB NATIVE FRAME CAPTURE NOW WORKS on current 0135.** Live COM7,
  high speed, config 1, errors 0. Header-only 64-byte host reads timed out on
  large frames; changed viewer.read_packet to large reads + buffered parsing
  and increased SetupComm input queue. Raw complete 3072064-byte frame in
  0.221s and probe complete 3072000-byte payload in 0.25s, 800x1280,
  stride2400 shift229. Screenshot proves mostly black lock screen with
  purple status/bottom label; no need ask user for another example screen.
  Files ios-t290/usb-captures/elements-raw/frame-0.{raw,png}, elements2/*.png,
  live-log*.txt. A later multi-frame attempt found device back in Android;
  do not claim sustained viewer stability from these two complete frames.
- **NEXT DIAGNOSTIC STAGED:** local bridge with bounded shader/program,
  uniform-name and texture/draw state trace; marker file beginning '1'.
  Trace disabled in eagltest, enabled only backboardd. Does NOT claim visual
  fix. Existing corrected test/guard preserved. Local compile/sign/page hash
  checks PASS. SD request 4 ops: backup bridge/log, install trace bridge +
  /private/var/tmp/t290eagl.trace. Full 34126850-byte readback PASS; SHA256
  9b3c5e8da47779cc4f9f1e3d6631a63911185253abe7a8a02aa7bac229c7e91f.
  Bridge ca4c4b6ee2ced72a72717480d720154f9a9329afa2576ee84d998349e3477918.
  Manifest dl/elements-trace1/sd-staged.json. Waiting manual iPadOS boot.
  Next immediately drain USB L logs repeatedly while capturing F frames.
  No kernel change or flash. '0' marker disables trace next boot/daemon start.

- **NEW HARDWARE LOG cloud-bgra1:** SD cloud update done 4/4. BGRA raw
  and alpha blend now PASS (128,0,0,128 / 128,0,127,255), confirming mip fix.
  Next failure was A8 raw sample 0,0,0,128, GL error 0, eagltest exit 52;
  launcher again correctly used CPU/system renderer. Raw log saved at
  ios-t290/logs/cloud-bgra1/console-ramoops-0.bin and console.txt.
- **A8 TEST EXPECTATION WAS WRONG, not an observed A8 driver fault.**
  GLES2 spec table 3.12 says ALPHA returns (0,0,0,A). Old test expected
  (1,1,1,A). Corrected expected raw mask and added separate white-ink shader
  checks, with/without premultiplied alpha composition (no guard bypass).
  Built/signed locally in 9s; ARM64/iOS16/page hashes/entitlements PASS.
- Preserved requested CLOUD bridge. Staged ONLY updated eagltest plus GET
  backups of old test/log to dl/a8-testfix1/before. Request 3 ops, full
  33666256-byte SD readback PASS. Request SHA256
  210a5e43a4a270cec99e7c34a26117f62a054b587cb9dab43f0683e7d074c5b2;
  test a7a14c6bedd2b7b20aff600a4bdb05c41b1b7f1a94cfc7ce02fa9021a91a75c1.
  NOT consumed yet; next manual iPadOS boot. Real pixel results for this
  corrected test still pending. No kernel or bridge write this turn.

- **USER CHOSE CLOUD BUILD FOR TABLET.** Replaced the unconsumed local
  request (state 0, 0/4) with cloud artifact from run 39796561147.
  SD request 4 ops: backup existing bridge/log to dl/cloud-eagl-bgra1/before,
  PUT cloud t290eagl.dylib and eagltest mode 755. Full 34233456-byte request
  readback PASS; SHA256
  e4172f9b4e2253463c1c1c2fbad9b3cd301042a6160e69ebc9a0dba1d738726b.
  Cloud bridge SHA f801ad5756a96b6a9ac06dc9dc1ee7f536dfc88203461e0bd303f8f5e3d49b84;
  test SHA 5dcd88489c959aa0a4d06adb9b79f86c3368c6a5213754740764a24786d5b440.
  Exact manifest dl/cloud-eagl-bgra1/sd-staged.json. NOT installed in HFS+
  until next manual iPadOS boot. Recovery 0135 already installed; no flash.

- **LOCAL WSL BRIDGE BUILD WORKS:** clang 14 + ld64.lld-14 + iPhoneOS16.5
  SDK + Procursus ldid. See t290/eagl/LOCAL-BUILD.md; build-local.sh produced
  dylib/test in 8 seconds. verify-local.py passed baseline ARM64, iOS16.0,
  SHA256 code pages and signed test entitlements. gen_dispatch.py supports
  cached 975-slot GLI layout plus iOS/Mesa GL headers. Kernel full link and
  Mesa build still use macOS CI; do not describe all components as local.
- Local BGRA mip-fix files: dl/local-eagl-bgra1. Bridge SHA256
  fef0217bd0da15ef7274c4c7a867807697388fce289380a47d6fc1a2f462594f,
  test 06a78a8bfc4901e00d95a00f148ab3847cda57aec77ed3342353c0d7d3e48c00.
  Staged SD request 4 ops: backup old bridge/log, install local bridge/test.
  Full 34197200-byte raw SD readback PASS, SHA256
  1b90da4082bd6cb44311ad15f5803b5556d28707360ce656343d78397606b6f7.
  Request NOT consumed yet. Next manual iPadOS boot, read GPU pixel test
  result / t290launch injection status. No recovery reflash needed.
- Cloud run **39796561147** now both jobs SUCCESS (workflow finalizing);
  iOS bridge + Intel host Mesa + fake ES2/ES3 passed. Downloaded bridge
  artifact dl/cloud-eagl-bgra1 as independent fallback. Deleted predecessor
  39794145243 only after new kernel reupload; retain sole new run.

- BGRA mip fix committed **25b21dd**; new CI **39796561147** reuses kernel
  from 39794145243. Keep 39794145243 until new kernel artifact reuploaded,
  then delete predecessor. Do not flash recovery: installed 0135 is enough.
  Next download final bridge/test after CI; preserve old SD transfer result
  (already read), stage new bridge/test with backup/log GETs and full raw
  request readback, manual boot, inspect eagltest exit and real GPU pixels.

- **0135 ACTUAL BOOT: CPU fallback confirmed.** User returned to Android;
  raw pstore saved ios-t290/logs/boot0135-sensors. SD update done 4/4.
  Real FD504 ES2 passed clear/triangle, IOSurface aliases/rows, LA08,
  RGBA blending and partial mip chain. BGRA icon then sampled 0,0,0,255
  with GL error 0, eagltest exit 51. t290launch correctly launched
  backboardd WITHOUT bridge (system renderer). No measured GPU UI FPS
  for 0135. Fake CI PASS was not pixel validation.
- Fix in progress: mip metadata previously compared only internal token
  plus dimensions. RGBA and BGRA uploads both used GL_RGBA internal but
  can select different Mesa storage, leaving incompatible mip levels.
  Track external format/type as well and clamp before incompatible levels.
  Existing real regression reuses the texture across this exact transition.
  Needs CI and real-device pixel retest; do not bypass launcher guard.
- Read-only sensor reconnaissance: Android sensorservice reports KIONIX
  KXTJ3 accelerometer; no gyroscope in device sensor list. No driver work
  installed. User clarified immediate priority is CPU fallback diagnosis.

- **READY FOR HARDWARE BOOT:** run 39794145243 completed all graphics steps
  successfully, including native Intel Mesa and fake-GPU ES2/ES3 regressions.
  These do not validate real GPU pixels. Downloaded t290eagl artifact into
  dl/k-t290-0135/graphics-39794145243. Removed predecessor 39792400349 only
  after new kernel upload succeeded; 39794145243 is the retained run.
- Previous SD request confirmed done 2/2. Staged new request 4 ops: GET old
  bridge/log into dl/k-t290-0135/before, PUT final bridge to
  /usr/lib/t290eagl-mesa.dylib and eagltest to /usr/bin/eagltest mode 755.
  Full 34233456-byte raw SD request readback PASS, SHA256
  e2b95fa7da3739e7695ec6d28bc767a98e9695a0ab9fcea543aff0a09c516ff6.
  Not consumed yet: manual iPadOS boot required. Recovery 0135 installed.
  Next USB live capture; if returning to Android run t290-xfer.ps1 -Result.

- **CI update:** 39792400349 kernel reuse/upload SUCCESS, iOS bridge build
  and upload SUCCESS. Host Mesa libraries built, but optional glprobe failed
  compiling ARM-only watchdog registers on Intel. ecb3b26 adds x86_64
  thread-state sampling; diff --check PASS. New combined run **39794145243**
  reuses kernel artifact from 39792400349. Host ES2/ES3 tests still pending.
  Deleted superseded 39788991320 after kernel was safely reuploaded.
  Keep 39792400349 until 39794145243 reuploads kernel, then remove it.
  No new userland artifact installed and no hardware reboot/test yet.

- **RECOVERY 0135 INSTALLED (user explicitly approved this write).**
  Guarded write checked model SM-T290, 64 MiB partition size, current 0133
  hash, staged image hash and saved backup hash before dd + sync.
  Full partition SHA256 readback PASS:
  `d2ef0bbfea670ea53505e27993e63874d940df2fd9240f82e71e96b003e1a8a5`.
  Local result ios-t290/backup-20261022-gpu0135/flash-0135-result.json.
  Android remains running; no reboot issued. 0135 not hardware-boot-tested.
  Final graphics library still pending: run 39792400349 both jobs queued.
  Do not claim new bridge/mip fix installed. Next: complete graphics CI,
  stage bridge/test via SD transfer, then manual recovery boot and USB capture.

- **Latest verified state:** kernel job 39788991320 SUCCESS; downloaded kernel
  SHA256 `8dcd7c61581fbd18a4a3d5bd11cbe3d7f2ef25497815f8cb3d8cc79c4e5037f5`
  matches artifact SHA256SUMS. Repacked recovery-0135.img in dl/k-t290-0135,
  SHA256 `d2ef0bbfea670ea53505e27993e63874d940df2fd9240f82e71e96b003e1a8a5`;
  shim/DTB, ADT, bootargs, payload and Samsung footer checks PASS.
- Android ADB connected. Actual recovery backed up and device hash matched
  `51d3531b86f0412cb38820b5f13020b783a763a85128f15607708968aa1eb9ee`
  in ios-t290/backup-20261022-gpu0135/recovery-before-0135.img (64 MiB).
  No recovery partition write yet; 0135 approval still pending.
- Fixed combined workflow dispatched as **39792400349**, reusing verified
  kernel from 39788991320; both jobs initially queued. Keep predecessor
  until new build job downloads/reuploads artifact, then delete predecessor.
  Final bridge tests/artifact and hardware validation remain pending.



- **CURRENT sole Actions run: 39788991320 (67a1508), Intel, XNU Build still
  in progress at the latest user status request.** Its t290-graphics job
  failed linking the iOS bridge: new ld forbids interpose tuples in a dylib
  it considers shared-cache eligible. Commit 2cee828 fixes both iOS/host
  link lines with `-Wl,-not_for_dyld_shared_cache`; not rebuilt yet.
  Current kernel compilation is being allowed to finish, not restarted.
- Previous Intel run 39787534608 reached IIG but failed because the DXB
  Python venv is 3.9: Path.write_text(newline=...) is unsupported there.
  67a1508 uses open(..., newline=...) instead; that run is deleted and the
  full old log is saved locally as actions-cleanup/intel-kernel2-failed.log.
  The current run continues to use the same verified Xcode-15 IIG cache.
- Kernel and graphics now share one workflow run, with separate Intel jobs.
  Graphics builds its own host Mesa instead of querying deleted CI history.
  Once the current kernel job succeeds, download its xnu-kernel artifact,
  verify SHA256, and run the fixed workflow with kernel_artifact_run=
  39788991320 and kernel_artifact_sha256=<verified hash>, runner=macos-15-intel,
  sweet_board=t290. This avoids recompiling the same kernel for a linker
  flag fix. The reuse step checks unchanged xnu/patches + iig-cache.py,
  same DXB SHA and the supplied kernel checksum. After the new run has
  downloaded/re-uploaded that artifact, remove the previous run so the
  user's requested single-run history is retained. Do not delete the only
  remote kernel artifact before the new run retrieves it.
- If the current kernel job fails, inspect its actual compiler/linker errors
  and fix them; do not pass an incomplete artifact to the reuse path.
  No image/bridge staged and no partition written during this recovery.

- **Intel fallback now running:** XNU **39787534608**, commit 2dce1a2,
  `runner=macos-15-intel`, `sweet_board=t290`. Compatible-cache download and
  Fetch build script both PASS; last observed step Deps in progress. Preserve
  this as the sole Actions run. Old ARM run 39781091148 was cancelled and
  deleted, as was first Intel setup attempt 39787210982.
- New optional workflow runner/IIG cache inputs, tools/iig-cache.py. The
  wrapper reuses the Xcode 15-generated 34 DriverKit files only after all
  39 XNU interface source hashes match. Locally checked all 17 definitions:
  outputs byte-identical, changed input rejected. Cache SHA256
  `0ebc2a8416ac45cb43e3bd2aafc2f567bb86a32e7a11c3bfa751aaf65c8f41a9`.
  Separate draft release `ci-iig-8796` holds `iig-cache.json.xz` (58880 B),
  containing only generated OSS XNU source. No firmware/SDK/device data.
  Draft asset read requires job Contents:write; first Intel attempt had
  Contents:read and failed at cache retrieval before any compiler ran.
  The second attempt's cache download is confirmed successful.
- No new bridge artifact or kernel image has been downloaded/staged yet.
  Installed recovery remains 0133. Latest partial-mip bridge code is in git,
  but still needs building (prior bridge artifact excludes that last fix).

- **Latest user instruction: delete previous Actions runs, keep only one
  kernel build. DONE:** 94 runs inventoried in this fork, 93 deleted through
  the API; a fresh paginated listing contains only XNU **39781091148** for
  t290 (30c8e21). It was rerun, is still queued at last check, and must be
  preserved. EAGL 39781544025 was cancelled and deleted with the old runs.
  Do not launch extra separate EAGL/Mesa runs without accounting for this
  request to keep a single kernel-building run.
- The earlier final builds failed because GitHub did not acquire a hosted
  runner after multiple attempts, not compiler errors. Annotations explicitly
  report ARM macOS capacity constraints. Both had zero executed build steps.
  Rerun of the one preserved XNU run is pending. An Intel alternative was
  investigated, not implemented: XNU needs its compatible Xcode 15 IIG ABI;
  macOS fake-GPU Mesa artifact is arm64 and cannot be loaded by an Intel test.
- Necessary artifacts saved BEFORE deletion under `dl/actions-cleanup/`:
  `eagl-39780670625/` (passed prior bridge + test),
  `buildtree-39774877169/buildtree.tgz` (archive validated),
  `mesa-mac-39771029491/` (Mesa/glapi + build logs).
  `backup-sha256.json` records file hashes, and before/after run inventories
  plus the deletion log are retained locally. Old run links below now refer
  to intentionally deleted history. Recovery images/Android backups remain
  local. Installed recovery is still 0133; no new partition write occurred.
- Follow-up CI dependency: EAGL's mac-smoke currently looks up the latest
  successful mesa-ios Actions run. That history was removed as requested;
  a future combined build must build/reuse Mesa explicitly instead of this
  now-empty historical lookup. No workflow migration has been committed yet.

- User still reports missing icons/labels/keyboard, purple text or regions,
  broken rendering in some apps; wants both higher FPS and graphical fixes.
- Fresh Android pstore saved to `ios-t290/logs/fps-bugs1/`: same boot as
  `logs/b9/`. ES2/ES3 GPU pixel guard PASS, GPU clock 400 MHz. Bridge counters
  report 29.0/35.5/24.6/46.0 rendered-frame flushes per second over 300-frame
  windows; waits 3.1-5.3 ms/frame, no padded copies. These counters are not
  proof of panel FPS or correct UI. No GL errors/GPU faults seen in this log.
- Recovery read-back is still **0133**, SHA256
  `51d3531b86f0412cb38820b5f13020b783a763a85128f15607708968aa1eb9ee`.
  Prepared 0134 has NOT been installed. Previous SD request is done 2/2:
  old bridge log retrieved to `dl/k-t290-0134/before/eagl9.log`, updated
  647024-byte bridge installed. CI 39774871567 (EAGL) and 39774877169 (XNU)
  both passed for 7095860.
- New patch 0135 handles surface 1 through the same synchronous cached
  native presentation path as CA's other buffer. Previously surface 1 went
  through a deferred timer while CA could reuse it: a concrete race in the
  code, but whether it explains the reported artifacts needs a device test.
  Direct presentation clears a pending redraw and mutes the console too.
  Actual SwapEnd/convert timing now logs every 300 swaps for both buffers.
- Additional concrete graphics bug: display-off fade wrote into fPixels,
  the GPU shadow, destroying retained CA pixels. On T290 the fade now only
  changes the packed physical panel, under the USB capture lock. The GPU
  surfaces survive lock/unlock for subsequent damage-only redraws.
- Local XNU compile of the changed framebuffer source PASS (0/1 failures),
  buildtree `/home/kirill/fps0135`, based on cached source plus 0133/0134.
  Generator `t290/display/mkpatch.py` takes the post-0134 framebuffer source.
- EAGL changes: raw TLS context mirror (pthread key retains ownership and
  exit cleanup), no redundant Flush before Finish on a full-screen frame.
  New guard tests sample/blend real CA formats: RGBA/BGRA icons, A8/L8
  glyphs, RGBA16F intermediates, ASTC icons, all with a mipmapped filter.
  Draw tracking now also covers base-vertex/multi/indirect variants, and
  compressed texture replacements/updates participate in IOSurface tracking
  and GL error checks. Previously these could bypass the presentation wait
  or retain stale image metadata after replacing texture storage.
- Fixed another texture completeness bug: defining mip level 1 restored
  MAX_LEVEL=1000, so a partial chain (e.g. 4x4 + 2x2 but no 1x1) sampled
  black. Track each defined level's format/dimensions and clamp to the
  contiguous matching chain; generated complete chains retain their normal
  range. Guard adds partial-chain sampling and reuse across pixel formats.
  Whether CA's missing UI takes this path still needs a hardware capture.
  CI/device results for these new changes are pending; no FPS gain claimed.
- Initial commit a0cd21f pushed; XNU CI 39780060304 and EAGL 39780057223
  queued at the last check (GitHub macOS runners). Kernel source is locally
  syntax-checked; real GPU format/blend tests need the next tablet boot.
- Latest committed state: eec9482 adds the remaining draw/texture hooks;
  **EAGL 39780670625 PASS**, all three jobs including iOS build and mac fake
  ES2/ES3 format/blend command tests (no GPU pixels verified by fake mode).
  30c8e21 adds the fade fix (local framebuffer compile PASS again, 0/1).
  e022a51 adds partial mip-chain handling and its sampling regression test.
- **Final builds pending macOS runners:** XNU 39781091148 (30c8e21), EAGL
  39781544025 (e022a51), both still queued at last check. Earlier kernel
  39780060304 and obsolete EAGL 39780057223 were cancelled/superseded.
  No final 0135 artifact downloaded, staged or flashed yet. No device test
  of these fixes, and no new measured FPS gain yet.
- Image packing preflight PASS: `dl/k-t290-0135/roundtrip.img` is byte-for-byte
  identical to installed recovery 0133, SHA256 51d3531b...aa1eb9ee. Use the
  existing `dl/eagl-k0130/repack.py` with that 0133 image and the final CI
  kernel. Preserve its shim, ADT, boot args and Samsung footer. The post-0134
  framebuffer source for regeneration is also saved at
  `dl/k-t290-0135/SweetFramebuffer.before.cpp` (ignored local artifact).
- Next: commit/build 0135 and the bridge/tests through CI, prepare a checked
  recovery image and SD request. A new recovery write requires user approval
  under AGENTS.md; no new approval has been requested or received yet.

## Previous handoff: kernel 0133 + bridge8/Mesa (GPU only)

- Bridge7 boot (logs `ios-t290/logs/b7`): eagltest PASS on hardware incl. new
  checks; UI 4.9 fps, full-screen copy 3.9 MB/frame, GPU wait 5.8 ms/frame.
  User: icons missing, lock screen purple, very low fps. User wants GPU only.
- Commit 7cc0625: YCbCr 420f plane imports (Mesa R8/RG8 formats in patch
  0003), mipmap clamp (single-level textures with trilinear filters sampled
  black), frame timing split (GL calls / GPU wait / copies / outside GL).
- Commit 875614a, kernel patch 0133: IOSurface rows rounded to 256 bytes
  (no padded copies), display shadow rows 3328 (GPU renders into scanout
  surface 1), panel conversion reads the shadow via the cached alias after a
  flush (was uncached WC reads), SweetGPU selector 8 Prepare = per-submit
  cache upkeep (Mesa sends BO handles), VDD_CX (pm8953 S2 "smpa" 2) voted
  NOM via RPM "vlvl" 256 then gfx3d GPLL0/2 = 400 MHz at the first GPU client
  (boot-arg t290gpu_mhz=200 disables). Not verified on hardware.
- CI: eagl 39771029402 PASS, mesa-ios 39771029491 PASS, xnu 39771042195 PASS.
  Artifacts `dl/k-t290-0133/{eagl,mesa,xnu-kernel}`. Recovery = 0131 image
  (953ba242...) repacked with the 0133 kernel only (round trip verified).
- User approved ("да"). **INSTALLED** recovery 0133 `dl/k-t290-0133/recovery-0133.img`
  SHA256 51d3531b86f0412cb38820b5f13020b783a763a85128f15607708968aa1eb9ee, full
  read-back verified; kernel e1b3d978... Rollback image = 0131 `dl/k-t290usb1/t290-ios.img`.
- SD request STAGED (7 ops, read back cdbbd3e5...): get old log/Mesa/glapi to
  `dl/k-t290-0133/before/`, put bridge (`t290eagl-mesa.dylib`), eagltest,
  libOSMesa.8 and libglapi.0 from these builds. Next: boot iPadOS, pstore,
  `t290-xfer.ps1 -Result`; check "core clock 400 MHz", eagltest PASS, fps line.

## Active handoff 2026-10-22 (evening): bridge7 — GPU UI artifacts and speed

- User report on bridge6 + kernel 0131 (boot pulled to `ios-t290/logs/now/`):
  GPU UI works but is slow, with many artifacts. Log: eagltest PASS, no GL
  errors, no missing GLI slots, no GPU faults; GPU waits avg ~4 ms; display
  is surface 1 (bpr 3200, padded to 3328 by the bridge, copied back by CPU).
- Causes found in `t290/eagl/eaglshim.m` (bridge6):
  1. Padded textures were refreshed from their IOSurface only on
     glBindTexture. CA does not rebind a texture after another process
     draws into the surface (zero-copy assumption) -> stale/missing images.
  2. Every display flush compared the whole 800x1280 surface three times
     (backing/snapshot/source) and copied changed rows, although CA redraws
     only the damage rectangle.
  3. Every draw/error check resolved Mesa functions by name
     (OSMesaGetProcAddress = linear strcmp over the glapi table).
  4. Padding used a 256-byte rule for all formats; Freedreno needs 64 px
     (LA08: 128 bytes, A8/L8: 64), so some LA08/A8 surfaces were padded needlessly.
- Commit 6bbe958 (bridge7): seed check of every bound padded texture before
  each draw; GPU writes tracked as row ranges from viewport/scissor, only
  those rows copied back (no snapshot); GL entry points cached; per-format
  pitch; log line every 300 frames: fps, GPU wait, KB copied per frame.
  eagltest adds: LA08 update without rebind, scissored redraw rows 10-19.
- **EAGL CI 39765269483 PASSED** (iOS build; mac fake-GPU ES2/ES3 incl. the
  new checks; fake GPU does not verify pixels). Artifacts `dl/eagl-bridge7`:
  bridge 449488 bytes SHA256 a942fc24f92e009a2e43d28109c6ca91927409d58b082b7c33a0f28173554727,
  eagltest 88720 bytes SHA256 47bdc2357451314e6d7f418e9d107c7d081817073bb46ba3ab638f048f85b4fc.
- Previous request (bridge6) confirmed done 4/4. **New SD request STAGED, 4 ops:**
  get `/private/var/tmp/t290eagl.log` -> `dl/eagl-bridge7/eagl6.before.log`,
  get `/usr/lib/t290eagl-mesa.dylib` -> `dl/eagl-bridge7/bridge.before.dylib`,
  put bridge7 as `/usr/lib/t290eagl-mesa.dylib`, put `/usr/bin/eagltest` (755).
  Whole 34138256-byte request read back from the SD, SHA256 811fcaf7...0ab75 matches.
  **Next:** user boots iPadOS (USB cable to the PC allows `t290/usb/viewer.py`
  screenshots), checks UI after ~3 min, returns to Android; then pstore +
  `t290-xfer.ps1 -Result`; look for the eagltest PASS lines and the
  "fps over 300 frames" lines. Not verified on hardware yet.
- Kernel-side follow-ups (NOT done, need CI + recovery flash approval):
  IOSurface rows always 256-aligned (no padding at all -> zero-copy), display
  surface 1 with bpr 3328 (GPU renders straight into the scanout surface),
  cache maintenance per submitted buffer instead of all imported surfaces on
  every submit/wait (`SweetGPU.cpp flush_surfaces`), GPU clock 200 MHz
  (shim GPLL0/4; Android runs up to 650 MHz) — needs the GFX rail corner.
- Separate stability issue seen in the bridge6 boot (`eagl6-console.bin`):
  panic `recount.c:414 rsn_time_mach 0 >= ...` (non-monotonic time, cpus=4).

## Handoff 2026-10-22 (later): USB CDC screen/debug link, kernel 0131

- Patch 0131 (`t290/usb`, commit with "xnu 0131"): HSUSB/ChipIdea device
  mode as CDC ACM (VID 1209 PID 0001, "T290 Screen Debug"), commands F/L/I
  return panel pixels, kernel log, info; PC side `t290/usb/viewer.py`
  (Windows usbser, tkinter + Pillow; unit test passes).
- Fixed vs the uncommitted draft: USB PHY rails verified on Android
  (`/sys/class/regulator`): hsusb_vdd_dig = **L23 0.8 V** (shared with DSI
  vdda), HSUSB_1p8 = L7 1.8 V, HSUSB_3p3 = L13 3.05 V. The draft used L2
  1.2 V (disabled, no consumers on Android). Init now runs in its own kernel
  thread so the root mount never waits for USB.
- Kernel CI 39749834055 PASSED. Image `dl/k-t290usb1/t290-ios.img`
  (mkboot NATIVE=1, -DT290_GPU2, EXTRA="t290usb=2"; boot args otherwise equal
  to recovery 0130), SHA256 953ba242a5e9ac695c905937986c4de0ed99e8bd24d16af12aecf826bb9bd4e0.
- User approved ("Да, записать recovery 0131 с USB"). Backup of 0130 first:
  `ios-t290/backup-20261022-usb/recovery-before-0131.img` (144be875...).
  **INSTALLED** and full-partition readback verified (953ba242...). Writes to
  mmcblk0p57 sometimes fail with a transient "Permission denied"; retry.
- Bridge6 SD request (below) is still pending and unaffected.
- **Next:** user boots iPadOS with the USB cable on the PC; check that
  Windows enumerates VID_1209&PID_0001 (COM port), run viewer.py; if not,
  read pstore lines "T290 USB:" (rails, id/cap, bus reset, setup).

## Active handoff 2026-10-22: EAGL bridge

### Latest result: bridge5 real tests PASS, GUI still slow/incomplete

- User booted bridge5 and reports slower-than-CPU UI, artifacts and missing
  elements. Fresh logs `ios-t290/logs/eagl5-{console,head}.bin`. All4 SD ops
  completed successfully; old log/bridge retrieved to `dl/eagl-bridge5`.
- Bridge5 **real-device ES2 and ES3 tests PASS**, including all rows of
  format0 120x120, BGRA800x1280, and LA08 samples127/127/127/255 then
  63/63/63/128 after an update. Final testexit0. No compositor import
  failures, missing GLI calls or GPU faults/timeouts observed in this log.
  This does not imply correct composition or acceptable UI performance.
- Concrete code problems: every flush became a full GPU wait and scanned
  all padded surfaces; bindings compared whole CPU images. The same
  surface65 was padded twice in backboardd, at independent texture names,
  so aliases did not share image storage or GPU resource tracking.
- Current fix: share a retained Mesa EGL image per IOSurface/layout within
  the sharegroup, including direct imports; use IOSurface seed changes
  from Lock/Unlock to refresh CPU images; track framebuffer GPU writes;
  publish dirty padded outputs only. Flush is asynchronous except when
  dirty display surface1 must be copied for the CPU framebuffer driver.
  Repeated object fences reuse a completed wait when no new work occurred.
- Regression test now aliases the same IOSurface through two texture names,
  renders green through the second and checks CPU pixels through the first
  object's fence. It would fail with bridge5's separate shadows. LA08 CPU
  updates now use IOSurfaceLock/Unlock, exercising the seed protocol.
- Added throttled GL error diagnostics (pending errors preserved for callers)
  and wait-time/flush/draw counters for the next actual compositor run.
  Hardware performance/correctness of these changes is still pending.
- CI39744412227 failed before compilation: parsed SDK return types retained
  trailing whitespace (`void `). Fix178794f normalizes them, which also
  makes diagnostic hooks reachable after void calls. Framebuffer attachment
  tracking now follows image storage replacement after an FBO was attached.
- **CI39744887745 PASSED**, commit5d22e0c: all3 jobs, iOS build and mac fake
  ES2/ES3 alias/seed/GL checks. Earlier CI39744753980 (178794f) also passed.
  **Bridge6 STAGED**, not yet verified on hardware. Files `dl/eagl-bridge6`:
  bridge429264 bytes SHA256 a66a72c321b005a333b7c4cf7f4aaecef5ea8c7bd6115a5080672aba6f053e2f;
  test88720 bytes SHA256 195b1a5366e04698e2cf6ec4ee5866a0757f694a0fbffff841f8ab77d12c8c15.
- **Pending SD request4 ops:** get previous log to
  `dl/eagl-bridge6/eagl5.before.log`, get active bridge to
  `dl/eagl-bridge6/bridge.before.dylib`, put new
  `/usr/lib/t290eagl-mesa.dylib` and `/usr/bin/eagltest` (mode755).
  Entire34118288-byte staged request read back from actual SD and SHA256
  verified17440700cbf91e88103b93f0088cf1e00372e1e5e7db1924f763a4f31ac022bb.
  User asked to boot manually, inspect speed/completeness after~3minutes,
  then return to Android. Next: pull fresh pstore, xfer-Result; check alias
  pixel tests, GL error diagnostics, GPU wait times and actual user report.
  Do not claim artifacts or slowness resolved before this hardware test.

### Previous bridge5 preparation

- User reports that an image appears with kernel 0130, but the UI is broken,
  incomplete and freezes. Fresh pstore pulled from connected Android:
  `ios-t290/logs/eagl0130-{console,head}.bin`. Both GPU pixel tests still
  PASS; backboardd creates ES3, submits draws and swaps surface 1. The old
  backboardd SIGSEGV is absent. No GPU timeout/fault observed in these logs.
- Concrete failures: format-less CA scratch surfaces 120x120/stride480,
  40x40/160 and 266x75/1064; BGRA display surface 1 800x1280/3200;
  LA08 source images 228x162/480 and 900x150/1824. Freedreno rejects rows
  not aligned to its import requirements. GLI slot470 finish_object_APPLE
  is also missing, so CA's wait before presentation does nothing.
- Bridge fix being built: infer missing pixel format from EAGL arguments;
  pad incompatible rows in a retained IOSurface, preserve packed original
  rows with CPU upload/publish copies, refresh CPU updates on texture bind,
  and implement finish_object_APPLE/flush as a real GPU wait plus publish.
  Direct aligned imports remain unchanged. Additional CPU copies and full
  waits are conservative; smoothness remains unverified on hardware.
- Regression test now covers format0 120x120, BGRA800x1280 with object-fence
  output/all rows, and LA08 228x162 sampling plus a later CPU update. Both
  ES2/ES3 run these cases before backboardd can use the new bridge.
- CI 39742047004 (09a40d0) passes the iOS build and both GLES fake-GPU
  regression paths; this does NOT validate GPU pixels. Follow-up 3f0bd95
  limits object-fence publication to that object and copies only changed
  rows, avoiding full-display copies for every small image fence.
  CI 39742295266 iOS build/mac smoke passed; layout job still pending when
  checked. Corrected signed tolerance arithmetic in the LA08 pixel check.
- **Final CI 39742477239 PASSED**, commit ca94264: all jobs including the
  iOS build and mac fake ES2/ES3 regression tests. These tests report GL
  error0 for both LA08 updates and exercise strides480/3200, but fake GPU
  does not verify rendered pixels. Device artifacts `dl/eagl-bridge5`:
  bridge426240 bytes SHA256 b3f1e7de6cdbb11324498da53cc29a43431397eaca11d1265c8c5f7d84839571;
  test88608 bytes SHA256 e402943b33a0e68e584f6acb1faf29b301b19fef6176871e428238cc04b9e353.
- Previous SD request confirmed done2/2. **New request STAGED: 4 ops**,
  get previous `/private/var/tmp/t290eagl.log` to
  `dl/eagl-bridge5/eagl0130.before.log`, get previous active bridge to
  `dl/eagl-bridge5/bridge.before.dylib`, then put updated
  `/usr/lib/t290eagl-mesa.dylib` and `/usr/bin/eagltest`. Entire 34115104-byte
  raw SD request read back from device and SHA256-verified:
  47d49628d5ff3132954e49af0ae6a8add0f8a31a010b34b1d29ad91a51ef1175.
  Files apply on the next iPadOS boot before the launcher guard runs.
  Recovery0130 and Mesa libraries are unchanged. User was asked to boot
  manually, inspect UI after ~3 minutes and return to Android. **Next:
  read fresh pstore and xfer -Result; new hardware results still pending.**

### Earlier kernel-0130 preparation and installation

- Boot with bridge3 completed all 5 SD operations. `eagltest` reported ES2
  and ES3 renderer FD504, FBO 0x8cd5, clear BGRA 191/128/64/255, triangle
  centre 0/0/255/255, and final exit 0. **Real GPU pixels are now verified.**
  Logs: `ios-t290/logs/eagl3-{console,head}.bin`.
- The guard injected backboardd, which created ES3 and imported its 800x1280
  display surface. It then crashed (SIGSEGV, far 0x30): memcpy from NULL+0x30
  inside `IOSurfaceClientGetBulkAttachments`, called by CA's
  `iosurface_get_edr_factor` / `WindowServer::IOSurface::wrap_buffer`.
- Exact cause from firmware disassembly: IOSurface selector 6 =
  `IOSurfaceClientWrapClientImage` (32-byte input, 0xa68-byte lock result).
  The generic success/zero-output stub creates an invalid IOSurfaceClient
  with no state page. The GPU itself did not fault.
- Fix 3dd79a4 interposes `IOSurfaceWrapClientImage` to return NULL on iOS,
  allowing CA's existing GL texture-upload fallback for CPU images. Native
  IOSurfaces still import directly. The new device test checks that this
  interposition actually takes effect; otherwise the guard uses CPU GUI.
- **EAGL build/mac smoke CI 39737962131 passed**. Artifacts `dl/eagl-bridge4`.
  Boot4 consumed the 2 puts successfully. Its test confirms interposition
  and real GPU pixels, but calls from the prebound QuartzCore shared-cache
  stubs bypass the interposed public entry point. Backboardd crashes at
  the identical IOSurfaceClientGetBulkAttachments memcpy from NULL+0x30.
  New logs: `ios-t290/logs/eagl4-{console,head}.bin`. The workaround is not
  sufficient for the compositor; no further shim-only reboot is useful.
- Kernel fix 0c84f68 / patch 0130 returns kIOReturnUnsupported for selector
  6 instead of a bogus success. **Kernel CI 39738089026 PASSED**,
  SWEET_BOARD=t290. Kernel downloaded and SHA256 matches the CI manifest:
  c0cca894f3347ef0452317e44d09241ea25fc819ff8bece549259400bd87d387.
- Current recovery backed up and SHA-verified on device and PC at
  `ios-t290/backup-20261022-gpu/recovery-before-0130.img`, SHA256
  dba7a21a196c3fe04a0ed432c29bb32dacabb0bfdecf0e823fe4dffbbf7b00cf.
  `dl/eagl-k0130/repack.py` replaces only the XNU payload, preserving shim,
  appended DTB, ADT, boot args and opaque Samsung/AVB metadata. The unchanged
  payload packing round trip is byte-identical to the backup.
- **INSTALLED:** `dl/eagl-k0130/recovery-0130.img` (64 MiB), SHA256
  144be875b8fca287c46e45e2fcd622255709b2f4deb341a7923023454cb50dc4.
  Preserved shim/DTB, ADT, boot args and opaque AVB metadata; unpack/check
  passed. Pushed to `/data/local/tmp/recovery-0130.img`; device SHA matches.
  Partition size 67108864. Original dba7a21a... recovery remains in the backup.
- **User explicitly approved writing recovery** (reply "Да, записать recovery"
  on 2026-10-22). After an adb disconnect, user reconnected USB and Android
  became available. The approved helper successfully wrote recovery, synced
  and read back the full partition: SHA256 144be875...cb50dc4 (matches image).
- Approved flash helper `dl/eagl-k0130/flash-approved.sh` verifies image hash,
  original partition hash and 64 MiB partition size before dd, then syncs
  and verifies the entire partition SHA256. Write completed successfully.
  Existing guard and bridge4 remain active. **Next: manual iPadOS boot with
  kernel 0130, then return to Android and read pstore.** No adb reboot
  recovery command (LK misc/recovery-loop issue); user uses buttons/menu.
- `t290-xfer.ps1` now checks every adb exit code and refuses to use stale
  local transfer headers after connection errors. Tested normal result
  reading and an injected native-command failure (exit 7); both pass.

### Earlier steps

- Verified from `ios-t290/logs/ps-eagl4.bin`: `t290launch` successfully injects
  the probe into backboardd, but Apple's `initWithAPI:properties:` returns nil
  for both ES3 and ES2. The GUI is still software rendered.
- Kernel 0129 already supports IOSurface imports and 256-byte row alignment.
  Mesa run 39729025501 failed: missing prototypes for OSMesaT290CreateImage /
  DestroyImage. Fixed in 4b07e1a, with real GLES contexts in patch 0004 and the
  shared libglapi runtime. **Mesa CI 39734142174 passed** (both jobs).
- Bridge in commits 5b07c6e / 6eba320: 975 typed GLI adapters, real GLES
  contexts, ARB shader adapters, IOSurface textures/renderbuffers. Keep the
  original observation probe separately. See `t290/eagl/README.md`.
- **EAGL CI 39735351364 passed** (6ebb7cc): iOS build and macOS smoke test
  with fake GPU. ES2/ES3 contexts report FD504, FBO 0x8cd5, shaders compile
  and draw commands generate without GL errors. Fake tests DO NOT verify
  GPU execution or pixels. Earlier iOS bridge build 39734954270 also passed.
- Local Mesa artifacts: `D:/test1/dl/mesa-eagl1/out`; initial bridge artifacts
  `D:/test1/dl/eagl-bridge1` (39734954270, clear-only test). The newer test
  additionally draws a triangle; it is not staged on the tablet yet.
- Staged 7-op SD transfer: get old `/System/Library/xpc/launchd.plist` and
  `/usr/lib/libOSMesa.8.dylib` to `dl/eagl-bridge1/*.before.*`; put new Mesa,
  libglapi, `/usr/lib/t290eagl-mesa.dylib`, `/usr/bin/eagltest`, and a launchd
  cache that runs the test once. Backboardd runs without the old verbose
  probe for this test. Existing `/usr/lib/t290eagl.dylib` stays untouched.
- **First device test completed**, logs `ios-t290/logs/eagl-bridge1-{head,console}.bin`.
  SD transfer: state 1, 7/7 successful; original Mesa and launchd saved to
  `dl/eagl-bridge1/*.before.*`. EAGL ES2 and ES3 both created on the device;
  each imported a 64x64 BGRA IOSurface, submitted GPU work, and reached
  `GPU finish`. ES2 necessarily passed its pixel check (otherwise ES3 would
  not start), but the final printf/PASS was not captured. Do not claim the
  entire test passed based on this log alone.
- That boot later panicked: `Non-monotonic time: last_dispatch ... ctime 0`
  at sched_prim.c:796, CPU 2. No GPU timeout/fault or eagltest crash observed.
  GUI was still the system software renderer in this boot.
- Commit dd2d40e adds kernel logging of every pixel result and final exit
  code, plus `t290launch --test TEST LIB PROGRAM`: run TEST with LIB; only
  inject PROGRAM if TEST exits 0, otherwise use the system renderer.
  **EAGL CI 39735995758 and ios-tools CI 39735995793 passed.** Artifacts:
  `dl/eagl-bridge3` and `dl/ios-tools-eagl3`.
- **Current pending SD request: 5 ops**, get old `/usr/bin/t290launch` to
  `dl/eagl-bridge3/t290launch.before`, then put updated bridge, shader/pixel
  test, launcher, and `launchd.guarded.plist`. Backboardd arguments are now
  `/usr/bin/t290launch --test /usr/bin/eagltest /usr/lib/t290eagl-mesa.dylib
  /usr/libexec/backboardd`. No separate test launchd job. On the next boot,
  shader/pixel test gates the first attempt to render the GUI with Mesa.
- User is back in rooted Android; request written and signature read back.
  Next: boot iPadOS, return to Android, read pstore and `t290-xfer.ps1 -Result`.
- GPU GUI still UNVERIFIED. Do not describe it as accelerated until the
  compositor runs through this bridge on the actual tablet. No partitions
  flashed in this session; only root files via the SD transfer were changed.

## Handoff 2026-10-21 (вечер)

- **GPU на голом железе работает** (gpu21, `t290/GPU.md` «SOLVED»): CP выполнил наше
  кольцо и нарисовал зелёный квадрат. Ключ — клоки GCC 0x59040 (timer) и 0x5904c (always-on).
  Следующий шаг: перенести эту инициализацию в XNU (драйвер GPU), затем present через GPU.
- **В recovery** (хэш 248a9321…, `D:\test1\dl\k-t290dev6\t290-gpu21.img`): ядро CI run
  39559502455 (патчи 0118 кнопки/батарея, 0119 родное разрешение 800×1280@1x, 0120 ленивое
  отображение SPMI), shim с тач-меню: iPadOS / Android (PSCI не работает → сброс PS_HOLD,
  проверено) / GPU diagnostics / Boot log. boot-args: NATIVE=1, sweetfb_hz=30, sweetbattery=1.
- Кнопки/батарея/30 Гц на планшете в iPadOS ещё не подтверждены пользователем.
- **Осторожно:** любое падение shim → LK снова грузит recovery (петля). Автокоманды
  (`t290/tools/t290-auto.ps1`, сектор SD 33556480) выключены (`T290_MENU_EXTRAS`), первая
  версия падала без AHB-клока SDCC2. Не включать без согласия пользователя.
- Выключение/перезагрузка из iPadOS не реализованы (нужен PS_HOLD + тип сброса в PMIC PON).

## Статус (2026-10-19)

Этап 0 — разведка. Планшет подключён по adb (только чтение), на нём ничего не меняли.

### Проверено на живом планшете (adb, без root, лог `logs/probe-20261019-225532.txt`, не в git)

- SM-T290, `gtowifi` / product `gtowifiser`, Android 11, прошивка **T290XXS5CWG5**
  (загрузчик ревизии 5 — откат на прошивку с меньшей ревизией невозможен), патч 2023-05-01.
- `ro.board.platform msm8937`, Hardware `Qualcomm Technologies, Inc SDM429`.
- 4 ядра, `CPU part 0xd03` = **Cortex-A53** r0p4; Features `fp asimd evtstrm aes pmull sha1 sha2 crc32` —
  **нет `atomics` (LSE)**, то есть чистый ARMv8.0. Подтверждает выбор userland iPad A9.
- RAM: MemTotal 1 892 156 kB (~1.8 ГБ доступно ядру).
- Экран 800×1280, density 213.
- Тач: `fts_ts` (FocalTech) на **i2c-3 @ 0x38** — совпадает с DTS P81081. Значит, файлы
  `sdm429-mtp-P81081*` действительно от T290.
- Остальное на I²C тоже совпадает с P81081: 5-0020 ABOV SAR («ABOV Cap Touch bottom»),
  8-0058/8-0059 усилители Awinic; ещё 2-0008/000c/000f/0045 (зарядка/fuel gauge/датчики — уточнить).
- Кнопки: `qpnp_pon` (питание и, видимо, громкость−) и `soc:gpio_keys` (громкость+).
- Загрузчик: **заблокирован** (`ro.boot.flash.locked 1`, `verifiedbootstate green`).
  `sys.oem_unlock_allowed 1` — переключатель «Заводская разблокировка» уже включён.
- eMMC `mmcblk0`, раздел **aboot** (= LK) есть. Ключевые разделы: boot p58, recovery p57,
  vbmeta p17, dtbo p27, userdata p69, persist p48, efs p43, sec_efs p42, modemst1/2 p40/p41,
  fsg p36, fsc p30, param p47. Размеры разделов, cmdline и /proc/device-tree без root не читаются.

## 🎉 2026-10-20 ~20:10: XNU + iPadOS userland на ПЛАНШЕТЕ с microSD

Как запускать: `t290/tools/mkboot-t290.sh KERNEL OUT.img STOCK_BOOT MAGISKBOOT FIX.py` → recovery-образ
(t290 shim как iBoot + payload mkpayload: ядро + ADT mkadt_t290 без --qemu; boot-args rd=sdroot0 sdrw=1 cpus=1).
Пишется из Android: `adb push` + `su -c dd of=/dev/block/by-name/recovery`. Запуск: выкл → Vol+ +Power.
Выход: Vol− + Power → Android; журнал ядра: `/sys/fs/pstore/console-ramoops-0` (последние 256К),
с 0116 ещё `dmesg-ramoops-0` (первые 256К загрузки). Логи: `D:\test1\ios-t290\logs\xnu-boot*-pstore.txt`.
Корень iPadOS на карте: `D:\test1\ios-t290\tools\write-sd.ps1` (админ; диск 2 «Generic Flash-Disk» USB,
проверка имени/шины/размера, 16 ГиБ за 23 мин ≈ 12 МБ/с, сверка 6 участков). Вся карта = том HFSX, без MBR.

- Загрузка 1 (CI 39412629412, 0113+0114): ядро доходит до IOKit, panic `SWEET CPU: expected boot MPIDR 0`
  (SweetCPU.cpp:169) — у планшета загрузочное ядро MPIDR 0x100. → **0115**.
- Загрузка 2 (CI 39418230815): sdroot0 смонтирован, launchd и десятки служб работают; GUI-процессы падают:
  `NSInternalInconsistencyException: We expect a valid bounds for configuration … Main-External mode 0x0`
  — AppleCLCD отказался от 24-bpp буфера (`fRowBytes < fWidth*4`), основного дисплея нет. Журнал
  (256К) весь забит этим спамом — ранние строки ядра потеряны. → **0116**: теневой буфер 1536×2048 BGRA
  (iPad 5) → на каждом flush ½ (nearest), по центру 800×1280, байты R,B,G, сдвиг из ADT sweet-fbcon;
  первые 256К консоли в зону dump ramoops (0x92100000) без перезаписи.
- 🎉🎉 **Загрузка 3 (CI 39422813087, 0116): ЭКРАН БЛОКИРОВКИ iPadOS 16 на планшете** (~20:47 → ~21:05,
  1 CPU). Логотип Apple от backboardd через теневой буфер, затем консольный этап (`SK[0]: __nexus_register …
  identityservices`), как в QEMU, затем lock screen. Журнал: `logs/xnu-boot3-head.txt` (dmesg-ramoops-0) и
  `xnu-boot3-tail.txt`. Карта: `SWEET SDHC: … 50 MHz, 1 MiB read in 44120 us` (~23 МБ/с, High Speed прошёл).
- Загрузка 4 (CPUS=4): `SWEET CPU: 4/4 CPUs initialized` (PSCI CPU_ON по SMC, MPIDR 0x101–0x103) → lock screen.
  Зеркало pstore при 4 CPU обрывается рано (параллельные t290_prz_put без блокировки) — починить.
- **Тач (0117, CI 39432676892, ~22:30): работает в iPadOS** (подтвердил пользователь). FT5452 @0x38:
  QUP3 (0x78b7000) даёт `I2C_STATUS 0x1321c4` BUS ERROR (причина не найдена; FIFO v2 с 2 байтами
  rx-тегов не помог), а bit-bang I2C на GPIO10/11 работает (shim touch1c: `BITBANG sda=1 scl=1 id=0x154`,
  374 отчёта). Драйвер `bsd/dev/sweet_t290_touch.c`: L5/L10 через `sweet_t290_rpm_ldo()` (канал SMD
  sweet_sdhc), reset GPIO64, опрос GPIO65 раз в 10 мс, bit-bang ~250 кГц; SweetHID: панель 800×1280 →
  окно iPad 768×1024 @(16,128). mkboot: тач включён, CPUS по умолчанию 4.
- GPU — `t290/GPU.md`. Итог автономной сессии ~22:35–23:15 (только из Android через kgsl, без
  перезагрузок в shim): своя PM4-команда выполнена; 2D-блиттер копирует (масштаб — нет); собран
  ассемблер ir3 из Mesa; первый вычислительный шейдер и шейдер вывода на панель (байт-в-байт верный,
  но медленный: номер нити внутри группы не доходит до шейдера — открытый вопрос).
- Состояние планшета на конец сессии: Android с root, в `recovery` — образ iPadOS
  `dl/k-t290dev4/t290-ios-recovery.img` (0113–0117, тач, 4 CPU); `/data/local/tmp` очищен.

## 2026-10-20 ~18:40: microSD отвечает на голом железе (diag milestone 3b)

Цепочка, которая работает (всё в `t290/shim/diag.c`):
1. **Питание карты через RPM** (L11 = карта, L12 = контакты; оба `qcom,rpm-smd-regulator`, напрямую по SPMI нельзя).
   SMEM 0x86300000 (ver 0xb), легаси-TOC с +208: item 13 = таблица каналов, `rpm_requests` cid 4
   (ctype & 0xff == 0x0f), item 14+cid = половинки канала (word access, по 11 слов; APPS tx, RPM tx),
   item 338+cid = FIFO (TOC reserved = база 0x60000 — RPM msg RAM): sh 0x60000, fifo 0x60800, 0x400 на сторону.
   LK оставляет канал tx=CLOSED, rx=CLOSING. Открытие как в Linux smd_state_change: **обнулить tx.head
   и rx.tail**, OPENING (+fSTATE, IPC 0xb011008 bit0), дождаться RPM OPENING/OPENED, OPENED + DSR/CTS/CD.
   Без обнуления первый запрос валит RPM → сброс SoC. Запрос: SMD-заголовок 5 слов (len,0,0,0,0),
   "req" 0x00716572, len, msg_id, set 0 (active), "ldoa", id, data_len, KVP {"uv" 2950000}, {"swen" 1}.
   Ответ RPM — 0x28 байт на каждый запрос.
2. Контакты sdc2: TLMM+0x109000 = 0x1fe4 (clk 16 мА без подтяжки, cmd/data pull-up 10 мА); LK оставляет 0xbdb (pull-down).
3. Частота: GCC SDCC2 RCG 0x43004 (M 1, N ~3, D ~4, CFG XO/12 dual-edge = 400 кГц), ветки ahb 0x4301c и apps 0x43018.
4. SDHCI: core+0x78 HC_MODE = 1|1<<13, SW reset, опрос/ACK pwr-irq (core 0xdc/0xe4/0xe8), clk ctl int+SD,
   power 3.3 В. pstate 0x01f80000 (CMD/DAT в единице).
5. CMD0, CMD8 → 0x1aa, ACMD41(0x40ff8000) → OCR 0xc0ff8000 (SDHC/SDXC), CMD2 CID (ADATA 0x1d "AD" "SD"),
   CMD3 RCA 0x59b4, CMD9 C_SIZE 0x1ce7f = 59200 МиБ (карта 64 ГБ пользователя).

Экран: байты в буфере **R, B, G**; видимая картинка = буфер со сдвигом **229 px вправо** с переносом
(экранный x → буферный x−229, при x<0 +800 и строка −1) — линейка подтвердила.
**Чтение работает (milestone 4, ~18:50):** CMD7 select (R1b), CMD17 PIO через буфер 0x20, блок 512 по
блочному адресу. LBA0 на 400 кГц/1 бит и LBA32768 на 25 МГц/4 бит (ACMD6 arg 2 + host ctl bit1;
RCG: GPLL0 /16, M/N 1/2) — суммы совпали с `dd` из Android (6dee0c04, 2b6e2cdb). 2048 × CMD17 = 1 МиБ
за 0,59 с ≈ 1,7 МБ/с (MMU/кеш выключены, PIO по одному блоку). Для XNU: CMD18/CMD25 + ADMA2 + 50 МГц HS.
Следующее: драйвер sweet_sdhc для XNU (rd=sdroot0, вся карта = том, без таблицы разделов).

## 2026-10-20 ~18:05: первый наш код на планшете (t290/shim/diag.c) — работает

`t290/shim/build.sh STOCK_BOOT MAGISKBOOT FIX_BOOTABLE_IMAGE.py` → `out/t290-diag.img`:
shim (start.S/shim.ld из ../../shim + diag.c) упакован в стоковый заголовок (magiskboot repack:
gzip Image + стоковые appended DTB) + SignerVer02/AVBf. Пишется в `recovery` из Android:
`adb push` → `su -c dd of=/dev/block/by-name/recovery` (+ sha256). Запуск: выключить → Vol+ +Power.
Выход: Vol− + Power ~7 с → **сразу Android** (круга нет, Odin не нужен), если shim не сбросил планшет сам.
TWRP обратно: тот же dd с `D:\test1\dl\twrp\recovery.img`.

Грабли (каждая стоила круга загрузки + Odin):
- **Чтение регистров MDP (0x1a01000 + пайпы) сбрасывает планшет** (XPU/защита?). Не трогать дисплейный блок.
- `adb reboot recovery` → LK грузит recovery после КАЖДОГО сброса (выход только Odin+TWRP).
  Запускать пробы кнопками. Shim не должен сам перезагружаться (теперь висит `HOLD`).
- Отладка без экрана: shim пишет журнал в **ramoops console** (`0x92140000`, заголовок
  persistent_ram_buffer sig 0x43474244, start=size=len) ДО каждого шага → после сброса Android/TWRP
  показывает его в `/sys/fs/pstore/console-ramoops-0`. Так найден сброс на MDP.

Результат (журнал `D:\test1\ios-t290\logs\diag-run1-pstore.txt`, фото у пользователя):
- EL1, MPIDR 0x80000100, MIDR 0x410fd034 (A53 r0p4); CNTFRQ 19.2 МГц; PSCI 1.0 по smc.
- LK: x0 = DTB 0x83400000 (0x597a6 Б), /memory 0x80000000+1G, 0xc0000000+1G.
- APSS WDT LK **не включает** (en=0).
- Splash 0x90000000: **24 bpp (RGB888), stride 2400**, порядок байт в памяти **R,G,B**
  (жёлтый вышел голубым при B,G,R). Видимая картинка **сдвинута по горизонтали** (строки
  «заворачиваются», хвост слева) — точку начала скан-аута уточнить линейкой.
- GCC: SDCC1 apps/ahb включены LK; **SDCC2 RCG (cmd=0x80000000) и ветки apps/ahb выключены**.
  После включения ahb (CBCR 0x4301c bit0) регистры sdhc2 читаются: HC ver 0x4d02 (SDHCI 3.0),
  cap 0x302dc8b2 (база 200 МГц), cap1 0x8007, clk 0x403, pstate 0x80000; core ver 0x1000004d.
- Карта: CD GPIO67 in=0, pstate CD=0 — карта не вставлена (или полярность — проверить с картой).
Следующее: цвета R,G,B + линейка для сдвига; включить apps-clk SDCC2 (RCG 0x43004/0x43008),
питание карты (PM8953 L11/L12 через SPMI), карта в слоте → CMD0/CMD8/ACMD41.

## 2026-10-20 ~17:00: планшет разблокирован, TWRP, живой FDT

- Загрузчик разблокирован пользователем (`ro.boot.flash.locked=0`, `verifiedbootstate=orange`),
  прошивка та же T290XXS5CWG5 / Android 11. Knox сгорел (необратимо).
- TWRP 3.7.0_11-HeribertYavuz (XDA «OFRP & TWRP For TAB A 2019 (T290) (Binary 5)») прошит Odin 3.14
  в AP одним tar: `recovery.img` автора + свой пустой `vbmeta.img` (AVB0, flags=2, 4096 Б) —
  `D:\test1\dl\twrp\twrp-AP.tar`. Стоковый vbmeta перезаписан → для отката нужна стоковая CWG5.
  Вход в TWRP: Odin без Auto Reboot → Vol−+Power до чёрного → сразу Vol+ +Power.
  Android грузится как раньше (boot/system/userdata не трогали). В TWRP adb = root.
- Дампы (вне git): `D:\test1\ios-t290\logs\twrp-20261020\` (fdt.dtb/fdt.dts, iomem, dmesg, partitions,
  getprop, interrupts); бэкап всех разделов ≤200 МБ (64 шт., 712 МБ, sha256): `D:\test1\ios-t290\backup-20261020\`
  (RPMB не читается — норма). Большие (system/vendor/product/oem/cache/userdata) не копировались.

- **Root + постоянный TWRP (17:20).** Android при каждой загрузке восстанавливал стоковый recovery
  (`/system/bin/install-recovery.sh` + `/system/recovery-from-boot.p`, applypatch только если boot = сток,
  sha1 10b1f840…). Решение: Magisk v30.7 (GitHub, sha256 e0d32d21…) патчит стоковый boot на ПК
  (`magiskboot` x86_64 из APK, `boot_patch.sh`, `LEGACYSAR=true KEEPFORCEENCRYPT=true KEEPVERITY=false`;
  в стоковом boot нет ramdisk, root=PARTUUID — legacy SAR) → `fix_bootable_image.py`
  (GalaxyA20s/A20s-Fix-Bootable-Image: `SignerVer02` + AVBf-размер, иначе SECURE CHECK FAIL) →
  Odin AP `D:\test1\dl\root\magisk-twrp-AP.tar` (boot+TWRP+пустой vbmeta). Откат boot: `stock-boot-AP.tar`.
  Проверено: Android грузится, `magiskd` работает, `adb shell /debug_ramdisk/su -c id` = root;
  после загрузки Android sha256 разделов recovery/boot = прошитым образам → TWRP больше не слетает.
  **Значит, наше ядро iPadOS в `recovery` Android тоже не затрёт.**

Живой FDT (board_id P81080BA5, `qcom,sdm429`, msm-id 0x162; панель `jd9367_wxga_video_txd`):
| Что | Значение |
| --- | --- |
| RAM | `0x80000000`+1 ГБ и `0xc0000000`+1 ГБ = сплошные 2 ГБ `0x80000000..0x100000000` |
| Свободно для XNU | крупнейший кусок System RAM: **`0x92600000..0xffffffff` (~1754 МБ)**; ниже — дыры reserved |
| reserved no-map | 0x85000000+0x800000, 0x85b00000+0xd00000, 0x86800000+0x5500000, 0x8bd00000+0x1100000, 0x8ce00000+0x700000; splash 0x90000000+0x1400000; ramoops 0x92100000+0x100000; 0x92200000+0x400000 |
| Splash fb | 0x90000000, 800×1280, 32 bpp, stride 3200 (`mdssfb_80000`) |
| GIC | v2 `qcom,msm-qgic2`, GICD 0x0b000000, GICC 0x0b002000 (подтверждено) |
| Таймер | 19.2 МГц, PPI <1 2>,<1 3>,<1 4>,<1 1> → **vtimer INTID 20** (подтверждено) |
| CPU | 4× cortex-a53, MPIDR 0x100..0x103, `enable-method = psci`, **PSCI 1.0 method = smc** (в QEMU — hvc) |
| eMMC | sdhc1 `qcom,sdhci-msm` hc 0x7824900, core 0x7824000, cmdq 0x7824e00; IRQ SPI 123 (hc), 138 (pwr); 8 бит; 32 ГБ (QX63AB) |
| **microSD** | **sdhc2** hc 0x7864900, core 0x7864000; IRQ SPI 125 (hc, INTID 157), 221 (pwr); 4 бит; **card-detect tlmm GPIO 67**; питание vdd/vdd-io — регуляторы PMIC (могут быть выключены LK — проверить) |
| UART | msm-uartdm 0x78b0000 (earlycon), IRQ SPI 108 |

План пользователя: iPadOS-корень на **microSD** (sdhc2), ядро — в раздел `recovery` (вход Vol+ +Power),
Android в `boot` не трогать. Нужно: драйвер SDHCI (проверить в QEMU), карта памяти в mkadt_t290
(база 0x92600000?), PSCI smc, формат Samsung boot.img v1 (ядро + дописанный DTB) для LK.

## 🎉🎉 2026-10-20 ~16:40: ЭКРАН БЛОКИРОВКИ iPadOS 16 в QEMU (прогон ios3)

Тот же прогон ios3 (CI 39321740004, SMP=1, TCG): логотип Apple ~240–1620 с, затем ~1620–1860 с
на экране консоль ядра (`SK[0]: __nexus_register identityservices(53)...`), первый `SWEET FB: swap`
~1840 с, к **1920 с — lock screen SpringBoard**: «Wednesday, December 31», часы, «Press home to open»,
батарея 100% (снимки `D:\test1\qemu-out\ios3\shot-1920.png` … `shot-2160.png`).
Вывод: ядро T290 (A53, 4K, GICv2, virtio-blk) + неизменённый userland iPad 5 доходят до GUI;
«зависание» на логотипе было просто медленной первой загрузкой (datamigrator) на 1 vCPU.
Следующее: SMP=4 (быстрее?), ввод в QEMU (Home/тач) → домашний экран; потом путь на планшет
(LK/Odin, eMMC SDHCI, экран 800×1280, тач FocalTech).

## 2026-10-20 ~16:00: iPadOS userland в QEMU, логотип Apple (прогон ios3)

CI 39321740004 (189dc00), `qemu-ios.sh` SMP=1 на свежей копии корня iPad 5:
корень `vblkroot0` смонтирован, **launchd стартовал**, через ~800 с — около 100 демонов
(`exec ...` в msgbuf), SpringBoard (pid 25) и backboardd (pid 56) живы, на экране **логотип Apple**.
Ошибок virtio-blk нет. Стеки SpringBoard/backboardd на 242 с и 365 с совпадают — ждут в mach_msg
(наблюдение); при этом работает `com.apple.datamigrator` — гипотеза: первая загрузка, SpringBoard
ждёт миграцию данных, а TCG на одном vCPU очень медленный. Не проверено.
Результаты: `D:\test1\qemu-out\ios3\shot-*.png`, `D:\test1\qemu-out\mb-ios3.txt` (вне git).

Почему ios2 падал (`SWEET VBLK: ... status 255`, `load_init_program ... errno 5`): кончилось место на C:
(ext4.vhdx WSL вырос до 105 ГБ). Теперь большие файлы — на D:: чистый корень
`D:\test1\ios-images\ipad5-root.pristine.img`, рабочая копия `/root/ios/TAG.img` в WSL (удалять после прогона),
старое содержимое WSL — `D:\wsl-backup\` (tar). QEMU нужно держать в foreground-вызове `wsl`:
`nohup ... &` внутри `wsl bash -c` умирает при выходе wsl.exe.

## 🎉 2026-10-20 ~03:40: ядро T290 доходит до userspace в QEMU

CI 39309753629 (0101–0110 + firehose -mcpu в workflow), `qemu-t290.sh` (cortex-a53, GICv2,
RAM-диск init): `BSD root: md0` → `*** SWEET userspace: init running as PID 1 ***`.
Цепочка исправлений этого дня (каждое найдено в QEMU):
- 0104 ранняя консоль телефона (0x9c000000, 16K-таблицы) → выключена для T290;
- 0105 `casa` в commpage (pfz trylock) → ldaxr/stxr;
- `-mcpu=cortex-a53` (clang для arm64-apple-macos держит apple-m1 и LSE при любом -march),
  то же для libfirehose_kernel (workflow, xcconfig `OTHER_CFLAGS[arch=arm64]`);
- 0106/0108 kmem claims — из самой большой дыры kernel_map + запас 1/32, лог каждого claim;
- 0107 zone map iOS (24 ГБ VA вместо 128), 0109 пул компрессора iOS (RAM вместо 16×RAM);
- ADT: CPU compatible должен содержать `qcom,kryo470` (IONameMatch SweetCPU), иначе вечное ожидание CPU;
- 0110 commpage text VA выровнен на PAGE_RATIO (4K железо + 16K VM-страницы → write_pte_fast panic).
Загрузка ждёт ~30 с RTC (в QEMU его нет) — не блокер.

Отладка: `t290/tools/kmem.py PORT KERNEL msgbuf|bt|regs|read` через gdb-stub QEMU
(`qemu-sweet.py --gdbport`); `D:\test1\dl\ci-boot.sh RUN TAG` = дождаться CI → скачать →
скан LSE во всём ядре (`dl/bt/kscan.sh`) → загрузка с msgbuf/bt (`dl/bt/dbgboot.sh`).

Образ iPadOS: чистый — `D:\test1\ios-images\ipad5-root.pristine.img` (раньше `/root/ios/` в WSL), 11 ГБ на HFS+ 16 ГБ, fsck OK.
Собран `t290/tools/mkroot-ipad5.sh` (stage в ext4 → tar → KVM-гость с Ubuntu-ядром,
hfsplus.ko + nls_utf8.ko + busybox распаковывает в HFS+). Предупреждение: в образе iPad нет
system-контейнера mobileactivationd (data ark не записан).

## Состояние 2026-10-20 (утро)

- Форк: github.com/terx1232/ios-sweet, ветка `t290` (ветка по умолчанию форка — иначе GitHub
  не регистрировал workflow). Сборка: `gh workflow run xnu.yml -R terx1232/ios-sweet --ref t290 -f sweet_board=t290`.
- CI 39280792571 (0101+0102 старой версии): упал только на pe_fiq.c и IOKitBSDInit.cpp —
  `\n` в трёх строках kprintf/IOLog превратился в перевод строки (heredoc через Bash-инструмент
  схлопывает `\\` → `\`; писать такие правки через Write/Edit). Флаги T290 в CI дошли до 1101
  файла, патчи 0101/0102 применились. Исправлено в eee22c1, CI 39285650537 запущен.
- Патчи: 0101 (A53/4K/GICv2), 0102 (virtio-blk root, `rd=vblkroot0 vblkrw=1`),
  0103 (PSCI через HVC по `sweetpsci=hvc`, для QEMU SMP).
- **Локальная проверка компиляции работает** (WSL, clang 14 из Ubuntu):
  дерево `xnu-buildtree` + лог CI автора (run 39158169212) → `~/bt`, на него наложены 0101–0103;
  `XNU_CC_EXTRA=-enable-trivial-auto-var-init-zero-knowing-it-will-be-removed-from-clang`,
  `XNU_CC_POST="-DSWEET_T290=1 -march=armv8-a+crc+crypto -UARM_LARGE_MEMORY -UVM_KERNEL_LINK_ADDRESS -DVM_KERNEL_LINK_ADDRESS=0xfffffff007004000"`,
  `python3 tools/xnu-cc.py ~/bt/run.log ~/bt --per-file` (новые файлы вроде sweet_vblk.c — только явным путём).
  Результат: всё ядро проходит, падают лишь хостовые `SETUP/*` (как и у sweet). Ошибки CI совпали с локальными 1:1.
- iOS: iPad 5 (iPad6,11/J71sAP) iPadOS 16.7.16 20H392, IPSW качается в `D:\test1\ipsw\` (вне git).
  OS = 087-86634-044.dmg, SystemOS cryptex = 087-86624-047.dmg, AppOS = 087-86715-047.dmg.
  `research/ipsw-ipad5/j71sap.adt` (DeviceTree, вне git) → /product для mkadt_t290.
- WSL без сети: служба Windows **HNS отключена** (StartupType Disabled), нужен админ
  (`Set-Service hns -StartupType Manual; Start-Service hns`). Обход: .deb скачаны через Windows
  (`D:\test1\dl\debs`: hfsprogs, libfuse3-dev, libbz2-dev), apfs-fuse собран g++ без cmake
  (`/usr/local/bin/apfs-fuse`, скрипт `D:\test1\dl\build-apfs.sh`).
- QEMU: `t290/tools/qemu-ios.sh KERNEL ROOT.img OUT` — 4×A53, GICv2, virtio-blk корень,
  экран 1536×2048 (AppleCLCD сам выбирает родной размер, если буфер больше 1125×2436),
  снимки каждые 30 с (`--shots`) = замер времени загрузки.

## Ядро T290 (2026-10-19) — первая версия

Порт живёт веткой `t290` форка ios-sweet. Отдельной MACHINE_CONFIG нет: весь код
sweet (80+ мест `ARM64_BOARD_CONFIG_SWEET`, стейдж-скрипты по `MACHINE_CONFIG == SWEET`)
используется как есть, плата выбирается переменной окружения **`SWEET_BOARD=t290`**
(CI: input `sweet_board: t290`). Без неё патч 0101 ничего не меняет — сборка sweet прежняя.

`xnu/patches/0101-t290-a53-4k-gicv2.patch` (сделан на xnu-8796.141.3 + 0001–0081, все 81 патч sweet
легли локально; патчи darwin-xnu-build не пересекаются с файлами 0101):
- `MakeInc.def`: `-DSWEET_T290=1 -march=armv8-a+crc+crypto`; iOS-раскладка ядра
  (`-UARM_LARGE_MEMORY`, link 0xfffffff007004000) — macOS-раскладка на −2 ТБ не помещается
  в 38-битное пространство 4K-режима (T1SZ 26).
- `SWEET.h`: при `SWEET_T290` нет `__ARM_16K_PG__` и `__ARM_PAN_AVAILABLE__`,
  есть `__ARM64_PMAP_SUBPAGE_L1__` (как BCM2837), `HAS_GIC_V2`, 4 CPU, vtimer INTID 20,
  регистры GICv2.
- `vm_param.h`: `MACH_VM_MAX_ADDRESS` = iOS 0xFC0000000 (макОС-значение 47 бит не влезает в T0SZ 26).
- `pe_fiq.c`: драйвер GICv2 (GICD+GICC по `/arm-io/gic reg`, маска интерфейса ЦП из
  GICD_ITARGETSR0, `sweet_gic_ack/eoi/send_sgi`); `sleh.c`: IAR/EOIR через GICC;
  `SweetCPU.cpp`: IPI через GICD_SGIR; `start.s`: ICC_SRE_EL2 только при GICv3.

Проверено на практике: готовое ядро sweet (CI 18.10) на QEMU `-cpu cortex-a53` падает на
первой же LSE-инструкции `ldadd` (0xb8280028, `lck_grp_reference`) — флаг `-march=armv8-a`
обязателен. QEMU 6.2 при этом не отверг 16K-таблицы (MMU включился) — гранулу он не
проверяет; для строгой проверки нужен QEMU ≥ 7.2.

Инструменты: `t290/tools/mkadt_t290.py [--qemu]` (дерево sweet + GICv2, 4×A53 MPIDR 0x10x,
RAM 0xa0000000+1.5 ГБ, fb 0x90000000 800×1280, без sweet-ufs), `tools/qemu-sweet.py`
получил `--gic-version` и `--fb`, `t290/tools/qemu-t290.sh KERNEL OUT` — запуск в QEMU.

Следующий шаг: форк на GitHub пользователя → `gh workflow run xnu.yml -f sweet_board=t290`
→ исправлять ошибки компиляции → `qemu-t290.sh`. Ожидаемый успех: `SWEET GIC: GICv2 ...`,
`init running as PID 1`, как у sweet.

Не проверено / известные вопросы:
- 4K-путь pmap в xnu-8796 никто не собирал для этой конфигурации — возможны ошибки компиляции.
- Драйверы sweet (кнопки SPMI, тач GENI, USB, RPMh) обращаются к MMIO SM7150 — на планшете их
  надо выключить boot-args (`sweetkeys=0 sweettouch=0`, sweetusb по умолчанию выкл.) или загейтить по плате.
- PSCI на SDM429 (smc/hvc) не проверен; в QEMU virt PSCI идёт через hvc — пока cpus=1.
- Формат splash-буфера (32 bpp?) и точная карта памяти — сверить с живым FDT.

## Решения

- **Личность устройства: iPad (5th gen), iPad6,11 / J71sAP, iPadOS 16.7.x.**
  A9 = ARMv8.0 (как Cortex-A53), 2 ГБ RAM (как T290), планшет, официально
  поддерживает iPadOS 16. Userland iPhone X (A11, ARMv8.2) мог бы содержать
  инструкции, которых нет на A53 (LSE-атомики и т.п.) — с A9 этот риск снят.
- **4K-страницы вместо 16K.** Cortex-A53 не поддерживает гранулу 16 КБ
  (ARM DDI 0500F, ID_AA64MMFR0_EL1.TGran16 = 0). XNU 8796 сохранил 4K-путь:
  `osfmk/arm64/proc_reg.h` `#ifdef __ARM_16K_PG__ ... #else ARM_PGSHIFT 12`,
  `osfmk/arm/pmap/pmap.c` `native_pt_attr = &pmap_pt_attr_4k` без `__ARM_16K_PG__`.
  Образец — официальная конфигурация Apple **BCM2837** (Raspberry Pi 3, тоже A53):
  `pexpert/pexpert/arm64/BCM2837.h` — без `__ARM_16K_PG__`, с
  `__ARM64_PMAP_SUBPAGE_L1__`, MAX_CPUS 4. sweet (patch 0004) наоборот
  задаёт `__ARM_16K_PG__ 1` — его конфиг платы НЕ переносить как есть.
- Ядро собирается так же, как в sweet: GitHub Actions macOS + blacktop/darwin-xnu-build
  (нужен форк и аккаунт GitHub пользователя).

## Железо (из LineageOS android_kernel_samsung_sdm429, ветка lineage-22.2, 56a0722)

ВНИМАНИЕ: файлы платы `sdm429-mtp-P81081*.dts*` (board-id <8 0>, Wingtech,
комментарии «N8-R Project») — предположительно T290, **сверить с живым FDT
планшета** (`/sys/firmware/fdt`, нужен root/TWRP).

| Что | Значение | Отличие от sweet |
| --- | --- | --- |
| SoC | SDM429 (семейство MSM8937), 4× Cortex-A53, MPIDR 0x100..0x103 (Aff1=1) | A55/A76 |
| Прерывания | **GICv2** `qcom,msm-qgic2`: GICD 0x0b000000, GICC 0x0b002000 | GICv3 → нужен драйвер GICv2 |
| Таймер | 19.2 МГц, PPI по-квалкомовски `<1 2>,<1 3>,<1 4>,<1 1>` → виртуальный таймер = PPI 4 = INTID 20 (проверить) | у sweet INTID 19 |
| SMP | PSCI (`enable-method = "psci"`) | так же |
| Накопитель | **eMMC**, `sdhc_1` = `qcom,sdhci-msm` @ 0x7824900 (hc), 0x7824000 (core); стандартный SDHCI | UFS → новый драйвер, но SDHCI проще |
| Экран | 800×1280 DSI, continuous splash: `cont_splash_mem` 0x90000000, 0x1400000 | 1080×2400 @ 0x9c000000 |
| Тач | FocalTech (ft3528/ft8201…) I²C 0x38 на `i2c_3`, IRQ tlmm 65, reset tlmm 64, питание pm8953 L10 / L5 | Goodix GT9896 |
| PMIC | PM8953 + PMI632 | PM6150/PM6150L |
| Загрузчик | LK/aboot эпохи MSM8937, `CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y` (DTB дописывается к Image) | ABL, boot.img v2 с отдельным DTB |
| Прошивка | Odin / Download mode, нет `fastboot boot` | fastboot |

Reserved-memory (no-map, низкий банк): 0x85b00000+0xd00000, 0x86800000+0x5000000,
0x8b800000+0x1100000, 0x8c900000+0x700000, ramoops 0x92100000, ss_plog 0x92200000,
removed-dma-pool 0x85000000+0x800000.

## Риски (по убыванию)

1. 4K-путь XNU для iOS 16 никто давно не собирал — возможны поломки компиляции/рантайма.
   Userland iPadOS для A9 исполнялся на 16K-ядре: проверить, не зашиты ли 16K-предположения
   (dyld shared cache, libmalloc, vm_page_size).
2. Samsung: разблокировка сжигает Knox (необратимо), стирает данные; vbmeta/AVB;
   каждый тест = прошивка boot через Odin (нет временной загрузки).
3. Гипервизор Qualcomm/Samsung на EL2 может ограничивать доступ к памяти/MMIO.
4. 2 ГБ RAM и 4×A53 — рисование интерфейса CPU будет медленным.

## План

0. **Разведка (сейчас).** Подключить планшет по adb (`t290/tools/t290-probe.sh`): модель,
   прошивка, статус OEM unlock, ядро. Потом TWRP → бэкап разделов + живой FDT.
1. Shim: свой код стартует из LK и рисует текст в splash-буфере 0x90000000.
2. XNU (4K, конфиг SWEET→T290 по образцу BCM2837, GICv2) — сначала в QEMU (`virt`,
   `-cpu cortex-a53`, gic-version=2), потом на планшете, лог в splash/eMMC.
3. Драйвер eMMC (SDHCI), корень HFS+ из IPSW iPad6,11.
4. Экран (AppleCLCD 800×1280 → iPad 1536×2048?), тач FocalTech, кнопки PM8953 → SpringBoard.
