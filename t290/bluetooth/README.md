# SM-T290 Bluetooth bring-up

0140 introduced a boot-gated, read-only APPS/WCNSS SMEM probe (`t290btprobe=1`).
This is transport discovery, not a working Bluetooth driver. No HCI commands,
FIFO consumption, firmware loading, clocks, PMIC writes or radio traffic occur.

Android inspection confirms Qualcomm Pronto and separate SMD channels
APPS_RIVA_BT_CMD (CID7) and APPS_RIVA_BT_ACL (CID8), each with 8KiB half-FIFOs.
The Android HAL owns these channels while Android is running: never open its
raw smd2/smd3 nodes concurrently. Board FDT places SMEM at 0x86300000/1MiB,
APPS/WCNSS hosts 0/4 and WCNSS reserved memory at 0x8ce00000/7MiB.

`smem_view.h` validates the private partition table and each allocation inside
the mapped range. `smem_probe.c` reports only allocation/channel state; stale
metadata can survive reboot and does not prove that firmware is executing.
A real HCI Read Local Version response is required before claiming a live
controller. Patch0140 adds both files and invokes the probe on SD-root startup.
Existing0139 motion and graphics objects remain in the linked image.

Host verification:

```sh
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-pie -no-pie -O1 t290/bluetooth/test-smem.c -o /tmp/test-smem
/tmp/test-smem
```

Fixtures cover private-host isolation, cached traversal with sub-cacheline
payloads, padding, truncation, malformed bounds and 20,000 corrupt inputs.
Non-PIE avoids intermittent sanitizer startup SIGSEGV seen in this WSL runtime.

0140 hardware boot returned status=-3 (no partition matched). The probe had
an incorrect hardcoded remote host3, which is DSPS in this downstream ABI.
Patch0141 selects WCNSS4 and reports table magic/version and bounded partition
metadata before looking up channels. Tests reject host3 and accept host4.
The0140 result cannot establish whether WCNSS firmware is running.
The collected boot also passed EAGL guards and continued motion/USB delivery.

Next: boot0141 and collect `SWEET BT:` over native USB. If the remote processor
is not running, implement bounded PAS6/Pronto startup and relocated MDT loading
before opening SMD and adapting the original iPadOS H4 service transport.
The firmware ELF physical addresses must not be copied literally: they lie
outside this board's reserved region. Firmware, device dumps, identifiers and
Apple binaries stay outside git under D:/test1/dl/t290-bluetooth.

Primary implementation references:
- https://github.com/torvalds/linux/blob/v6.12/drivers/soc/qcom/smem.c
- https://github.com/torvalds/linux/blob/v6.12/drivers/bluetooth/btqcomsmd.c
- https://github.com/torvalds/linux/blob/v6.12/drivers/remoteproc/qcom_wcnss.c

Downstream host-ID reference (SMEM_WCNSS=4):
https://android.googlesource.com/kernel/msm.git/+/e38998faf70429357419a02f5850ceefe9e887b6/include/soc/qcom/smem.h
