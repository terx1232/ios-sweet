#!/usr/bin/env python3
"""Differential pixel test: airgl GLSL (software Mesa) vs airinterp (reference) on random inputs.

Fragment shaders without function constants or framebuffer inputs:
each case renders a 4x4 RGBA32F target with constant varyings, random
uniform buffers and random 4x4 RGBA8 textures (nearest, clamp), then
compares two pixels with the interpreter.
Usage: difftest.py [OPT_DIR] [GLSL_DIR] [NAME_FILTER]
"""
import ctypes as C
import json
import math
import os
import random
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
import airgl
import airinterp
import llparse

opt_dir = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/air/opt')
glsl_dir = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else '~/air/glsl')
only = sys.argv[3] if len(sys.argv) > 3 else None
names = open(os.path.join(os.path.dirname(opt_dir.rstrip('/')), 'names.txt')).read().split()

os.environ.setdefault('EGL_PLATFORM', 'surfaceless')
os.environ.setdefault('LIBGL_ALWAYS_SOFTWARE', '1')
os.environ.setdefault('MESA_GLES_VERSION_OVERRIDE', '3.2')
egl = C.CDLL('libEGL.so.1'); gl = C.CDLL('libGLESv2.so.2')
P, I, U, F = C.c_void_p, C.c_int, C.c_uint, C.c_float


def api(lib, n, r, *a):
    f = getattr(lib, n); f.restype, f.argtypes = r, a; return f


dpy = api(egl, 'eglGetDisplay', P, P)(None)
api(egl, 'eglInitialize', U, P, P, P)(dpy, None, None)
cfg = P(); n = I()
api(egl, 'eglChooseConfig', U, P, P, P, I, P)(dpy, (I * 5)(0x3040, 0x0040, 0x3033, 0x0001, 0x3038), C.byref(cfg), 1, C.byref(n))
api(egl, 'eglBindAPI', U, U)(0x30A0)
ctx = api(egl, 'eglCreateContext', P, P, P, P, P)(dpy, cfg, None, (I * 3)(0x3098, 3, 0x3038))
api(egl, 'eglMakeCurrent', U, P, P, P, P)(dpy, None, None, ctx)
G = {}
for nm, r, a in [('glCreateShader', U, (U,)), ('glShaderSource', None, (U, I, P, P)), ('glCompileShader', None, (U,)),
                 ('glGetShaderiv', None, (U, U, P)), ('glGetShaderInfoLog', None, (U, I, P, P)),
                 ('glCreateProgram', U, ()), ('glAttachShader', None, (U, U)), ('glLinkProgram', None, (U,)),
                 ('glGetProgramiv', None, (U, U, P)), ('glGetProgramInfoLog', None, (U, I, P, P)),
                 ('glUseProgram', None, (U,)), ('glGetUniformLocation', I, (U, C.c_char_p)),
                 ('glUniform1i', None, (I, I)), ('glUniform1f', None, (I, F)), ('glUniform4fv', None, (I, I, P)),
                 ('glUniform4iv', None, (I, I, P)),
                 ('glGetUniformBlockIndex', U, (U, C.c_char_p)), ('glUniformBlockBinding', None, (U, U, U)),
                 ('glGenBuffers', None, (I, P)), ('glBindBuffer', None, (U, U)), ('glBufferData', None, (U, C.c_ssize_t, P, U)),
                 ('glBindBufferBase', None, (U, U, U)), ('glGenTextures', None, (I, P)), ('glBindTexture', None, (U, U)),
                 ('glTexImage2D', None, (U, I, I, I, I, I, U, U, P)), ('glTexParameteri', None, (U, U, I)),
                 ('glActiveTexture', None, (U,)), ('glGenFramebuffers', None, (I, P)), ('glBindFramebuffer', None, (U, U)),
                 ('glFramebufferTexture2D', None, (U, U, U, U, I)), ('glCheckFramebufferStatus', U, (U,)),
                 ('glViewport', None, (I, I, I, I)), ('glDrawArrays', None, (U, I, I)),
                 ('glReadPixels', None, (I, I, I, I, U, U, P)), ('glGetError', U, ()), ('glDeleteProgram', None, (U,)),
                 ('glDeleteShader', None, (U,)), ('glClearColor', None, (F, F, F, F)), ('glClear', None, (U,)),
                 ('glGenVertexArrays', None, (I, P)), ('glBindVertexArray', None, (U,)),
                 ('glTexBuffer', None, (U, U, U)), ('glDrawBuffers', None, (I, P)), ('glReadBuffer', None, (U,)),
                 ('glTexImage3D', None, (U, I, I, I, I, I, I, U, U, P))]:
    G[nm[2:]] = api(gl, nm, r, *a)
vao = U(); G['GenVertexArrays'](1, C.byref(vao)); G['BindVertexArray'](vao.value)
W = H = 4
rt = U(); G['GenTextures'](1, C.byref(rt)); G['BindTexture'](0x0DE1, rt.value)
G['TexImage2D'](0x0DE1, 0, 0x8814, W, H, 0, 0x1908, 0x1406, None)      # RGBA32F
fbo = U(); G['GenFramebuffers'](1, C.byref(fbo)); G['BindFramebuffer'](0x8D40, fbo.value)
G['FramebufferTexture2D'](0x8D40, 0x8CE0, 0x0DE1, rt.value, 0)
assert G['CheckFramebufferStatus'](0x8D40) == 0x8CD5, 'RGBA32F framebuffer incomplete'


def shader(kind, text):
    sh = G['CreateShader'](kind)
    G['ShaderSource'](sh, 1, (C.c_char_p * 1)(text.encode()), None); G['CompileShader'](sh)
    ok = I(); G['GetShaderiv'](sh, 0x8B81, C.byref(ok))
    if not ok.value:
        buf = C.create_string_buffer(3000); G['GetShaderInfoLog'](sh, 3000, None, buf)
        raise RuntimeError('compile: ' + buf.value.decode()[:400])
    return sh


def specialize(text, consts):
    defs = ['#define T290_SPECIALIZED 1']
    for idx, v in consts.items():
        defs += ['#define FC%d %s' % (idx, v), '#define FCDEF%d 1' % idx]
    lines = text.split('\n')
    k = 1
    while k < len(lines) and lines[k].startswith('#extension'): k += 1
    return '\n'.join(lines[:k] + defs + lines[k:])


def arg_roles(mod, fn):
    tr = airgl.Translator(mod, fn, 'fragment')
    outs, args = tr.entry_meta()
    roles = {}
    for items in args:
        k = items[0]
        rest = items[1:]
        if 'air.function_constant' in rest:
            j = rest.index('air.function_constant'); rest = rest[:j] + rest[j + 2:]
        roles[k] = rest
    return roles, outs, tr


def rand_varying(t):
    if t.kind == 'float': return random.uniform(0.0, 1.0)
    if t.kind == 'vec' and t.elem.kind == 'float': return [random.uniform(0.0, 1.0) for _ in range(t.n)]
    if t.kind == 'int': return random.randrange(0, 4)
    if t.kind == 'vec': return [random.randrange(0, 4) for _ in range(t.n)]
    raise RuntimeError('varying type %r' % t)


def glsl_lit(v, t):
    if t.kind == 'float': return airgl.fnum(f32(v))
    if t.kind == 'int': return str(v)
    if t.elem.kind == 'float': return 'vec%d(%s)' % (t.n, ', '.join(airgl.fnum(f32(x)) for x in v))
    return 'ivec%d(%s)' % (t.n, ', '.join(str(x) for x in v))


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def close(a, b):
    if isinstance(a, list): return all(close(p, q) for p, q in zip(a, b))
    if a != a and b != b: return True
    if a in (float('inf'), float('-inf')) or b in (float('inf'), float('-inf')): return a == b or abs(a) > 1e30 and abs(b) > 1e30
    return abs(a - b) <= 2e-3 * (1 + abs(b))


def rand_consts(refl):
    out = {}
    for c in refl['constants']:
        t = c['type']
        if t == 'b': out[c['index']] = random.randrange(2)
        elif t == 'h': out[c['index']] = random.randrange(4)
        elif t == 'Dv3_h': out[c['index']] = [random.randrange(4) for _ in range(3)]
        else: raise RuntimeError('constant type %s' % t)
    return out


def fc_literal(v):
    if isinstance(v, list): return 'ivec%d(%s)' % (len(v), ', '.join(map(str, v)))
    return str(v)


def run_case(mod, fn, refl, text, roles, outs, seed):
    random.seed(seed)
    consts = rand_consts(refl)
    fbtex = {}
    # inputs
    params = fn.params
    varyings, args = {}, []
    bufs, texs = {}, {}
    for k, (pt, pname) in enumerate(params):
        rest = roles.get(k)
        kind = rest[0] if rest else None
        if kind == 'air.fragment_input':
            v = rand_varying(pt)
            varyings[airgl.varying_key(rest[1])] = (v, pt)
            args.append(v)
        elif kind == 'air.position':
            args.append(None)                  # filled per pixel
        elif kind == 'air.buffer':
            idx = Translator_attr(rest, 'air.location_index')
            size = next((b.get('ubo_bytes', 4096) for b in refl['buffers'] if b['index'] == idx), 4096)
            data = struct.pack('<%df' % (size // 4), *[random.uniform(0.0, 1.0) for _ in range(size // 4)])
            bufs[idx] = data
            args.append(airinterp.Ptr(airinterp.Mem(data, 'b%d' % idx)))
        elif kind == 'air.texture':
            idx = Translator_attr(rest, 'air.location_index')
            if '3d' in Translator_attr(rest, 'air.arg_type_name'):
                tx = [[[[random.randrange(256) / 255.0 for _ in range(4)] for _ in range(4)] for _ in range(4)] for _ in range(4)]
                texs[idx] = ('3d', tx)
                args.append(airinterp.Tex(4, 4, tx, idx, d=4))
            else:
                tx = [[[random.randrange(256) / 255.0 for _ in range(4)] for _ in range(4)] for _ in range(4)]
                texs[idx] = tx
                args.append(airinterp.Tex(4, 4, tx, idx))
        elif kind == 'air.sampler':
            args.append(airinterp.Smp())
        elif kind == 'air.front_facing':
            args.append(1)
        elif kind == 'air.point_coord':
            args.append([0.25, 0.75])        # triangles: GLSL source gets the same constant
        elif kind == 'air.render_target':
            rtn_ = rest[1]
            fbtex[rtn_] = [[[random.randrange(256) / 255.0 for _ in range(4)] for _ in range(W)] for _ in range(H)]
            args.append(('fb', rtn_, pt))
        else:
            raise RuntimeError('arg kind %s' % kind)
    # GL program
    vs_lines = ['#version 310 es', 'precision highp float;']
    flats = {i['key'] for i in refl['inputs'] if i.get('interp') == 'flat'}
    for key, (v, t) in varyings.items():
        flat = 'flat ' if key in flats else ''
        vs_lines.append('%sout %s vy_%s;' % (flat, glsl_in(t), key))
    vs_lines.append('void main() { vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);')
    vs_lines.append('gl_Position = vec4(p, 0.0, 1.0);')
    for key, (v, t) in varyings.items():
        vs_lines.append('vy_%s = %s;' % (key, glsl_lit(v, t)))
    vs_lines.append('}')
    vs = shader(0x8B31, '\n'.join(vs_lines))
    fs = shader(0x8B30, specialize(text.replace('gl_PointCoord', 'vec2(0.25, 0.75)'),
                                   {k: fc_literal(v) for k, v in consts.items()}))
    prog = G['CreateProgram'](); G['AttachShader'](prog, vs); G['AttachShader'](prog, fs); G['LinkProgram'](prog)
    ok = I(); G['GetProgramiv'](prog, 0x8B82, C.byref(ok))
    if not ok.value:
        buf = C.create_string_buffer(3000); G['GetProgramInfoLog'](prog, 3000, None, buf)
        raise RuntimeError('link: ' + buf.value.decode()[:300])
    G['UseProgram'](prog)
    loc = G['GetUniformLocation'](prog, b'T290_RT_HEIGHT')
    if loc >= 0: G['Uniform1f'](loc, float(H))
    binding = 0
    objs = []
    for b in refl['buffers']:
        data = bufs[b['index']]
        if b['kind'] == 'tbuf':
            bo = U(); G['GenBuffers'](1, C.byref(bo)); G['BindBuffer'](0x8C2A, bo.value)
            G['BufferData'](0x8C2A, len(data), data, 0x88E4)
            to = U(); G['GenTextures'](1, C.byref(to))
            G['ActiveTexture'](0x84C0 + 15 - binding); G['BindTexture'](0x8C2A, to.value)
            G['TexBuffer'](0x8C2A, 0x8236, bo.value)                     # R32UI
            l = G['GetUniformLocation'](prog, b['name'].encode())
            if l >= 0: G['Uniform1i'](l, 15 - binding)
            G['ActiveTexture'](0x84C0)
            binding += 1
            continue
        if b['kind'] != 'ubo': raise RuntimeError('buffer kind %s not in fragment test' % b['kind'])
        bo = U(); G['GenBuffers'](1, C.byref(bo)); G['BindBuffer'](0x8A11, bo.value)
        G['BufferData'](0x8A11, len(data), data, 0x88E4)
        bi = G['GetUniformBlockIndex'](prog, (b['name'] + '_blk').encode())
        if bi != 0xFFFFFFFF:
            G['UniformBlockBinding'](prog, bi, binding); G['BindBufferBase'](0x8A11, binding, bo.value)
        binding += 1
    unit = 0
    for pair in refl['pairs']:
        tx = texs[pair['texture']]
        to = U(); G['GenTextures'](1, C.byref(to))
        G['ActiveTexture'](0x84C0 + unit)
        if isinstance(tx, tuple):
            G['BindTexture'](0x806F, to.value)
            raw = bytes(int(round(c * 255)) for sl in tx[1] for row in sl for px in row for c in px)
            G['TexImage3D'](0x806F, 0, 0x8058, 4, 4, 4, 0, 0x1908, 0x1401, raw)
            tgt = 0x806F
        else:
            G['BindTexture'](0x0DE1, to.value)
            raw = bytes(int(round(c * 255)) for row in tx for px in row for c in px)
            G['TexImage2D'](0x0DE1, 0, 0x8058, 4, 4, 0, 0x1908, 0x1401, raw)
            tgt = 0x0DE1
        for pname, val in ((0x2801, 0x2600), (0x2800, 0x2600), (0x2802, 0x812F), (0x2803, 0x812F), (0x8072, 0x812F)):
            G['TexParameteri'](tgt, pname, val)
        l = G['GetUniformLocation'](prog, pair['name'].encode())
        if l >= 0: G['Uniform1i'](l, unit)
        unit += 1
    for rtn_, tx in fbtex.items():
        to = U(); G['GenTextures'](1, C.byref(to))
        G['ActiveTexture'](0x84C0 + unit); G['BindTexture'](0x0DE1, to.value)
        raw = bytes(int(round(c * 255)) for row in tx for px in row for c in px)
        G['TexImage2D'](0x0DE1, 0, 0x8058, W, H, 0, 0x1908, 0x1401, raw)
        for pname, val in ((0x2801, 0x2600), (0x2800, 0x2600)):
            G['TexParameteri'](0x0DE1, pname, val)
        l = G['GetUniformLocation'](prog, b'T290_FB%d' % rtn_)
        if l >= 0: G['Uniform1i'](l, unit)
        unit += 1
    G['ActiveTexture'](0x84C0)
    rtn = next((o['render_target'] for o in refl['outputs'] if 'render_target' in o), 0)
    G['BindFramebuffer'](0x8D40, fbo.value)
    for a_ in range(4): G['FramebufferTexture2D'](0x8D40, 0x8CE0 + a_, 0x0DE1, rt.value if a_ == rtn else 0, 0)
    G['DrawBuffers'](rtn + 1, (U * (rtn + 1))(*([0] * rtn + [0x8CE0 + rtn])))
    G['ReadBuffer'](0x8CE0 + rtn)
    G['Viewport'](0, 0, W, H)
    G['ClearColor'](0, 0, 0, 0); G['Clear'](0x4000)
    G['DrawArrays'](4, 0, 3)
    px = (F * (W * H * 4))()
    G['ReadPixels'](0, 0, W, H, 0x1908, 0x1406, px)
    err = G['GetError']()
    if err: raise RuntimeError('GL error %#x' % err)
    G['DeleteProgram'](prog)
    bad = []
    for (x, y) in ((0, 0), (2, 3)):
        a2 = list(args)
        for k, (pt, pname) in enumerate(params):
            r = roles.get(k)
            if r and r[0] == 'air.position':
                a2[k] = [x + 0.5, H - (y + 0.5), 0.5, 1.0]
            if isinstance(a2[k], tuple) and a2[k][0] == 'fb':
                texel = fbtex[a2[k][1]][y][x]
                t_ = a2[k][2]
                a2[k] = texel if t_.kind == 'vec' and t_.n == 4 else (texel[:t_.n] if t_.kind == 'vec' else texel[0])
        ip = airinterp.Interp(mod, consts)
        ref = ip.run(fn, a2)
        if isinstance(ref, list) and ref and isinstance(ref[0], list): ref = ref[0]      # first output
        if not isinstance(ref, list): ref = [ref]
        ref = [float(v) for v in ref] + [0.0] * (3 - len(ref)) + ([1.0] if len(ref) < 4 else [])
        got = list(px[(y * W + x) * 4:(y * W + x) * 4 + 4])
        if not close(got, ref[:4]):
            bad.append((x, y, [round(v, 4) for v in got], [round(v, 4) for v in ref[:4]]))
    return bad


def glsl_in(t):
    if t.kind == 'float': return 'float'
    if t.kind == 'int': return 'int'
    return ('vec%d' if t.elem.kind == 'float' else 'ivec%d') % t.n


def Translator_attr(items, key):
    i = items.index(key)
    return items[i + 1]


results = {'pass': 0, 'fail': 0, 'skip': 0}
for k, name in enumerate(names):
    if only and only not in name: continue
    jp = os.path.join(glsl_dir, name + '.json')
    if not os.path.exists(jp): continue
    refl = json.load(open(jp))
    if refl['stage'] != 'fragment':
        results['skip'] += 1
        continue
    text = open(os.path.join(glsl_dir, name + '.glsl')).read()
    mod = llparse.parse_module(open(os.path.join(opt_dir, 'm%03d.ll' % k)).read())
    fn = [f for f in mod.funcs.values() if f.section != 'air.static_init'][0]
    try:
        roles, outs, _ = arg_roles(mod, fn)
        bad = []
        for seed in range(12 if refl['constants'] else 3):
            bad += run_case(mod, fn, refl, text, roles, outs, seed * 7919 + k)
    except Exception as e:
        print('ERROR %-40s %s' % (name, str(e)[:200]))
        results['fail'] += 1
        continue
    if bad:
        results['fail'] += 1
        print('FAIL  %-40s %s' % (name, bad[:2]))
    else:
        results['pass'] += 1
        print('PASS  %s' % name)
print(results)
