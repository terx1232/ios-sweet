#!/bin/bash
# Inline + simplify every AIR module with stock LLVM 14 opt; report failures and what remains.
cd ~/air
mkdir -p opt
fail=0
for f in m*.bc; do
	b=${f%.bc}
	sed -e 's/^target triple = .*//' -e '/^attributes #/s/ noinline//' -e '/^attributes #.*frame-pointer/s/{ /{ alwaysinline /' "$b.ll" > "opt/$b.in.ll"
	if ! opt-14 -passes='always-inline,inline,sroa,early-cse,instcombine,simplifycfg,adce' \
		-inline-threshold=1000000 "opt/$b.in.ll" -o "opt/$b.bc" 2>"opt/$b.err"; then
		echo "FAIL $b: $(head -c 300 "opt/$b.err")"; fail=$((fail+1)); continue
	fi
	llvm-dis-14 "opt/$b.bc" -o "opt/$b.ll"
done
echo "opt failures: $fail"
python3 - <<'PY'
import re, glob, collections
fns = collections.Counter(); left = []
files = sorted(f for f in glob.glob('opt/m*.ll') if not f.endswith('.in.ll'))
for f in files:
    t = open(f).read()
    defs = re.findall(r'^define [^@]*@([\w.$]+)\(', t, re.M)
    fns[len(defs)] += 1
    if len(defs) > 1: left.append((f, defs))
print('modules', len(files), 'defined functions per module after inlining:', dict(fns))
for f, d in left[:8]: print(f, [x[:50] for x in d[:6]])
big = sorted((len(open(f).read().splitlines()), f) for f in files)[-5:]
print('largest:', big)
PY
