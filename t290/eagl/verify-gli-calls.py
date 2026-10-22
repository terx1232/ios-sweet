#!/usr/bin/env python3
"""Check explicit CALL casts against the cached GLI ABI before compiling."""
import pathlib
import re
import sys


def abi(t):
    t = t.strip()
    if '*' in t or t in ('GLIContext', 'GLsync'):
        return 'pointer'
    if t == 'void':
        return 'void'
    if t in ('GLfloat', 'GLclampf', 'float'):
        return 'float32'
    if t in ('GLdouble', 'GLclampd', 'double'):
        return 'float64'
    if t in ('GLintptr', 'GLintptrARB', 'GLsizeiptr', 'GLsizeiptrARB', 'GLint64',
             'GLint64EXT', 'GLuint64', 'GLuint64EXT', 'int64_t', 'uint64_t'):
        return 'integer64'
    if t in ('GLenum', 'GLuint', 'GLint', 'GLsizei', 'GLbitfield', 'GLhandleARB',
             'GLboolean', 'GLbyte', 'GLubyte', 'GLshort', 'GLushort', 'int', 'unsigned'):
        return 'integer32'
    raise ValueError(f'unknown GLI ABI type: {t}')


layout = {}
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    entry, ret, params = line.split(' | ', 2)
    slot, name = entry.split(' ', 1)
    types = [re.sub(r'\b\w+\s*$', '', p).strip() for p in params.split(',')]
    layout[int(slot)] = (name, abi(ret), [abi(t) for t in types])

source = pathlib.Path(sys.argv[2]).read_text()
errors = []
count = 0
for call in re.finditer(r'CALL\(\s*(\d+)\s*,\s*([^,]+),\s*\(([^)]*)\)', source):
    slot, ret, params = int(call[1]), call[2], call[3]
    signature = (abi(ret), [abi(t) for t in params.split(',')])
    name, expected_ret, expected_params = layout[slot]
    count += 1
    if signature != (expected_ret, expected_params):
        line = source.count('\n', 0, call.start()) + 1
        errors.append(f'{sys.argv[2]}:{line}: slot {slot} {name}: {signature} != '
                      f'{(expected_ret, expected_params)}')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS {count} explicit GLI call signatures')
