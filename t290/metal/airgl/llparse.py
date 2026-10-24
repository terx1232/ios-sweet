"""Parser for the textual LLVM IR (llvm-dis-14) of Apple AIR shader modules.

Covers the subset QuartzCore's default.metallib uses after inlining
(airopt.sh): scalar/vector/aggregate SSA, loads/stores/GEPs through
address-spaced pointers, phi/br/switch/select, calls to air.* and llvm.*
intrinsics, module globals with constant initializers and named metadata.
"""
import re

# ---------------------------------------------------------------- types

class Ty:
    """kind: void int float vec arr struct ptr label meta opaque"""
    __slots__ = ('kind', 'bits', 'n', 'elem', 'fields', 'packed', 'space', 'name')

    def __init__(self, kind, bits=0, n=0, elem=None, fields=None, packed=False, space=0, name=None):
        self.kind, self.bits, self.n, self.elem = kind, bits, n, elem
        self.fields, self.packed, self.space, self.name = fields or [], packed, space, name

    def __repr__(self):
        k = self.kind
        if k == 'int': return 'i%d' % self.bits
        if k == 'float': return {16: 'half', 32: 'float', 64: 'double'}[self.bits]
        if k == 'vec': return '<%d x %r>' % (self.n, self.elem)
        if k == 'arr': return '[%d x %r]' % (self.n, self.elem)
        if k == 'ptr': return '%r addrspace(%d)*' % (self.elem, self.space)
        if k == 'struct':
            if self.name: return self.name
            body = '{ %s }' % ', '.join(map(repr, self.fields))
            return '<%s>' % body if self.packed else body
        return k

    def is_scalar(self):
        return self.kind in ('int', 'float')


VOID, LABEL, META = Ty('void'), Ty('label'), Ty('meta')


def align_of(t):
    if t.kind == 'int': return max(1, t.bits // 8)
    if t.kind == 'float': return t.bits // 8
    if t.kind == 'vec':
        # AIR datalayout: v16:16 v24:32 v32:32 v48:64 v64:64 v96:128 v128:128 ...
        size = t.n * t.elem.bits // 8
        p = 1
        while p < size: p *= 2
        return p
    if t.kind == 'arr': return align_of(t.elem)
    if t.kind == 'struct':
        return 1 if t.packed else max([align_of(f) for f in t.fields] or [1])
    if t.kind == 'ptr': return 8
    raise ValueError(t)


def size_of(t):
    if t.kind == 'int': return max(1, t.bits // 8)
    if t.kind == 'float': return t.bits // 8
    if t.kind == 'vec':
        return align_of(t)      # 3-element vectors occupy 4 slots
    if t.kind == 'arr': return t.n * alloc_size(t.elem)
    if t.kind == 'struct':
        off = 0
        for f in t.fields:
            if not t.packed: off = _round(off, align_of(f))
            off += alloc_size(f)
        return _round(off, align_of(t))
    if t.kind == 'ptr': return 8
    raise ValueError(t)


def alloc_size(t):
    return _round(size_of(t), align_of(t))


def field_offset(t, i):
    off = 0
    for k, f in enumerate(t.fields):
        if not t.packed: off = _round(off, align_of(f))
        if k == i: return off
        off += alloc_size(f)
    raise IndexError(i)


def _round(x, a):
    return (x + a - 1) // a * a


# ---------------------------------------------------------------- values

class Val:
    """kind: local global const undef zero cvec carr cstruct cexpr meta null"""
    __slots__ = ('kind', 'ty', 'v')

    def __init__(self, kind, ty, v=None):
        self.kind, self.ty, self.v = kind, ty, v

    def __repr__(self):
        return '%s:%r' % (self.kind, self.v)


class Inst:
    __slots__ = ('res', 'op', 'ty', 'args', 'extra', 'text')

    def __init__(self, res, op, ty, args, extra=None, text=''):
        self.res, self.op, self.ty, self.args, self.extra, self.text = res, op, ty, args, extra or {}, text

    def __repr__(self):
        return self.text


class Block:
    def __init__(self, name):
        self.name, self.insts, self.preds = name, [], []


class Func:
    def __init__(self, name, ret, params):
        self.name, self.ret, self.params, self.blocks, self.section = name, ret, params, [], None


class Global:
    def __init__(self, name, ty, init, const, section, space):
        self.name, self.ty, self.init, self.const, self.section, self.space = name, ty, init, const, section, space


class Module:
    def __init__(self):
        self.types, self.globals, self.funcs, self.meta, self.named = {}, {}, {}, {}, {}


# ---------------------------------------------------------------- lexer

TOKEN = re.compile(r'''
    (?P<ws>[ \t]+)
  | (?P<str>c?"(?:[^"\\]|\\.)*")
  | (?P<local>%[-\w.$]+|%"[^"]*")
  | (?P<global>@[-\w.$]+|@"[^"]*")
  | (?P<meta>![-\w.]+)
  | (?P<attr>\#\d+)
  | (?P<hex>0x[KLMHR]?[0-9A-Fa-f]+)
  | (?P<num>-?\d+(?:\.\d+(?:[eE][-+]?\d+)?)?)
  | (?P<word>[A-Za-z_][\w.]*)
  | (?P<punct>\.\.\.|[{}()\[\]<>,=*:|])
''', re.X)


def lex(s):
    out, pos = [], 0
    while pos < len(s):
        m = TOKEN.match(s, pos)
        if not m: raise SyntaxError('lex at %r' % s[pos:pos + 40])
        pos = m.end()
        if m.lastgroup != 'ws':
            out.append((m.lastgroup, m.group()))
    return out


class P:
    """Token cursor."""

    def __init__(self, mod, text):
        self.mod, self.t, self.i = mod, lex(text), 0

    def peek(self, k=0):
        return self.t[self.i + k][1] if self.i + k < len(self.t) else None

    def kind(self, k=0):
        return self.t[self.i + k][0] if self.i + k < len(self.t) else None

    def next(self):
        tok = self.t[self.i][1]
        self.i += 1
        return tok

    def eat(self, tok):
        if self.peek() == tok:
            self.i += 1
            return True
        return False

    def want(self, tok):
        if not self.eat(tok): raise SyntaxError('want %r got %r in %s' % (tok, self.peek(), self.rest()))

    def rest(self):
        return ' '.join(t[1] for t in self.t[self.i:self.i + 12])

    def done(self):
        return self.i >= len(self.t)

    # ---- types
    def ty(self):
        t = self.base_ty()
        while True:
            if self.peek() == 'addrspace':
                self.next(); self.want('('); sp = int(self.next()); self.want(')'); self.want('*')
                t = Ty('ptr', elem=t, space=sp)
            elif self.eat('*'):
                t = Ty('ptr', elem=t, space=0)
            elif self.peek() == '(' and t is not None:
                # function type: ret (args) -- only appears in pointer-to-function contexts
                self.next()
                while not self.eat(')'):
                    if self.eat('...'): continue
                    self.ty(); self.eat(',')
                t = Ty('opaque', name='fn')
            else:
                return t

    def base_ty(self):
        tok = self.next()
        if tok == 'void': return VOID
        if tok == 'label': return LABEL
        if tok == 'metadata': return META
        if tok in ('half', 'float', 'double'):
            return Ty('float', bits={'half': 16, 'float': 32, 'double': 64}[tok])
        if re.fullmatch(r'i\d+', tok): return Ty('int', bits=int(tok[1:]))
        if tok == '<':
            if self.peek() == '{':          # packed struct
                self.next()
                fs = self.fields('}')
                self.want('>')
                return Ty('struct', fields=fs, packed=True)
            n = int(self.next()); self.want('x'); e = self.ty(); self.want('>')
            return Ty('vec', n=n, elem=e)
        if tok == '[':
            n = int(self.next()); self.want('x'); e = self.ty(); self.want(']')
            return Ty('arr', n=n, elem=e)
        if tok == '{':
            return Ty('struct', fields=self.fields('}'))
        if tok.startswith('%'):
            return self.mod.types.setdefault(tok, Ty('struct', name=tok))
        if tok == 'opaque': return Ty('opaque')
        raise SyntaxError('type %r at %s' % (tok, self.rest()))

    def fields(self, close):
        fs = []
        while not self.eat(close):
            fs.append(self.ty()); self.eat(',')
        return fs

    # ---- values
    def value(self, ty):
        k, tok = self.kind(), self.peek()
        if k == 'local':
            self.next(); return Val('local', ty, tok)
        if k == 'global':
            self.next(); return Val('global', ty, tok)
        if k == 'meta' or tok == '!{':
            return Val('meta', ty, self.meta_ref())
        self.next()
        if k in ('num', 'hex'):
            return Val('const', ty, parse_number(tok, ty))
        if tok in ('true', 'false'): return Val('const', ty, 1 if tok == 'true' else 0)
        if tok in ('undef', 'poison'): return Val('undef', ty)
        if tok == 'zeroinitializer': return Val('zero', ty)
        if tok == 'null': return Val('null', ty)
        if tok == '<':
            items = self.typed_list('>')
            return Val('cvec', ty, items)
        if tok == '[':
            return Val('carr', ty, self.typed_list(']'))
        if tok == '{':
            return Val('cstruct', ty, self.typed_list('}'))
        if tok == 'c' or k == 'str':
            return Val('cstr', ty, tok)
        if tok in ('getelementptr', 'bitcast', 'addrspacecast', 'ptrtoint', 'inttoptr'):
            return self.cexpr(tok, ty)
        raise SyntaxError('value %r at %s' % (tok, self.rest()))

    def typed_list(self, close):
        if close == '>' and self.peek() == '{':     # packed struct constant <{ ... }>
            self.next()
            items = self.typed_list('}')
            self.want('>')
            return items
        items = []
        while not self.eat(close):
            t = self.ty(); items.append(self.value(t)); self.eat(',')
        return items

    def cexpr(self, op, ty):
        self.eat('inbounds')
        self.want('(')
        if op == 'getelementptr':
            src = self.ty(); self.want(',')
            pt = self.ty(); base = self.value(pt)
            idx = []
            while self.eat(','):
                it = self.ty(); idx.append(self.value(it))
            self.want(')')
            return Val('cexpr', ty, ('gep', src, base, idx))
        st = self.ty(); v = self.value(st); self.want('to'); dt = self.ty(); self.want(')')
        return Val('cexpr', ty, (op, v, dt))

    def typed_value(self):
        t = self.ty()
        return self.value(t)

    def meta_ref(self):
        tok = self.next()
        if tok == '!' and self.peek() == '{':
            pass
        return tok

    def skip_attrs(self):
        while self.kind() in ('word', 'attr') and self.peek() in FN_ATTRS or self.kind() == 'attr':
            w = self.next()
            if self.peek() == '(':
                depth = 0
                while True:
                    x = self.next()
                    depth += x == '('
                    depth -= x == ')'
                    if depth == 0: break


FN_ATTRS = set('''fast nnan ninf nsz arcp contract afn reassoc tail musttail notail fastcc ccc
    zeroext signext inreg noalias nocapture readonly readnone writeonly nonnull nofree noundef
    dereferenceable dereferenceable_or_null align byval immarg returned local_unnamed_addr
    unnamed_addr internal private convergent nounwind'''.split())


def parse_number(tok, ty):
    if tok.startswith('0x'):
        import struct
        body = tok[2:]
        if body[0] == 'H':          # half bits
            return struct.unpack('<e', struct.pack('<H', int(body[1:], 16)))[0]
        if body[0] in 'KLMR':
            raise SyntaxError('unsupported float literal %s' % tok)
        if ty is not None and ty.kind == 'float':
            # LLVM writes float/half constants as the equivalent double bits
            return struct.unpack('<d', struct.pack('<Q', int(body, 16)))[0]
        return int(body, 16)
    if ty is not None and ty.kind == 'float':
        return float(tok)
    return int(tok)


# ---------------------------------------------------------------- module

LINE_TYPE = re.compile(r'^(%[-\w.$"]+|%"[^"]*") = type (.*)$')


def parse_module(text):
    mod = Module()
    lines = text.split('\n')
    # named struct types first (bodies may reference later ones)
    for line in lines:
        m = LINE_TYPE.match(line)
        if m:
            mod.types.setdefault(m.group(1), Ty('struct', name=m.group(1)))
    for line in lines:
        m = LINE_TYPE.match(line)
        if m and m.group(2) != 'opaque':
            p = P(mod, m.group(2))
            t = p.ty()
            named = mod.types[m.group(1)]
            named.fields, named.packed = t.fields, t.packed
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith('@'):
            parse_global(mod, line)
        elif line.startswith('define '):
            j = i
            while lines[j] != '}': j += 1
            parse_function(mod, lines[i:j + 1])
            i = j
        elif line.startswith('!'):
            parse_meta(mod, line)
        i += 1
    return mod


def parse_global(mod, line):
    m = re.match(r'^(@[-\w.$]+|@"[^"]*") = (.*)$', line)
    name, rest = m.group(1), m.group(2)
    if name.startswith('@llvm.'): return
    section = re.search(r'section "([^"]+)"', rest)
    p = P(mod, re.sub(r', (section|align) .*$', '', rest))
    space = 0
    while True:
        w = p.peek()
        if w == 'addrspace':
            p.next(); p.want('('); space = int(p.next()); p.want(')')
        elif w in ('global', 'constant'):
            break
        else:
            p.next()
    const = p.next() == 'constant'
    ty = p.ty()
    init = None if p.done() else p.value(ty)
    mod.globals[name] = Global(name, ty, init, const, section.group(1) if section else None, space)


def parse_meta(mod, line):
    m = re.match(r'^(![-\w.]+) = (?:distinct )?!\{(.*)\}\s*$', line)
    if not m: return
    items = split_top(m.group(2))
    if re.match(r'^!\d+$', m.group(1)):
        mod.meta[m.group(1)] = items
    else:
        mod.named[m.group(1)] = items


def split_top(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '{(<[': depth += 1
        if ch in '})>]': depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += ch
    if cur.strip(): out.append(cur.strip())
    return out


def parse_function(mod, lines):
    head = lines[0]
    m = re.match(r'^define (.*?)(@[-\w.$]+)\((.*)\)(.*)\{$', head)
    pre, name, params, post = m.groups()
    p = P(mod, re.sub(r'\b(internal|fastcc|local_unnamed_addr|unnamed_addr|noundef|zeroext|signext|dso_local)\b', '', pre))
    ret = p.ty()
    plist = []
    for k, ptext in enumerate(split_top(params)):
        pp = P(mod, ptext)
        t = pp.ty()
        while not pp.done() and pp.kind() != 'local':
            tok = pp.next()
            if pp.peek() == '(':
                while pp.next() != ')': pass
        plist.append((t, pp.next() if not pp.done() else '%%%d' % k))
    f = Func(name, ret, plist)
    sec = re.search(r'section "([^"]+)"', post)
    f.section = sec.group(1) if sec else None
    # numbered blocks: entry is %N where N == number of params unless named
    cur = Block('%%%d' % len(plist))
    f.blocks.append(cur)
    body = []
    for line in lines[1:-1]:            # join multi-line switch tables
        if body and body[-1].rstrip().endswith('[') or body and body[-1].count('[') > body[-1].count(']') \
                and body[-1].lstrip().startswith(('switch', '%')) and 'switch' in body[-1]:
            body[-1] += ' ' + line.strip()
        else:
            body.append(line)
    for line in body:
        if not line.strip(): continue
        lm = re.match(r'^([-\w.$]+):', line)
        if lm:
            if cur.insts:
                cur = Block('%' + lm.group(1)); f.blocks.append(cur)
            else:
                cur.name = '%' + lm.group(1)
            continue
        cur.insts.append(parse_inst(mod, line.strip()))
    mod.funcs[name] = f
    return f


def strip_md(line):
    # drop trailing ", !tbaa !5, !range !6 ..." attachments (not inside braces)
    out, depth = '', 0
    i = 0
    while i < len(line):
        ch = line[i]
        if ch in '{[(<': depth += 1
        if ch in '}])>': depth -= 1
        if ch == ',' and depth == 0 and re.match(r',\s*!\w', line[i:]):
            break
        out += ch
        i += 1
    return out


BINOPS = set('add sub mul udiv sdiv urem srem shl lshr ashr and or xor fadd fsub fmul fdiv frem'.split())
CASTS = set('trunc zext sext fptrunc fpext fptoui fptosi uitofp sitofp bitcast addrspacecast ptrtoint inttoptr'.split())


def parse_inst(mod, line):
    text = line
    line = strip_md(line)
    res = None
    m = re.match(r'^(%[-\w.$]+) = (.*)$', line)
    if m:
        res, line = m.group(1), m.group(2)
    p = P(mod, line)
    while p.peek() in ('tail', 'musttail', 'notail'): p.next()
    op = p.next()
    flags = []
    while p.peek() in ('nuw', 'nsw', 'exact', 'fast', 'nnan', 'ninf', 'nsz', 'arcp', 'contract',
                       'afn', 'reassoc', 'inbounds', 'disjoint'):
        flags.append(p.next())
    if op in BINOPS:
        t = p.ty(); a = p.value(t); p.want(','); b = p.value(t)
        return Inst(res, op, t, [a, b], text=text)
    if op in ('icmp', 'fcmp'):
        pred = p.next()
        while p.peek() in ('fast', 'nnan', 'ninf', 'nsz'): p.next()
        t = p.ty(); a = p.value(t); p.want(','); b = p.value(t)
        rt = Ty('int', bits=1) if t.kind != 'vec' else Ty('vec', n=t.n, elem=Ty('int', bits=1))
        return Inst(res, op, rt, [a, b], {'pred': pred, 'opty': t}, text)
    if op in CASTS:
        st = p.ty(); v = p.value(st); p.want('to'); dt = p.ty()
        return Inst(res, op, dt, [v], {'from': st}, text)
    if op == 'fneg':
        t = p.ty(); a = p.value(t)
        return Inst(res, op, t, [a], text=text)
    if op == 'select':
        ct = p.ty(); c = p.value(ct); p.want(',')
        t = p.ty(); a = p.value(t); p.want(','); t2 = p.ty(); b = p.value(t2)
        return Inst(res, op, t, [c, a, b], text=text)
    if op == 'extractelement':
        vt = p.ty(); v = p.value(vt); p.want(','); it = p.ty(); i = p.value(it)
        return Inst(res, op, vt.elem, [v, i], text=text)
    if op == 'insertelement':
        vt = p.ty(); v = p.value(vt); p.want(','); et = p.ty(); e = p.value(et); p.want(',')
        it = p.ty(); i = p.value(it)
        return Inst(res, op, vt, [v, e, i], text=text)
    if op == 'shufflevector':
        at = p.ty(); a = p.value(at); p.want(','); bt = p.ty(); b = p.value(bt); p.want(',')
        mt = p.ty(); mask = p.value(mt)
        return Inst(res, op, Ty('vec', n=mt.n, elem=at.elem), [a, b, mask], text=text)
    if op == 'extractvalue':
        at = p.ty(); a = p.value(at); idx = []
        while p.eat(','): idx.append(int(p.next()))
        t = at
        for k in idx: t = t.fields[k] if t.kind == 'struct' else t.elem
        return Inst(res, op, t, [a], {'idx': idx, 'agg': at}, text)
    if op == 'insertvalue':
        at = p.ty(); a = p.value(at); p.want(','); et = p.ty(); e = p.value(et); idx = []
        while p.eat(','): idx.append(int(p.next()))
        return Inst(res, op, at, [a, e], {'idx': idx}, text)
    if op == 'load':
        p.eat('volatile')
        t = p.ty(); p.want(','); pt = p.ty(); ptr = p.value(pt)
        return Inst(res, op, t, [ptr], {'ptrty': pt}, text)
    if op == 'store':
        p.eat('volatile')
        t = p.ty(); v = p.value(t); p.want(','); pt = p.ty(); ptr = p.value(pt)
        return Inst(None, op, VOID, [v, ptr], {'valty': t}, text)
    if op == 'getelementptr':
        src = p.ty(); p.want(','); pt = p.ty(); base = p.value(pt); idx = []
        while p.eat(','):
            it = p.ty(); idx.append(p.value(it))
        rt = gep_result(src, pt, idx)
        return Inst(res, op, rt, [base] + idx, {'src': src}, text)
    if op == 'alloca':
        t = p.ty()
        n = 1
        if p.eat(','):
            if p.peek() != 'align':
                p.ty(); n = int(p.next())
        return Inst(res, op, Ty('ptr', elem=t, space=0), [], {'alloc': t, 'count': n}, text)
    if op == 'phi':
        t = p.ty(); inc = []
        while True:
            p.want('['); v = p.value(t); p.want(','); b = p.next(); p.want(']')
            inc.append((v, b))
            if not p.eat(','): break
        return Inst(res, op, t, [v for v, _ in inc], {'blocks': [b for _, b in inc]}, text)
    if op == 'br':
        if p.peek() == 'label':
            p.next(); return Inst(None, 'br', VOID, [], {'targets': [p.next()]}, text)
        ct = p.ty(); c = p.value(ct); p.want(','); p.want('label'); a = p.next(); p.want(',')
        p.want('label'); b = p.next()
        return Inst(None, 'condbr', VOID, [c], {'targets': [a, b]}, text)
    if op == 'switch':
        t = p.ty(); v = p.value(t); p.want(','); p.want('label'); default = p.next(); p.want('[')
        cases = []
        while not p.eat(']'):
            ct = p.ty(); c = p.value(ct); p.want(','); p.want('label'); cases.append((c.v, p.next()))
        return Inst(None, 'switch', VOID, [v], {'default': default, 'cases': cases,
                                               'targets': [default] + [b for _, b in cases]}, text)
    if op == 'ret':
        if p.peek() == 'void': return Inst(None, 'ret', VOID, [], text=text)
        t = p.ty(); return Inst(None, 'ret', t, [p.value(t)], text=text)
    if op == 'unreachable':
        return Inst(None, 'unreachable', VOID, [], text=text)
    if op == 'call':
        while p.peek() in FN_ATTRS or p.kind() == 'attr': p.next()
        rt = p.ty()
        callee = p.next()
        p.want('(')
        args = []
        while not p.eat(')'):
            t = p.ty()
            while p.peek() in FN_ATTRS:
                p.next()
                if p.peek() == '(':
                    while p.next() != ')': pass
            args.append(p.value(t)); p.eat(',')
        return Inst(res, 'call', rt, args, {'callee': callee}, text)
    if op == 'freeze':
        t = p.ty(); a = p.value(t)
        return Inst(res, 'freeze', t, [a], text=text)
    raise SyntaxError('instruction %r: %s' % (op, text))


def gep_result(src, pt, idx):
    t = src
    for v in idx[1:]:
        if t.kind == 'struct':
            t = t.fields[v.v]
        else:
            t = t.elem
    space = pt.space if pt.kind == 'ptr' else (pt.elem.space if pt.kind == 'vec' else 0)
    return Ty('ptr', elem=t, space=space)
