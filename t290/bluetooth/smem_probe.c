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

/* INFO/IS_CALL_AVAILABLE only: no PIL command is executed. Prefer the
 * detected SMCCC convention; do not try a different ABI after a valid reply. */
static int bt_scm_available(unsigned wide, unsigned service, unsigned command)
{
    register uint64_t x0 __asm__("x0") = (wide ? 0xc2000000UL : 0x82000000UL) | 0x601;
    register uint64_t x1 __asm__("x1") = 1; /* one value argument */
    register uint64_t x2 __asm__("x2") = 0x02000000UL | service << 8 | command;
    register uint64_t x3 __asm__("x3") = 0;
    register uint64_t x4 __asm__("x4") = 0;
    register uint64_t x5 __asm__("x5") = 0;
    register uint64_t x6 __asm__("x6") = 0;
    register uint64_t x7 __asm__("x7") = 0;
    unsigned resumes = 0;
    do {
        __asm__ volatile("smc #0" : "+r"(x0), "+r"(x1), "+r"(x2), "+r"(x3),
            "+r"(x4), "+r"(x5), "+r"(x6), "+r"(x7) : :
            "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "memory");
        if (x0 == 1) {
            x1 = 1; x2 = 0x02000000UL | service << 8 | command;
            x3 = x4 = x5 = x7 = 0; /* retain Qualcomm continuation cookie x6 */
        }
    } while (x0 == 1 && ++resumes < 64);
    if (x0 == 1) return -2; /* no ABI fallback after incomplete continuation */
    if (x0) return -1;
    return x1 == 1 ? 1 : 0;
}

void sweet_t290_bt_probe(void)
{
    int enable = 0;
    PE_parse_boot_argn("t290btprobe", &enable, sizeof(enable));
    if (!enable) return;
    int scm = 0;
    PE_parse_boot_argn("t290btscm", &scm, sizeof(scm));
    if (scm) {
        int wide = 1, available = bt_scm_available(1, 6, 1);
        if (available != 1 && available != -2) { wide = 0; available = bt_scm_available(0, 6, 1); }
        printf("SWEET BT: SCM INFO query convention=%u available=%d\n", wide ? 64 : 32, available);
        if (available == 1) {
            const unsigned commands[] = {1,2,5,7};
            for (unsigned i = 0; i < 4; ++i) {
                int ready = bt_scm_available(wide,2,commands[i]);
                printf("SWEET BT: PIL command%u API-available=%d; command not invoked\n", commands[i],ready);
                if (ready == -2) break;
            }
        }
    }
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
                uint32_t a = t290_smem_u16(p,e+12), b = t290_smem_u16(p,e+14);
                uint32_t off = t290_smem_u32(p,e), size = t290_smem_u32(p,e+4);
                if (((a == 0 && b == 4) || (a == 4 && b == 0)) && size >= 32 &&
                    t290_smem_range(toc, off, size))
                    printf("SWEET BT: WCNSS heap magic=%#x uncached-end=%#x cached-start=%#x size=%#x\n",
                        t290_smem_u32(p,off), t290_smem_u32(p,off+12),
                        t290_smem_u32(p,off+16), size);
            }
        }
    }
    unsigned found = 0;
    static const uint16_t items[2][3] = {{13,14,338},{266,138,202}};
    for (unsigned bank = 0; bank < 2; ++bank) {
    T290SmemView table;
    int err = t290_smem_wcnss_item(p, 0x100000, items[bank][0], &table);
    printf("SWEET BT: WCNSS table%u item%u status=%d size=%u\n", bank, items[bank][0], err, table.size);
    if (err) continue;
    for (uint32_t i = 0; i + 32 <= table.size && i < 64*32; i += 32) {
        uint32_t e = table.offset + i;
        char name[21];
        for (unsigned j = 0; j < 20; ++j) name[j] = (char)p[e+j];
        name[20] = 0;
        if (strcmp(name, "APPS_RIVA_BT_CMD") && strcmp(name, "APPS_RIVA_BT_ACL")) continue;
        uint32_t cid = t290_smem_u32(p, e + 20);
        uint32_t type = t290_smem_u32(p, e + 24);
        uint32_t refs = t290_smem_u32(p, e + 28);
        if (!refs || (type & 0xff) != 6) {
            printf("SWEET BT: %s not allocated on APPS/WCNSS edge type=%#x refs=%u\n", name,type,refs);
            continue;
        }
        if (cid >= 64) { printf("SWEET BT: invalid channel id %u\n", cid); continue; }
        T290SmemView control, fifo;
        int ce = t290_smem_wcnss_item(p, 0x100000, (uint16_t)(items[bank][1] + cid), &control);
        int fe = t290_smem_wcnss_item(p, 0x100000, (uint16_t)(items[bank][2] + cid), &fifo);
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
    }
    printf("SWEET BT: probe complete, %u valid channels; no controller commands sent\n", found);
}
#endif
