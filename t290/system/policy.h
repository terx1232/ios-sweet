#ifndef T290_SYSTEM_POLICY_H
#define T290_SYSTEM_POLICY_H
#include <stdint.h>

/* A bounded compatibility floor for the small Apple driverkitd launch limit.
 * Preserve defaults/unlimited requests, larger limits, and all other tasks. */
static inline int t290_driverkit_limit(int driverkit, int requested)
{
    return driverkit && requested > 0 && requested < 64 ? 64 : requested;
}

static inline int t290_rtc_epoch(uint32_t raw, int64_t offset, long *epoch)
{
    /* Reject corrupt calibration before adding, including signed overflow. */
    if (offset < -4294967295LL || offset > 4294967295LL) return -1;
    int64_t result = (int64_t)raw + offset;
    if (result < 1577836800LL || result >= 4102444800LL) return -1;
    *epoch = (long)result; /* ARM64: Unix seconds, 2020..2099. */
    return 0;
}
#endif
