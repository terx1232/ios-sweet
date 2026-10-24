/* airglc: Apple AIR (Metal shader bitcode) -> GLSL ES 3.10 for the SM-T290 Metal driver.
 *
 * C++ port of t290/metal/airgl (Python reference + difftests). One call takes
 * the bitcode of one metallib function, specializes it for the given function
 * constants with LLVM (inlining, constant folding, full unrolling) and returns
 * GLSL plus a JSON reflection (buffers, textures/samplers, varyings, render
 * targets). Constants not listed count as undefined
 * (is_function_constant_defined() == false, value 0).
 */
#ifndef AIRGLC_H
#define AIRGLC_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

struct airglc_constant {
	uint32_t index;         /* [[function_constant(index)]] */
	uint32_t count;         /* 1 for scalars, 2..4 for vectors */
	double value[4];        /* bool/integer/float values */
};

/* 0: ok, *glsl and *json allocated; otherwise *error allocated.
 * Free every returned string with airglc_free(). */
int airglc_compile(const void *bitcode, size_t size, const char *function,
                   const struct airglc_constant *constants, size_t count,
                   char **glsl, char **json, char **error);
/* Function constants declared by the module: JSON array of
 * {"index": n, "name": "fc_...", "type": "b"|"h"|"Dv3_h"|...} (Itanium codes). */
int airglc_constants(const void *bitcode, size_t size, char **json, char **error);
void airglc_free(void *p);

#ifdef __cplusplus
}
#endif
#endif
