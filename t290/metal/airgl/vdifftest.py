#!/usr/bin/env python3
"""Differential test of translated vertex shaders: transform feedback vs airinterp.

Each case draws 3 points with random attributes / buffers / function
constants and captures every varying plus the final gl_Position. The
reference position is converted the way the GLSL does it
(x, -y, 2z - w, w).
Usage: vdifftest.py OPT_DIR GLSL_DIR [NAME_FILTER]
"""
import ctypes as C
import json
import os
import random
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
import airgl
import airinterp
import llparse

opt_dir, glsl_dir = os.path.expanduser(sys.argv[1]), os.path.expanduser(sys.argv[2])
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
                 ('glUniform1i', None, (I, I)), ('glGetUniformBlockIndex', U, (U, C.c_char_p)),
                 ('glUniformBlockBinding', None, (U, U, U)), ('glGenBuffers', None, (I, P)),
                 ('glBindBuffer', None, (U, U)), ('glBufferData', None, (U, C.c_ssize_t, P, U)),
                 ('glBindBufferBase', None, (U, U, U)), ('glGenTextures', None, (I, P)),
                 ('glBindTexture', None, (U, U)), ('glActiveTexture', None, (U,)), ('glTexBuffer', None, (U, U, U)),
                 ('glTransformFeedbackVaryings', None, (U, I, P, U)), ('glBeginTransformFeedback', None, (U,)),
                 ('glEndTransformFeedback', None, ()), ('glEnable', None, (U,)), ('glDisable', None, (U,)),
                 ('glDrawArrays', None, (U, I, I)), ('glGetError', U, ()), ('glDeleteProgram', None, (U,)),
                 ('glGenVertexArrays', None, (I, P)), ('glBindVertexArray', None, (U,)),
                 ('glVertexAttrib4fv', None, (U, P)), ('glVertexAttribI4i', None, (U, I, I, I, I)),
                 ('glMapBufferRange', P, (U, C.c_ssize_t, C.c_ssize_t, U)), ('glUnmapBuffer', U, (U,)),
                 ('glGetTransformFeedbackVarying', None, (U, U, I, P, P, P, P))]:
    G[nm[2:]] = api(gl, nm, r, *a)
vao = U(); G['GenVertexArrays'](1, C.byref(vao)); G['BindVertexArray'](vao.value)
# surfaceless context: draws need a complete framebuffer even with rasterizer discard
for nm, r, a_ in [('glGenFramebuffers', None, (I, P)), ('glBindFramebuffer', None, (U, U)),
                  ('glFramebufferTexture2D', None, (U, U, U, U, I)),
                  ('glTexImage2D', None, (U, I, I, I, I, I, U, U, P))]:
    G[nm[2:]] = api(gl, nm, r, *a_)
_t = U(); G['GenTextures'](1, C.byref(_t)); G['BindTexture'](0x0DE1, _t.value)
G['TexImage2D'](0x0DE1, 0, 0x8058, 4, 4, 0, 0x1908, 0x1401, None)
_f = U(); G['GenFramebuffers'](1, C.byref(_f)); G['BindFramebuffer'](0x8D40, _f.value)
G['FramebufferTexture2D'](0x8D40, 0x8CE0, 0x0DE1, _t.value, 0)


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


def close(a, b):
    if isinstance(a, list): return all(close(p, q) for p, q in zip(a, b))
    if a != a and b != b: return True
    if abs(b) > 1e6 or abs(a) > 1e6: return abs(a - b) <= 1e-3 * max(abs(a), abs(b))
    return abs(a - b) <= 2e-3 * (1 + abs(b))


def ncomp(t):
    return t.n if t.kind == 'vec' else 1


def run_case(mod, fn, refl, text, seed):
    random.seed(seed)
    tr = airgl.Translator(mod, fn, 'vertex')
    outs, argmeta = tr.entry_meta()
    roles = {}
    for items in argmeta:
        rest = items[1:]
        if 'air.function_constant' in rest:
            j = rest.index('air.function_constant'); rest = rest[:j] + rest[j + 2:]
        roles[items[0]] = rest
    consts = {}
    for c in refl['constants']:
        consts[c['index']] = random.randrange(2) if c['type'] == 'b' else random.randrange(4)
    attrs, bufs, args_proto = {}, {}, []
    for k, (pt, pname) in enumerate(fn.params):
        rest = roles[k]
        kind = rest[0]
        if kind == 'air.vertex_input':
            loc = rest[rest.index('air.location_index') + 1]
            v = [random.uniform(-1, 1) for _ in range(ncomp(pt))]
            attrs[loc] = v
            args_proto.append(('attr', v if pt.kind == 'vec' else v[0]))
        elif kind == 'air.vertex_id':
            args_proto.append(('vid', None))
        elif kind in ('air.instance_id', 'air.base_vertex', 'air.base_instance'):
            args_proto.append(('const', 0))
        elif kind == 'air.buffer':
            idx = rest[rest.index('air.location_index') + 1]
            b = next(x for x in refl['buffers'] if x['index'] == idx)
            size = b.get('ubo_bytes', 4096)
            data = struct.pack('<%df' % (size // 4), *[random.uniform(0.0, 1.0) for _ in range(size // 4)])
            bufs[idx] = data
            args_proto.append(('buf', airinterp.Ptr(airinterp.Mem(data, 'b%d' % idx))))
        else:
            raise RuntimeError('vertex arg kind %s' % kind)
    # capture all varyings + position
    vs_text = specialize(text, consts)
    vs_text = vs_text.rstrip()
    assert vs_text.endswith('}')
    vs_text = vs_text[:-1] + '    t290_pos = gl_Position;\n}\n'
    vs_text = vs_text.replace('void main() {', 'out vec4 t290_pos;\nvoid main() {', 1)
    vary = [o for o in refl['outputs'] if 'key' in o]
    cap = ['t290_pos'] + ['vy_' + o['key'] for o in vary]
    fs = shader(0x8B30, '#version 310 es\nprecision highp float;\nout vec4 o;\nvoid main(){o=vec4(0.0);}')
    vs = shader(0x8B31, vs_text)
    prog = G['CreateProgram'](); G['AttachShader'](prog, vs); G['AttachShader'](prog, fs)
    arr = (C.c_char_p * len(cap))(*[c.encode() for c in cap])
    G['TransformFeedbackVaryings'](prog, len(cap), arr, 0x8C8C)          # interleaved
    G['LinkProgram'](prog)
    ok = I(); G['GetProgramiv'](prog, 0x8B82, C.byref(ok))
    if not ok.value:
        buf = C.create_string_buffer(3000); G['GetProgramInfoLog'](prog, 3000, None, buf)
        raise RuntimeError('link: ' + buf.value.decode()[:300])
    G['UseProgram'](prog)
    unit, binding = 0, 0
    for b in refl['buffers']:
        data = bufs[b['index']]
        bo = U(); G['GenBuffers'](1, C.byref(bo))
        if b['kind'] == 'tbuf':
            G['BindBuffer'](0x8C2A, bo.value); G['BufferData'](0x8C2A, len(data), data, 0x88E4)
            to = U(); G['GenTextures'](1, C.byref(to))
            G['ActiveTexture'](0x84C0 + unit); G['BindTexture'](0x8C2A, to.value); G['TexBuffer'](0x8C2A, 0x8236, bo.value)
            l = G['GetUniformLocation'](prog, b['name'].encode())
            if l >= 0: G['Uniform1i'](l, unit)
            unit += 1
        else:
            G['BindBuffer'](0x8A11, bo.value); G['BufferData'](0x8A11, len(data), data, 0x88E4)
            bi = G['GetUniformBlockIndex'](prog, (b['name'] + '_blk').encode())
            if bi != 0xFFFFFFFF:
                G['UniformBlockBinding'](prog, bi, binding); G['BindBufferBase'](0x8A11, binding, bo.value)
            binding += 1
    G['ActiveTexture'](0x84C0)
    for loc, v in attrs.items():
        G['VertexAttrib4fv'](loc, (F * 4)(*(v + [0.0, 0.0, 0.0, 1.0][len(v):])))
    comps = [4] + [int(re.search(r'(\d)$', o['type']).group(1)) if o['type'][-1].isdigit() else 1 for o in vary]
    stride = sum(comps)
    nverts = 3
    tfb = U(); G['GenBuffers'](1, C.byref(tfb)); G['BindBuffer'](0x8C8E, tfb.value)
    G['BufferData'](0x8C8E, stride * 4 * nverts, None, 0x88E5)
    G['BindBufferBase'](0x8C8E, 0, tfb.value)
    G['Enable'](0x8C89)                                # RASTERIZER_DISCARD
    G['BeginTransformFeedback'](0)                     # POINTS
    G['DrawArrays'](0, 0, nverts)
    G['EndTransformFeedback'](); G['Disable'](0x8C89)
    ptr = G['MapBufferRange'](0x8C8E, 0, stride * 4 * nverts, 0x0001)
    raw_words = list((C.c_uint32 * (stride * nverts)).from_address(ptr))
    out = [struct.unpack('<f', struct.pack('<I', w))[0] for w in raw_words]
    # integer varyings are captured as int bits
    o_ = 4
    for vo, nc in zip(vary, comps[1:]):
        if vo['type'].startswith(('int', 'ivec')):
            for vtx in range(nverts):
                for c_ in range(nc):
                    k_ = vtx * stride + o_ + c_
                    out[k_] = float(struct.unpack('<i', struct.pack('<I', raw_words[k_]))[0])
        o_ += nc
    G['UnmapBuffer'](0x8C8E)
    err = G['GetError']()
    if err: raise RuntimeError('GL error %#x' % err)
    G['DeleteProgram'](prog)
    bad = []
    for vid in range(nverts):
        args = []
        for kind, v in args_proto:
            args.append(vid if kind == 'vid' else v)
        ref = airinterp.Interp(mod, consts).run(fn, args)
        fields = ref if (fn.ret.kind == 'struct') else [ref]
        row = out[vid * stride:(vid + 1) * stride]
        pos = None; vals = {}
        for f, items in zip(fields, outs):
            rest = list(items)
            if 'air.function_constant' in rest:
                j = rest.index('air.function_constant'); rest = rest[:j] + rest[j + 2:]
            if rest[0] == 'air.position': pos = f
            elif rest[0] == 'air.vertex_output': vals[airgl.varying_key(rest[1])] = f
        x, y, z, w = pos
        want = [[x, -y, 2 * z - w, w]]
        got = [row[0:4]]
        o = 4
        for vo, nc in zip(vary, comps[1:]):
            v = vals[vo['key']]
            want.append(v if isinstance(v, list) else [v])
            got.append(row[o:o + nc]); o += nc
        for g_, w_, name in zip(got, want, cap):
            if not close(list(g_), [float(e) for e in w_]):
                bad.append((vid, name, [round(e, 4) for e in g_], [round(float(e), 4) for e in w_]))
    return bad


results = {'pass': 0, 'fail': 0}
for k, name in enumerate(names):
    if only and only not in name: continue
    jp = os.path.join(glsl_dir, name + '.json')
    if not os.path.exists(jp): continue
    refl = json.load(open(jp))
    if refl['stage'] != 'vertex': continue
    text = open(os.path.join(glsl_dir, name + '.glsl')).read()
    mod = llparse.parse_module(open(os.path.join(opt_dir, 'm%03d.ll' % k)).read())
    fn = [f for f in mod.funcs.values() if f.section != 'air.static_init'][0]
    try:
        bad = []
        for seed in range(8 if refl['constants'] else 2):
            bad += run_case(mod, fn, refl, text, seed * 31 + k)
    except Exception as e:
        print('ERROR %-36s %s' % (name, str(e)[:220]), flush=True)
        results['fail'] += 1
        continue
    if bad:
        results['fail'] += 1
        print('FAIL  %-36s %s' % (name, bad[:2]), flush=True)
    else:
        results['pass'] += 1
        print('PASS  %s' % name, flush=True)
print(results)
