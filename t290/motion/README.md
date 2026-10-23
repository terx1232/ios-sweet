# SM-T290 accelerometer bring-up

The requested end result is automatic iPadOS screen rotation. Patch 0138 is
the first hardware test of the input path; automatic rotation is **not yet
verified or complete**. No orientation values or gyroscope readings are
fabricated. The iPadOS consumer/matching path still needs a device test.

Android read-only inspection on 2026-10-23 confirmed a Kionix KXTJ3 and no
gyroscope. The matching board configuration is `msm8937`, SoC 354, MTP:
I2C bus 4, address 0x0e, interrupt GPIO42, axes +Y/-X/+Z. Its live device tree
maps bus 4 to QUP 0x078b8000, TLMM GPIO14/15; the Linux controller is disabled
because SSC/DSP owns sensors. Both pins have pull-ups in the Android GPIO
snapshot. The persisted sensor registry also contains the KXTJ3 UUID with
bus 4/address 0x0e. Device dumps stay outside git in `dl/t290-motion`.

`kxtj3.c` uses bounded open-drain transfers on GPIO14/15 with the sensor DSP
inactive under XNU. It checks WHO_AM_I=0x35 before configuring 25Hz, high
resolution, +/-2g. It polls six output bytes together. Mapping to CoreMotion
gravity coordinates, including sign, requires confirmation in known tablet
poses. No regulator, interrupt-controller or DSP configuration is changed.
Probe failure restores pin settings; repeated read errors stop polling.

The register definitions and left-aligned output format follow the
[Kionix KXTJ3-1057 specification](https://download.mikroe.com/documents/datasheets/KXTJ3-1057.pdf).
The event uses the existing
[Apple IOHIDFamily accelerometer event API](https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-1915.140.3/IOHIDFamily/IOHIDEvent.cpp).

`hid-accel.inc` is appended to SweetHID.cpp by the patch and registers a
standard HID Sensors/Accelerometer3D service only after successful probe.
It emits timestamped 16.16 g samples with a sequence number, at 25Hz, and
logs sample values and subscriber counts every five seconds. It is opt-in
through `t290accel=1`; without that argument it does not touch the bus.

Validation before hardware: all three changed/new ARM64 objects compile,
full kernel relink succeeds, patch reverse-application check passes. Final60s QEMU smoke reaches a live PID1 without observed panic. QEMU
checks ordinary kernel boot with the sensor disabled; it cannot test this
physical sensor or prove that iPadOS subscribes to it.

Next device checks:

1. Observe probe=0/id=0x35 and sensible samples in native USB logs.
2. Check flat face-up, portrait, both landscape positions and upside-down;
   verify signs, scale and whether any consumer opens the service.
3. Trace iPadOS orientation delivery if the standard sensor service has no
   consumer. Implement the verified matching/event path, then test actual
   rotation, touch mapping, rotation lock and app orientation restrictions.

0138 preserves the 0137 graphics library and its safety guard. Recovery
replacement requires separate approval; staging an image is not flashing.
