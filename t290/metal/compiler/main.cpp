/* airglc CLI: airglc <function.bc> <entry> [index=v[,v..] ...] -o <out.glsl> [-j <out.json>]
 * Host test driver for airglc.cpp; t290/metal/airgl/spectest.py drives it the same way as the Python path. */
#include "airglc.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static bool slurp(const char *path, std::vector<char> &out)
{
	FILE *f = fopen(path, "rb");
	if (!f) return false;
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.insert(out.end(), buf, buf + n);
	fclose(f);
	return true;
}

static bool spit(const char *path, const char *s)
{
	FILE *f = strcmp(path, "-") ? fopen(path, "wb") : stdout;
	if (!f) return false;
	fputs(s, f);
	if (f != stdout) fclose(f);
	return true;
}

int main(int argc, char **argv)
{
	const char *in = nullptr, *entry = nullptr, *out = "-", *jout = nullptr;
	std::vector<airglc_constant> consts;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-o") && i + 1 < argc) out = argv[++i];
		else if (!strcmp(argv[i], "-j") && i + 1 < argc) jout = argv[++i];
		else if (strchr(argv[i], '=')) {
			airglc_constant c{};
			char *p = argv[i];
			c.index = (uint32_t)strtoul(p, &p, 10);
			p++;
			while (c.count < 4) {
				c.value[c.count++] = strtod(p, &p);
				if (*p != ',') break;
				p++;
			}
			consts.push_back(c);
		} else if (!in) in = argv[i];
		else if (!entry) entry = argv[i];
		else { fprintf(stderr, "unexpected argument %s\n", argv[i]); return 64; }
	}
	if (!in || !entry) {
		fprintf(stderr, "usage: airglc <in.bc> <entry> [index=v[,v..]...] [-o out.glsl] [-j out.json]\n");
		return 64;
	}
	std::vector<char> bc;
	if (!slurp(in, bc)) { perror(in); return 66; }
	char *glsl, *json, *err;
	int rc = airglc_compile(bc.data(), bc.size(), entry, consts.data(), consts.size(), &glsl, &json, &err);
	if (rc) {
		fprintf(stderr, "airglc: %s\n", err);
		airglc_free(err);
		return rc;
	}
	bool ok = spit(out, glsl) && (!jout || spit(jout, json));
	airglc_free(glsl);
	airglc_free(json);
	return ok ? 0 : 74;
}
