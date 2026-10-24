"""Optional C++ backend for the difftests: with AIRGLC=<path to airglc CLI> set,
each case is specialized and translated by t290/metal/compiler (airglc.cpp) from
the original bitcode instead of instantiating the Python template."""
import json
import os
import subprocess
import tempfile

AIRGLC = os.environ.get('AIRGLC')
bc_path = None      # set by the test loop: ~/air/mNNN.bc of the module under test


def compile(entry, consts):
    args = [AIRGLC, bc_path, entry.lstrip('@')]
    args += ['%d=%s' % (k, ','.join(map(str, v)) if isinstance(v, list) else v) for k, v in consts.items()]
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(args + ['-o', d + '/s.glsl', '-j', d + '/s.json'], capture_output=True, text=True, timeout=300)
        if r.returncode:
            raise RuntimeError('airglc: %s' % r.stderr.strip()[:300])
        return open(d + '/s.glsl').read(), json.load(open(d + '/s.json'))


def pad(data, b):
    """UBO data at least as large as the C++ shader declares."""
    n = b.get('ubo_bytes', 0)
    return data + b'\0' * (n - len(data)) if len(data) < n else data
