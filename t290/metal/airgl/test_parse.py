#!/usr/bin/env python3
"""Parse every inlined QuartzCore AIR module (~/air/opt/m*.ll); report failures."""
import glob, os, sys, collections
sys.path.insert(0, os.path.dirname(__file__))
import llparse

files = sorted(f for f in glob.glob(os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/air/opt') + '/m*.ll')
               if not f.endswith('.in.ll'))
ok, ops, calls = 0, collections.Counter(), collections.Counter()
for f in files:
    try:
        m = llparse.parse_module(open(f).read())
    except Exception as e:
        print('FAIL', f, type(e).__name__, str(e)[:300])
        continue
    ok += 1
    for fn in m.funcs.values():
        for b in fn.blocks:
            for i in b.insts:
                ops[i.op] += 1
                if i.op == 'call': calls[i.extra['callee']] += 1
print('parsed %d/%d' % (ok, len(files)))
print(sorted(ops.items(), key=lambda x: -x[1]))
print(len(calls), 'callees')
