#!/usr/bin/env python3
"""Difftest of LLVM-specialized uber shaders: for random function-constant sets,
specialize.py output (GLSL) vs airinterp on the original, unspecialized module.

spectest.py MODULE.ll NAME CASES
"""
import json
import os
import random
import subprocess
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))
sys.argv, args = [sys.argv[0], os.path.expanduser('~/air/opt'), os.path.expanduser('~/air/glsl'), '@none@'], sys.argv[1:]
import difftest   # noqa: E402  (sets up the GL context; runs no tests with the filter above)
import llparse    # noqa: E402

mod_path, name, cases = args[0], args[1], int(args[2])
mod = llparse.parse_module(open(mod_path).read())
fn = [f for f in mod.funcs.values() if f.section != 'air.static_init'][0]
refl0 = json.load(open(os.path.expanduser('~/air/glsl/%s.json' % name)))
roles, outs, _ = difftest.arg_roles(mod, fn)
ok = fail = 0
sizes = []
for c in range(cases):
    random.seed(1000 + c)
    consts = difftest.rand_consts(refl0)
    if 0 in consts: consts[0] = 0      # fc_generic=1 is the run-time-config path (not specializable)
    spec_args = ['%d=%s' % (k, ','.join(map(str, v)) if isinstance(v, list) else v) for k, v in consts.items()]
    prefix = os.path.expanduser('~/air/spec/%s_%d' % (name, c))
    t0 = time.time()
    subprocess.run([sys.executable, os.path.join(here, 'specialize.py'), mod_path, prefix] + spec_args,
                   check=True, stdout=subprocess.DEVNULL)
    dt = time.time() - t0
    text = open(prefix + '.glsl').read()
    refl = json.load(open(prefix + '.json'))
    sizes.append(len(text))
    # constants are folded: the template needs no FC macros (refl lists none)
    orig_rand = difftest.rand_consts
    difftest.rand_consts = lambda r, cc=consts: dict(cc)
    try:
        # buffers/textures as declared by the specialized shader; interpreter runs the original
        bad = difftest.run_case(mod, fn, refl, text, roles, outs, 7 + c)
    except Exception as e:
        bad = ['ERROR %s' % str(e)[:300]]
    finally:
        difftest.rand_consts = orig_rand
    if bad:
        fail += 1
        print('FAIL case %d consts %s: %s' % (c, consts, bad[:2]), flush=True)
    else:
        ok += 1
        print('PASS case %d (%.1fs specialize, %d bytes GLSL)' % (c, dt, len(text)), flush=True)
print('%s: %d pass, %d fail; GLSL bytes min %d max %d' % (name, ok, fail, min(sizes), max(sizes)))
