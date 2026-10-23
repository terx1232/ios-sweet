/* SM-T290 Bluetooth bring-up, first test: inspect WCNSS transport state.
 * Read-only: no firmware loading, PMIC/clock changes, SMD opens, FIFO writes,
 * radio traffic or iPadOS controller registration. Enabled by t290btprobe=1.
 */
#if defined(ARM64_BOARD_CONFIG_SWEET) && defined(SWEET_T290)
#include <sys/param.h>
#include <sys/systm.h>
#include <machine/machine_routines.h>
#include <pexpert/pexpert.h>
#include "sweet_t290_smem_view.h"

extern vm_offset_t ml_io_map(vm_offset_t, vm_size_t);
void sweet_t290_bt_probe(void);

void sweet_t290_bt_probe(void)
{
    int enable = 0;
    PE_parse_boot_argn("t290btprobe", &enable, sizeof(enable));
    if (!enable) return;
    vm_offset_t va = ml_io_map(0x86300000UL, 0x100000);
    if (!va) { printf("SWEET BT: SMEM map failed\n"); return; }
    const volatile uint8_t *p = (const volatile uint8_t *)va;
    /* Downstream SMEM host IDs: APPS0, Q6/ADSP2, DSPS3, WCNSS4.
     * Report table identity separately from a missing host partition. */
    uint32_t toc = 0x100000 - 4096;
    printf("SWEET BT: SMEM version=%#x toc-magic=%#x version=%u entries=%u\n",
        t290_smem_u32(p, 64 + 7*4), t290_smem_u32(p, toc),
        t290_smem_u32(p, toc + 4), t290_smem_u32(p, toc + 8));
    if (t290_smem_magic(p + toc, "$TOC")) {
        uint32_t count = t290_smem_u32(p, toc + 8);
        if (count <= (4096-32)/48) {
            for (uint32_t i = 0; i < count; ++i) {
                uint32_t e = toc + 32 + i*48;
                printf("SWEET BT: partition%u hosts=%u/%u offset=%#x size=%#x cacheline=%u\n",
                    i, t290_smem_u16(p, e+12), t290_smem_u16(p, e+14),
                    t290_smem_u32(p,e), t290_smem_u32(p,e+4), t290_smem_u32(p,e+16));
            }
        }
    }
    T290SmemView table;
    int err = t290_smem_wcnss_item(p, 0x100000, 13, &table);
    printf("SWEET BT: read-only WCNSS allocation table status=%d size=%u\n", err, table.size);
    if (err) return;
    unsigned found = 0;
    for (uint32_t i = 0; i + 32 <= table.size && i < 64*32; i += 32) {
        uint32_t e = table.offset + i;
        char name[21];
        for (unsigned j = 0; j < 20; ++j) name[j] = (char)p[e+j];
        name[20] = 0;
        if (strcmp(name, "APPS_RIVA_BT_CMD") && strcmp(name, "APPS_RIVA_BT_ACL")) continue;
        uint32_t cid = t290_smem_u32(p, e + 20);
        uint32_t type = t290_smem_u32(p, e + 24);
        if (cid >= 64) { printf("SWEET BT: invalid channel id %u\n", cid); continue; }
        T290SmemView control, fifo;
        int ce = t290_smem_wcnss_item(p, 0x100000, (uint16_t)(14 + cid), &control);
        int fe = t290_smem_wcnss_item(p, 0x100000, (uint16_t)(338 + cid), &fifo);
        printf("SWEET BT: %s cid=%u type=%#x control=%d/%u fifo=%d/%u\n",
            name, cid, type, ce, control.size, fe, fifo.size);
        if (ce || fe || (control.size != 40 && control.size != 88) ||
            fifo.size < 128 || (fifo.size & (fifo.size-1))) continue;
        uint32_t half = control.size / 2, head = half == 20 ? 16 : 40;
        uint32_t tx = control.offset, rx = tx + half;
        printf("SWEET BT: %s local-state=%u remote-state=%u tx-head=%u rx-head=%u half-fifo=%u\n",
            name, t290_smem_u32(p, tx), t290_smem_u32(p, rx),
            t290_smem_u32(p, tx + head), t290_smem_u32(p, rx + head), fifo.size / 2);
        ++found;
    }
    printf("SWEET BT: probe complete, %u valid channels; no controller commands sent\n", found);
}
#endif
