#!/usr/bin/env python3
"""Pixel checks of the shipped shader strings using Linux software Mesa/EGL.

This checks shader arithmetic, not the iOS hooks/GLI ABI or Adreno execution.
Those are covered separately by the guarded eagltest on the tablet.
"""
import ast
import ctypes as C
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

if len(sys.argv) == 1:
    for version in (2, 3):
        subprocess.run([sys.executable, __file__, str(version)], check=True)
    sys.exit(0)
assert sys.argv[1] in ('2', '3')
os.environ['MESA_GLES_VERSION_OVERRIDE'] = sys.argv[1] + '.0'

os.environ['EGL_PLATFORM'] = 'surfaceless'
os.environ['LIBGL_ALWAYS_SOFTWARE'] = '1'
egl = C.CDLL('libEGL.so.1')
gl = C.CDLL('libGLESv2.so.2')
P, I, U, F = C.c_void_p, C.c_int, C.c_uint, C.c_float


def api(lib, name, ret, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = ret, args
    return fn


get_display = api(egl, 'eglGetDisplay', P, P)
initialize = api(egl, 'eglInitialize', U, P, P, P)
choose = api(egl, 'eglChooseConfig', U, P, P, P, I, P)
bind = api(egl, 'eglBindAPI', U, U)
surface = api(egl, 'eglCreatePbufferSurface', P, P, P, P)
context = api(egl, 'eglCreateContext', P, P, P, P, P)
current = api(egl, 'eglMakeCurrent', U, P, P, P, P)
destroy_context = api(egl, 'eglDestroyContext', U, P, P)
destroy_surface = api(egl, 'eglDestroySurface', U, P, P)
terminate = api(egl, 'eglTerminate', U, P)
create_shader = api(gl, 'glCreateShader', U, U)
source = api(gl, 'glShaderSource', None, U, I, P, P)
compile_shader = api(gl, 'glCompileShader', None, U)
shader_iv = api(gl, 'glGetShaderiv', None, U, U, P)
shader_log = api(gl, 'glGetShaderInfoLog', None, U, I, P, P)
create_program = api(gl, 'glCreateProgram', U)
attach = api(gl, 'glAttachShader', None, U, U)
attribute = api(gl, 'glBindAttribLocation', None, U, U, C.c_char_p)
link = api(gl, 'glLinkProgram', None, U)
program_iv = api(gl, 'glGetProgramiv', None, U, U, P)
program_log = api(gl, 'glGetProgramInfoLog', None, U, I, P, P)
use = api(gl, 'glUseProgram', None, U)
uniform = api(gl, 'glGetUniformLocation', I, U, C.c_char_p)
matrix = api(gl, 'glUniformMatrix4fv', None, I, I, C.c_ubyte, P)
vec2 = api(gl, 'glUniform2f', None, I, F, F)
vec4 = api(gl, 'glUniform4fv', None, I, I, P)
integer = api(gl, 'glUniform1i', None, I, I)
gen_tex = api(gl, 'glGenTextures', None, I, P)
bind_tex = api(gl, 'glBindTexture', None, U, U)
tex_image = api(gl, 'glTexImage2D', None, U, I, I, I, I, I, U, U, P)
tex_parameter = api(gl, 'glTexParameteri', None, U, U, I)
gen_buffer = api(gl, 'glGenBuffers', None, I, P)
bind_buffer = api(gl, 'glBindBuffer', None, U, U)
buffer_data = api(gl, 'glBufferData', None, U, C.c_ssize_t, P, U)
pointer = api(gl, 'glVertexAttribPointer', None, U, I, U, C.c_ubyte, I, P)
enable_array = api(gl, 'glEnableVertexAttribArray', None, U)
viewport = api(gl, 'glViewport', None, I, I, I, I)
clear_color = api(gl, 'glClearColor', None, F, F, F, F)
clear = api(gl, 'glClear', None, U)
draw = api(gl, 'glDrawArrays', None, U, I, I)
read = api(gl, 'glReadPixels', None, I, I, I, I, U, U, P)
error = api(gl, 'glGetError', U)
get_string = api(gl, 'glGetString', C.c_char_p, U)

text = Path(__file__).with_name('ca_shaders.h').read_text()


def shipped(name):
    match = re.search(r'static const char ' + name + r'\[\]\s*=\s*'
                      r'((?:"(?:[^"\\]|\\.)*"\s*)+);', text)
    assert match, name
    return ''.join(ast.literal_eval(s) for s in
                   re.findall(r'"(?:[^"\\]|\\.)*"', match[1])).encode()


compat_tmp = tempfile.TemporaryDirectory(prefix='t290-ca-compat-')
compat_path = Path(compat_tmp.name)
compat_path.joinpath('compat.c').write_text(
    '#include <stdlib.h>\n#include <string.h>\n' +
    Path(__file__).with_name('ca_shader_compat.h').read_text() +
    '\nchar *repair(const char *s,const char *e){return t290_ca_coord_source(s,e);}\n')
subprocess.run(['clang','-shared','-fPIC',str(compat_path/'compat.c'),'-o',str(compat_path/'compat.so')],check=True)
compat = C.CDLL(str(compat_path/'compat.so'))
repair = api(compat,'repair',P,C.c_char_p,C.c_char_p)
release = api(C.CDLL(None),'free',None,P)


def compile_program(fragment, vertex=None):
    program = create_program()
    for typ, body in ((0x8b31, vertex or shipped('ca_vertex_source')),
                      (0x8b30, fragment if isinstance(fragment,bytes) else shipped(fragment))):
        shader = create_shader(typ)
        strings = (C.c_char_p * 1)(body)
        source(shader, 1, strings, None)
        compile_shader(shader)
        ok = I()
        shader_iv(shader, 0x8b81, C.byref(ok))
        log = C.create_string_buffer(4096)
        shader_log(shader, len(log), None, log)
        if not ok.value and vertex is not None and typ == 0x8b30:
            assert b'coord_arg' in log.value and b'undeclared' in log.value,log.value
            fixed = repair(body,log.value)
            assert fixed
            try:
                strings=(C.c_char_p*1)(C.string_at(fixed))
                source(shader,1,strings,None)
                compile_shader(shader)
                shader_iv(shader,0x8b81,C.byref(ok))
                shader_log(shader,len(log),None,log)
            finally:
                release(fixed)
        assert ok.value, log.value
        attach(program, shader)
    for index, name in enumerate((b'p', b'c', b't')):
        attribute(program, index, name)
    link(program)
    ok = I()
    program_iv(program, 0x8b82, C.byref(ok))
    log = C.create_string_buffer(4096)
    program_log(program, len(log), None, log)
    assert ok.value, log.value
    return program


def pixel(x, y):
    value = (C.c_ubyte * 4)()
    read(x, y, 1, 1, 0x1908, 0x1401, value)
    assert error() == 0
    return list(value)


def expect(actual, wanted):
    assert all(abs(a - b) <= 2 for a, b in zip(actual, wanted)), (actual, wanted)


display = get_display(None)
assert display and initialize(display, None, None)
assert bind(0x30a0)
for version in (int(sys.argv[1]),):
    attributes = (I * 15)(0x3033, 1, 0x3040, 4 if version == 2 else 64,
        0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038, 0, 0)
    config, count = P(), I()
    assert choose(display, attributes, C.byref(config), 1, C.byref(count)) and count.value
    pb = surface(display, config, (I * 5)(0x3057, 64, 0x3056, 64, 0x3038))
    ctx = context(display, config, None, (I * 3)(0x3098, version, 0x3038))
    assert pb and ctx and current(display, pb, pb, ctx)
    actual = get_string(0x1f02).decode()
    assert actual.startswith(f'OpenGL ES {version}.'), actual
    print(actual)
    tex, vbo = U(), U()
    gen_tex(1, C.byref(tex))
    bind_tex(0x0de1, tex)
    colors = [[64,128,192,255], [17,34,51,128], [200,80,40,255], [255,0,255,255]]
    tex_image(0x0de1, 0, 0x1908, 2, 2, 0, 0x1908, 0x1401,
              (C.c_ubyte * 16)(*(c for color in colors for c in color)))
    for parameter in (0x2800, 0x2801):
        tex_parameter(0x0de1, parameter, 0x2600)
    vertices = (F * 30)(-1,-1,0,1, 1,1,1,1, 0,0,
                        3,-1,0,1, 1,1,1,1, 4,0,
                       -1, 3,0,1, 1,1,1,1, 0,4)
    gen_buffer(1, C.byref(vbo))
    bind_buffer(0x8892, vbo)
    buffer_data(0x8892, C.sizeof(vertices), vertices, 0x88e4)
    for index, size, offset in ((0,4,0), (1,4,16), (2,2,32)):
        pointer(index, size, 0x1406, 0, 40, P(offset))
        enable_array(index)
    viewport(0, 0, 64, 64)
    for name in ('ca_copy_source', 'ca_color_source'):
        program = compile_program(name)
        use(program)
        transform = (F * 16)(1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1)
        matrix(uniform(program, b'mvp'), 1, 0, transform)
        vec2(uniform(program, b'invSize'), .5, .5)
        integer(uniform(program, b'src'), 0)
        if name == 'ca_color_source':
            cols = (F * 20)(0,0,0,1, 0,0,0,0, 0,0,0,0, 0,0,0,0, -1,.25,2,0)
            vec4(uniform(program, b'cols'), 5, cols)
        clear_color(0,0,0,0)
        clear(0x4000)
        draw(4,0,3)
        for position, color in zip(((16,16),(48,16),(16,48),(48,48)), colors):
            expect(pixel(*position), color if name == 'ca_copy_source' else [0,64,255,color[0]])
        transform[12] = 4
        matrix(uniform(program, b'mvp'), 1, 0, transform)
        clear(0x4000)
        draw(4,0,3)
        expect(pixel(32,32), [0,0,0,0])
        print(f'PASS ES{version} {name}: 4 quadrants/RGBA, matrix/clamp, clip transform')
    # Compile the same independently written fixture as the device GLI guard.
    fixture=Path(__file__).with_name('eagltest.m').read_text().split('static int test_ca_inverse_mask',1)[1]
    literals=fixture.split('const char *sources[]={',1)[1].split('};',1)[0]
    literals=re.sub(r'"\s*"','',literals)
    vertex,fragment=[v.encode() for v in ast.literal_eval('['+literals+']')]
    error_text=b"coord_arg undeclared"
    assert not repair(fragment,b'unrelated error')
    assert not repair(b'#version 100\n'+fragment,error_text)
    assert not repair(b'uniform lowp vec4 coord_arg;\n'+fragment,error_text)
    assert not repair(b'void main(){}',error_text)
    program=compile_program(fragment,vertex)
    use(program)
    mask=(C.c_ubyte*8)(0,0,0,0,0,0,0,255)
    tex_image(0x0de1,0,0x1908,2,1,0,0x1908,0x1401,mask)
    vertices2=(F*6)(-1,-1,3,-1,-1,3)
    buffer_data(0x8892,C.sizeof(vertices2),vertices2,0x88e4)
    attribute_index=api(gl,'glGetAttribLocation',I,U,C.c_char_p)(program,b'position')
    pointer(attribute_index,2,0x1406,0,0,None)
    enable_array(attribute_index)
    bounds=uniform(program,b'coord_arg')
    assert bounds>=0
    vec4(bounds,1,(F*4)(0,0,1,1))
    draw(4,0,3)
    expect(pixel(16,16),[128,64,32,255]);expect(pixel(48,16),[0,0,0,0])
    vec4(bounds,1,(F*4)(0,0,0,1))
    draw(4,0,3)
    expect(pixel(48,16),[128,64,32,255])
    print(f'PASS ES{version} inverse-mask compiler failure/retry, both halves and caller clamp override; refusal cases')
    assert current(display, None, None, None)
    destroy_context(display, ctx)
    destroy_surface(display, pb)
terminate(display)
compat_tmp.cleanup()
