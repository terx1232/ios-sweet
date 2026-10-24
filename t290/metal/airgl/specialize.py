#!/usr/bin/env python3
"""Specialize an inlined AIR module for given function constants, re-optimize with LLVM, translate.

specialize.py MODULE.ll OUT_PREFIX [idx=value ...]   (unlisted constants: 0)
Writes OUT_PREFIX.ll (specialized IR), .glsl and .json; prints sizes.
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import airgl

src, out = sys.argv[1], sys.argv[2]
values = {int(k): v for k, v in (a.split('=') for a in sys.argv[3:])}
text = open(src).read()

# function-constant globals -> real constants with the chosen values
decl = re.compile(r'^(@[\w.$]+\.MTL_FC_INIT_(\d+)_(\w+)) = internal (unnamed_addr )?addrspace\(2\) externally_initialized constant (i8|i16|i32|half|float|<3 x i8>) undef(.*)$', re.M)


def lit(ty, v):
    if ty.startswith('<3 x'):
        vals = v.split(',') if isinstance(v, str) else [0, 0, 0]
        return '<i8 %s, i8 %s, i8 %s>' % tuple(vals)
    return str(v)


def repl(m):
    name, idx, code, ua, ty, rest = m.groups()
    v = values.get(int(idx), 0)
    return '%s = internal addrspace(2) constant %s %s%s' % (name, ty, lit(ty, v), rest.replace(' externally_initialized', ''))


text, n = decl.subn(repl, text)
# every constant is defined
text = re.sub(r'(?:tail )?call i1 @air\.is_function_constant_defined\(i8 addrspace\(2\)\* (?:nocapture )?@[\w.$]+\)(?: #\d+)?',
              'add i1 1, 0', text)
text = re.sub(r'(?:tail )?call i8 @air\.normalize_function_constant_predicate\.i8\(i8 ([^)]+)\)(?: #\d+)?',
              r'add i8 \1, 0', text)
# run the static initializer inside the entry so derived flags fold too
init = re.search(r'^define internal void (@_GLOBAL__sub_I_[\w.$]+)\(\)', text, re.M)
if init:
    m = re.search(r'^define (?!internal)[^\n]*\{\n', text, re.M)
    text = text[:m.end()] + '  call void %s()\n' % init.group(1) + text[m.end():]
    text = re.sub(r'^@llvm\.global_ctors = .*$', '', text, flags=re.M)
    text = text.replace('section "air.static_init" ', '')
open(out + '.in.ll', 'w').write(text)
fold = 'function(sroa,instcombine,sccp,gvn,instcombine,simplifycfg,adce)'
loops = ('function(loop-simplify,lcssa,loop-rotate,loop-unroll-full,loop-unroll<O3>,sroa,instcombine,'
         'sccp,gvn,instcombine,simplifycfg,adce)')
cmd = ['opt-14', '-inline-threshold=1000000',
       '-passes=always-inline,inline,%s,globalopt,%s,globalopt,%s,%s,globaldce' % (fold, fold, loops, fold),
       '-unroll-threshold=100000', out + '.in.ll', '-S', '-o', out + '.ll']
subprocess.run(cmd, check=True)
glsl, refl = airgl.translate_file(out + '.ll')
open(out + '.glsl', 'w').write(glsl)
import json
open(out + '.json', 'w').write(json.dumps(refl, indent=1))
print('constants replaced %d; IR lines %d -> %d; GLSL bytes %d' % (
    n, len(open(src).read().splitlines()), len(open(out + '.ll').read().splitlines()), len(glsl)))
