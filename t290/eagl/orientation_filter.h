#ifndef T290_ORIENTATION_FILTER_H
#define T290_ORIENTATION_FILTER_H
#include <math.h>
#include <stdint.h>

/* CoreMotion gravity coordinates, g. Keep the last orientation while flat,
 * moving vigorously, or near a diagonal. A new pose must remain stable. */
typedef struct {
    double x, y, z;
    uint64_t last_ns, candidate_ns;
    unsigned candidate_samples;
    int candidate, reported;
} T290OrientationFilter;

static int t290_orientation_step(T290OrientationFilter *s,
                                double x, double y, double z, uint64_t ns)
{
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) ||
        fabs(x) > 2.5 || fabs(y) > 2.5 || fabs(z) > 2.5 || !ns) {
        s->candidate = 0; s->candidate_samples = 0;
        return 0;
    }
    if (s->last_ns && ns <= s->last_ns) return 0;
    uint64_t dt = s->last_ns ? ns - s->last_ns : 0;
    if (!s->last_ns || dt > 500000000ULL) {
        s->x = x; s->y = y; s->z = z;
        s->candidate = 0; s->candidate_samples = 0;
    } else {
        double a = (double)dt / (120000000.0 + (double)dt);
        s->x += a * (x - s->x);
        s->y += a * (y - s->y);
        s->z += a * (z - s->z);
    }
    s->last_ns = ns;
    double raw_norm = x*x + y*y + z*z;
    double ax = fabs(s->x), ay = fabs(s->y);
    int pose = 0;
    if (raw_norm >= 0.65*0.65 && raw_norm <= 1.35*1.35 && fabs(s->z) < 0.8) {
        if (ay >= 0.65 && ay > ax + 0.15) pose = s->y < 0 ? 1 : 2;
        if (ax >= 0.65 && ax > ay + 0.15) pose = s->x < 0 ? 3 : 4;
    }
    if (!pose) { s->candidate = 0; s->candidate_samples = 0; return 0; }
    if (pose != s->candidate) {
        s->candidate = pose; s->candidate_ns = ns; s->candidate_samples = 1;
        return 0;
    }
    if (s->candidate_samples < 100) ++s->candidate_samples;
    if (s->candidate_samples >= 5 && ns - s->candidate_ns >= 350000000ULL &&
        pose != s->reported) {
        s->reported = pose;
        return pose;
    }
    return 0;
}
#endif
