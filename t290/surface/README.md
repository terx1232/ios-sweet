# Buffer lifetime and final-row extent (0146)

0145 hardware testing captured a GPU SMMU fault while the kernel and USB
continued running. The graphics budget was below its cap. The faulting
allocation has not been identified; these changes do not prove recovery.

Patch0146 waits for already submitted GPU work before releasing mappings.
Free returns a timeout without releasing busy memory. A timed-out close
retains the client and its buffers until reboot. Imported buffers retain
their SweetSurface so the backing and graphics budget survive the import.
This is conservative lifetime protection; hardware GPU reset is absent.

Caller memory can end exactly after the last pixel in the final row:
137x137 RGBA at576-byte stride needs78884 bytes, rather than78912 including
unused final padding. A78883-byte allocation remains invalid. Client
memory still uses owned GPU mirrors and row-sized copies. Automatic sizing
and explicit planar bounds remain unchanged.

```
python3 t290/surface/test-free.py /path/to/xnu/iokit/Kernel/arm/SweetGPU.cpp
python3 t290/surface/test-layout.py /path/to/xnu/iokit/Kernel/arm/SweetSurface.cpp
```

# Graphics stability (0145)

Patch0145 shares a 512MiB reservation budget between owned GPU buffers and
owned/pinned surfaces. Imports retain their surface reference without double
counting. Selector10 reports used, peak, cap and rejected reservations; process
samples print the same counters. The cap is provisional and needs hardware
measurement: rejection is not a fix for leaks or application exceptions.

GPU fence waits use a real deadline capped at five seconds, spin for about one
millisecond, then yield the CPU. IOSurface descriptor mapping runs outside the
global surface table lock. Failed GPU mappings unwind their entire reserved
window. Prepared handles have capacity4096 and are removed when freed.

Host checks compile the actual implementation with ASan/UBSan:

```
python3 t290/surface/test-budget.py /path/to/xnu/iokit/Kernel/arm/SweetSurface.cpp
python3 t290/surface/test-wait.py /path/to/xnu/bsd/dev/sweet_t290_gpu.c
```

Budget tests cover overflow, exact capacity and160000 concurrent reservation/
release pairs. Wait tests cover completed/delayed fences, zero timeout,
UINT32_MAX timeout, sequence wrap and unavailable hardware. These checks and
QEMU boot do not establish real GPU stability or FPS. Existing400MHz clock
configuration and30Hz framebuffer setting are preserved;60FPS is not claimed.

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
