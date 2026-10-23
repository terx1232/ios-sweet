/* PM8953 RTC, SM-T290 only. Read hardware; never change Android's RTC/alarm.
 * Android keeps wall-clock correction separately from the raw PMIC counter.
 * t290rtc_offset is calibrated against Android once, not the build timestamp.
 */
#if defined(ARM64_BOARD_CONFIG_SWEET) && defined(SWEET_T290)
#include <sys/param.h>
#include <sys/systm.h>
#include <pexpert/pexpert.h>
#include "sweet_spmi.h"
#include "sweet_t290_system_policy.h"

long sweet_t290_rtc_get(void);
void sweet_t290_rtc_set(long);

static int rtc_enabled;
static int rtc_checked;
static int64_t rtc_offset;
static int rtc_logged;

static int rtc_read(uint32_t *seconds)
{
    if (sweet_spmi_init()) return -1;
    uint8_t control;
    if (sweet_spmi_read(0, 0x6046, &control) || !(control & 0x80)) return -1;
    for (unsigned retry = 0; retry < 3; ++retry) {
        uint8_t bytes[4], low;
        for (unsigned i = 0; i < 4; ++i)
            if (sweet_spmi_read(0, 0x6048 + i, &bytes[i])) return -1;
        if (sweet_spmi_read(0, 0x6048, &low)) return -1;
        if (low < bytes[0]) continue; /* carry during the multi-byte read */
        *seconds = (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
            (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
        return 0;
    }
    return -1;
}

long sweet_t290_rtc_get(void)
{
    if (!rtc_checked) {
        PE_parse_boot_argn("t290rtc", &rtc_enabled, sizeof(rtc_enabled));
        PE_parse_boot_argn("t290rtc_offset", &rtc_offset, sizeof(rtc_offset));
        rtc_checked = 1;
    }
    if (!rtc_enabled) return 0;
    uint32_t raw;
    long epoch;
    if (rtc_read(&raw) || t290_rtc_epoch(raw, rtc_offset, &epoch)) {
        if (!rtc_logged) printf("SWEET RTC: no valid calibrated PM8953 time\n");
        rtc_logged = 1;
        return 0;
    }
    if (!rtc_logged) printf("SWEET RTC: PM8953 raw=%u offset=%lld epoch=%ld, hardware read-only\n",
        raw, rtc_offset, epoch);
    rtc_logged = 1;
    return epoch;
}

void sweet_t290_rtc_set(long epoch)
{
    uint32_t raw;
    long checked;
    if (!rtc_enabled || rtc_read(&raw)) return;
    int64_t offset = (int64_t)epoch - raw;
    if (t290_rtc_epoch(raw, offset, &checked)) return;
    rtc_offset = offset; /* correction for this boot; no PMIC writes */
}
#endif
