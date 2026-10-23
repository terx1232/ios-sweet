#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include "policy.h"
int main(void)
{
    for (int n = -2; n <= 256; ++n) {
        assert(t290_driverkit_limit(0,n) == n);
        assert(t290_driverkit_limit(1,n) == (n > 0 && n < 64 ? 64 : n));
    }
    long epoch = 42;
    assert(!t290_rtc_epoch(23695729,1769073406,&epoch) && epoch == 1792769135);
    assert(!t290_rtc_epoch(1792769135,0,&epoch) && epoch == 1792769135);
    assert(t290_rtc_epoch(0,0,&epoch));
    assert(t290_rtc_epoch(UINT32_MAX,INT64_MAX,&epoch));
    assert(t290_rtc_epoch(0,INT64_MIN,&epoch));
    assert(t290_rtc_epoch(1,4102444799LL,&epoch));
    assert(!t290_rtc_epoch(UINT32_MAX,-1000000000LL,&epoch));
    puts("PASS driverkit bounded floor/defaults and calibrated RTC bounds/overflow");
}
