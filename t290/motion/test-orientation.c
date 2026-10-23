#include <assert.h>
#include <stdio.h>
#include "../eagl/orientation_filter.h"

static uint64_t now = 1000000000ULL;
static int samples(T290OrientationFilter *s, double x, double y, double z, int n)
{
    int count = 0;
    while (n--) {
        now += 40000000;
        if (t290_orientation_step(s, x, y, z, now)) ++count;
    }
    return count;
}
int main(void)
{
    T290OrientationFilter s = {0};
    /* Stable tails from labelled device recordings, after the new axis map. */
    assert(samples(&s, -0.06, -1.01, -0.14, 5) == 0);
    assert(samples(&s, -0.06, -1.01, -0.14, 20) == 1 && s.reported == 1);
    assert(samples(&s, -0.06, -1.01, -0.14, 100) == 0); /* no update flood */
    assert(samples(&s, -1.03, -0.01, -0.15, 35) == 1 && s.reported == 3);
    assert(samples(&s, 0, 0, -1.05, 40) == 0 && s.reported == 3); /* flat */
    assert(samples(&s, 0.707, -0.707, 0, 40) == 0 && s.reported == 3);
    assert(samples(&s, 0, 1, 0, 40) == 1 && s.reported == 2);
    assert(samples(&s, 1, 0, 0, 40) == 1 && s.reported == 4);
    assert(samples(&s, 0, -1, 0, 40) == 1 && s.reported == 1);
    assert(samples(&s, 0, -2, 0, 30) == 0 && s.reported == 1); /* vigorous motion */
    assert(samples(&s, NAN, 0, 0, 20) == 0);
    assert(samples(&s, INFINITY, 0, 0, 20) == 0);
    assert(t290_orientation_step(&s, 1, 0, 0, 0) == 0);
    assert(t290_orientation_step(&s, 1, 0, 0, s.last_ns) == 0);
    assert(t290_orientation_step(&s, 1, 0, 0, s.last_ns - 1) == 0);
    now += 1000000000;
    assert(samples(&s, -1, 0, 0, 1) == 0); /* stale stream must debounce again */
    assert(samples(&s, -1, 0, 0, 15) == 1 && s.reported == 3);
    T290OrientationFilter jitter = {0};
    for (int i = 0; i < 100; ++i)
        assert(samples(&jitter, i&1 ? 1 : -1, 0, 0, 1) == 0);
    puts("PASS orientation: recorded poses, four rotations, flat/diagonal hold, debounce, jitter, invalid/stale input");
    return 0;
}
