#!/usr/bin/env python3
"""Translate all inlined QuartzCore modules; compile each with Mesa (EGL surfaceless, GLES 3.1).

Function constants are given a default specialization (all 0, defined) just
for compiling; the driver supplies real values per pipeline.
Usage: run_all.py [OPT_DIR] [OUT_DIR]
"""
import ctypes as C
import glob
import json
import os
import re
import sys
import traceback

sys.path.insert(0, os.path.dirname(__file__))
import airgl

src_dir = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/air/opt')
out_dir = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else '~/air/glsl')
os.makedirs(out_dir, exist_ok=True)
names = open(os.path.join(os.path.dirname(src_dir.rstrip('/')), 'names.txt')).read().split()

os.environ.setdefault('EGL_PLATFORM', 'surfaceless')
os.environ.setdefault('LIBGL_ALWAYS_SOFTWARE', '1')
os.environ.setdefault('MESA_GLES_VERSION_OVERRIDE', '3.2')
egl = C.CDLL('libEGL.so.1'); gl = C.CDLL('libGLESv2.so.2')
P, I, U = C.c_void_p, C.c_int, C.c_uint
def api(lib, n, r, *a):
    f = getattr(lib, n); f.restype, f.argtypes = r, a; return f
dpy = api(egl, 'eglGetDisplay', P, P)(None)
api(egl, 'eglInitialize', U, P, P, P)(dpy, None, None)
cfg = P(); n = I()
attrs = (I * 5)(0x3040, 0x0040, 0x3033, 0x0001, 0x3038)   # RENDERABLE=ES3, SURFACE=PBUFFER
api(egl, 'eglChooseConfig', U, P, P, P, I, P)(dpy, attrs, C.byref(cfg), 1, C.byref(n))
api(egl, 'eglBindAPI', U, U)(0x30A0)
ctx = api(egl, 'eglCreateContext', P, P, P, P, P)(dpy, cfg, None, (I * 3)(0x3098, 3, 0x3038))
api(egl, 'eglMakeCurrent', U, P, P, P, P)(dpy, None, None, ctx)
create = api(gl, 'glCreateShader', U, U)
source = api(gl, 'glShaderSource', None, U, I, P, P)
compile_ = api(gl, 'glCompileShader', None, U)
iv = api(gl, 'glGetShaderiv', None, U, U, P)
log = api(gl, 'glGetShaderInfoLog', None, U, I, P, P)
version = api(gl, 'glGetString', C.c_char_p, U)(0x1F02)
print('GL', version)


def compile_glsl(stage, text):
    sh = create({'vertex': 0x8B31, 'fragment': 0x8B30, 'kernel': 0x91B9}[stage])
    b = text.encode()
    source(sh, 1, (C.c_char_p * 1)(b), None)
    compile_(sh)
    ok = I(); iv(sh, 0x8B81, C.byref(ok))
    buf = C.create_string_buffer(4000); log(sh, 4000, None, buf)
    return ok.value, buf.value.decode(errors='replace')


def specialize(text, refl):
    defs = ['#define T290_SPECIALIZED 1', '#define T290_LOCAL_X 8', '#define T290_LOCAL_Y 8',
            '#define T290_LOCAL_Z 1']
    for c in refl['constants']:
        defs.append('#define FC%d 0' % c['index'])
        defs.append('#define FCDEF%d 1' % c['index'])
    lines = text.split('\n')
    k = 1
    while k < len(lines) and lines[k].startswith('#extension'): k += 1
    return '\n'.join(lines[:k] + defs + lines[k:])


files = sorted(f for f in glob.glob(src_dir + '/m*.ll') if not f.endswith('.in.ll'))
stats = {'ok': 0, 'unsupported': 0, 'compile_fail': 0}
reasons = {}
for f in files:
    k = int(re.search(r'm(\d+)', f).group(1))
    fname = names[k] if k < len(names) else f
    try:
        text, refl = airgl.translate_file(f)
    except airgl.Unsupported as e:
        stats['unsupported'] += 1
        reasons.setdefault(str(e)[:80], []).append(fname)
        continue
    except Exception as e:
        stats['unsupported'] += 1
        reasons.setdefault('CRASH ' + type(e).__name__ + ' ' + str(e)[:60], []).append(fname)
        if os.environ.get('AIRGL_TRACE'): traceback.print_exc()
        continue
    base = os.path.join(out_dir, fname)
    open(base + '.glsl', 'w').write(text)
    open(base + '.json', 'w').write(json.dumps(refl, indent=1))
    ok, msg = compile_glsl(refl['stage'], specialize(text, refl))
    if ok:
        stats['ok'] += 1
    else:
        stats['compile_fail'] += 1
        first = msg.strip().split('\n')[0][:120]
        reasons.setdefault('COMPILE ' + re.sub(r'\d+:\d+\(\d+\)', '', first)[:90], []).append(fname)
        open(base + '.log', 'w').write(msg)
print(stats)
for r, fs in sorted(reasons.items(), key=lambda x: -len(x[1])):
    print('%3d  %s  e.g. %s' % (len(fs), r, ', '.join(fs[:3])))
