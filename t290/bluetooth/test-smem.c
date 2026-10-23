#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "smem_view.h"

static uint8_t memory[16384], clean[16384];
static void w16(unsigned o, uint16_t v) { memory[o]=(uint8_t)v; memory[o+1]=(uint8_t)(v>>8); }
static void w32(unsigned o, uint32_t v) { w16(o,(uint16_t)v); w16(o+2,(uint16_t)(v>>16)); }
static int find(unsigned id, T290SmemView *v)
{
    int r=t290_smem_wcnss_item(memory,sizeof(memory),(uint16_t)id,v);
    if (!r) assert(t290_smem_range(sizeof(memory),v->offset,v->size));
    return r;
}
int main(void)
{
    T290SmemView v;
    assert(find(13,&v)==T290_SMEM_NO_PARTITION);
    unsigned toc=sizeof(memory)-4096, part=4096;
    memcpy(memory+toc,"$TOC",4);w32(toc+4,1);w32(toc+8,1);
    w32(toc+32,part);w32(toc+36,4096);w16(toc+44,0);w16(toc+46,4);w32(toc+48,32);
    memcpy(memory+part,"$PRT",4);w16(part+4,0);w16(part+6,4);
    w32(part+8,4096);w32(part+12,80);w32(part+16,4096);
    w16(part+32,0xa5a5);w16(part+34,13);w32(part+36,32);
    assert(find(13,&v)==0 && v.offset==part+48 && v.size==32);
    assert(find(21,&v)==T290_SMEM_NOT_FOUND);
    memcpy(clean,memory,sizeof(memory));
    w16(part+40,4);assert(find(13,&v)==0 && v.size==28); /* payload padding */
    memcpy(memory,clean,sizeof(memory));w32(part+36,UINT32_MAX);
    assert(find(13,&v)==T290_SMEM_INVALID);
    memcpy(memory,clean,sizeof(memory));w16(part+32,0);
    assert(find(13,&v)==T290_SMEM_INVALID);
    memcpy(memory,clean,sizeof(memory));w32(toc+32,UINT32_MAX);
    assert(find(13,&v)==T290_SMEM_INVALID);
    memcpy(memory,clean,sizeof(memory));w32(toc+8,UINT32_MAX);
    assert(find(13,&v)==T290_SMEM_INVALID);
    memcpy(memory,clean,sizeof(memory));w16(toc+46,3);
    assert(find(13,&v)==T290_SMEM_NO_PARTITION); /* never inspect another host */
    memcpy(memory,clean,sizeof(memory));w32(part+16,4032);
    w16(part+4064,0xa5a5);w16(part+4066,21);w32(part+4068,16);w16(part+4072,8);
    assert(find(21,&v)==0 && v.offset==part+4048 && v.size==8);
    /* Walk past an entry whose payload is smaller than the cacheline. */
    w32(part+16,3984);
    w16(part+4016,0xa5a5);w16(part+4018,22);w32(part+4020,32);
    assert(find(22,&v)==0 && v.offset==part+3984 && v.size==32);
    assert(find(23,&v)==T290_SMEM_NOT_FOUND);
    /* Truncated mappings and corrupt input must never escape the mapping. */
    for (unsigned n=0;n<sizeof(memory);n+=17)
        (void)t290_smem_wcnss_item(memory,n,13,&v);
    uint32_t seed=0x290;
    for (unsigned i=0;i<20000;++i) {
        memcpy(memory,clean,sizeof(memory));
        for (unsigned j=0;j<4;++j) {
            seed=seed*1664525U+1013904223U;
            unsigned o=seed%(sizeof(memory)-4);
            w32(o,seed);
        }
        (void)find(i&1 ? 13 : 21,&v);
    }
    puts("PASS SMEM: uncached/cached allocations, host isolation, truncation, padding, bounds and 20000 corrupt fixtures");
}
