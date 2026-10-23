#ifndef T290_SMEM_VIEW_H
#define T290_SMEM_VIEW_H
#include <stdint.h>

/* Read-only view of the APPS/WCNSS private SMEM heap. All offsets remain
 * inside the caller's mapping. This never allocates items or changes a FIFO. */
typedef struct { uint32_t offset, size; } T290SmemView;
enum { T290_SMEM_OK = 0, T290_SMEM_INVALID = -1,
       T290_SMEM_NOT_FOUND = -2, T290_SMEM_NO_PARTITION = -3 };

static uint16_t t290_smem_u16(const volatile uint8_t *p, uint32_t o)
{
    return (uint16_t)((uint16_t)p[o] | (uint16_t)p[o+1] << 8);
}
static uint32_t t290_smem_u32(const volatile uint8_t *p, uint32_t o)
{
    return (uint32_t)p[o] | (uint32_t)p[o+1] << 8 |
           (uint32_t)p[o+2] << 16 | (uint32_t)p[o+3] << 24;
}
static int t290_smem_range(uint32_t capacity, uint32_t offset, uint32_t length)
{
    return offset <= capacity && length <= capacity - offset;
}
static int t290_smem_magic(const volatile uint8_t *p, const char *magic)
{
    return p[0] == (uint8_t)magic[0] && p[1] == (uint8_t)magic[1] &&
           p[2] == (uint8_t)magic[2] && p[3] == (uint8_t)magic[3];
}
static int t290_smem_wcnss_item(const volatile uint8_t *p, uint32_t capacity,
                               uint16_t wanted, T290SmemView *result)
{
    result->offset = result->size = 0;
    if (capacity < 4096 + 32) return T290_SMEM_INVALID;
    uint32_t toc = capacity - 4096;
    if (!t290_smem_magic(p + toc, "$TOC")) return T290_SMEM_NO_PARTITION;
    if (t290_smem_u32(p, toc + 4) != 1) return T290_SMEM_INVALID;
    uint32_t entries = t290_smem_u32(p, toc + 8);
    if (entries > (4096 - 32) / 48) return T290_SMEM_INVALID;
    for (uint32_t i = 0; i < entries; ++i) {
        uint32_t e = toc + 32 + i * 48;
        uint16_t a = t290_smem_u16(p, e + 12), b = t290_smem_u16(p, e + 14);
        if (!((a == 0 && b == 3) || (a == 3 && b == 0))) continue;
        uint32_t off = t290_smem_u32(p, e), size = t290_smem_u32(p, e + 4);
        uint32_t alignment = t290_smem_u32(p, e + 16);
        if (size < 32 || !t290_smem_range(toc, off, size) ||
            alignment < 16 || alignment > 4096 || (alignment & (alignment-1)))
            return T290_SMEM_INVALID;
        const volatile uint8_t *part = p + off;
        if (!t290_smem_magic(part, "$PRT") || t290_smem_u16(part, 4) != a ||
            t290_smem_u16(part, 6) != b || t290_smem_u32(part, 8) != size)
            return T290_SMEM_INVALID;
        uint32_t uncached = t290_smem_u32(part, 12), cached = t290_smem_u32(part, 16);
        if (uncached < 32 || uncached > cached || cached > size)
            return T290_SMEM_INVALID;
        uint32_t cursor = 32;
        while (cursor < uncached) {
            if (!t290_smem_range(uncached, cursor, 16) ||
                t290_smem_u16(part, cursor) != 0xa5a5) return T290_SMEM_INVALID;
            uint32_t length = t290_smem_u32(part, cursor + 4);
            uint32_t pad = t290_smem_u16(part, cursor + 8);
            uint32_t header_pad = t290_smem_u16(part, cursor + 10);
            uint32_t start = cursor + 16;
            if (pad > length || !t290_smem_range(uncached, start, header_pad))
                return T290_SMEM_INVALID;
            start += header_pad;
            if (!t290_smem_range(uncached, start, length)) return T290_SMEM_INVALID;
            if (t290_smem_u16(part, cursor + 2) == wanted) {
                result->offset = off + start; result->size = length - pad;
                return T290_SMEM_OK;
            }
            cursor = start + length;
        }
        /* Cached entries place their data before an aligned header. */
        uint32_t header_size = (16 + alignment - 1) & ~(alignment - 1);
        if (header_size > size) return T290_SMEM_INVALID;
        cursor = size - header_size;
        while (cursor > cached) {
            if (!t290_smem_range(size, cursor, 16) ||
                t290_smem_u16(part, cursor) != 0xa5a5) return T290_SMEM_INVALID;
            uint32_t length = t290_smem_u32(part, cursor + 4);
            uint32_t pad = t290_smem_u16(part, cursor + 8);
            if (pad > length || length > cursor || cursor - length < cached)
                return T290_SMEM_INVALID;
            if (t290_smem_u16(part, cursor + 2) == wanted) {
                result->offset = off + cursor - length; result->size = length - pad;
                return T290_SMEM_OK;
            }
            /* Cached length already includes the allocator's data padding. */
            if (header_size > cursor - length)
                return T290_SMEM_INVALID;
            cursor -= length + header_size;
        }
        return T290_SMEM_NOT_FOUND;
    }
    return T290_SMEM_NO_PARTITION;
}
#endif
