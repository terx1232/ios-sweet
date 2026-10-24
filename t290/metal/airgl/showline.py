#!/usr/bin/env python3
"""Show a line of the specialized GLSL (as compiled by run_all.py): showline.py NAME LINE"""
import json, os, sys
sys.argv += []
sys.path.insert(0, os.path.dirname(__file__))
name, line = sys.argv[1], int(sys.argv[2])
base = os.path.expanduser('~/air/glsl/' + name)
text = open(base + '.glsl').read()
refl = json.load(open(base + '.json'))
defs = ['#define T290_SPECIALIZED 1', '#define T290_LOCAL_X 8', '#define T290_LOCAL_Y 8', '#define T290_LOCAL_Z 1']
for c in refl['constants']:
    defs += ['#define FC%d 0' % c['index'], '#define FCDEF%d 1' % c['index']]
lines = text.split('\n')
k = 1
while k < len(lines) and lines[k].startswith('#extension'): k += 1
spec = lines[:k] + defs + lines[k:]
for n in range(line - 2, line + 1):
    print(n, spec[n - 1][:500])
