# SM-T290 system compatibility corrections (0142)

0141 native USB logs showed driverkitd SIGKILL with Jetsam namespace1/code7,
320 AppleSPU log_aop assertions, a 50MB watermark request failing EINVAL, and
wall time at1969-12-31. These observations do not establish the causes of
unrelated application crashes or a system-wide memory shortage.

Patch0142 makes three board-specific changes:

- Our HID services publish Embedded transport instead of Apple SPU. They
  have no Apple SPU/AOP user client. Sensor usage/product and measured
  orientation delivery remain unchanged. Actual assertion cessation must
  still be checked on hardware.
- Enable the existing high-watermark/task-limit compatibility commands on
  SWEET_T290 even with CONFIG_JETSAM disabled, using the normal limit setter,
  authorization and fatal/nonfatal semantics. Keep coalition-only commands
  gated. A provisional64MB minimum applies only to positive driverkitd
  limits below64MB; default/unlimited, larger and other-process limits are
  preserved. This bounded allowance must be validated on hardware. Fatal
  footprint reports now include actual footprint and limit for diagnosis.
- Wire platform calendar reads to PM8953 SID0 RTC peripheral0x60. Read enable
  and counter registers with carry detection; no alarm or PMIC writes.
  Android raw RTC is not Unix wall time: use a calibrated t290rtc_offset.
  Invalid dates/overflow are rejected. Calendar writes update a software
  correction for this boot only. Calibration must be repeated if Android
  changes its wall-clock correction or the PMIC counter resets.

Android calibration2026-10-23: stable raw23695729 vs Unix1792769135,
correction1769073406 seconds. This device-specific value belongs in local
boot arguments, not source defaults. `t290rtc=1` enables hardware reads;
QEMU leaves it disabled. No build timestamp is presented as hardware time.

```sh
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  -fno-pie -no-pie t290/system/test-policy.c -o /tmp/test-system
/tmp/test-system
```

Tests cover bounded driverkitd allowance, all other/default limits, calibration,
time validity and signed overflow. Kernel compile/relink and QEMU smoke boot
are necessary but do not prove the hardware issues resolved. After installation
check SWEET RTC/MEM, SPU assertions, driverkitd survival and motion regression.

RTC register/carry reference:
https://github.com/torvalds/linux/blob/v6.12/drivers/rtc/rtc-pm8xxx.c

0142 hardware observation: calibrated RTC returned valid2026 UTC, SPU/AOP
assertions fell from320 to0, launchd50MB watermark error disappeared. The
actual driverkitd request was6MB;64MB floor applied and its previous crash did
not recur in the capture window. GPU guards and measured rotation still pass.
Settings and Photos have independent NSException failures (Wallet specifier
nil dictionary and missing root album); these remain unresolved.
