#!/usr/bin/env python3
"""Which inlined modules still have loops (back edges) and how many blocks."""
import glob, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import llparse

d = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/air/opt')
names = open(os.path.join(os.path.dirname(d.rstrip('/')), 'names.txt')).read().split()
for f in sorted(glob.glob(d + '/m*.ll')):
    if f.endswith('.in.ll'): continue
    k = int(os.path.basename(f)[1:4])
    m = llparse.parse_module(open(f).read())
    for fn in m.funcs.values():
        idx = {b.name: i for i, b in enumerate(fn.blocks)}
        back = sum(1 for b in fn.blocks for t in b.insts[-1].extra.get('targets', []) if idx[t] <= idx[b.name])
        if back or len(fn.blocks) > 20:
            print('%-36s %-34s blocks %4d back-edges %d' % (names[k], fn.name[:34], len(fn.blocks), back))
