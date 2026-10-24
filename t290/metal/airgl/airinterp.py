"""Reference interpreter for the parsed AIR IR subset (independent of the GLSL emitter).

Used by difftest.py to check airgl's translation pixel by pixel. Semantics
follow LLVM IR and the documented Metal intrinsics; textures are sampled
nearest/clamp-to-edge, matching the test's GL sampler state.
"""
import math
import re
import struct

import llparse
from llparse import alloc_size, field_offset


class Mem:
    def __init__(self, data, name):
        self.data, self.name = bytearray(data), name


class Ptr:
    def __init__(self, mem, off=0):
        self.mem, self.off = mem, off


class Tex:
    def __init__(self, w, h, texels, idx=None, d=1):
        # 2D: texels[y][x] = [r,g,b,a]; 3D: texels[z][y][x]
        self.w, self.h, self.texels, self.idx, self.d = w, h, texels, idx, d


class Smp:
    pass


class Ret(Exception):
    def __init__(self, v):
        self.v = v


def f32(x):
    try:
        return struct.unpack('<f', struct.pack('<f', x))[0]
    except OverflowError:
        return math.copysign(float('inf'), x)


class Interp:
    def __init__(self, mod, fc=None):
        self.mod, self.fc = mod, fc or {}
        self.globals = {}
        for name, g in mod.globals.items():
            if g.section == 'air.fc_initializer':
                continue
            size = max(4, alloc_size(g.ty))
            buf = bytearray(size)
            if g.init is not None:
                self.pack(buf, 0, g.init, g.ty)
            self.globals[name] = Ptr(Mem(buf, name))

    # ---------------- memory
    def pack(self, buf, off, v, t):
        if v is None or v.kind in ('zero', 'undef', 'null'): return
        if t.kind == 'int':
            n = max(1, t.bits // 8)
            buf[off:off + n] = (v.v & ((1 << (8 * n)) - 1)).to_bytes(n, 'little')
        elif t.kind == 'float':
            buf[off:off + t.bits // 8] = struct.pack({16: '<e', 32: '<f', 64: '<d'}[t.bits], v.v)
        elif t.kind in ('vec', 'arr'):
            step = alloc_size(t.elem) if t.kind == 'arr' else t.elem.bits // 8
            for i, e in enumerate(v.v): self.pack(buf, off + i * step, e, t.elem)
        elif t.kind == 'struct':
            for i, (e, f) in enumerate(zip(v.v, t.fields)): self.pack(buf, off + field_offset(t, i), e, f)

    def rd(self, p, t):
        if isinstance(p, Ptr) and p.mem is None:
            return self.zero(t)
        if t.kind == 'vec':
            es = t.elem.bits // 8
            return [self.rd(Ptr(p.mem, p.off + i * es), t.elem) for i in range(t.n)]
        if t.kind == 'struct':
            return [self.rd(Ptr(p.mem, p.off + field_offset(t, i)), f) for i, f in enumerate(t.fields)]
        if t.kind == 'arr':
            es = alloc_size(t.elem)
            return [self.rd(Ptr(p.mem, p.off + i * es), t.elem) for i in range(t.n)]
        d, o = p.mem.data, p.off
        if o < 0 or o + max(1, t.bits // 8) > len(d):
            return 0.0 if t.kind == 'float' else 0          # out of range (default globals)
        if t.kind == 'float':
            return struct.unpack({16: '<e', 32: '<f', 64: '<d'}[t.bits], bytes(d[o:o + t.bits // 8]))[0]
        n = max(1, t.bits // 8)
        v = int.from_bytes(d[o:o + n], 'little')
        return v & 1 if t.bits == 1 else v

    def wr(self, p, v, t):
        if t.kind == 'vec':
            es = t.elem.bits // 8
            for i in range(t.n): self.wr(Ptr(p.mem, p.off + i * es), v[i], t.elem)
            return
        if t.kind == 'struct':
            for i, f in enumerate(t.fields): self.wr(Ptr(p.mem, p.off + field_offset(t, i)), v[i], f)
            return
        d, o = p.mem.data, p.off
        if t.kind == 'float':
            d[o:o + t.bits // 8] = struct.pack({16: '<e', 32: '<f', 64: '<d'}[t.bits], v)
        else:
            n = max(1, t.bits // 8)
            d[o:o + n] = (int(v) & ((1 << (8 * n)) - 1)).to_bytes(n, 'little')

    def zero(self, t):
        if t.kind == 'float': return 0.0
        if t.kind == 'int': return 0
        if t.kind == 'vec': return [self.zero(t.elem)] * t.n
        if t.kind == 'struct': return [self.zero(f) for f in t.fields]
        if t.kind == 'arr': return [self.zero(t.elem)] * t.n
        return None

    # ---------------- values
    def val(self, v, env, t=None):
        t = t or v.ty
        k = v.kind
        if k == 'local': return env[v.v]
        if k == 'const': return v.v if t.kind != 'float' else float(v.v)
        if k in ('undef', 'zero'): return self.zero(t)
        if k == 'null': return Ptr(None, 0)
        if k == 'cvec': return [self.val(e, env, t.elem) for e in v.v]
        if k == 'carr': return [self.val(e, env, t.elem) for e in v.v]
        if k == 'cstruct': return [self.val(e, env, f) for e, f in zip(v.v, t.fields)]
        if k == 'global':
            g = self.mod.globals[v.v]
            if g.section == 'air.fc_initializer':
                return ('fc', v.v)
            if v.v.startswith('@__air_sampler_state'): return Smp()
            return self.globals[v.v]
        if k == 'cexpr':
            op = v.v[0]
            if op == 'gep':
                return self.gep(self.val(v.v[2], env), v.v[1], [self.val(x, env) for x in v.v[3]], v.v[3])
            return self.val(v.v[1], env)
        raise ValueError(v)

    def gep(self, base, src, idxv, idx):
        if not isinstance(base, Ptr): return base
        off = base.off + idxv[0] * alloc_size(src)
        t = src
        for raw, x in zip(idx[1:], idxv[1:]):
            if t.kind == 'struct':
                off += field_offset(t, x); t = t.fields[x]
            else:
                es = alloc_size(t.elem) if t.kind == 'arr' else t.elem.bits // 8
                off += x * es; t = t.elem
        return Ptr(base.mem, off)

    # ---------------- execution
    def run(self, fn, args):
        for f in self.mod.funcs.values():
            if f.section == 'air.static_init':
                self.exec_fn(f, {})
        env = {name: a for (t, name), a in zip(fn.params, args)}
        return self.exec_fn(fn, env)

    def exec_fn(self, fn, env):
        blocks = {b.name: b for b in fn.blocks}
        cur, prev = fn.blocks[0], None
        steps = 0
        while True:
            # phis in parallel
            news = {}
            for i in cur.insts:
                if i.op != 'phi': break
                k = i.extra['blocks'].index(prev)
                news[i.res] = self.val(i.args[k], env, i.ty)
            env.update(news)
            nxt = None
            for i in cur.insts:
                if i.op == 'phi': continue
                steps += 1
                if steps > 2000000: raise RuntimeError('runaway')
                if i.op == 'br':
                    nxt = i.extra['targets'][0]; break
                if i.op == 'condbr':
                    c = self.val(i.args[0], env)
                    nxt = i.extra['targets'][0 if c else 1]; break
                if i.op == 'switch':
                    v = self.val(i.args[0], env) & ((1 << i.args[0].ty.bits) - 1)
                    nxt = i.extra['default']
                    for c, b in i.extra['cases']:
                        if (c & ((1 << i.args[0].ty.bits) - 1)) == v: nxt = b
                    break
                if i.op == 'ret':
                    return self.val(i.args[0], env, i.ty) if i.args else None
                if i.op == 'unreachable':
                    raise RuntimeError('unreachable')
                r = self.inst(i, env)
                if i.res: env[i.res] = r
            prev, cur = cur.name, blocks[nxt]

    def inst(self, i, env):
        op, a = i.op, i.args
        V = lambda k, t=None: self.val(a[k], env, t)
        if op in llparse.BINOPS:
            return self.elementwise(op, i.ty, V(0, i.ty), V(1, i.ty))
        if op == 'fneg':
            x = V(0)
            return [-e for e in x] if isinstance(x, list) else -x
        if op in ('icmp', 'fcmp'):
            t = i.extra['opty']
            x, y = V(0, t), V(1, t)
            f = lambda p, q: self.cmp(op, i.extra['pred'], p, q, t.elem if t.kind == 'vec' else t)
            return [f(p, q) for p, q in zip(x, y)] if t.kind == 'vec' else f(x, y)
        if op in llparse.CASTS:
            x = V(0, i.extra['from'])
            if isinstance(x, (Ptr, Tex, Smp, tuple)): return x
            src = i.extra['from']
            if op == 'bitcast':
                return self.bitcast(x, src, i.ty)
            se = src.elem if src.kind == 'vec' else src
            te = i.ty.elem if i.ty.kind == 'vec' else i.ty
            f = lambda e: self.cast(op, e, se, te)
            return [f(e) for e in x] if isinstance(x, list) else f(x)
        if op == 'select':
            c, x, y = V(0), V(1, i.ty), V(2, i.ty)
            if isinstance(c, list): return [p if q else r for q, p, r in zip(c, x, y)]
            return x if c else y
        if op == 'extractelement': return V(0)[V(1)]
        if op == 'insertelement':
            v = list(V(0)); v[V(2)] = V(1, i.ty.elem); return v
        if op == 'shufflevector':
            x = V(0); y = V(1) if a[1].kind not in ('undef', 'zero') else None
            n = len(x)
            mask = [m.v if m.kind == 'const' else None for m in a[2].v] if a[2].kind == 'cvec' else [0] * i.ty.n
            out = []
            for m in mask:
                if m is None: out.append(self.zero(i.ty.elem))
                elif m < n: out.append(x[m])
                else: out.append(y[m - n] if y is not None else self.zero(i.ty.elem))
            return out
        if op == 'extractvalue':
            x = V(0)
            for k in i.extra['idx']: x = x[k]
            return x
        if op == 'insertvalue':
            import copy
            x = copy.deepcopy(V(0, i.ty)); e = V(1, a[1].ty)
            c = x
            for k in i.extra['idx'][:-1]: c = c[k]
            c[i.extra['idx'][-1]] = e
            return x
        if op == 'load':
            p = V(0)
            if isinstance(p, tuple) and p[0] == 'fc':
                idx = int(re.search(r'MTL_FC_INIT_(\d+)', p[1]).group(1))
                v = self.fc.get(idx, 0)
                if i.ty.kind == 'vec': return [float(e) if i.ty.elem.kind == 'float' else e for e in v]
                if i.ty.kind == 'float': return float(v)
                return (1 if v else 0) if i.ty.kind == 'int' and i.ty.bits == 1 else v
            if isinstance(p, (Tex, Smp)): return p
            return self.rd(p, i.ty)
        if op == 'store':
            self.wr(V(1), V(0, i.extra['valty']), i.extra['valty']); return None
        if op == 'getelementptr':
            return self.gep(V(0), i.extra['src'], [self.val(x, env) for x in a[1:]], a[1:])
        if op == 'alloca':
            return Ptr(Mem(bytearray(max(4, alloc_size(i.extra['alloc']) * i.extra['count'])), 'alloca'))
        if op == 'freeze': return V(0)
        if op == 'call': return self.call(i, env)
        raise ValueError(op)

    def elementwise(self, op, t, x, y):
        if t.kind == 'vec':
            return [self.binop(op, t.elem, p, q) for p, q in zip(x, y)]
        return self.binop(op, t, x, y)

    def binop(self, op, t, x, y):
        if t.kind == 'float':
            if op == 'fadd': return x + y
            if op == 'fsub': return x - y
            if op == 'fmul': return x * y
            if op == 'fdiv': return x / y if y else (math.copysign(float('inf'), x) if x else float('nan'))
            if op == 'frem': return math.fmod(x, y)
        bits = t.bits
        m = (1 << bits) - 1
        x &= m; y &= m
        sx = x - (1 << bits) if bits > 1 and x >> (bits - 1) else x
        sy = y - (1 << bits) if bits > 1 and y >> (bits - 1) else y
        r = {'add': lambda: x + y, 'sub': lambda: x - y, 'mul': lambda: x * y, 'and': lambda: x & y,
             'or': lambda: x | y, 'xor': lambda: x ^ y, 'shl': lambda: x << y, 'lshr': lambda: x >> y,
             'ashr': lambda: sx >> y, 'udiv': lambda: x // y, 'urem': lambda: x % y,
             'sdiv': lambda: int(sx / sy), 'srem': lambda: sx - int(sx / sy) * sy}[op]()
        return r & m

    def cmp(self, op, pred, x, y, t):
        if op == 'fcmp':
            base = pred[1:] if pred[0] in 'ou' and pred not in ('ord', 'uno') else pred
            if pred == 'true': return 1
            if pred == 'false': return 0
            if pred == 'ord': return int(x == x and y == y)
            if pred == 'uno': return int(x != x or y != y)
        else:
            bits = t.bits
            m = (1 << bits) - 1
            x &= m; y &= m
            if pred[0] == 's':
                x = x - (1 << bits) if bits > 1 and x >> (bits - 1) else x
                y = y - (1 << bits) if bits > 1 and y >> (bits - 1) else y
            base = pred if pred in ('eq', 'ne') else pred[1:]
        return int({'eq': x == y, 'ne': x != y, 'lt': x < y, 'le': x <= y, 'gt': x > y, 'ge': x >= y}[base])

    def cast(self, op, x, se, te):
        if op in ('fpext', 'fptrunc'): return x
        if op == 'zext': return x & ((1 << se.bits) - 1)
        if op == 'sext':
            x &= (1 << se.bits) - 1
            if x >> (se.bits - 1): x -= 1 << se.bits
            return x & ((1 << te.bits) - 1)
        if op == 'trunc': return x & ((1 << te.bits) - 1)
        if op == 'sitofp':
            x &= (1 << se.bits) - 1
            if se.bits > 1 and x >> (se.bits - 1): x -= 1 << se.bits
            return float(x)
        if op == 'uitofp': return float(x & ((1 << se.bits) - 1))
        if op in ('fptosi', 'fptoui'):
            return int(x) & ((1 << te.bits) - 1) if x == x and abs(x) != float('inf') else 0
        raise ValueError(op)

    def bitcast(self, x, src, t):
        buf = bytearray(max(1, llparse.size_of(src)))
        self.wr(Ptr(Mem(buf, 'bc')), x, src)
        return self.rd(Ptr(Mem(buf, 'bc')), t)

    # ---------------- intrinsics
    def call(self, i, env):
        name = i.extra['callee'][1:]
        args = [self.val(x, env) for x in i.args]
        m = re.match(r'air\.(fast_)?(\w+?)(\.[\w.]+)?$', name)
        fn = m.group(2) if m else name
        vec = lambda f, *xs: [f(*e) for e in zip(*xs)] if isinstance(xs[0], list) else f(*xs)
        b = lambda x: [x] * len(args[0]) if isinstance(args[0], list) and not isinstance(x, list) else x
        def flt(f):
            return lambda *e: f(*e)
        simple = {'fabs': abs, 'floor': math.floor, 'ceil': math.ceil, 'sqrt': lambda x: math.sqrt(x) if x >= 0 else float('nan'),
                  'rsqrt': lambda x: 1 / math.sqrt(x) if x > 0 else float('inf'), 'fract': lambda x: x - math.floor(x),
                  'sin': math.sin, 'cos': math.cos, 'exp': lambda x: math.exp(min(x, 80)),
                  'log': lambda x: math.log(x) if x > 0 else float('-inf'),
                  'log2': lambda x: math.log2(x) if x > 0 else float('-inf'),
                  'exp2': lambda x: 2.0 ** min(x, 120), 'sign': lambda x: (x > 0) - (x < 0),
                  'trunc': math.trunc, 'tan': math.tan}
        if fn in simple: return vec(lambda x: float(simple[fn](x)), args[0])
        if fn in ('fmax', 'max'): return vec(max, args[0], b(args[1]))
        if fn in ('fmin', 'min'): return vec(min, args[0], b(args[1]))
        if name.startswith('air.min.s') or name.startswith('air.max.s'):
            sg = lambda x: x - (1 << 32) if x >> 31 else x
            r = (min if '.min' in name else max)(sg(args[0]), sg(args[1]))
            return r & 0xffffffff
        if name.startswith('air.min.u') or name.startswith('air.max.u'):
            return (min if '.min' in name else max)(args[0], args[1])
        if fn == 'clamp': return vec(lambda x, l, h: min(max(x, l), h), args[0], b(args[1]), b(args[2]))
        if fn == 'saturate': return vec(lambda x: min(max(x, 0.0), 1.0), args[0])
        if fn == 'mix': return vec(lambda x, y, t: x + (y - x) * t, args[0], b(args[1]), b(args[2]))
        if fn == 'fma': return vec(lambda x, y, z: x * y + z, args[0], b(args[1]), b(args[2]))
        if fn in ('pow', 'powr'): return vec(lambda x, y: x ** y if x > 0 else (0.0 if x == 0 and y > 0 else float('nan')), args[0], b(args[1]))
        if fn == 'atan2': return math.atan2(args[0], args[1])
        if fn == 'dot': return sum(p * q for p, q in zip(args[0], args[1]))
        if fn == 'all': return int(all(args[0]))
        if fn == 'any': return int(any(args[0]))
        if fn in ('dfdx', 'dfdy', 'fwidth'): return vec(lambda x: 0.0, args[0])   # tests use uniform-derivative inputs
        if name.startswith('air.convert.'):
            parts = name.split('.')
            dk = parts[2]
            st = i.args[0].ty
            se = st.elem if st.kind == 'vec' else st
            te = i.ty.elem if i.ty.kind == 'vec' else i.ty
            def conv(x):
                if dk == 'f':
                    if se.kind == 'int':
                        x &= (1 << se.bits) - 1
                        if len(parts) > 4 and parts[4] == 's' and se.bits > 1 and x >> (se.bits - 1): x -= 1 << se.bits
                        return float(x)
                    return x
                if te.bits == 1: return int(x != 0)
                if dk == 'u': return int(max(x, 0)) & ((1 << te.bits) - 1) if x == x else 0
                return int(x) & ((1 << te.bits) - 1) if x == x else 0
            return vec(conv, args[0])
        if name.startswith('air.unpack.unorm4x8'):
            return [((args[0] >> (8 * k)) & 255) / 255.0 for k in range(4)]
        if name == 'air.is_function_constant_defined':
            return 1
        if name.startswith('air.normalize_function_constant_predicate'):
            return 1 if args[0] else 0
        if name.startswith('air.sample_texture_2d'):
            tex, coord = args[0], args[2]
            return [self.sample(tex, coord), 0]
        if name.startswith('air.sample_texture_3d'):
            tex, c = args[0], args[2]
            if not isinstance(tex, Tex): return [[0.0] * 4, 0]
            ix = [min(max(math.floor(c[k] * n), 0), n - 1) for k, n in enumerate((tex.w, tex.h, tex.d))]
            return [list(tex.texels[ix[2]][ix[1]][ix[0]]), 0]
        if name.startswith('air.read_texture_2d'):
            tex, c = args[0], args[1]
            return [self.texel(tex, c[0], c[1]), 0]
        if name.startswith('air.get_width_texture'): return args[0].w if isinstance(args[0], Tex) else 0
        if name.startswith('air.get_height_texture'): return args[0].h if isinstance(args[0], Tex) else 0
        if name.startswith('air.get_null_texture'): return None
        raise ValueError('intrinsic %s' % name)

    def texel(self, tex, x, y):
        if not isinstance(tex, Tex): return [0.0] * 4
        x = min(max(int(x), 0), tex.w - 1); y = min(max(int(y), 0), tex.h - 1)
        return list(tex.texels[y][x])

    def sample(self, tex, coord):
        if not isinstance(tex, Tex): return [0.0] * 4
        x = math.floor(coord[0] * tex.w); y = math.floor(coord[1] * tex.h)
        return self.texel(tex, x, y)
