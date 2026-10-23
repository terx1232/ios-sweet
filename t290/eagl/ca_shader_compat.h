/* Narrow compatibility for the observed CA inverse-mask fragment shader.
 * Apply only after the compiler reports this missing identifier. */
static char *t290_ca_coord_source(const char *source, const char *error)
{
    static const char prefix[] = "/* T290 missing coord_arg */\nuniform lowp vec4 coord_arg;\n";
    if (!source || !error || !strstr(error, "coord_arg") || !strstr(error, "undeclared") ||
        !strstr(source, "clamp(texcoord1_0, coord_arg.xy, coord_arg.zw)") ||
        !strstr(source, "color * s0 * (1.0 - s1.a)") ||
        strstr(source, "#version") || strstr(source, "coord_arg;")) return NULL;
    size_t n = strlen(source);
    if (n > 16384) return NULL;
    char *result = malloc(sizeof(prefix) + n);
    if (!result) return NULL;
    memcpy(result, prefix, sizeof(prefix)-1);
    memcpy(result+sizeof(prefix)-1, source, n+1);
    return result;
}
