#!/usr/bin/env python3
"""Specialize a module for N random constant sets (as spectest would) and report sizes/time/memory."""
import json, os, random, resource, subprocess, sys, time
here = os.path.dirname(os.path.abspath(__file__))
mod, name, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
refl = json.load(open(os.path.expanduser('~/air/glsl/%s.json' % name)))
for c in range(n):
    random.seed(1000 + c)
    args = []
    for k in refl['constants']:
        t = k['type']
        v = random.randrange(2) if t == 'b' else (','.join(str(random.randrange(4)) for _ in range(3)) if t == 'Dv3_h' else random.randrange(4))
        args.append('%d=%s' % (k['index'], v))
    t0 = time.time()
    r = subprocess.run(['/usr/bin/time', '-f', '%M KB', sys.executable, os.path.join(here, 'specialize.py'), mod,
                        os.path.expanduser('~/air/spec/%s_r%d' % (name, c))] + args,
                       capture_output=True, text=True, timeout=900)
    print(c, '%.1fs' % (time.time() - t0), r.stdout.strip().splitlines()[-1] if r.stdout.strip() else '', r.stderr.strip().splitlines()[-1][:120], flush=True)
