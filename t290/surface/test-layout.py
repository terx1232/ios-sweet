#!/usr/bin/env python3
"""Execute the actual SweetSurface layout function with small host OSObject stubs.

Usage: python3 test-layout.py PATH/TO/SweetSurface.cpp
This checks geometry only; pinning, mappings and pixels require the tablet test.
"""
import pathlib
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).read_text()
helpers = source[source.index('static uint32_t\nsweet_dict_u32'):source.index('/* Per-client mapping')]
stub = r'''
#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include <cassert>
#include <cstdio>
using IOReturn = int;
enum { kIOReturnSuccess, kIOReturnBadArgument, kIOReturnNoMemory };
#define SWEET_SURFACE_MAX_DIM 16384
#define SWEET_SURFACE_MAX_ALLOC (256u << 20)
#define SWEET_SURFACE_MAX_PLANES 20
#define SWEET_SURFACE_ROW_ALIGN 256
#define round_page(x) (((uint64_t)(x) + 4095) & ~4095ull)
struct OSObject { virtual ~OSObject() = default; };
struct OSNumber : OSObject {
    uint64_t value;
    OSNumber(uint64_t n) : value(n) {}
    uint32_t unsigned32BitValue() { return value; }
};
struct OSDictionary : OSObject {
    std::map<std::string, OSObject *> objects;
    OSObject *getObject(const char *key) { auto i = objects.find(key); return i == objects.end() ? nullptr : i->second; }
    void number(const char *key, uint64_t n) { objects[key] = new OSNumber(n); }
};
struct OSArray : OSObject {
    std::vector<OSObject *> objects;
    unsigned getCount() { return objects.size(); }
    OSObject *getObject(unsigned n) { return objects[n]; }
};
#define OSDynamicCast(type, object) dynamic_cast<type *>(object)
struct sweet_surface_plane {
    uint32_t width, height, bytesPerRow, offset, size;
    uint16_t bytesPerElement;
    uint8_t elementWidth, elementHeight;
};
struct SweetSurface {
    uint32_t width, height, bytesPerRow, offset, pixelFormat, allocSize;
    uint16_t bytesPerElement;
    uint8_t elementWidth, elementHeight;
    uint32_t cacheMode, planeCount;
    sweet_surface_plane planes[20];
};
'''
tests = r'''
int main() {
    OSDictionary p;
    p.number("IOSurfaceWidth", 120); p.number("IOSurfaceHeight", 120);
    p.number("IOSurfaceBytesPerRow", 480); p.number("IOSurfaceAllocSize", 57600);
    SweetSurface s = {};
    assert(sweet_surface_layout(&s, &p, true) == 0);
    assert(s.bytesPerRow == 480 && s.allocSize == 57600);
    assert(sweet_surface_layout(&s, &p, false) == 0);
    assert(s.bytesPerRow == 512 && s.allocSize == 61440);
    p.objects.erase("IOSurfaceBytesPerRow");
    assert(sweet_surface_layout(&s, &p, true) == 0 && s.bytesPerRow == 480);
    p.number("IOSurfaceAllocSize", 57599);
    assert(sweet_surface_layout(&s, &p, true) == kIOReturnBadArgument);
    p.number("IOSurfaceAllocSize", 57619); p.number("IOSurfaceOffset", 19);
    assert(sweet_surface_layout(&s, &p, true) == 0 && s.allocSize == 57619);
    p.number("IOSurfaceBytesPerRow", 479);
    assert(sweet_surface_layout(&s, &p, true) == kIOReturnBadArgument);
    p.number("IOSurfaceBytesPerRow", 0xffffffff);
    assert(sweet_surface_layout(&s, &p, true) == kIOReturnBadArgument);
    p.number("IOSurfaceBytesPerRow", 480); p.number("IOSurfaceOffset", 0);
    p.objects.erase("IOSurfaceAllocSize");
    assert(sweet_surface_layout(&s, &p, true) == 0 && s.allocSize == 57600);
    OSDictionary plane;
    plane.number("IOSurfacePlaneWidth", 60); plane.number("IOSurfacePlaneHeight", 60);
    plane.number("IOSurfacePlaneBytesPerElement", 2);
    OSArray planes; planes.objects.push_back(&plane); p.objects["IOSurfacePlaneInfo"] = &planes;
    assert(sweet_surface_layout(&s, &p, true) == 0 && s.planes[0].bytesPerRow == 120);
    assert(s.planes[0].size == 7200);
    plane.number("IOSurfacePlaneSize", 7199);
    assert(sweet_surface_layout(&s, &p, true) == kIOReturnBadArgument);
    plane.number("IOSurfacePlaneSize", 7200); plane.number("IOSurfacePlaneBytesPerRow", 119);
    assert(sweet_surface_layout(&s, &p, true) == kIOReturnBadArgument);
    p.objects.erase("IOSurfacePlaneInfo"); p.number("IOSurfaceWidth", 16385);
    assert(sweet_surface_layout(&s, &p, true) == kIOReturnBadArgument);
    p.number("IOSurfaceWidth", 120); p.number("IOSurfaceAllocSize", (256u << 20) + 1);
    assert(sweet_surface_layout(&s, &p, true) == kIOReturnNoMemory);
    puts("PASS actual SweetSurface layout: packed/owned rows, exact sizes, offsets, planes and bounds");
}
'''
with tempfile.TemporaryDirectory(prefix='t290-layout-') as tmp:
    cpp = pathlib.Path(tmp) / 'layout.cpp'
    exe = pathlib.Path(tmp) / 'layout-test'
    cpp.write_text(stub + helpers + tests)
    subprocess.run(['clang++', '-std=c++17', '-O1', '-fsanitize=undefined,address',
                    '-fno-omit-frame-pointer', '-no-pie', str(cpp), '-o', str(exe)], check=True)
    # Stub dictionaries own no values: short-lived test fixture allocations.
    import os
    subprocess.run([str(exe)], env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'}, check=True)
