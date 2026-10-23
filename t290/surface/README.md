# Client memory surfaces (0136)

Patch0136 handles `IOSurfaceAddress` creation: pin the original memory,
preserve the caller's pitch and allocation, map independent aliases in
clients, and release the pin/task after the last surface user. Read-only
image providers are accepted for sampling. Invalid short allocations and
unsupported address-range arrays fail instead of producing a blank image.
Pinned pages share the existing surface memory budget with owned buffers.

SweetGPU selector9 returns `0x5432393000000000 | flags` for a surface ID:
bit0 means client memory, bit1 read-only. The bridge checks the signature
before using the flags, so it still supports older kernels. Wrapped memory
uses an owned aligned GPU backing; GPU imports of arbitrary client pages
are refused. CPU seed changes refresh the backing. Object fences publish
GPU-written rows to writable original buffers. Read-only images cannot be
framebuffer targets. Format-less byte order is not changed globally.

Run the actual layout function on a Linux host with ASan/UBSan:

```
python3 t290/surface/test-layout.py /path/to/xnu/iokit/Kernel/arm/SweetSurface.cpp
```

The hardware guard checks original pixels, exact480/512-byte rows, unaligned
addresses, two CPU updates, read-only memory after unmapping the original
address, GPU publish and padding canaries in both ES2 and ES3. These cases
are skipped for the host fake GPU. They require kernel0136 and must pass
before enabling the compositor. They do not establish whole-interface
correctness or FPS.
