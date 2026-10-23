/* Exercise the actual EAGL object and GLI ABI; no Apple GL C entry points. */
#import <Foundation/Foundation.h>
#include "surface.h"
#include <dlfcn.h>
#include <TargetConditionals.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "gl_types.h"

@interface NSObject (EAGLTest)
- (id)initWithAPI:(unsigned)api;
- (id)initWithAPI:(unsigned)api group:(id)group;
+ (BOOL)setCurrentContext:(id)context;
- (void *)getMacroContextPrivate;
- (BOOL)attachImage:(GLenum)target toCoreSurface:(IOSurfaceRef)s invertedRender:(BOOL)inverted;
@end

struct Macro { void *renderer; void *slots[1100]; };
#define CALL(slot, ret, types, ...) ((ret (*) types)m->slots[slot])(m->renderer, ##__VA_ARGS__)

static int tlog(const char *format, ...) __attribute__((format(printf, 1, 2)));
static int tlog(const char *format, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, format);
    int n = vsnprintf(buf, sizeof(buf), format, ap);
    va_end(ap);
    fputs(buf, stdout);
    void (*report)(const char *) = dlsym(RTLD_DEFAULT, "T290EAGLLog");
    if (report) report(buf);
    return n;
}
#define printf tlog

/* Actual failing layouts from the kernel-0130 compositor log. Exercise
 * output copies through Apple's object fence, not just glFinish. */
static int test_row_layouts(id ctx, struct Macro *m)
{
    const unsigned widths[] = {120, 800};
    const unsigned heights[] = {120, 1280};
    const uint32_t formats[] = {0, 0x42475241};
    for (unsigned c = 0; c < 2; c++) {
        IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (__bridge id)kIOSurfaceWidth: @(widths[c]), (__bridge id)kIOSurfaceHeight: @(heights[c]),
            (__bridge id)kIOSurfaceBytesPerElement: @4,
            (__bridge id)kIOSurfaceBytesPerRow: @(widths[c] * 4),
            (__bridge id)kIOSurfacePixelFormat: @(formats[c]), (__bridge id)kIOSurfaceIsGlobal: @YES
        });
        if (!s) return 20;
        size_t stride = IOSurfaceGetBytesPerRow(s);
        memset(IOSurfaceGetBaseAddress(s), 0x5a, stride * heights[c]);
        GLuint tex = 0, fbo = 0;
        CALL(98, void, (void *, GLsizei, GLuint *), 1, &tex);
        CALL(5, void, (void *, GLenum, GLuint), 0x0de1, tex);
        if (![ctx attachImage:0x0de1 toCoreSurface:s invertedRender:NO]) return 21;
        CALL(674, void, (void *, GLsizei, GLuint *), 1, &fbo);
        CALL(672, void, (void *, GLenum, GLuint), 0x8d40, fbo);
        CALL(677, void, (void *, GLenum, GLenum, GLenum, GLuint, GLint), 0x8d40, 0x8ce0, 0x0de1, tex, 0);
        if (CALL(675, GLenum, (void *, GLenum), 0x8d40) != 0x8cd5) return 22;
        CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 0.25f, 0.5f, 0.75f, 1.0f);
        CALL(10, void, (void *, GLbitfield), 0x4000);
        CALL(470, void, (void *, GLenum, GLuint), 0x1702, tex);
        if (CALL(102, GLenum, (void *))) return 23;
        const uint8_t *p = IOSurfaceGetBaseAddress(s);
        if (!getenv("SWEET_FAKE")) {
            for (size_t y = 0; y < heights[c]; y++) {
                for (size_t x = 0; x < widths[c]; x++) {
                    const uint8_t *q = p + y * stride + x * 4;
                    if (abs(q[0] - (c ? 191 : 64)) > 1 || abs(q[1] - 128) > 1 ||
                        abs(q[2] - (c ? 64 : 191)) > 1 || q[3] != 255) return 24;
                }
                /* Row tails survive only the bridge's padded copy. A GPU-aligned
                 * surface (kernel 0133) is rendered in place: GMEM resolves
                 * whole tiles, so its tail bytes are scratch, as on Apple's GPUs. */
                if (stride % 256)
                    for (size_t x = widths[c] * 4; x < stride; x++) if (p[y * stride + x] != 0x5a) return 25;
            }
        }
        printf("PASS output %ux%u fmt %#x stride %zu, object fence and all rows\n",
            widths[c], heights[c], formats[c], stride);
        /* Two texture names must share the same IOSurface storage. The
         * old per-texture shadows returned red/old pixels through tex1
         * after tex2 rendered into a separate shadow of the same surface. */
        GLuint alias = 0;
        CALL(98, void, (void *, GLsizei, GLuint *), 1, &alias);
        CALL(5, void, (void *, GLenum, GLuint), 0x0de1, alias);
        if (![ctx attachImage:0x0de1 toCoreSurface:s invertedRender:NO]) return 26;
        CALL(677, void, (void *, GLenum, GLenum, GLenum, GLuint, GLint), 0x8d40, 0x8ce0, 0x0de1, alias, 0);
        CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 0, 1, 0, 1);
        CALL(10, void, (void *, GLbitfield), 0x4000);
        CALL(470, void, (void *, GLenum, GLuint), 0x1702, tex);
        if (CALL(102, GLenum, (void *))) return 27;
        if (!getenv("SWEET_FAKE")) {
            const uint8_t *p = IOSurfaceGetBaseAddress(s);
            for (size_t y = 0; y < heights[c]; y++) for (size_t x = 0; x < widths[c]; x++) {
                const uint8_t *q = p + y * stride + x * 4;
                if (q[0] || q[1] != 255 || q[2] || q[3] != 255) return 28;
            }
        }
        printf("PASS shared IOSurface storage across two texture names\n");
        /* Scissored redraw (CA's damage rectangle): rows 10-19 change, the
         * rest must keep the earlier green after the object fence. */
        CALL(72, void, (void *, GLenum), 0x0c11);
        CALL(251, void, (void *, GLint, GLint, GLsizei, GLsizei), 0, 10, (GLsizei)widths[c], 10);
        CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 1, 0, 0, 1);
        CALL(10, void, (void *, GLbitfield), 0x4000);
        CALL(63, void, (void *, GLenum), 0x0c11);
        CALL(470, void, (void *, GLenum, GLuint), 0x1702, tex);
        if (CALL(102, GLenum, (void *))) return 29;
        if (!getenv("SWEET_FAKE")) {
            const uint8_t *p = IOSurfaceGetBaseAddress(s);
            for (size_t y = 0; y < heights[c]; y++) {
                BOOL red = y >= 10 && y < 20;
                const uint8_t *q = p + y * stride + (widths[c] / 2) * 4;
                unsigned r = c ? q[2] : q[0], g = q[1], b = c ? q[0] : q[2];
                if (r != (red ? 255 : 0) || g != (red ? 0 : 255) || b || q[3] != 255) return 19;
            }
        }
        printf("PASS scissored redraw copies its rows only\n");
        CALL(59, void, (void *, GLsizei, const GLuint *), 1, &alias);
        CALL(673, void, (void *, GLsizei, const GLuint *), 1, &fbo);
        CALL(59, void, (void *, GLsizei, const GLuint *), 1, &tex);
        CFRelease(s);
    }
    return 0;
}

static int test_luminance_alpha(id ctx, struct Macro *m, GLuint targetFbo, unsigned api)
{
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge id)kIOSurfaceWidth: @228, (__bridge id)kIOSurfaceHeight: @162,
        (__bridge id)kIOSurfaceBytesPerElement: @2, (__bridge id)kIOSurfaceBytesPerRow: @480,
        (__bridge id)kIOSurfacePixelFormat: @0x4c413038, (__bridge id)kIOSurfaceIsGlobal: @YES
    });
    if (!s) return 30;
    GLuint tex = 0;
    CALL(98, void, (void *, GLsizei, GLuint *), 1, &tex);
    CALL(5, void, (void *, GLenum, GLuint), 0x0de1, tex);
    if (![ctx attachImage:0x0de1 toCoreSurface:s invertedRender:NO]) return 31;
    /* trilinear on a single-level IOSurface texture, as CA does for icons */
    CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2801, 0x2703);
    CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2800, 0x2600);
    const char *sources[] = {
        "attribute vec2 position; varying vec2 uv; void main(){uv=position*0.5+0.5;gl_Position=vec4(position,0.0,1.0);}",
        "precision mediump float; varying vec2 uv; uniform sampler2D image; uniform int glyph; "
        "void main(){vec4 s=texture2D(image,uv);gl_FragColor=glyph!=0?vec4(s.a):s;}"
    };
    GLuint shaders[2], program = CALL(597, GLuint, (void *));
    for (unsigned j = 0; j < 2; j++) {
        shaders[j] = CALL(594, GLuint, (void *, GLenum), j ? 0x8b30 : 0x8b31);
        CALL(595, void, (void *, GLuint, GLsizei, const char *const *, const GLint *), shaders[j], 1, &sources[j], NULL);
        CALL(596, void, (void *, GLuint), shaders[j]);
        GLint ok = 0;
        CALL(622, void, (void *, GLuint, GLenum, GLint *), shaders[j], 0x8b81, &ok);
        if (!ok) return 32;
        CALL(598, void, (void *, GLuint, GLuint), program, shaders[j]);
    }
    CALL(630, void, (void *, GLuint, GLuint, const char *), program, 0, "position");
    CALL(599, void, (void *, GLuint), program);
    GLint ok = 0;
    CALL(622, void, (void *, GLuint, GLenum, GLint *), program, 0x8b82, &ok);
    if (!ok) return 33;
    CALL(600, void, (void *, GLuint), program);
    CALL(672, void, (void *, GLenum, GLuint), 0x8d40, targetFbo);
    CALL(335, void, (void *, GLint, GLint, GLsizei, GLsizei), 0, 0, 64, 64);
    for (unsigned round = 0; round < 2; round++) {
        if (IOSurfaceLock(s, 0, NULL)) return 36;
        uint8_t *p = IOSurfaceGetBaseAddress(s);
        size_t stride = IOSurfaceGetBytesPerRow(s);
        int lum = round ? 63 : 127, alpha = round ? 128 : 255;
        for (size_t y = 0; y < 162; y++) for (size_t x = 0; x < 228; x++) {
            p[y * stride + x * 2] = lum;
            p[y * stride + x * 2 + 1] = alpha;
        }
        if (IOSurfaceUnlock(s, 0, NULL)) return 37;
        /* Round 1 keeps the texture bound, as CA does: the new CPU pixels
         * must still reach the padded GPU copy before the draw. */
        if (!round) CALL(5, void, (void *, GLenum, GLuint), 0x0de1, tex);
        CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
        CALL(90, void, (void *));
        uint8_t pixel[4] = {0};
        CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *), 32, 32, 1, 1, 0x1908, 0x1401, pixel);
        GLenum err = CALL(102, GLenum, (void *));
        printf("LA08 round %u stride %zu sample %u,%u,%u,%u error %#x\n",
            round, stride, pixel[0], pixel[1], pixel[2], pixel[3], err);
        if (err) return 34;
        if (!getenv("SWEET_FAKE") && (abs(pixel[0] - lum) > 1 || abs(pixel[1] - lum) > 1 ||
            abs(pixel[2] - lum) > 1 || abs(pixel[3] - alpha) > 1)) return 35;
    }
    /* Formats actually seen in backboardd: alpha glyphs, BGRA images,
     * half-float intermediate layers and ASTC icons. Exercise both direct
     * sampling and alpha composition; a successful import alone is not
     * evidence that text, colors and transparency are correct. */
    const struct {
        const char *name;
        GLenum internal, format, type;
        unsigned cpp;
        uint8_t value[8], expected[4];
        BOOL straightAlpha;
    } cases[] = {
        {"RGBA icon", 0x1908, 0x1908, 0x1401, 4, {128, 0, 0, 128}, {128, 0, 0, 128}, NO},
        {"BGRA icon", 0x1908, 0x80e1, 0x1401, 4, {0, 0, 128, 128}, {128, 0, 0, 128}, NO},
        {"A8 mask", 0x1906, 0x1906, 0x1401, 1, {128}, {0, 0, 0, 128}, YES},
        {"L8 glyph", 0x1909, 0x1909, 0x1401, 1, {96}, {96, 96, 96, 255}, NO},
        {"RGBA16F layer", 0x881a, 0x1908, 0x140b, 8,
            {0x00, 0x38, 0x00, 0x34, 0x00, 0x3c, 0x00, 0x38}, {128, 64, 255, 128}, NO},
        {"ASTC icon", 0x93b0, 0, 0, 0, {0}, {128, 0, 0, 128}, NO},
    };
    GLuint upload = 0;
    CALL(98, void, (void *, GLsizei, GLuint *), 1, &upload);
    CALL(5, void, (void *, GLenum, GLuint), 0x0de1, upload);
    CALL(195, void, (void *, GLenum, GLint), 0x0cf5, 1); /* unpack alignment */
    GLint glyph = CALL(625, GLint, (void *, GLuint, const char *), program, "glyph");
    if (glyph < 0) return 62;
    for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        CALL(606, void, (void *, GLint, GLint), glyph, 0);
        if (cases[c].type == 0x140b && api < 3) continue;
        /* Reuse the same texture after the RGBA partial chain. BGRA may
         * choose different Mesa storage despite the same unsized internal
         * format; old RGBA mip levels must not make it incomplete. */
        if (cases[c].cpp) {
            uint8_t data[16 * 8];
            for (unsigned p = 0; p < 16; p++) memcpy(data + p * cases[c].cpp, cases[c].value, cases[c].cpp);
            CALL(301, void, (void *, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *),
                0x0de1, 0, cases[c].internal, 4, 4, 0, cases[c].format, cases[c].type, data);
        } else {
            /* ASTC LDR void-extent block, constant RGBA16 UNORM. */
            const uint8_t block[16] = {0xfc, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                0x80, 0x80, 0, 0, 0, 0, 0x80, 0x80};
            CALL(380, void, (void *, GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLsizei, const void *),
                0x0de1, 0, cases[c].internal, 4, 4, 0, sizeof(block), block);
        }
        /* Default mipmapped filter on a one-level icon must remain usable. */
        CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2801, 0x2703);
        CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2800, 0x2600);
        for (unsigned blend = 0; blend < 2; blend++) {
            CALL(63, void, (void *, GLenum), 0x0be2);
            CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 0, 0, 1, 1);
            CALL(10, void, (void *, GLbitfield), 0x4000);
            if (blend) {
                CALL(72, void, (void *, GLenum), 0x0be2);
                CALL(336, void, (void *, GLenum, GLenum, GLenum, GLenum),
                    cases[c].straightAlpha ? 0x0302 : 1, 0x0303, 1, 0x0303);
            }
            CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
            uint8_t pixel[4] = {0};
            CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *),
                32, 32, 1, 1, 0x1908, 0x1401, pixel);
            GLenum err = CALL(102, GLenum, (void *));
            printf("format %s blend %u sample %u,%u,%u,%u error %#x\n",
                cases[c].name, blend, pixel[0], pixel[1], pixel[2], pixel[3], err);
            if (err) return 40 + c;
            if (!getenv("SWEET_FAKE")) for (unsigned k = 0; k < 4; k++) {
                int expected = cases[c].expected[k];
                if (blend) {
                    if (k == 3) expected = 255;
                    else {
                        if (cases[c].straightAlpha) expected = (expected * cases[c].expected[3] + 127) / 255;
                        if (k == 2) expected = MIN(255, expected + 255 - cases[c].expected[3]);
                    }
                }
                if (abs(pixel[k] - expected) > 2) return 50 + c;
            }
        }
        if (cases[c].format == 0x1906) {
            /* GLES2 table 3.12: ALPHA samples (0,0,0,A). A glyph shader
             * supplies the ink color. Check premultiplied white ink as well
             * as the raw mask, rather than requiring white from GL_ALPHA. */
            CALL(606, void, (void *, GLint, GLint), glyph, 1);
            for (unsigned blend = 0; blend < 2; blend++) {
                CALL(63, void, (void *, GLenum), 0x0be2);
                CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 0, 0, 1, 1);
                CALL(10, void, (void *, GLbitfield), 0x4000);
                if (blend) {
                    CALL(72, void, (void *, GLenum), 0x0be2);
                    CALL(336, void, (void *, GLenum, GLenum, GLenum, GLenum), 1, 0x0303, 1, 0x0303);
                }
                CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
                uint8_t pixel[4] = {0};
                CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *),
                    32, 32, 1, 1, 0x1908, 0x1401, pixel);
                GLenum err = CALL(102, GLenum, (void *));
                printf("A8 white glyph blend %u sample %u,%u,%u,%u error %#x\n",
                    blend, pixel[0], pixel[1], pixel[2], pixel[3], err);
                if (err) return 63;
                const uint8_t expected[4] = {128, 128, blend ? 255 : 128, blend ? 255 : 128};
                if (!getenv("SWEET_FAKE")) for (unsigned k = 0; k < 4; k++)
                    if (abs(pixel[k] - expected[k]) > 2) return 64;
            }
            CALL(606, void, (void *, GLint, GLint), glyph, 0);
        }
        if (!c) {
            uint8_t mip[4 * 4];
            for (unsigned p = 0; p < 4; p++) memcpy(mip + p * 4, cases[c].value, 4);
            CALL(301, void, (void *, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *),
                0x0de1, 1, 0x1908, 2, 2, 0, 0x1908, 0x1401, mip);
            CALL(63, void, (void *, GLenum), 0x0be2);
            CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
            uint8_t pixel[4] = {0};
            CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *),
                32, 32, 1, 1, 0x1908, 0x1401, pixel);
            GLenum err = CALL(102, GLenum, (void *));
            printf("partial mip chain 4x4 + 2x2 (no 1x1) sample %u,%u,%u,%u error %#x\n",
                pixel[0], pixel[1], pixel[2], pixel[3], err);
            if (err) return 60;
            if (!getenv("SWEET_FAKE")) for (unsigned k = 0; k < 4; k++)
                if (abs(pixel[k] - cases[c].expected[k]) > 2) return 61;
        }
    }
    CALL(63, void, (void *, GLenum), 0x0be2);
    /* Actual CA icon surfaces: 120x120, unspecified RGBA or BGRA, with
     * 512-byte GPU-aligned rows on this kernel. Previous CPU update tests
     * covered padded LA08 mirrors, but not these direct imports. */
    CALL(606, void, (void *, GLint, GLint), glyph, 0);
    const uint8_t quadrants[4][4] = {{255,0,0,255}, {0,255,0,255},
        {0,0,255,255}, {64,32,128,128}};
    for (unsigned c = 0; c < (getenv("SWEET_FAKE") ? 2 : 5); c++) {
        BOOL external = c >= 2, readOnly = c == 4;
        unsigned bgra = c == 1 || c == 3;
        size_t sourceStride = c == 3 ? 512 : 480, sourceSize = sourceStride * 120;
        size_t prefix = 19, page = (size_t)getpagesize();
        size_t mappedSize = (prefix + sourceSize + 64 + page - 1) & ~(page - 1);
        uint8_t *allocation = NULL, *original = NULL;
        NSMutableDictionary *props = [@{
            (__bridge id)kIOSurfaceWidth: @120, (__bridge id)kIOSurfaceHeight: @120,
            (__bridge id)kIOSurfaceBytesPerElement: @4,
            (__bridge id)kIOSurfaceBytesPerRow: @(sourceStride),
            (__bridge id)kIOSurfacePixelFormat: @(bgra ? 0x42475241 : 0),
            (__bridge id)kIOSurfaceIsGlobal: @YES
        } mutableCopy];
        if (external) {
            allocation = mmap(NULL, mappedSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (allocation == MAP_FAILED) return 86;
            memset(allocation, 0x5a, mappedSize);
            original = allocation + prefix;        /* deliberately not page aligned */
            for (unsigned y = 0; y < 120; y++) for (unsigned x = 0; x < 120; x++) {
                const uint8_t *rgba = quadrants[(x >= 60) + 2 * (y >= 60)];
                uint8_t *dest = original + y * sourceStride + x * 4;
                dest[0] = rgba[bgra ? 2 : 0]; dest[1] = rgba[1];
                dest[2] = rgba[bgra ? 0 : 2]; dest[3] = rgba[3];
            }
            props[@"IOSurfaceAddress"] = @((uintptr_t)original);
            props[@"IOSurfaceAllocSize"] = @(sourceSize);
            if (c == 2) {
                NSMutableDictionary *bad = [props mutableCopy];
                bad[@"IOSurfaceAllocSize"] = @(sourceSize - 1);
                IOSurfaceRef invalid = IOSurfaceCreate((__bridge CFDictionaryRef)bad);
                if (invalid) { CFRelease(invalid); return 92; }
                printf("PASS client-memory undersized allocation rejected\n");
            }
            if (readOnly && mprotect(allocation, mappedSize, PROT_READ)) return 87;
        }
        IOSurfaceRef icon = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!icon) return 80;
        size_t iconStride = IOSurfaceGetBytesPerRow(icon);
        if (external) {
            if (iconStride != sourceStride || IOSurfaceGetAllocSize(icon) != sourceSize ||
                memcmp(IOSurfaceGetBaseAddress(icon), original, sourceSize)) return 88;
            if (readOnly && !IOSurfaceLock(icon, 0, NULL)) return 89;
            printf("PASS client-memory alias %s stride %zu size %zu, original pixels preserved\n",
                readOnly ? "read-only" : "writable", iconStride, sourceSize);
            if (readOnly) {
                /* The surface's unique mapping and pin must survive removal
                 * of the original user mapping, including the GPU upload. */
                if (munmap(allocation, mappedSize)) return 93;
                allocation = NULL;
                original = IOSurfaceGetBaseAddress(icon);
            }
        }
        GLuint iconTex = 0;
        CALL(98, void, (void *, GLsizei, GLuint *), 1, &iconTex);
        CALL(5, void, (void *, GLenum, GLuint), 0x0de1, iconTex);
        if (![ctx attachImage:0x0de1 toCoreSurface:icon invertedRender:NO]) return 81;
        CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2801, 0x2600);
        CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2800, 0x2600);
        CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2802, 0x812f);
        CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2803, 0x812f);
        for (unsigned round = 0; round < (readOnly ? 1 : 2); round++) {
            if (IOSurfaceLock(icon, readOnly ? 1 : 0, NULL)) return 82;
            uint8_t *base = external ? original : IOSurfaceGetBaseAddress(icon);
            if (!readOnly) for (unsigned y = 0; y < 120; y++) for (unsigned x = 0; x < 120; x++) {
                const uint8_t *rgba = quadrants[((x >= 60) + 2 * (y >= 60) + round) % 4];
                uint8_t *dest = base + y * iconStride + x * 4;
                dest[0] = rgba[bgra ? 2 : 0]; dest[1] = rgba[1];
                dest[2] = rgba[bgra ? 0 : 2]; dest[3] = rgba[3];
            }
            if (external && memcmp(IOSurfaceGetBaseAddress(icon), original, sourceSize)) return 90;
            if (IOSurfaceUnlock(icon, readOnly ? 1 : 0, NULL)) return 83;
            /* Keep the import bound across the second CPU update. */
            CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
            const GLint points[4][2] = {{16,16}, {48,16}, {24,40}, {40,40}};
            for (unsigned q = 0; q < 4; q++) {
                uint8_t pixel[4] = {0};
                CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *),
                    points[q][0], points[q][1], 1, 1, 0x1908, 0x1401, pixel);
                GLenum err = CALL(102, GLenum, (void *));
                printf("CPU icon %s external %u readonly %u stride %zu round %u quadrant %u RGBA %u,%u,%u,%u error %#x\n",
                    bgra ? "BGRA" : "inferred-RGBA", external, readOnly, iconStride, round, q,
                    pixel[0], pixel[1], pixel[2], pixel[3], err);
                if (err) return 84;
                if (!getenv("SWEET_FAKE")) for (unsigned k = 0; k < 4; k++)
                    if (abs(pixel[k] - quadrants[(q + round) % 4][k]) > 2) return 85;
            }
        }
        if (external && !readOnly) {
            GLuint writeFbo = 0;
            CALL(674, void, (void *, GLsizei, GLuint *), 1, &writeFbo);
            CALL(672, void, (void *, GLenum, GLuint), 0x8d40, writeFbo);
            CALL(677, void, (void *, GLenum, GLenum, GLenum, GLuint, GLint), 0x8d40, 0x8ce0, 0x0de1, iconTex, 0);
            if (CALL(675, GLenum, (void *, GLenum), 0x8d40) != 0x8cd5) return 94;
            CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 0.25f, 0.5f, 0.75f, 1.0f);
            CALL(10, void, (void *, GLbitfield), 0x4000);
            CALL(470, void, (void *, GLenum, GLuint), 0x1702, iconTex);
            if (CALL(102, GLenum, (void *))) return 95;
            for (unsigned y = 0; y < 120; y++) {
                for (unsigned x = 0; x < 120; x++) {
                    const uint8_t *q = original + y * sourceStride + x * 4;
                    if (abs(q[0] - (bgra ? 191 : 64)) > 1 || abs(q[1] - 128) > 1 ||
                        abs(q[2] - (bgra ? 64 : 191)) > 1 || q[3] != 255) return 96;
                }
                for (size_t j = 480; j < sourceStride; j++)
                    if (original[y * sourceStride + j] != 0x5a) return 97;
            }
            printf("PASS client-memory GPU publish to original %s, all rows and padding\n", bgra ? "BGRA" : "RGBA");
            CALL(672, void, (void *, GLenum, GLuint), 0x8d40, targetFbo);
            CALL(673, void, (void *, GLsizei, const GLuint *), 1, &writeFbo);
        }
        CALL(59, void, (void *, GLsizei, const GLuint *), 1, &iconTex);
        CFRelease(icon);
        if (allocation) {
            for (size_t j = 0; j < prefix; j++) if (allocation[j] != 0x5a) return 91;
            for (size_t j = prefix + sourceSize; j < mappedSize; j++) if (allocation[j] != 0x5a) return 91;
            munmap(allocation, mappedSize);
        }
    }
    CALL(195, void, (void *, GLenum, GLint), 0x0cf5, 4);
    CALL(59, void, (void *, GLsizei, const GLuint *), 1, &upload);
    CALL(600, void, (void *, GLuint), 0);
    CALL(591, void, (void *, GLuint), program);
    for (unsigned j = 0; j < 2; j++) CALL(591, void, (void *, GLuint), shaders[j]);
    CALL(59, void, (void *, GLsizei, const GLuint *), 1, &tex);
    CFRelease(s);
    return 0;
}

/* Match CA's lowp vertex color, matrix upload and an offscreen texture pass.
 * The original tests used a constant fragment color and missed these paths. */
static int test_ca_color(struct Macro *m, GLuint targetFbo)
{
    const char *sources[] = {
        "uniform highp mat4 vertex_matrix; attribute highp vec4 vertex_position; "
        "attribute lowp vec4 vertex_color; varying lowp vec4 color; varying highp vec2 uv; "
        "void main(){gl_Position=vertex_matrix*vertex_position;color=vertex_color;"
        "uv=vertex_position.xy*0.5+0.5;}",
        "precision mediump float; varying lowp vec4 color; varying highp vec2 uv; "
        "uniform sampler2D image; uniform int sample_image; "
        "void main(){gl_FragData[0]=sample_image!=0?texture2D(image,uv)*color:color;}"
    };
    GLuint shaders[2], program = CALL(597, GLuint, (void *));
    for (unsigned i = 0; i < 2; i++) {
        shaders[i] = CALL(594, GLuint, (void *, GLenum), i ? 0x8b30 : 0x8b31);
        CALL(595, void, (void *, GLuint, GLsizei, const char *const *, const GLint *), shaders[i], 1, &sources[i], NULL);
        CALL(596, void, (void *, GLuint), shaders[i]);
        GLint ok = 0;
        CALL(622, void, (void *, GLuint, GLenum, GLint *), shaders[i], 0x8b81, &ok);
        if (!ok) return 70;
        CALL(598, void, (void *, GLuint, GLuint), program, shaders[i]);
    }
    CALL(630, void, (void *, GLuint, GLuint, const char *), program, 0, "vertex_position");
    CALL(630, void, (void *, GLuint, GLuint, const char *), program, 1, "vertex_color");
    CALL(599, void, (void *, GLuint), program);
    GLint ok = 0;
    CALL(622, void, (void *, GLuint, GLenum, GLint *), program, 0x8b82, &ok);
    if (!ok) return 71;
    CALL(600, void, (void *, GLuint), program);
    GLint matrix = CALL(625, GLint, (void *, GLuint, const char *), program, "vertex_matrix");
    GLint image = CALL(625, GLint, (void *, GLuint, const char *), program, "image");
    GLint sample = CALL(625, GLint, (void *, GLuint, const char *), program, "sample_image");
    if (matrix < 0 || image < 0 || sample < 0) return 72;
    GLfloat transform[16] = {.75f,0,0,0, 0,.75f,0,0, 0,0,1,0, 0,0,0,1};
    CALL(620, void, (void *, GLint, GLsizei, GLboolean, const GLfloat *), matrix, 1, 0, transform);
    CALL(606, void, (void *, GLint, GLint), image, 1);
    CALL(606, void, (void *, GLint, GLint), sample, 0);
    CALL(63, void, (void *, GLenum), 0x0be2);
    CALL(63, void, (void *, GLenum), 0x0c11);
    CALL(335, void, (void *, GLint, GLint, GLsizei, GLsizei), 0, 0, 64, 64);
    struct Vertex { GLfloat p[4]; uint8_t color[4]; } vertices[3] = {
        {{-1,-1,0,1},{0}}, {{1,-1,0,1},{0}}, {{0,1,0,1},{0}}
    };
    /* GLContext::init_client_state: position at 0, half-float color at 32,
     * stride 48; these arrays can be in client memory instead of a VBO. */
    struct CAVertex { GLfloat p[4], uv[4]; uint16_t color[4]; uint32_t pad[2]; } ca[3] = {0};
    _Static_assert(sizeof(struct CAVertex) == 48 && offsetof(struct CAVertex, color) == 32,
        "CA vertex layout");
    for (unsigned v = 0; v < 3; v++) memcpy(ca[v].p, vertices[v].p, sizeof(ca[v].p));
    GLuint textures[2] = {0}, vbo = 0, intermediateFbo = 0;
    CALL(98, void, (void *, GLsizei, GLuint *), 2, textures);
    CALL(342, void, (void *, GLenum), 0x84c1);
    CALL(5, void, (void *, GLenum, GLuint), 0x0de1, textures[0]);
    const uint8_t white[4] = {255,255,255,255};
    CALL(301, void, (void *, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *),
        0x0de1, 0, 0x1908, 1, 1, 0, 0x1908, 0x1401, white);
    CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2801, 0x2600);
    CALL(644, void, (void *, GLsizei, GLuint *), 1, &vbo);
    CALL(642, void, (void *, GLenum, GLuint), 0x8892, vbo);
    CALL(511, void, (void *, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *),
        0, 4, 0x1406, 0, sizeof(struct Vertex), NULL);
    CALL(512, void, (void *, GLuint), 0);
    CALL(672, void, (void *, GLenum, GLuint), 0x8d40, targetFbo);
    const uint8_t colors[][4] = {{255,255,255,255}, {0,255,0,255}, {128,64,192,255}, {128,128,128,128}};
    const uint16_t half[][4] = {{0x3c00,0x3c00,0x3c00,0x3c00}, {0,0x3c00,0,0x3c00},
        {0x3800,0x3400,0x3a00,0x3c00}, {0x3800,0x3800,0x3800,0x3800}};
    const char *modes[] = {"constant", "normalized-u8", "half-vbo48", "half-client48-indexed"};
    for (unsigned array = 0; array < 4; array++) {
        CALL(642, void, (void *, GLenum, GLuint), 0x8892, array == 3 ? 0 : vbo);
        CALL(511, void, (void *, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *),
            0, 4, 0x1406, 0, array >= 2 ? sizeof(struct CAVertex) : sizeof(struct Vertex),
            array == 3 ? (const void *)ca : NULL);
        if (array == 1) {
            CALL(511, void, (void *, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *),
                1, 4, 0x1401, 1, sizeof(struct Vertex), (const void *)offsetof(struct Vertex, color));
            CALL(512, void, (void *, GLuint), 1);
        } else if (array >= 2) {
            CALL(511, void, (void *, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *),
                1, 4, 0x140b, 1, sizeof(struct CAVertex),
                array == 3 ? (const void *)ca[0].color : (const void *)offsetof(struct CAVertex, color));
            CALL(512, void, (void *, GLuint), 1);
        } else CALL(513, void, (void *, GLuint), 1);
        for (unsigned c = 0; c < 4; c++) {
            for (unsigned v = 0; v < 3; v++) {
                memcpy(vertices[v].color, colors[c], 4);
                memcpy(ca[v].color, half[c], sizeof(ca[v].color));
            }
            if (array != 3) CALL(646, void, (void *, GLenum, GLsizeiptr, const void *, GLenum),
                0x8892, array == 2 ? sizeof(ca) : sizeof(vertices),
                array == 2 ? (const void *)ca : (const void *)vertices, 0x88e4);
            if (!array) CALL(485, void, (void *, GLuint, GLfloat, GLfloat, GLfloat, GLfloat),
                1, colors[c][0]/255.f, colors[c][1]/255.f, colors[c][2]/255.f, colors[c][3]/255.f);
            if (array == 3) {
                const uint16_t indices[] = {0,1,2};
                CALL(642, void, (void *, GLenum, GLuint), 0x8893, 0);
                CALL(67, void, (void *, GLenum, GLsizei, GLenum, const void *), 4, 3, 0x1403, indices);
            } else CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
            uint8_t pixel[4] = {0};
            CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *),
                32, 32, 1, 1, 0x1908, 0x1401, pixel);
            GLenum err = CALL(102, GLenum, (void *));
            printf("CA color %s case %u RGBA %u,%u,%u,%u error %#x\n", modes[array],
                c, pixel[0], pixel[1], pixel[2], pixel[3], err);
            if (err) return 73;
            if (!getenv("SWEET_FAKE")) for (unsigned k = 0; k < 4; k++)
                if (abs(pixel[k] - colors[c][k]) > 2) return 74;
        }
    }
    CALL(642, void, (void *, GLenum, GLuint), 0x8892, vbo);
    CALL(646, void, (void *, GLenum, GLsizeiptr, const void *, GLenum), 0x8892, sizeof(vertices), vertices, 0x88e4);
    CALL(511, void, (void *, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *),
        0, 4, 0x1406, 0, sizeof(struct Vertex), NULL);
    /* Draw into a GPU texture, then sample it through a second FBO. */
    CALL(5, void, (void *, GLenum, GLuint), 0x0de1, textures[1]);
    CALL(301, void, (void *, GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *),
        0x0de1, 0, 0x1908, 64, 64, 0, 0x1908, 0x1401, NULL);
    CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2801, 0x2600);
    CALL(304, void, (void *, GLenum, GLenum, GLint), 0x0de1, 0x2800, 0x2600);
    CALL(674, void, (void *, GLsizei, GLuint *), 1, &intermediateFbo);
    CALL(672, void, (void *, GLenum, GLuint), 0x8d40, intermediateFbo);
    CALL(677, void, (void *, GLenum, GLenum, GLenum, GLuint, GLint), 0x8d40, 0x8ce0, 0x0de1, textures[1], 0);
    if (CALL(675, GLenum, (void *, GLenum), 0x8d40) != 0x8cd5) return 75;
    CALL(5, void, (void *, GLenum, GLuint), 0x0de1, textures[0]);
    CALL(513, void, (void *, GLuint), 1);
    CALL(485, void, (void *, GLuint, GLfloat, GLfloat, GLfloat, GLfloat), 1, 0, 1, 0, 1);
    CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 0, 0, 0, 0);
    CALL(10, void, (void *, GLbitfield), 0x4000);
    CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
    CALL(672, void, (void *, GLenum, GLuint), 0x8d40, targetFbo);
    CALL(5, void, (void *, GLenum, GLuint), 0x0de1, textures[1]);
    CALL(485, void, (void *, GLuint, GLfloat, GLfloat, GLfloat, GLfloat), 1, 1, 1, 1, 1);
    CALL(606, void, (void *, GLint, GLint), sample, 1);
    CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
    uint8_t pixel[4] = {0};
    CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *),
        32, 32, 1, 1, 0x1908, 0x1401, pixel);
    GLenum err = CALL(102, GLenum, (void *));
    printf("CA intermediate RGBA %u,%u,%u,%u error %#x\n", pixel[0], pixel[1], pixel[2], pixel[3], err);
    if (err || (!getenv("SWEET_FAKE") && (pixel[0] || pixel[1] != 255 || pixel[2] || pixel[3] != 255))) return 76;
    /* Real missing-program path, with the native CA state indirection and
     * pixel-space texcoords. No replacement shader is supplied by this test. */
    void (*setCA)(void *, const GLfloat *) = dlsym(RTLD_DEFAULT, "T290EAGLTestCA");
    if (!setCA) return 77;
    struct { uint64_t pad[2]; uint32_t function; } caState = {{0}, 89};
    struct { uint64_t pad[2]; void *state; } caContext = {{0}, &caState};
    _Static_assert(offsetof(__typeof__(caState), function) == 0x10 &&
        offsetof(__typeof__(caContext), state) == 0x10, "native CA function indirection");
    CALL(342, void, (void *, GLenum), 0x84c0);
    CALL(5, void, (void *, GLenum, GLuint), 0x0de1, textures[1]);
    CALL(513, void, (void *, GLuint), 2);
    CALL(485, void, (void *, GLuint, GLfloat, GLfloat, GLfloat, GLfloat), 2, 32, 32, 0, 1);
    CALL(342, void, (void *, GLenum), 0x84c1);
    CALL(600, void, (void *, GLuint), 0);
    const GLfloat colorMatrix[20] = {0,0,0,0, .25f,.5f,.75f,1, 0,0,0,0, 0,0,0,0, 0,0,0,0};
    const uint8_t expected[][4] = {{0,255,0,255}, {0,0,0,0}, {64,128,191,255}, {255,0,255,255}, {0,0,0,0}};
    for (unsigned c = 0; c < 5; c++) {
        caState.function = c == 2 ? 20 : c == 4 ? 61 : 89;
        setCA(&caContext, c == 2 ? colorMatrix : NULL);
        /* CA mutates its matrix between draws without a GL uniform upload
         * when it has no program. A saved copy would draw case1 incorrectly. */
        transform[12] = c == 1 ? 4 : 0;
        CALL(672, void, (void *, GLenum, GLuint), 0x8d40, c == 3 ? intermediateFbo : targetFbo);
        CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), c == 3 ? 1 : 0, 0, c == 3 ? 1 : 0, c == 3 ? 1 : 0);
        CALL(10, void, (void *, GLbitfield), 0x4000);
        CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
        CALL(237, void, (void *, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *),
            32, 32, 1, 1, 0x1908, 0x1401, pixel);
        GLint activeProgram = -1, activeUnit = -1, attrib2 = -1;
        CALL(104, void, (void *, GLenum, GLint *), 0x8b8d, &activeProgram);
        CALL(104, void, (void *, GLenum, GLint *), 0x84e0, &activeUnit);
        CALL(516, void, (void *, GLuint, GLenum, GLint *), 2, 0x8622, &attrib2);
        err = CALL(102, GLenum, (void *));
        printf("CA missing-program case%u RGBA %u,%u,%u,%u error %#x restored program%d unit%#x attrib2%d\n",
            c, pixel[0], pixel[1], pixel[2], pixel[3], err, activeProgram, activeUnit, attrib2);
        if (err || activeProgram || activeUnit != 0x84c1 || attrib2) return 78;
        if (!getenv("SWEET_FAKE")) for (unsigned k = 0; k < 4; k++)
            if (abs(pixel[k] - expected[c][k]) > 2) return 79;
    }
    setCA(NULL, NULL);
    transform[12] = 0;
    CALL(672, void, (void *, GLenum, GLuint), 0x8d40, targetFbo);
    CALL(342, void, (void *, GLenum), 0x84c0);
    CALL(643, void, (void *, GLsizei, const GLuint *), 1, &vbo);
    CALL(673, void, (void *, GLsizei, const GLuint *), 1, &intermediateFbo);
    CALL(59, void, (void *, GLsizei, const GLuint *), 2, textures);
    CALL(600, void, (void *, GLuint), 0);
    CALL(591, void, (void *, GLuint), program);
    for (unsigned i = 0; i < 2; i++) CALL(591, void, (void *, GLuint), shaders[i]);
    return 0;
}

static int test_main(void)
{
    @autoreleasepool {
#if TARGET_OS_IPHONE
        /* Regression: the unimplemented kernel selector used to return a
         * seemingly valid client with null shared state, crashing CA. */
        extern IOSurfaceRef IOSurfaceWrapClientImage(uint32_t, uint32_t,
            uint32_t, uint32_t, uint32_t, void *);
        uint8_t image[64 * 64 * 4] = {0};
        IOSurfaceRef wrapped = IOSurfaceWrapClientImage(64, 64, 0x42475241, 256, 0, image);
        if (wrapped) {
            printf("FAIL: client-image interposition did not take effect\n");
            CFRelease(wrapped);
            return 12;
        }
        printf("PASS: unsupported client-image wrapping uses GL uploads\n");
#endif
        /* macOS has no EAGLContext: exercise the same implementation directly. */
        Class cls = NSClassFromString(@"EAGLContext") ?: NSClassFromString(@"T290Context");
        for (unsigned api = 2; api <= 3; api++) {
            id ctx;
            if ([NSStringFromClass(cls) isEqualToString:@"T290Context"])
                ctx = [[cls alloc] initWithAPI:api group:nil];
            else ctx = [[cls alloc] initWithAPI:api];
            if (!ctx) { fprintf(stderr, "FAIL ES%u context\n", api); return 1; }
            struct Macro *m = [ctx getMacroContextPrivate];
            const char *renderer = (const char *)CALL(117, const GLubyte *, (void *, GLenum), 0x1f01);
            const char *version = (const char *)CALL(117, const GLubyte *, (void *, GLenum), 0x1f02);
            printf("ES%u renderer %s version %s\n", api, renderer, version);
            if (!renderer || !strstr(renderer, "FD504") || !strstr(version, "OpenGL ES")) return 2;
            IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)@{
                (__bridge id)kIOSurfaceWidth: @64, (__bridge id)kIOSurfaceHeight: @64,
                (__bridge id)kIOSurfaceBytesPerElement: @4, (__bridge id)kIOSurfaceBytesPerRow: @256,
                (__bridge id)kIOSurfacePixelFormat: @0x42475241, (__bridge id)kIOSurfaceIsGlobal: @YES
            });
            if (!surf) return 3;
            GLuint tex = 0, fbo = 0;
            CALL(98, void, (void *, GLsizei, GLuint *), 1, &tex);
            CALL(5, void, (void *, GLenum, GLuint), 0x0de1, tex);
            if (![ctx attachImage:0x0de1 toCoreSurface:surf invertedRender:NO]) return 4;
            CALL(674, void, (void *, GLsizei, GLuint *), 1, &fbo);
            CALL(672, void, (void *, GLenum, GLuint), 0x8d40, fbo);
            CALL(677, void, (void *, GLenum, GLenum, GLenum, GLuint, GLint), 0x8d40, 0x8ce0, 0x0de1, tex, 0);
            GLenum status = CALL(675, GLenum, (void *, GLenum), 0x8d40);
            printf("FBO status %#x\n", status);
            if (status != 0x8cd5) return 5;
            CALL(12, void, (void *, GLfloat, GLfloat, GLfloat, GLfloat), 0.25f, 0.5f, 0.75f, 1.0f);
            CALL(10, void, (void *, GLbitfield), 0x4000);
            CALL(89, void, (void *));
            GLenum err = CALL(102, GLenum, (void *));
            uint8_t *pixel = IOSurfaceGetBaseAddress(surf);
            printf("clear GL error %#x, IOSurface BGRA %u,%u,%u,%u\n", err, pixel[0], pixel[1], pixel[2], pixel[3]);
            if (err) return 6;
            /* SWEET_FAKE validates command generation only; no pixels execute. */
            if (!getenv("SWEET_FAKE") &&
                (abs(pixel[0] - 191) > 1 || abs(pixel[1] - 128) > 1 || abs(pixel[2] - 64) > 1 || pixel[3] != 255)) return 7;
            const char *sources[] = {
                "attribute vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}",
                "precision mediump float; void main(){gl_FragColor=vec4(1.0,0.0,0.0,1.0);}"
            };
            GLuint shaders[2];
            for (unsigned j = 0; j < 2; j++) {
                shaders[j] = CALL(594, GLuint, (void *, GLenum), j ? 0x8b30 : 0x8b31);
                CALL(595, void, (void *, GLuint, GLsizei, const char *const *, const GLint *), shaders[j], 1, &sources[j], NULL);
                CALL(596, void, (void *, GLuint), shaders[j]);
                GLint ok = 0;
                CALL(622, void, (void *, GLuint, GLenum, GLint *), shaders[j], 0x8b81, &ok);
                if (!ok) {
                    char log[1024] = {0};
                    CALL(623, void, (void *, GLuint, GLsizei, GLsizei *, char *), shaders[j], sizeof(log), NULL, log);
                    fprintf(stderr, "FAIL shader %u: %s\n", j, log);
                    return 8;
                }
            }
            GLuint program = CALL(597, GLuint, (void *));
            for (unsigned j = 0; j < 2; j++) CALL(598, void, (void *, GLuint, GLuint), program, shaders[j]);
            CALL(630, void, (void *, GLuint, GLuint, const char *), program, 0, "position");
            CALL(599, void, (void *, GLuint), program);
            GLint linked = 0;
            CALL(622, void, (void *, GLuint, GLenum, GLint *), program, 0x8b82, &linked);
            if (!linked) return 9;
            CALL(600, void, (void *, GLuint), program);
            GLuint vbo = 0;
            const GLfloat vertices[] = {-1,-1, 1,-1, 0,1};
            CALL(644, void, (void *, GLsizei, GLuint *), 1, &vbo);
            CALL(642, void, (void *, GLenum, GLuint), 0x8892, vbo);
            CALL(646, void, (void *, GLenum, GLsizeiptr, const void *, GLenum), 0x8892, sizeof(vertices), vertices, 0x88e4);
            CALL(511, void, (void *, GLuint, GLint, GLenum, GLboolean, GLsizei, const void *), 0, 2, 0x1406, 0, 0, NULL);
            CALL(512, void, (void *, GLuint), 0);
            CALL(335, void, (void *, GLint, GLint, GLsizei, GLsizei), 0, 0, 64, 64);
            CALL(65, void, (void *, GLenum, GLint, GLsizei), 4, 0, 3);
            CALL(89, void, (void *));
            err = CALL(102, GLenum, (void *));
            pixel += 32 * 256 + 32 * 4;
            printf("triangle GL error %#x, centre BGRA %u,%u,%u,%u\n", err, pixel[0], pixel[1], pixel[2], pixel[3]);
            if (err) return 10;
            if (!getenv("SWEET_FAKE") && (pixel[0] || pixel[1] || pixel[2] != 255 || pixel[3] != 255)) return 11;
            int layouts = test_row_layouts(ctx, m);
            if (layouts) return layouts;
            int la = test_luminance_alpha(ctx, m, fbo, api);
            if (la) return la;
            int color = test_ca_color(m, fbo);
            if (color) return color;
            CALL(643, void, (void *, GLsizei, const GLuint *), 1, &vbo);
            CALL(600, void, (void *, GLuint), 0);
            CALL(591, void, (void *, GLuint), program);
            for (unsigned j = 0; j < 2; j++) CALL(591, void, (void *, GLuint), shaders[j]);
            CALL(673, void, (void *, GLsizei, const GLuint *), 1, &fbo);
            CALL(59, void, (void *, GLsizei, const GLuint *), 1, &tex);
            CFRelease(surf);
        }
        printf("PASS EAGL ES2/ES3, GLI dispatch, IOSurface framebuffer and shaders%s\n",
            getenv("SWEET_FAKE") ? " (fake GPU; pixels not verified)" : " and GPU pixels");
    }
    return 0;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    int result = test_main();
    printf("EAGL test exit %d\n", result);
    return result;
}
