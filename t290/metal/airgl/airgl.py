#!/usr/bin/env python3
"""AIR (Apple Metal IR, inlined LLVM 14 text) -> GLSL ES 3.10 for the T290 Metal driver.

Output per entry point: a GLSL template plus a JSON reflection. Function
constants stay macros (FC<index>, FCDEF<index>) that the driver defines
when it creates a pipeline, so Mesa folds the specialised code.

Memory model (freedreno a5xx: no vertex SSBOs):
  addrspace(2) buffer args     -> std140 UBO of uvec4 words   (B<idx>_U)
  addrspace(1) read-only args  -> usamplerBuffer of R32UI     (B<idx>_T)
  addrspace(1) written args    -> SSBO of uint words           (B<idx>_S, FS/CS only)
  globals, allocas             -> GLSL uint word arrays
Coordinates: Metal clip z is 0..1 and the framebuffer origin is top-left;
the vertex stage writes gl_Position.y negated and z remapped, the fragment
stage derives Metal's position.y from T290_RT_HEIGHT.
"""
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(__file__))
import llparse
from llparse import Ty, Val, align_of, alloc_size, field_offset, size_of


class Unsupported(Exception):
    pass


# ---------------------------------------------------------------- helpers

def glsl_ty(t):
    k = t.kind
    if k == 'float': return 'float'
    if k == 'int': return 'bool' if t.bits == 1 else 'int'
    if k == 'vec':
        e = t.elem
        if t.n > 4: raise Unsupported('vector width %d' % t.n)
        if e.kind == 'float': return 'vec%d' % t.n
        if e.kind == 'int': return ('bvec%d' if e.bits == 1 else 'ivec%d') % t.n
    if k == 'struct' or k == 'arr': return struct_name(t)
    raise Unsupported('type %r' % t)


STRUCTS = {}


def struct_name(t):
    key = repr(t) if t.kind == 'arr' or not t.name else t.name
    key = repr_full(t)
    if key not in STRUCTS:
        STRUCTS[key] = ('S%d' % len(STRUCTS), t)
    return STRUCTS[key][0]


def repr_full(t):
    if t.kind == 'struct':
        return ('<' if t.packed else '') + '{' + ','.join(repr_full(f) for f in t.fields) + '}'
    if t.kind == 'arr': return '[%d x %s]' % (t.n, repr_full(t.elem))
    return repr(t)


def struct_decl(name, t):
    if t.kind == 'arr':
        return 'struct %s { %s e[%d]; };' % (name, glsl_ty(t.elem), t.n)
    return 'struct %s { %s };' % (name, ' '.join('%s f%d;' % (glsl_ty(f), i) for i, f in enumerate(t.fields)))


def fnum(x):
    if x != x: return '(0.0/0.0)'
    if x in (float('inf'), float('-inf')): return '(%s1.0/0.0)' % ('-' if x < 0 else '')
    s = repr(float(x))
    if 'e' in s or 'E' in s:
        m, e = s.lower().split('e')
        if '.' not in m: m += '.0'
        return '%se%s' % (m, e)
    return s


def ilit(x, bits=32):
    x &= (1 << 32) - 1 if bits >= 32 else (1 << bits) - 1
    if bits == 1: return 'true' if x else 'false'
    if x >= 1 << 31: x -= 1 << 32
    if x == -(1 << 31): return 'int(0x80000000u)'      # -2147483648 is not a valid GLSL literal
    return str(x) if x >= 0 else '(%d)' % x


def scalar_const(v, t):
    if v.kind in ('undef', 'zero', 'null'):
        return '0.0' if t.kind == 'float' else ('false' if t.bits == 1 else '0')
    if t.kind == 'float': return fnum(v.v)
    return ilit(v.v, t.bits)


def zero_of(t):
    if t.kind == 'float': return '0.0'
    if t.kind == 'int': return 'false' if t.bits == 1 else '0'
    if t.kind == 'vec': return '%s(%s)' % (glsl_ty(t), zero_of(t.elem))
    if t.kind == 'struct':
        return '%s(%s)' % (glsl_ty(t), ', '.join(zero_of(f) for f in t.fields))
    if t.kind == 'arr':
        return '%s(%s[%d](%s))' % (glsl_ty(t), glsl_ty(t.elem), t.n, ', '.join([zero_of(t.elem)] * t.n))
    raise Unsupported('zero of %r' % t)


# ---------------------------------------------------------------- pointers

class Ptr:
    """A compile-time pointer: memory object + byte offset (int or GLSL int expr)."""

    def __init__(self, mem, off, elem):
        self.mem, self.off, self.elem = mem, off, elem

    def add(self, o):
        if isinstance(self.off, int) and isinstance(o, int):
            return Ptr(self.mem, self.off + o, self.elem)
        if o == 0: return Ptr(self.mem, self.off, self.elem)
        return Ptr(self.mem, '(%s + %s)' % (self.off, o), self.elem)


class Choice:
    """A pointer chosen at run time among compile-time pointers: sel is a GLSL
    int expression (index into opts). Typically decided by function constants."""

    def __init__(self, sel, opts, elem=None):
        self.sel, self.opts, self.elem = sel, opts, elem

    def map(self, f):
        return Choice(self.sel, [f(o) for o in self.opts], self.elem)

    def pick(self, exprs):
        out = exprs[-1]
        for k in range(len(exprs) - 2, -1, -1):
            out = '((%s) == %d ? %s : %s)' % (self.sel, k, exprs[k], out)
        return out


class Mem:
    """kind: ubo tbuf ssbo array texture sampler fc null"""

    def __init__(self, kind, name, **kw):
        self.kind, self.name = kind, name
        self.__dict__.update(kw)


# ---------------------------------------------------------------- translator

class Translator:
    def __init__(self, mod, fn, stage):
        self.mod, self.fn, self.stage = mod, fn, stage
        self.vals = {}           # SSA name -> GLSL expr | Ptr
        self.decls = []          # function-local declarations
        self.body = []
        self.globals_out = []
        self.mems = {}
        self.refl = {'name': fn.name.lstrip('@'), 'stage': stage, 'inputs': [], 'outputs': [],
                     'buffers': [], 'textures': [], 'samplers': [], 'pairs': [], 'constants': [],
                     'const_samplers': []}
        self.tmp = 0
        self.pairs = {}
        self.fc = {}
        self.uses_fc = set()
        self.ubo_size = {}

    def new(self, prefix='t'):
        self.tmp += 1
        return '%s%d' % (prefix, self.tmp)

    # ---------------- metadata
    def meta_items(self, ref):
        return self.mod.meta.get(ref, [])

    def entry_meta(self):
        key = {'vertex': '!air.vertex', 'fragment': '!air.fragment', 'kernel': '!air.kernel'}[self.stage]
        for ref in self.mod.named.get(key, []):
            items = self.meta_items(ref)
            if self.fn.name in items[0]:
                outs = [self.flat(r) for r in self.meta_items(items[1])] if len(items) > 1 else []
                args = [self.flat(r) for r in self.meta_items(items[2])] if len(items) > 2 else []
                return outs, args
        raise Unsupported('no entry metadata')

    def flat(self, ref):
        """Metadata node -> list of python items (strings without !"", ints, sub-lists)."""
        out = []
        for it in self.meta_items(ref):
            if re.fullmatch(r'!\d+', it): out.append(self.flat(it))
            elif it.startswith('!"'): out.append(it[2:-1])
            elif re.fullmatch(r'i\d+ -?\d+', it): out.append(int(it.split()[1]))
            else: out.append(it)
        return out

    @staticmethod
    def attr(items, key, n=1):
        if key in items:
            i = items.index(key)
            return items[i + 1:i + 1 + n] if n > 1 else items[i + 1]
        return None

    # ---------------- values
    def fc_index(self, gname):
        m = re.search(r'MTL_FC_INIT_(\d+)_(\w+)$', gname)
        return (int(m.group(1)), m.group(2)) if m else None

    def val(self, v, t=None):
        t = t or v.ty
        if v.kind == 'local':
            x = self.vals.get(v.v)
            if x is None: raise Unsupported('use before def %s' % v.v)
            return x
        if v.kind == 'const': return scalar_const(v, t)
        if v.kind in ('undef', 'zero', 'null'):
            if t.kind == 'ptr': return Ptr(Mem('null', 'null'), 0, t.elem)
            return zero_of(t)
        if v.kind == 'cvec':
            return '%s(%s)' % (glsl_ty(t), ', '.join(self.val(e, t.elem) for e in v.v))
        if v.kind in ('carr', 'cstruct'):
            if t.kind == 'arr':
                return '%s(%s[%d](%s))' % (glsl_ty(t), glsl_ty(t.elem), t.n, ', '.join(self.val(e, t.elem) for e in v.v))
            return '%s(%s)' % (glsl_ty(t), ', '.join(self.val(e, f) for e, f in zip(v.v, t.fields)))
        if v.kind == 'global': return self.global_ptr(v.v)
        if v.kind == 'cexpr': return self.cexpr(v)
        raise Unsupported('value %r' % v)

    def cexpr(self, v):
        op = v.v[0]
        if op == 'gep':
            _, src, base, idx = v.v
            return self.gep(self.val(base), src, idx)
        if op in ('bitcast', 'addrspacecast'):
            x = self.val(v.v[1])
            if isinstance(x, Ptr): return Ptr(x.mem, x.off, v.v[2].elem if v.v[2].kind == 'ptr' else x.elem)
            raise Unsupported('cexpr cast of value')
        raise Unsupported('cexpr %s' % op)

    def global_ptr(self, name):
        g = self.mod.globals.get(name)
        if g is None: raise Unsupported('unknown global %s' % name)
        if g.section == 'air.fc_initializer':
            idx, code = self.fc_index(name)
            return Ptr(Mem('fc', name, index=idx, code=code), 0, g.ty)
        if name.startswith('@__air_sampler_state'):
            if name not in self.mems:
                sid = len(self.refl['const_samplers'])
                self.refl['const_samplers'].append({'id': sid, 'state': g.init.v if g.init and g.init.kind == 'const' else 0})
                self.mems[name] = Mem('sampler', 'cs%d' % sid, const=sid)
            return Ptr(self.mems[name], 0, g.ty)
        if name not in self.mems:
            words = max(1, (alloc_size(g.ty) + 3) // 4)
            mname = 'G' + re.sub(r'\W', '_', name[1:])[-40:]
            init = self.const_words(g.init, g.ty) if g.init is not None else None
            if g.const and init is not None:
                self.globals_out.append('const uint %s[%d] = uint[%d](%s);' % (
                    mname, words, words, ', '.join('%du' % w for w in init)))
            else:
                self.globals_out.append('uint %s[%d];' % (mname, words))
                if init is not None and any(init):
                    self.init_globals.append((mname, init))
            self.mems[name] = Mem('array', mname, words=words, writable=not g.const)
        return Ptr(self.mems[name], 0, g.ty)

    def const_words(self, v, t):
        buf = bytearray(alloc_size(t))
        self.pack_const(buf, 0, v, t)
        buf += b'\0' * ((-len(buf)) % 4)
        return list(struct.unpack('<%dI' % (len(buf) // 4), bytes(buf)))

    def pack_const(self, buf, off, v, t):
        if v is None or v.kind in ('zero', 'undef', 'null'): return
        if t.kind == 'int':
            buf[off:off + max(1, t.bits // 8)] = (v.v & ((1 << max(8, t.bits)) - 1)).to_bytes(max(1, t.bits // 8), 'little')
        elif t.kind == 'float':
            buf[off:off + t.bits // 8] = struct.pack({16: '<e', 32: '<f', 64: '<d'}[t.bits], v.v)
        elif t.kind in ('vec', 'arr'):
            step = alloc_size(t.elem) if t.kind == 'arr' else t.elem.bits // 8
            for i, e in enumerate(v.v): self.pack_const(buf, off + i * step, e, t.elem)
        elif t.kind == 'struct':
            for i, (e, f) in enumerate(zip(v.v, t.fields)): self.pack_const(buf, off + field_offset(t, i), e, f)
        else:
            raise Unsupported('const of %r' % t)

    # ---------------- memory access
    def word(self, mem, idx):
        k = mem.kind
        if k == 'ubo':
            u = self.ubo_size[mem.name]
            if isinstance(idx, int):
                u[0] = max(u[0], idx // 4 + 1)
                return '%s.w[%d][%d]' % (mem.name, idx >> 2, idx & 3)
            u[1] = True
            return '%s.w[(%s) >> 2][(%s) & 3]' % (mem.name, idx, idx)
        if k == 'tbuf': return 'texelFetch(%s, %s).x' % (mem.name, idx)
        if k == 'ssbo': return '%s.w[%s]' % (mem.name, idx)
        if k == 'array':
            # constant reads past a default ("unused_*") global only occur on
            # branches the function constants rule out; GLSL rejects them
            if isinstance(idx, int) and idx >= mem.words: return '0u'
            return '%s[%s]' % (mem.name, idx)
        raise Unsupported('read of %s' % k)

    def load(self, ptr, t):
        if isinstance(ptr, Choice):
            return ptr.pick([self.load(o, t) for o in ptr.opts])
        mem = ptr.mem
        if mem.kind == 'fc':
            self.uses_fc.add((mem.index, mem.code))
            if t.kind == 'int' and t.bits == 1: return '(FC%d != 0)' % mem.index
            if t.kind in ('float', 'vec'): return '%s(FC%d)' % (glsl_ty(t), mem.index)
            return 'int(FC%d)' % mem.index
        if mem.kind == 'null': return zero_of(t)
        return self.load_typed(ptr, t)

    def load_typed(self, ptr, t):
        if t.kind == 'vec':
            es = t.elem.bits // 8
            return '%s(%s)' % (glsl_ty(t), ', '.join(self.load_typed(ptr.add(i * es), t.elem) for i in range(t.n)))
        if t.kind == 'struct':
            return '%s(%s)' % (glsl_ty(t), ', '.join(self.load_typed(ptr.add(field_offset(t, i)), f)
                                                       for i, f in enumerate(t.fields)))
        if t.kind == 'arr':
            es = alloc_size(t.elem)
            return '%s(%s[%d](%s))' % (glsl_ty(t), glsl_ty(t.elem), t.n,
                                        ', '.join(self.load_typed(ptr.add(i * es), t.elem) for i in range(t.n)))
        off = ptr.off
        size = max(1, t.bits // 8)
        widx = (off >> 2) if isinstance(off, int) else '((%s) >> 2)' % off
        w = self.word(ptr.mem, widx)
        if size == 4:
            if t.kind == 'float': return 'uintBitsToFloat(%s)' % w
            return 'int(%s)' % w
        sh = ((off & 3) * 8) if isinstance(off, int) else '(((%s) & 3) * 8)' % off
        bits = '((%s) >> %s)' % (w, sh) if sh != 0 else '(%s)' % w
        if t.kind == 'float' and t.bits == 16:
            return 'unpackHalf2x16(%s).x' % bits
        if t.kind == 'int':
            mask = (1 << t.bits) - 1 if t.bits > 1 else 0xff
            v = 'int(%s & %du)' % (bits, mask)
            return '(%s != 0)' % v if t.bits == 1 else v
        raise Unsupported('load %r' % t)

    def store(self, ptr, value, t):
        if isinstance(ptr, Choice):
            tmp = self.new('cs')
            self.emit('%s %s = %s;' % (glsl_ty(t), tmp, value))
            for k, o in enumerate(ptr.opts):
                self.emit('if ((%s) == %d) {' % (ptr.sel, k)); self.depth += 1
                self.store(o, tmp, t)
                self.depth -= 1; self.emit('}')
            return
        mem = ptr.mem
        if mem.kind == 'ssbo' or (mem.kind == 'array' and mem.writable):
            pass
        elif mem.kind == 'array':
            mem.writable = True
        else:
            raise Unsupported('store to %s' % mem.kind)
        if t.kind == 'vec':
            es = t.elem.bits // 8
            tmp = self.new('sv')
            self.emit('%s %s = %s;' % (glsl_ty(t), tmp, value))
            for i in range(t.n): self.store(ptr.add(i * es), '%s[%d]' % (tmp, i), t.elem)
            return
        if t.kind == 'struct':
            tmp = self.new('ss')
            self.emit('%s %s = %s;' % (glsl_ty(t), tmp, value))
            for i, f in enumerate(t.fields): self.store(ptr.add(field_offset(t, i)), '%s.f%d' % (tmp, i), f)
            return
        off = ptr.off
        widx = (off >> 2) if isinstance(off, int) else '((%s) >> 2)' % off
        w = self.word(mem, widx)
        size = max(1, t.bits // 8)
        if size == 4:
            self.emit('%s = %s;' % (w, 'floatBitsToUint(%s)' % value if t.kind == 'float' else 'uint(%s)' % value))
            return
        sh = ((off & 3) * 8) if isinstance(off, int) else '(((%s) & 3) * 8)' % off
        if t.kind == 'float':
            bits = '(packHalf2x16(vec2(%s, 0.0)) & 0xffffu)' % value
            mask = 0xffff
        else:
            mask = (1 << t.bits) - 1 if t.bits > 1 else 0xff
            bits = '(uint(%s) & %du)' % ('int(%s)' % value if t.bits == 1 else value, mask)
        self.emit('%s = (%s & ~(%du << %s)) | (%s << %s);' % (w, w, mask, sh, bits, sh))

    def gep(self, base, src, idx):
        if isinstance(base, Choice):
            return base.map(lambda o: self.gep(o, src, idx))
        if not isinstance(base, Ptr): raise Unsupported('gep on non-pointer %r' % (base,))
        if base.mem.kind in ('texture', 'sampler', 'fc'):
            return base
        off = 0
        t = src
        first = idx[0]
        off = self.scaled(first, alloc_size(src))
        p = base.add(off)
        for v in idx[1:]:
            if t.kind == 'struct':
                p = p.add(field_offset(t, v.v)); t = t.fields[v.v]
            else:
                es = alloc_size(t.elem) if t.kind == 'arr' else t.elem.bits // 8
                p = p.add(self.scaled(v, es)); t = t.elem
        return Ptr(p.mem, p.off, t)

    def scaled(self, v, size):
        if v.kind == 'const': return v.v * size
        if v.kind in ('zero', 'undef'): return 0
        x = self.val(v)
        return '(int(%s) * %d)' % (x, size)

    # ---------------- emission
    def emit(self, s):
        self.body.append('    ' * self.depth + s)

    def vname(self, res):
        return self.prefix + 'v' + re.sub(r'\W', '_', res[1:])

    def define(self, inst, expr):
        if inst.res is None: return
        name = self.vname(inst.res)
        if not hasattr(self, 'declared'): self.declared = set()
        if name not in self.declared:
            self.declared.add(name)
            self.decls.append('%s %s;' % (glsl_ty(inst.ty), name))
        self.emit('%s = %s;' % (name, expr))
        self.vals[inst.res] = name

    def translate(self):
        self.depth = 1
        self.init_globals = []
        self.prefix = ''
        outs, args = self.entry_meta()
        self.setup_args(args)
        self.out_meta = outs
        entry_vals = self.vals
        # air.static_init: derived function-constant globals; own SSA namespace
        for f in self.mod.funcs.values():
            if f.section == 'air.static_init':
                self.vals, self.prefix = {}, 'si_'
                self.emit_body(f)
        self.vals, self.prefix = entry_vals, ''
        self.emit_body(self.fn)
        return self.assemble()

    def emit_body(self, fn):
        blocks = fn.blocks
        succ = {b.name: b.insts[-1].extra.get('targets', []) for b in blocks}
        # true back edges (DFS); an acyclic graph is emitted in topological
        # order with forward flags, a cyclic one as a block dispatch loop
        cyclic, order = self.cfg_order(blocks, succ)
        if not cyclic:
            byname = {b.name: b for b in blocks}
            blocks = [byname[n] for n in order]
        names = [b.name for b in blocks]
        index = {n: i for i, n in enumerate(names)}
        self.phis = {}
        if not hasattr(self, 'declared'): self.declared = set()
        for b in blocks:
            for i in b.insts:
                if i.op == 'phi':
                    name = self.vname(i.res)
                    self.declared.add(name)
                    if i.ty.kind == 'ptr':
                        self.decls.append('int %s = 0;' % name)
                        self.vals[i.res] = Choice(name, [])
                    else:
                        self.decls.append('%s %s;' % (glsl_ty(i.ty), name))
                        self.vals[i.res] = name
                    self.phis.setdefault(b.name, []).append(i)
        if len(blocks) == 1:
            self.block(blocks[0], None)
        elif not cyclic:
            for b in blocks[1:]:
                self.decls.append('bool %s = false;' % self.flag(b.name))
            for k, b in enumerate(blocks):
                if k:
                    self.emit('if (%s) {' % self.flag(b.name)); self.depth += 1
                self.block(b, 'flags')
                if k:
                    self.depth -= 1; self.emit('}')
        else:
            bb = self.prefix + 'bb'
            self.decls.append('int %s = 0;' % bb)
            self.emit('for (int g_%s = 0; g_%s < 100000 && %s >= 0; g_%s++) {' % (bb, bb, bb, bb)); self.depth += 1
            for k, b in enumerate(blocks):
                self.emit('%sif (%s == %d) {' % ('' if k == 0 else 'else ', bb, k)); self.depth += 1
                self.block(b, 'loop', index)
                self.depth -= 1; self.emit('}')
            self.depth -= 1; self.emit('}')

    @staticmethod
    def cfg_order(blocks, succ):
        """(has_cycle, reachable blocks in topological order from the entry)."""
        entry = blocks[0].name
        state, post, cyclic = {}, [], False
        stack = [(entry, iter(succ[entry]))]
        state[entry] = 1
        while stack:
            node, it = stack[-1]
            nxt = next(it, None)
            if nxt is None:
                state[node] = 2; post.append(node); stack.pop()
            elif state.get(nxt) == 1:
                cyclic = True
            elif nxt not in state:
                state[nxt] = 1; stack.append((nxt, iter(succ[nxt])))
        return cyclic, post[::-1]

    def flag(self, name):
        return self.prefix + 'r' + self.bid(name)

    def bid(self, name):
        return re.sub(r'\W', '_', name[1:])

    def edge(self, src, dst, mode, index=None):
        copies = []
        for phi in self.phis.get(dst, []):
            k = phi.extra['blocks'].index(src)
            if phi.ty.kind == 'ptr':
                ch = self.vals[phi.res]
                ch.opts.append(self.val(phi.args[k], phi.ty))
                self.emit('%s = %d;' % (ch.sel, len(ch.opts) - 1))
                continue
            copies.append((self.vals[phi.res], self.val(phi.args[k], phi.ty), phi.ty))
        if len(copies) > 1:
            tmps = []
            for dstv, expr, t in copies:
                tv = self.new('pc')
                self.emit('%s %s = %s;' % (glsl_ty(t), tv, expr)); tmps.append((dstv, tv))
            for dstv, tv in tmps: self.emit('%s = %s;' % (dstv, tv))
        else:
            for dstv, expr, _ in copies: self.emit('%s = %s;' % (dstv, expr))
        if mode == 'flags': self.emit('%s = true;' % self.flag(dst))
        elif mode == 'loop': self.emit('%sbb = %d;' % (self.prefix, index[dst]))

    def block(self, b, mode, index=None):
        for i in b.insts:
            if i.op == 'phi': continue
            if i.op == 'br':
                self.edge(b.name, i.extra['targets'][0], mode, index)
            elif i.op == 'condbr':
                c = self.val(i.args[0])
                t, f = i.extra['targets']
                self.emit('if (%s) {' % c); self.depth += 1
                self.edge(b.name, t, mode, index)
                self.depth -= 1; self.emit('} else {'); self.depth += 1
                self.edge(b.name, f, mode, index)
                self.depth -= 1; self.emit('}')
            elif i.op == 'switch':
                v = self.val(i.args[0])
                first = True
                for c, tgt in i.extra['cases']:
                    self.emit('%sif (%s == %s) {' % ('' if first else '} else ', v, ilit(c, i.args[0].ty.bits)))
                    first = False
                    self.depth += 1; self.edge(b.name, tgt, mode, index); self.depth -= 1
                self.emit('} else {'); self.depth += 1
                self.edge(b.name, i.extra['default'], mode, index)
                self.depth -= 1; self.emit('}')
            elif i.op == 'ret':
                self.ret(i)
                if mode == 'loop': self.emit('%sbb = -1;' % self.prefix)
            elif i.op == 'unreachable':
                if mode == 'loop': self.emit('%sbb = -1;' % self.prefix)
            else:
                self.inst(i)

    # ---------------- arguments / entry
    def setup_args(self, args):
        params = self.fn.params
        for items in args:
            if not items or not isinstance(items[0], int): continue
            k = items[0]
            pt, pname = params[k]
            kind = items[1] if not (isinstance(items[1], list) or items[1] == 'air.function_constant') else None
            pred = None
            rest = items[1:]
            if 'air.function_constant' in rest:
                j = rest.index('air.function_constant')
                pred = rest[j + 1]
                rest = rest[:j] + rest[j + 2:]
            kind = rest[0]
            argname = self.attr(rest, 'air.arg_name') or 'a%d' % k
            if kind == 'air.vertex_input':
                loc = self.attr(rest, 'air.location_index', 2)[0]
                gt = glsl_ty(pt)
                var = 'in_%s' % argname
                self.globals_out.append('layout(location = %d) in %s %s;' % (loc, self.in_ty(pt), var))
                self.vals[pname] = self.conv_in(var, pt)
                self.refl['inputs'].append({'location': loc, 'type': gt, 'name': argname})
            elif kind == 'air.vertex_id':
                self.vals[pname] = 'gl_VertexID'
            elif kind == 'air.instance_id':
                self.vals[pname] = 'gl_InstanceID'
            elif kind == 'air.base_vertex':
                self.vals[pname] = '0'
            elif kind == 'air.base_instance':
                self.vals[pname] = '0'
            elif kind == 'air.position' and self.stage == 'fragment':
                self.vals[pname] = 'vec4(gl_FragCoord.x, T290_RT_HEIGHT - gl_FragCoord.y, gl_FragCoord.z, 1.0 / gl_FragCoord.w)'
                self.need_rt_height = True
            elif kind == 'air.fragment_input':
                gen = rest[1]
                var = 'vy_%s' % varying_key(gen)
                flat = 'flat ' if 'air.flat' in rest or pt.kind == 'int' or (pt.kind == 'vec' and pt.elem.kind == 'int') else ''
                self.globals_out.append('%sin %s %s;' % (flat, self.in_ty(pt), var))
                self.vals[pname] = self.conv_in(var, pt)
                self.refl['inputs'].append({'varying': gen, 'type': glsl_ty(pt), 'key': varying_key(gen),
                                            'interp': 'flat' if flat else 'smooth'})
            elif kind == 'air.render_target' and self.stage == 'fragment':
                # programmable blending input: the driver binds a copy of the
                # attachment (no framebuffer fetch on Adreno 5xx in GLES)
                rt = rest[1]
                var = 'T290_FB%d' % rt
                if not any(var in g for g in self.globals_out):
                    self.globals_out.append('uniform highp sampler2D %s;' % var)
                    self.refl.setdefault('fb_inputs', []).append(rt)
                e = 'texelFetch(%s, ivec2(gl_FragCoord.xy), 0)' % var
                n = pt.n if pt.kind == 'vec' else 1
                self.vals[pname] = e if n == 4 else '%s.%s' % (e, 'xyzw'[:n])
            elif kind == 'air.front_facing':
                self.vals[pname] = 'gl_FrontFacing'
            elif kind == 'air.point_coord':
                self.vals[pname] = 'gl_PointCoord'
            elif kind == 'air.sample_id':
                self.vals[pname] = '0'
            elif kind == 'air.buffer':
                idx = self.attr(rest, 'air.location_index', 2)[0]
                space = self.attr(rest, 'air.address_space')
                writes = 'air.read_write' in rest or 'air.write' in rest
                written = writes and self.writes_param(pname)
                if space == 2:
                    mk, name = 'ubo', 'B%d_U' % idx
                    size = self.attr(rest, 'air.buffer_size') or self.attr(rest, 'air.arg_type_size') or 16
                    # block size fixed in assemble(): max(declared, highest word read)
                    self.globals_out.append('layout(std140) uniform %s_blk { uvec4 w[@UBO_%s@]; } %s;' % (name, name, name))
                    self.ubo_size[name] = [(size + 15) // 16, False]
                elif written:
                    if self.stage == 'vertex': raise Unsupported('vertex stage writes a device buffer')
                    mk, name = 'ssbo', 'B%d_S' % idx
                    self.globals_out.append('layout(std430) buffer %s_blk { uint w[]; } %s;' % (name, name))
                else:
                    mk, name = 'tbuf', 'B%d_T' % idx
                    self.globals_out.append('uniform highp usamplerBuffer %s;' % name)
                    self.need_tbuf = True
                mem = Mem(mk, name, writable=mk == 'ssbo')
                self.vals[pname] = Ptr(mem, 0, pt.elem)
                self.refl['buffers'].append({'index': idx, 'kind': mk, 'name': name, 'space': space,
                                             'pred': self.pred_name(pred)})
            elif kind == 'air.texture':
                idx = self.attr(rest, 'air.location_index', 2)[0]
                tname = self.attr(rest, 'air.arg_type_name')
                dim = '3d' if '3d' in tname else '2d'
                mem = Mem('texture', 'T%d' % idx, index=idx, dim=dim, access='write' if 'air.write' in rest else 'sample')
                self.vals[pname] = Ptr(mem, 0, None)
                self.refl['textures'].append({'index': idx, 'type': tname, 'dim': dim, 'pred': self.pred_name(pred)})
            elif kind == 'air.sampler':
                idx = self.attr(rest, 'air.location_index', 2)[0]
                self.vals[pname] = Ptr(Mem('sampler', 'S%d' % idx, index=idx), 0, None)
                self.refl['samplers'].append({'index': idx})
            elif kind == 'air.threads_per_threadgroup':
                self.vals[pname] = ('ivec%d(gl_WorkGroupSize%s)' % (pt.n, '.xy' if pt.n == 2 else '')
                                    if pt.kind == 'vec' else 'int(gl_WorkGroupSize.x)')
            elif kind == 'air.threadgroups_per_grid':
                self.vals[pname] = ('ivec%d(gl_NumWorkGroups%s)' % (pt.n, '.xy' if pt.n == 2 else '')
                                    if pt.kind == 'vec' else 'int(gl_NumWorkGroups.x)')
            elif kind in ('air.thread_position_in_grid', 'air.thread_position_in_threadgroup',
                          'air.threadgroup_position_in_grid', 'air.thread_index_in_threadgroup'):
                gl = {'air.thread_position_in_grid': 'gl_GlobalInvocationID',
                      'air.thread_position_in_threadgroup': 'gl_LocalInvocationID',
                      'air.threadgroup_position_in_grid': 'gl_WorkGroupID',
                      'air.thread_index_in_threadgroup': 'gl_LocalInvocationIndex'}[kind]
                if pt.kind == 'vec':
                    self.vals[pname] = 'ivec%d(%s%s)' % (pt.n, gl, '.xy' if pt.n == 2 else '')
                else:
                    self.vals[pname] = 'int(%s%s)' % (gl, '' if 'Index' in gl else '.x')
            elif kind == 'air.imageblock_data' or kind == 'air.threadgroup':
                raise Unsupported('argument kind %s' % kind)
            else:
                raise Unsupported('argument kind %s' % kind)

    def pred_name(self, pred):
        if not pred: return None
        return pred[0].split()[-1] if isinstance(pred, list) else str(pred)

    def writes_param(self, pname):
        for b in self.fn.blocks:
            for i in b.insts:
                if i.op == 'store' and self.base_param(i.args[1]) == pname: return True
                if i.op == 'call' and 'write' in i.extra['callee'] and i.args and i.args[0].v == pname: return True
        return False

    def base_param(self, v):
        defs = {i.res: i for b in self.fn.blocks for i in b.insts if i.res}
        seen = 0
        while v.kind == 'local' and v.v in defs and seen < 64:
            d = defs[v.v]
            if d.op in ('getelementptr', 'bitcast', 'addrspacecast'): v = d.args[0]
            else: break
            seen += 1
        if v.kind == 'cexpr': return self.base_param(v.v[2] if v.v[0] == 'gep' else v.v[1])
        return v.v

    def in_ty(self, t):
        if t.kind == 'float' or (t.kind == 'vec' and t.elem.kind == 'float'): return glsl_ty(t)
        if t.kind == 'int': return 'int'
        if t.kind == 'vec': return 'ivec%d' % t.n
        raise Unsupported('input type %r' % t)

    def conv_in(self, var, t):
        if t.kind == 'int' and t.bits == 1: return '(%s != 0)' % var
        return var

    def ret(self, inst):
        if not inst.args: return
        rv = self.val(inst.args[0])
        t = inst.args[0].ty
        tmp = self.new('rv')
        self.emit('%s %s = %s;' % (glsl_ty(t), tmp, rv))
        fields = [('%s.f%d' % (tmp, i), f) for i, f in enumerate(t.fields)] if t.kind == 'struct' else [(tmp, t)]
        if len(fields) != len(self.out_meta): raise Unsupported('output count mismatch')
        for (expr, ft), items in zip(fields, self.out_meta):
            rest = list(items)
            pred = None
            if 'air.function_constant' in rest:
                j = rest.index('air.function_constant'); pred = rest[j + 1]; rest = rest[:j] + rest[j + 2:]
            kind = rest[0]
            if kind == 'air.position':
                self.emit('gl_Position = vec4(%s.x, -(%s.y), 2.0 * %s.z - %s.w, %s.w);' % ((expr,) * 5))
            elif kind == 'air.point_size':
                self.emit('gl_PointSize = %s;' % expr)
            elif kind == 'air.vertex_output':
                var = 'vy_%s' % varying_key(rest[1])
                if not any(var in g for g in self.globals_out):
                    key = varying_key(rest[1])
                    integer = ft.kind == 'int' or (ft.kind == 'vec' and ft.elem.kind == 'int')
                    # Metal states flat-ness on the fragment side only; GLSL ES needs it on
                    # both, so the driver defines T290_Q_<key> as "flat" when the FS wants it.
                    q = 'flat' if integer else 'T290_Q_%s' % key
                    if not integer:
                        self.globals_out.append('#ifndef T290_Q_%s\n#define T290_Q_%s\n#endif' % (key, key))
                    self.globals_out.append('%s out %s %s;' % (q, self.in_ty(ft), var))
                    self.refl['outputs'].append({'varying': rest[1], 'key': key, 'type': glsl_ty(ft),
                                                 'pred': self.pred_name(pred)})
                self.emit('%s = %s;' % (var, expr if not (ft.kind == 'int' and ft.bits == 1) else 'int(%s)' % expr))
            elif kind == 'air.render_target':
                rt = rest[1]
                var = 'o_rt%d' % rt
                if not any(var in g for g in self.globals_out):
                    self.globals_out.append('layout(location = %d) out %s %s;' % (rt, 'vec4', var))
                    self.refl['outputs'].append({'render_target': rt, 'type': glsl_ty(ft)})
                n = ft.n if ft.kind == 'vec' else 1
                v = expr if n == 4 else 'vec4(%s%s)' % (expr, ', 0.0' * (3 - n) + ', 1.0')
                self.emit('%s = %s;' % (var, v))
            elif kind == 'air.depth':
                self.emit('gl_FragDepth = %s;' % expr)
            elif kind == 'air.sample_mask':
                pass
            else:
                raise Unsupported('output kind %s' % kind)

    # ---------------- instructions
    def inst(self, i):
        op = i.op
        a = i.args
        if op in llparse.BINOPS:
            self.define(i, self.binop(op, i.ty, self.val(a[0], i.ty), self.val(a[1], i.ty)))
        elif op == 'fneg':
            self.define(i, '(-(%s))' % self.val(a[0]))
        elif op in ('icmp', 'fcmp'):
            self.define(i, self.compare(op, i.extra['pred'], i.extra['opty'], self.val(a[0], i.extra['opty']),
                                        self.val(a[1], i.extra['opty'])))
        elif op in llparse.CASTS:
            self.cast(i)
        elif op == 'select':
            c, x, y = self.val(a[0]), self.val(a[1], i.ty), self.val(a[2], i.ty)
            if isinstance(x, (Ptr, Choice)) or isinstance(y, (Ptr, Choice)):
                if isinstance(x, Ptr) and isinstance(y, Ptr) and x.mem is y.mem:
                    self.vals[i.res] = Ptr(x.mem, '((%s) ? %s : %s)' % (c, x.off, y.off), x.elem)
                    return
                self.vals[i.res] = Choice('((%s) ? 0 : 1)' % c, [x, y])
                return
            if a[0].ty.kind == 'vec':
                self.define(i, 'mix(%s, %s, %s)' % (y, x, c) if i.ty.elem.kind == 'float' else
                            '%s(%s)' % (glsl_ty(i.ty), ', '.join('(%s[%d] ? %s[%d] : %s[%d])' % (c, k, x, k, y, k) for k in range(i.ty.n))))
            else:
                self.define(i, '((%s) ? %s : %s)' % (c, x, y))
        elif op == 'extractelement':
            self.define(i, '%s[%s]' % (self.paren(self.val(a[0])), self.int_index(a[1])))
        elif op == 'insertelement':
            t = i.ty
            vec, e, idx = self.val(a[0], t), self.val(a[1], t.elem), a[2]
            if idx.kind == 'const':
                k = idx.v
                tmp = self.new('ie')
                self.emit('%s %s = %s;' % (glsl_ty(t), tmp, vec))
                self.emit('%s[%d] = %s;' % (tmp, k, e))
                self.define(i, tmp)
            else:
                tmp = self.new('ie')
                self.emit('%s %s = %s;' % (glsl_ty(t), tmp, vec))
                self.emit('%s[%s] = %s;' % (tmp, self.int_index(idx), e))
                self.define(i, tmp)
        elif op == 'shufflevector':
            self.shuffle(i)
        elif op == 'extractvalue':
            self.define(i, self.agg_path(self.val(a[0]), i.extra['agg'], i.extra['idx']))
        elif op == 'insertvalue':
            tmp = self.new('iv')
            self.emit('%s %s = %s;' % (glsl_ty(i.ty), tmp, self.val(a[0], i.ty)))
            et = i.ty
            for k in i.extra['idx'][:-1]: et = et.fields[k] if et.kind == 'struct' else et.elem
            self.emit('%s = %s;' % (self.agg_path(tmp, i.ty, i.extra['idx']), self.val(a[1], a[1].ty)))
            self.define(i, tmp)
        elif op == 'load':
            p = self.val(a[0])
            if isinstance(p, Choice):
                if all(o.mem.kind in ('texture', 'sampler') for o in p.opts):
                    self.vals[i.res] = p; return
                self.define(i, self.load(p, i.ty)); return
            if not isinstance(p, Ptr): raise Unsupported('load from non-pointer')
            if p.mem.kind in ('texture', 'sampler'):
                self.vals[i.res] = p
                return
            self.define(i, self.load(p, i.ty))
        elif op == 'store':
            p = self.val(a[1])
            if not isinstance(p, (Ptr, Choice)): raise Unsupported('store to non-pointer')
            self.store(p, self.val(a[0], i.extra['valty']), i.extra['valty'])
        elif op == 'getelementptr':
            self.vals[i.res] = self.gep(self.val(a[0]), i.extra['src'], a[1:])
        elif op == 'alloca':
            t = i.extra['alloc']
            words = max(1, (alloc_size(t) * i.extra['count'] + 3) // 4)
            name = self.new('A')
            self.decls.append('uint %s[%d];' % (name, words))
            self.vals[i.res] = Ptr(Mem('array', name, words=words, writable=True), 0, t)
        elif op == 'call':
            self.call(i)
        elif op == 'freeze':
            self.define(i, self.val(a[0], i.ty))
        else:
            raise Unsupported('op %s' % op)

    def paren(self, x):
        return x if re.fullmatch(r'[\w.]+', x) else '(%s)' % x

    def int_index(self, v):
        if v.kind == 'const': return str(v.v)
        return 'int(%s)' % self.val(v)

    def agg_path(self, base, t, idx):
        s = self.paren(base)
        for k in idx:
            if t.kind == 'struct':
                s += '.f%d' % k; t = t.fields[k]
            elif t.kind == 'arr':
                s += '.e[%d]' % k; t = t.elem
            else:
                s += '[%d]' % k; t = t.elem
        return s

    def binop(self, op, t, x, y):
        isvec = t.kind == 'vec'
        et = t.elem if isvec else t
        if et.kind == 'float':
            sym = {'fadd': '+', 'fsub': '-', 'fmul': '*', 'fdiv': '/'}.get(op)
            if sym: return '(%s %s %s)' % (x, sym, y)
            if op == 'frem': return 'mod(%s, %s)' % (x, y)   # sign differs for negatives
            raise Unsupported(op)
        if et.bits == 1:
            sym = {'and': '&&', 'or': '||', 'xor': '!='}.get(op)
            if isvec:
                if op == 'and': return '%s(%s)' % (glsl_ty(t), ', '.join('%s[%d] && %s[%d]' % (x, k, y, k) for k in range(t.n)))
                if op == 'or': return '%s(%s)' % (glsl_ty(t), ', '.join('%s[%d] || %s[%d]' % (x, k, y, k) for k in range(t.n)))
                if op == 'xor': return 'notEqual(%s, %s)' % (x, y)
            if sym: return '(%s %s %s)' % (x, sym, y)
            raise Unsupported('i1 ' + op)
        bits = et.bits
        u = 'uvec%d' % t.n if isvec else 'uint'
        i_ = glsl_ty(t)
        if op in ('add', 'sub', 'mul'):
            r = '(%s %s %s)' % (x, {'add': '+', 'sub': '-', 'mul': '*'}[op], y)
            return self.wrap(r, bits, t)
        if op == 'and': return '(%s & %s)' % (x, y)
        if op == 'or': return '(%s | %s)' % (x, y)
        if op == 'xor': return '(%s ^ %s)' % (x, y)
        if op == 'shl': return self.wrap('(%s << %s)' % (x, y), bits, t)
        if op == 'lshr': return '%s(%s(%s) >> %s(%s))' % (i_, u, self.zx(x, bits, t), u, y)
        if op == 'ashr': return '(%s >> %s)' % (self.sx(x, bits, t), y)
        if op == 'sdiv': return '(%s / %s)' % (self.sx(x, bits, t), self.sx(y, bits, t))
        if op == 'srem': return '(%s - (%s / %s) * %s)' % (self.sx(x, bits, t), self.sx(x, bits, t), self.sx(y, bits, t), self.sx(y, bits, t))
        if op == 'udiv': return '%s(%s(%s) / %s(%s))' % (i_, u, self.zx(x, bits, t), u, self.zx(y, bits, t))
        if op == 'urem': return '%s(%s(%s) %% %s(%s))' % (i_, u, self.zx(x, bits, t), u, self.zx(y, bits, t))
        raise Unsupported(op)

    def wrap(self, r, bits, t):
        if bits >= 32: return r
        return '(%s & %d)' % (r, (1 << bits) - 1)

    def zx(self, x, bits, t):
        if bits >= 32: return x
        return '(%s & %d)' % (x, (1 << bits) - 1)

    def sx(self, x, bits, t):
        if bits >= 32: return x
        s = 32 - bits
        return '((%s << %d) >> %d)' % (x, s, s)

    def compare(self, op, pred, t, x, y):
        isvec = t.kind == 'vec'
        et = t.elem if isvec else t
        if op == 'fcmp':
            if pred == 'true': return 'true' if not isvec else 'bvec%d(true)' % t.n
            if pred == 'false': return 'false' if not isvec else 'bvec%d(false)' % t.n
            base = pred[1:] if pred[0] in 'ou' and pred not in ('ord', 'uno') else pred
            if pred == 'ord': return '!(isnan(%s) || isnan(%s))' % (x, y) if not isvec else 'not(%s)' % self.vor('isnan(%s)' % x, 'isnan(%s)' % y, t.n)
            if pred == 'uno': return '(isnan(%s) || isnan(%s))' % (x, y) if not isvec else self.vor('isnan(%s)' % x, 'isnan(%s)' % y, t.n)
            sym = {'eq': '==', 'ne': '!=', 'lt': '<', 'le': '<=', 'gt': '>', 'ge': '>='}[base]
            fn = {'eq': 'equal', 'ne': 'notEqual', 'lt': 'lessThan', 'le': 'lessThanEqual',
                  'gt': 'greaterThan', 'ge': 'greaterThanEqual'}[base]
            # fast-math shaders: ordered/unordered NaN distinctions dropped
            return '%s(%s, %s)' % (fn, x, y) if isvec else '(%s %s %s)' % (x, sym, y)
        if et.bits == 1:
            if pred in ('eq', 'ne'):
                return '(%s %s %s)' % (x, '==' if pred == 'eq' else '!=', y) if not isvec else \
                    '%s(%s, %s)' % ('equal' if pred == 'eq' else 'notEqual', x, y)
            x, y = ('int(%s)' % x, 'int(%s)' % y) if not isvec else ('ivec%d(%s)' % (t.n, x), 'ivec%d(%s)' % (t.n, y))
        bits = et.bits
        uns = pred in ('ult', 'ule', 'ugt', 'uge')
        if uns:
            u = 'uvec%d' % t.n if isvec else 'uint'
            x, y = '%s(%s)' % (u, self.zx(x, bits, t)), '%s(%s)' % (u, self.zx(y, bits, t))
        elif pred in ('slt', 'sle', 'sgt', 'sge'):
            x, y = self.sx(x, bits, t), self.sx(y, bits, t)
        elif bits < 32 and et.bits != 1:
            x, y = self.zx(x, bits, t), self.zx(y, bits, t)
        base = pred[-2:] if pred not in ('eq', 'ne') else pred
        sym = {'eq': '==', 'ne': '!=', 'lt': '<', 'le': '<=', 'gt': '>', 'ge': '>='}[base]
        fn = {'eq': 'equal', 'ne': 'notEqual', 'lt': 'lessThan', 'le': 'lessThanEqual',
              'gt': 'greaterThan', 'ge': 'greaterThanEqual'}[base]
        return '%s(%s, %s)' % (fn, x, y) if isvec else '(%s %s %s)' % (x, sym, y)

    def vor(self, a, b, n):
        return 'bvec%d(%s)' % (n, ', '.join('(%s[%d] || %s[%d])' % (a, k, b, k) for k in range(n)))

    def cast(self, i):
        op, src = i.op, i.extra['from']
        x = self.val(i.args[0], src)
        t = i.ty
        if isinstance(x, Choice) and op in ('bitcast', 'addrspacecast'):
            self.vals[i.res] = x.map(lambda o: Ptr(o.mem, o.off, t.elem if t.kind == 'ptr' else o.elem))
            return
        if isinstance(x, Ptr):
            if op in ('bitcast', 'addrspacecast'):
                self.vals[i.res] = Ptr(x.mem, x.off, t.elem if t.kind == 'ptr' else x.elem)
                return
            raise Unsupported('pointer cast %s' % op)
        isvec = t.kind == 'vec'
        et = t.elem if isvec else t
        st = src.elem if src.kind == 'vec' else src
        gt = glsl_ty(t)
        if op in ('fpext', 'fptrunc'):
            self.define(i, x); return
        if op == 'zext':
            if st.bits == 1: self.define(i, '%s(%s)' % (gt, x))
            else: self.define(i, self.zx(x, st.bits, t))
            return
        if op == 'sext':
            if st.bits == 1: self.define(i, '(-%s(%s))' % (gt, x))
            else: self.define(i, self.sx(x, st.bits, t))
            return
        if op == 'trunc':
            if et.bits == 1: self.define(i, '((%s & 1) != 0)' % x if not isvec else 'notEqual(%s & 1, %s(0))' % (x, glsl_ty(src)))
            else: self.define(i, self.wrap(x, et.bits, t))
            return
        if op in ('sitofp',): self.define(i, '%s(%s)' % (gt, self.sx(x, st.bits, src))); return
        if op in ('uitofp',):
            u = 'uvec%d' % t.n if isvec else 'uint'
            self.define(i, '%s(%s(%s))' % (gt, u, self.zx(x, st.bits, src) if st.bits != 1 else x)); return
        if op == 'fptosi': self.define(i, '%s(%s)' % (gt, x)); return
        if op == 'fptoui': self.define(i, '%s(%s)' % (gt, x)); return
        if op == 'bitcast':
            self.define(i, self.bitcast(x, src, t)); return
        raise Unsupported('cast %s %r -> %r' % (op, src, t))

    def bitcast(self, x, src, t):
        sb = size_of(src); tb = size_of(t)
        if repr(src) == repr(t): return x
        # go through 32-bit words
        words = self.to_words(x, src)
        return self.from_words(words, t)

    def to_words(self, x, t):
        tmp = self.new('bw')
        self.emit('%s %s = %s;' % (glsl_ty(t), tmp, x))
        parts = []    # list of (expr uint, bits)
        if t.kind == 'vec':
            for k in range(t.n): parts.append(self.scalar_bits('%s[%d]' % (tmp, k), t.elem))
        else:
            parts.append(self.scalar_bits(tmp, t))
        # pack into 32-bit words
        words, cur, used = [], None, 0
        for e, b in parts:
            if b == 32:
                words.append(e); continue
            if cur is None: cur, used = '(%s)' % e, b
            else: cur, used = '(%s | (%s << %du))' % (cur, e, used), used + b
            if used == 32: words.append(cur); cur, used = None, 0
        if cur is not None: words.append(cur)
        return words

    def scalar_bits(self, e, t):
        if t.kind == 'float':
            if t.bits == 32: return 'floatBitsToUint(%s)' % e, 32
            return '(packHalf2x16(vec2(%s, 0.0)) & 0xffffu)' % e, 16
        if t.bits == 32: return 'uint(%s)' % e, 32
        return '(uint(%s) & %du)' % (e, (1 << t.bits) - 1), t.bits

    def from_words(self, words, t):
        tmp = self.new('bu')
        self.emit('uint %s[%d] = uint[%d](%s);' % (tmp, len(words), len(words), ', '.join(words)))
        elems = []
        et = t.elem if t.kind == 'vec' else t
        n = t.n if t.kind == 'vec' else 1
        bits = et.bits
        for k in range(n):
            bitoff = k * bits
            w = '%s[%d]' % (tmp, bitoff // 32)
            sh = bitoff % 32
            raw = '(%s >> %du)' % (w, sh) if sh else w
            if et.kind == 'float':
                elems.append('uintBitsToFloat(%s)' % raw if bits == 32 else 'unpackHalf2x16(%s).x' % raw)
            else:
                elems.append('int(%s)' % raw if bits == 32 else 'int(%s & %du)' % (raw, (1 << bits) - 1))
        return elems[0] if n == 1 else '%s(%s)' % (glsl_ty(t), ', '.join(elems))

    def shuffle(self, i):
        a, b, mask = i.args
        at = a.ty
        n = at.n
        x = self.val(a, at)
        y = self.val(b, b.ty) if b.kind not in ('undef', 'zero') else None
        idx = [m.v if m.kind == 'const' else None for m in mask.v] if mask.kind == 'cvec' else [0] * i.ty.n
        xs = self.paren(x)
        ys = self.paren(y) if y else None
        comps = []
        for m in idx:
            if m is None: comps.append(zero_of(at.elem))
            elif m < n: comps.append('%s[%d]' % (xs, m))
            else: comps.append('%s[%d]' % (ys, m - n) if ys else zero_of(at.elem))
        if len(comps) == 1: self.define(i, comps[0])
        else: self.define(i, '%s(%s)' % (glsl_ty(i.ty), ', '.join(comps)))

    # ---------------- calls
    def call(self, i):
        name = i.extra['callee'][1:]
        a = i.args
        m = re.match(r'air\.(fast_)?(\w+?)(\.[\w.]+)?$', name)
        if not m: raise Unsupported('call %s' % name)
        fn = m.group(2)
        X = lambda k: self.val(a[k])
        simple = {'fabs': 'abs', 'floor': 'floor', 'ceil': 'ceil', 'sqrt': 'sqrt', 'rsqrt': 'inversesqrt',
                  'fract': 'fract', 'sin': 'sin', 'cos': 'cos', 'exp': 'exp', 'log': 'log', 'log2': 'log2',
                  'exp2': 'exp2', 'sign': 'sign', 'trunc': 'trunc', 'rint': 'roundEven', 'round': 'round',
                  'dfdx': 'dFdx', 'dfdy': 'dFdy', 'fwidth': 'fwidth', 'normalize': 'normalize',
                  'length': 'length', 'tan': 'tan', 'atan': 'atan', 'asin': 'asin', 'acos': 'acos'}
        if fn in simple:
            self.define(i, '%s(%s)' % (simple[fn], X(0))); return
        if fn in ('fmax', 'fmin', 'max', 'min'):
            g = 'max' if 'max' in fn else 'min'
            self.define(i, '%s(%s, %s)' % (g, X(0), X(1))); return
        if fn.startswith('min.') or fn.startswith('max.') or fn in ('min_s', 'max_s'):
            raise Unsupported(name)
        if name.startswith('air.min.s') or name.startswith('air.max.s'):
            self.define(i, '%s(%s, %s)' % ('min' if '.min' in name else 'max', X(0), X(1))); return
        if name.startswith('air.min.u') or name.startswith('air.max.u'):
            u = 'uint'
            self.define(i, 'int(%s(%s(%s), %s(%s)))' % ('min' if '.min' in name else 'max', u, X(0), u, X(1))); return
        if fn == 'clamp': self.define(i, 'clamp(%s, %s, %s)' % (X(0), X(1), X(2))); return
        if fn == 'saturate': self.define(i, 'clamp(%s, 0.0, 1.0)' % X(0)); return
        if fn == 'mix': self.define(i, 'mix(%s, %s, %s)' % (X(0), X(1), X(2))); return
        if fn == 'fma': self.define(i, '(%s * %s + %s)' % (X(0), X(1), X(2))); return
        if fn in ('pow', 'powr'): self.define(i, 'pow(%s, %s)' % (X(0), X(1))); return
        if fn == 'atan2': self.define(i, 'atan(%s, %s)' % (X(0), X(1))); return
        if fn == 'dot': self.define(i, 'dot(%s, %s)' % (X(0), X(1))); return
        if fn == 'all': self.define(i, 'all(%s)' % X(0)); return
        if fn == 'any': self.define(i, 'any(%s)' % X(0)); return
        if name.startswith('air.convert.'):
            self.convert(i, name); return
        if name.startswith('air.unpack.unorm4x8'):
            self.define(i, 'unpackUnorm4x8(uint(%s))' % X(0)); return
        if name == 'air.is_function_constant_defined':
            p = self.val(a[0])
            self.uses_fc.add((p.mem.index, p.mem.code))
            self.define(i, '(FCDEF%d != 0)' % p.mem.index); return
        if name.startswith('air.normalize_function_constant_predicate'):
            self.define(i, '(%s != 0 ? 1 : 0)' % X(0)); return
        if name.startswith('air.sample_texture_'):
            self.sample(i, name); return
        if name.startswith('air.read_texture_2d'):
            tex = self.val(a[0])
            st = glsl_ty(i.ty)
            self.define(i, self.per_texture(tex, lambda t: '%s(texelFetch(%s, %s, %s), 0)' % (
                st, self.combined(t, None), X(1), X(2)), zero_of(i.ty)))
            return
        if name.startswith('air.get_width_texture') or name.startswith('air.get_height_texture'):
            tex = self.val(a[0])
            comp = 'x' if 'width' in name else 'y'
            self.define(i, self.per_texture(tex, lambda t: 'textureSize(%s, %s).%s' % (
                self.combined(t, None), X(1), comp), '0')); return
        if name.startswith('air.get_null_texture'):
            self.vals[i.res] = Ptr(Mem('texture', 'TNULL', index=-1, dim='2d', access='sample'), 0, None); return
        if name.startswith('air.write_texture_2d'):
            tex = self.val(a[0])
            if self.stage != 'kernel' and self.stage != 'fragment': raise Unsupported('texture write in %s' % self.stage)
            img = 'IMG%d' % tex.mem.index
            if not any(img in g for g in self.globals_out):
                self.globals_out.append('layout(rgba8) writeonly uniform highp image2D %s;' % img)
                self.refl.setdefault('images', []).append({'index': tex.mem.index})
            self.emit('imageStore(%s, ivec2(%s), vec4(%s));' % (img, X(1), X(2))); return
        if name.startswith('air.wg.barrier'):
            self.emit('barrier(); memoryBarrierShared();'); return
        if name.startswith('air.load.implicit_imageblock') or name.startswith('air.quad_shuffle') \
                or name.startswith('air.simd_'):
            raise Unsupported('Apple-GPU-only %s' % name)
        raise Unsupported('call %s' % name)

    def convert(self, i, name):
        # air.convert.<dstkind>.<dstty>.<srckind>.<srcty>
        parts = name.split('.')
        dk, sk = parts[2], parts[4] if len(parts) > 4 else parts[2]
        x = self.val(i.args[0])
        st = i.args[0].ty
        t = i.ty
        gt = glsl_ty(t)
        se = st.elem if st.kind == 'vec' else st
        if dk == 'f':
            if se.kind == 'int':
                if se.bits == 1:
                    self.define(i, '%s(%s)' % (gt, x)); return
                if sk == 'u':
                    u = 'uvec%d' % st.n if st.kind == 'vec' else 'uint'
                    self.define(i, '%s(%s(%s))' % (gt, u, self.zx(x, se.bits, st))); return
                self.define(i, '%s(%s)' % (gt, self.sx(x, se.bits, st))); return
            self.define(i, x); return
        te = t.elem if t.kind == 'vec' else t
        if te.bits == 1:
            self.define(i, '(%s != 0.0)' % x if st.kind != 'vec' else 'notEqual(%s, %s(0.0))' % (x, glsl_ty(st))); return
        if dk == 'u':
            # Metal float->uint conversion saturates; mask to width
            u = 'uvec%d' % t.n if t.kind == 'vec' else 'uint'
            self.define(i, self.wrap('%s(%s(max(%s, %s(0.0))))' % (gt, u, x, glsl_ty(st)), te.bits, t)); return
        self.define(i, '%s(%s)' % (gt, x))

    def per_texture(self, tex, f, null):
        """f(texture ptr) for one texture or each run-time option; null texture -> null."""
        one = lambda t: null if t.mem.kind == 'texture' and t.mem.index == -1 else f(t)
        if isinstance(tex, Choice): return tex.pick([one(o) for o in tex.opts])
        return one(tex)

    def combined(self, tex, smp):
        """Combined GLSL sampler uniform for a (texture, sampler) pair."""
        if tex.mem.kind != 'texture': raise Unsupported('sample of non-texture')
        if tex.mem.index == -1: raise Unsupported('null texture sample')
        skey = None if smp is None else (('c', smp.mem.const) if hasattr(smp.mem, 'const') else ('s', smp.mem.index))
        key = (tex.mem.index, skey)
        if key not in self.pairs:
            name = 'TS%d_%s' % (tex.mem.index, 'n' if skey is None else '%s%d' % skey)
            st = 'sampler3D' if tex.mem.dim == '3d' else 'sampler2D'
            self.globals_out.append('uniform highp %s %s;' % (st, name))
            self.pairs[key] = name
            self.refl['pairs'].append({'name': name, 'texture': tex.mem.index,
                                       'sampler': None if skey is None else skey[1],
                                       'const_sampler': skey is not None and skey[0] == 'c'})
        return self.pairs[key]

    def sample(self, i, name):
        a = i.args
        tex, smp = self.val(a[0]), self.val(a[1])
        coord = self.val(a[2])
        if isinstance(tex, Choice) or isinstance(smp, Choice):
            if isinstance(tex, Choice) and isinstance(smp, Choice):
                self.define(i, tex.pick([smp.pick([self.sample_expr(i, t_, s_, coord) for s_ in smp.opts])
                                         for t_ in tex.opts]))
                return
            outer = tex if isinstance(tex, Choice) else smp
            exprs = []
            for k in range(len(outer.opts)):
                t_ = tex.opts[k] if isinstance(tex, Choice) else tex
                s_ = smp.opts[k] if isinstance(smp, Choice) else smp
                exprs.append(self.sample_expr(i, t_, s_, coord))
            self.define(i, outer.pick(exprs)); return
        self.define(i, self.sample_expr(i, tex, smp, coord))

    def sample_expr(self, i, tex, smp, coord):
        a = i.args
        if tex.mem.kind == 'texture' and tex.mem.index == -1:
            return zero_of(i.ty)
        ts = self.combined(tex, smp)
        lod_explicit = a[5].kind == 'const' and a[5].v == 1
        bias = a[6]
        if lod_explicit:
            expr = 'textureLod(%s, %s, %s)' % (ts, coord, self.val(bias))
        elif bias.kind == 'const' and bias.v == 0:
            expr = 'texture(%s, %s)' % (ts, coord)
        else:
            expr = 'texture(%s, %s, %s)' % (ts, coord, self.val(bias))
        st = glsl_ty(i.ty)
        return '%s(%s, 0)' % (st, expr)

    # ---------------- assembly
    def assemble(self):
        hdr = ['#version 310 es']
        if getattr(self, 'need_tbuf', False): hdr.append('#extension GL_EXT_texture_buffer : require')
        hdr += ['precision highp float;', 'precision highp int;', 'precision highp usamplerBuffer;' if getattr(self, 'need_tbuf', False) else '',
                '#ifndef T290_SPECIALIZED', '#error function constants not defined', '#endif']
        if getattr(self, 'need_rt_height', False): hdr.append('uniform highp float T290_RT_HEIGHT;')
        if self.stage == 'kernel':
            hdr.append('layout(local_size_x = T290_LOCAL_X, local_size_y = T290_LOCAL_Y, local_size_z = T290_LOCAL_Z) in;')
        structs = [struct_decl(n, t) for n, t in STRUCTS.values()]
        init = []
        for mname, words in self.init_globals:
            for k, w in enumerate(words):
                if w: init.append('    %s[%d] = %du;' % (mname, k, w))
        self.refl['constants'] = [{'index': k, 'type': c} for k, c in sorted(self.uses_fc)]
        for name, (vecs, dynamic) in self.ubo_size.items():
            n = max(vecs, 1024 if dynamic else 1)
            self.globals_out = [g.replace('@UBO_%s@' % name, str(n)) for g in self.globals_out]
            self.refl['buffers'] = [dict(b, ubo_bytes=n * 16) if b['name'] == name else b for b in self.refl['buffers']]
        main = ['void main() {'] + ['    ' + d for d in self.decls] + init + self.body + ['}']
        return '\n'.join([h for h in hdr if h] + structs + self.globals_out + main) + '\n'


def varying_key(gen):
    return re.sub(r'\W', '_', gen.replace('generated(', '').rstrip(')'))


def stage_of(mod, fname):
    for key, st in (('!air.vertex', 'vertex'), ('!air.fragment', 'fragment'), ('!air.kernel', 'kernel')):
        for ref in mod.named.get(key, []):
            if fname in mod.meta[ref][0]: return st
    return None


def translate_file(path):
    STRUCTS.clear()
    mod = llparse.parse_module(open(path).read())
    entry = [f for f in mod.funcs.values() if f.section != 'air.static_init']
    if len(entry) != 1: raise Unsupported('expected one entry function, got %d' % len(entry))
    fn = entry[0]
    st = stage_of(mod, fn.name)
    if st is None: raise Unsupported('no stage')
    tr = Translator(mod, fn, st)
    src = tr.translate()
    return src, tr.refl


if __name__ == '__main__':
    out = sys.argv[2] if len(sys.argv) > 2 else None
    src, refl = translate_file(sys.argv[1])
    if out:
        open(out + '.glsl', 'w').write(src)
        open(out + '.json', 'w').write(json.dumps(refl, indent=1))
    else:
        print(src)
