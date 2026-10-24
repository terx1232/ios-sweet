#!/usr/bin/env python3
"""Print the AIR entry-point metadata of one module, resolving node references."""
import os, re, sys
sys.path.insert(0, os.path.dirname(__file__))
import llparse

m = llparse.parse_module(open(sys.argv[1]).read())


def show(ref, depth=0, seen=()):
    if ref in seen or depth > 6: return ref
    items = m.meta.get(ref)
    if items is None: return ref
    out = []
    for it in items:
        if re.fullmatch(r'!\d+', it): out.append(show(it, depth + 1, seen + (ref,)))
        else: out.append(it)
    return '{' + ', '.join(out) + '}'


for key in ('!air.vertex', '!air.fragment', '!air.kernel'):
    for ref in m.named.get(key, []):
        items = m.meta[ref]
        print(key, items[0])
        for part in items[1:]:
            for sub in m.meta.get(part, []):
                print('   ', show(sub))
fc = [g for g in m.globals.values() if g.section == 'air.fc_initializer']
print('function constants:', [g.name for g in fc])
print('other globals:', [(g.name, g.space) for g in m.globals.values() if g.section != 'air.fc_initializer'][:20])
