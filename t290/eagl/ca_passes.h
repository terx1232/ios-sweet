/* Missing CA GLES programs. Firmware addresses are verified against the
 * installed 16.7.16 cache, never inferred from the 16.5 reference port.
 * No function_supported override: unsupported effects remain unsupported.
 */
static __thread void *ca_drawing_context;
struct CAParameters { void *context; unsigned function, count; GLfloat value[20]; };
static __thread struct CAParameters ca_parameters[16];
static __thread unsigned ca_parameter_next;

static BOOL ca_read(const void *address, void *out, size_t size)
{
    vm_size_t copied = 0;
    return address && vm_read_overwrite(mach_task_self(), (vm_address_t)(uintptr_t)address,
        size, (vm_address_t)(uintptr_t)out, &copied) == KERN_SUCCESS && copied == size;
}
static unsigned ca_function(void *context)
{
    uintptr_t state = 0;
    uint32_t function = 90;
    if (!context || !ca_read((char *)context + 0x10, &state, sizeof(state)) ||
        !ca_read((void *)(state + 0x10), &function, sizeof(function))) return 90;
    return function & 255;
}
static void ca_remember(void *context, unsigned index, size_t components,
    size_t count, const GLfloat *values)
{
    unsigned function = ca_function(context);
    /* color matrix (20, 45): 5 x vec4; blur step (28): 4 x vec2 */
    BOOL matrix = (function == 20 || function == 45) && components == 4 && count == 5;
    BOOL blur = function == 28 && components == 2 && count == 4;
    if (index || (!matrix && !blur)) return;
    size_t n = components * count;
    struct CAParameters *entry = NULL;
    for (unsigned i = 0; i < 16; i++)
        if (ca_parameters[i].context == context && ca_parameters[i].function == function)
            entry = &ca_parameters[i];
    if (!entry) entry = &ca_parameters[ca_parameter_next++ % 16];
    *entry = (struct CAParameters){.context = context, .function = function};
    if (ca_read(values, entry->value, n * sizeof(GLfloat))) {
        for (size_t i = 0; i < n; i++) if (!isfinite(entry->value[i])) return;
        entry->count = (unsigned)n;
    }
}

static void (*ca_original_draw)(void *, unsigned, unsigned, const uint16_t *,
    const void *, unsigned, unsigned, const void *);
static void (*ca_original_draw_short)(void *, unsigned, unsigned, const uint16_t *,
    const void *, unsigned, unsigned);
static void (*ca_original_uniform)(void *, unsigned, size_t, size_t, const GLfloat *);
static int (*ca_original_supported)(void *);
static int ca_supported(void *context)
{
    int result = ca_original_supported(context);
    if (trace_render) {
        static uint8_t seen[256];
        unsigned function = ca_function(context);
        if (function < 256 && !__atomic_exchange_n(&seen[function], 1, __ATOMIC_RELAXED)) {
            plog("TRACE CA function %u supported %d", function, result);
        }
    }
    return result;
}
static void ca_draw(void *context, unsigned mode, unsigned count, const uint16_t *indices,
    const void *vertices, unsigned a, unsigned b, const void *clip)
{
    void *previous = ca_drawing_context;
    ca_drawing_context = context;
    ca_original_draw(context, mode, count, indices, vertices, a, b, clip);
    ca_drawing_context = previous;
}
static void ca_draw_short(void *context, unsigned mode, unsigned count, const uint16_t *indices,
    const void *vertices, unsigned a, unsigned b)
{
    void *previous = ca_drawing_context;
    ca_drawing_context = context;
    ca_original_draw_short(context, mode, count, indices, vertices, a, b);
    ca_drawing_context = previous;
}
static void ca_uniform(void *context, unsigned index, size_t components,
    size_t count, const GLfloat *values)
{
    ca_remember(context, index, components, count, values);
    unsigned function=ca_function(context);
    if ((function==28 || function==45) && components && components<=4 && count<=20) {
        static unsigned samples[2];
        unsigned which=function==45;
        if (__atomic_fetch_add(&samples[which],1,__ATOMIC_RELAXED)<8) {
            GLfloat copy[80]={0}; size_t n=components*count;
            if (n && ca_read(values,copy,n*sizeof(GLfloat))) {
                plog("t290eagl: missing pass %u uniform %u components %zu count %zu",function,index,components,count);
                for(size_t i=0;i<n;i+=4)
                    plog("t290eagl: missing pass %u values %zu %.8g %.8g %.8g %.8g",function,i,
                        copy[i],i+1<n?copy[i+1]:0,i+2<n?copy[i+2]:0,i+3<n?copy[i+3]:0);
            }
        }
    }
    ca_original_uniform(context, index, components, count, values);
}

static void t290_ca_install(void)
{
    if (strcmp(getprogname(), "backboardd")) return;
    static const uint8_t uuid[16] = {0x9e,0x40,0xb2,0xeb,0x26,0x0c,0x3a,0xf1,
        0xae,0x45,0xa1,0xa5,0x51,0xa8,0xc1,0xb9};
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/QuartzCore.framework/QuartzCore")) continue;
        const struct mach_header_64 *mh = (const void *)_dyld_get_image_header(i);
        if (mh->magic != MH_MAGIC_64) return;
        const struct load_command *lc = (const void *)(mh + 1);
        BOOL match = NO;
        for (uint32_t j = 0; j < mh->ncmds; j++) {
            if (lc->cmd == LC_UUID && lc->cmdsize == sizeof(struct uuid_command))
                match = !memcmp(((const struct uuid_command *)lc)->uuid, uuid, 16);
            lc = (const void *)((const char *)lc + lc->cmdsize);
        }
        if (!match) { plog("t290eagl: CA hooks disabled: QuartzCore UUID mismatch"); return; }
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uintptr_t *draw = (void *)(0x1d57df7f8UL + slide);
        uintptr_t *short_draw = (void *)(0x1d57df800UL + slide);
        uintptr_t *uniform = (void *)(0x1d57dfa80UL + slide);
        uintptr_t *supported = (void *)(0x1d57dfa70UL + slide);
        if (*draw != 0x1884316d0UL + slide || *short_draw != 0x18838591cUL + slide ||
            *uniform != 0x1884321acUL + slide || *supported != 0x188432164UL + slide) {
            plog("t290eagl: CA hooks disabled: vtable mismatch"); return;
        }
        vm_address_t page = (uintptr_t)draw & ~((uintptr_t)vm_page_size - 1);
        if (((uintptr_t)uniform & ~((uintptr_t)vm_page_size - 1)) != page) return;
        kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, NO,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr) { plog("t290eagl: CA private vtable mapping failed %#x", kr); return; }
        ca_original_draw = (void *)*draw;
        ca_original_draw_short = (void *)*short_draw;
        ca_original_uniform = (void *)*uniform;
        ca_original_supported = (void *)*supported;
        *draw = (uintptr_t)ca_draw;
        *short_draw = (uintptr_t)ca_draw_short;
        *uniform = (uintptr_t)ca_uniform;
        *supported = (uintptr_t)ca_supported;
        kr = vm_protect(mach_task_self(), page, vm_page_size, NO, VM_PROT_READ);
        plog("t290eagl: CA16.7 draw/uniform hooks installed; support unchanged, protection %#x", kr);
        return;
    }
    plog("t290eagl: CA hooks disabled: QuartzCore image absent");
}

static void t290_use_program(GLuint program)
{
    gl.UseProgram(program);
    GLint actual = 0;
    gl.GetIntegerv(0x8b8d, &actual);
    current_ctx()->_program = (GLuint)actual;
}
static void t290_uniform_matrix4fv(GLint location, GLsizei count, GLboolean transpose,
    const GLfloat *values)
{
    gl.UniformMatrix4fv(location, count, transpose, values);
    T290Context *ctx = current_ctx();
    NSNumber *matrix = ctx.sharegroup.caMatrixLocations[@(ctx->_program)];
    if (matrix && location == [matrix intValue] && count == 1 && !transpose)
        ctx->_caMatrix = values;
}

#include "ca_shaders.h"
static GLuint ca_program(const char *fragment)
{
    GLuint shaders[2] = {0}, program = gl.CreateProgram();
    BOOL ok = program != 0;
    for (unsigned i = 0; i < 2 && ok; i++) {
        shaders[i] = gl.CreateShader(i ? 0x8b30 : 0x8b31);
        const char *source = i ? fragment : ca_vertex_source;
        gl.ShaderSource(shaders[i], 1, &source, NULL);
        gl.CompileShader(shaders[i]);
        GLint status = 0;
        gl.GetShaderiv(shaders[i], 0x8b81, &status);
        ok = status != 0;
        if (ok) gl.AttachShader(program, shaders[i]);
        else { char log[180] = {0}; gl.GetShaderInfoLog(shaders[i], sizeof(log), NULL, log);
            plog("t290eagl: CA shader failed: %s", log); }
    }
    if (ok) {
        gl.BindAttribLocation(program, 0, "p");
        gl.BindAttribLocation(program, 1, "c");
        gl.BindAttribLocation(program, 2, "t");
        gl.LinkProgram(program);
        GLint status = 0;
        gl.GetProgramiv(program, 0x8b82, &status);
        ok = status != 0;
    }
    for (unsigned i = 0; i < 2; i++) if (shaders[i]) gl.DeleteShader(shaders[i]);
    if (!ok && program) { gl.DeleteProgram(program); program = 0; }
    return program;
}

enum { CA_PASS_UNCHANGED, CA_PASS_PROGRAM, CA_PASS_SKIP };
static int ca_skip(unsigned function, unsigned reason, const char *message)
{
    static unsigned seen[256];
    if (function < 256 && !(__atomic_fetch_or(&seen[function], 1u << reason,
        __ATOMIC_RELAXED) & (1u << reason)))
        plog("t290eagl: CA function %u skipped: %s", function, message);
    return CA_PASS_SKIP;
}
static int t290_ca_draw_begin(T290Context *ctx)
{
    if (ctx->_program || !ca_drawing_context) return CA_PASS_UNCHANGED;
    unsigned function = ca_function(ca_drawing_context);
    static uint8_t logged[256];
    if (function < 256 && !__atomic_exchange_n(&logged[function], 1, __ATOMIC_RELAXED)) {
        plog("t290eagl: CA programless function %u, ctx %p, draw %u", function,
            ca_drawing_context, ctx->_drawCount);
        if(function==28 || function==45)
            plog("t290eagl: missing pass %u textures %u,%u target %u source surfaces %u,%u",
                function,ctx->_boundName[0],ctx->_boundName[1],ctx->_drawFbo,
                ctx->_bound[0]?IOSurfaceGetID(ctx->_bound[0]->source):0,
                ctx->_bound[1]?IOSurfaceGetID(ctx->_bound[1]->source):0);
    }
    /* 20/45 color matrix (45: wallpaper and vibrant labels), 28 blur step,
     * 89 copy; other programless functions stay skipped */
    if (function != 20 && function != 45 && function != 28 && function != 89) return CA_PASS_SKIP;
    BOOL colorMatrix = function == 20 || function == 45;
    GLfloat matrix[16];
    if (!ca_read(ctx->_caMatrix, matrix, sizeof(matrix)))
        return ca_skip(function, 0, "vertex matrix unavailable");
    for (unsigned i = 0; i < 16; i++) if (!isfinite(matrix[i]))
        return ca_skip(function, 1, "nonfinite vertex matrix");
    GLuint source = ctx->_boundName[0];
    uint64_t target = [ctx->_attachmentNames[@(ctx->_drawFbo)] unsignedLongLongValue];
    if (!source) return ca_skip(function, 2, "no source texture");
    if ((target == source) ||
        (ctx->_drawImage && ctx->_bound[0] && ctx->_drawImage->source == ctx->_bound[0]->source))
        return ca_skip(function, 3, "texture feedback prevented");
    NSArray *definition = ctx.sharegroup.mipLevels[@(source)][@0];
    if ([definition count] < 3) return ca_skip(function, 4, "texture geometry unavailable");
    GLsizei w = [definition[1] intValue], h = [definition[2] intValue];
    if (w <= 0 || h <= 0) return ca_skip(function, 4, "invalid texture geometry");
    const GLfloat *values = NULL;
    if (function != 89) {
        unsigned want = function == 28 ? 8 : 20;
        for (unsigned i = 0; i < 16; i++)
            if (ca_parameters[i].context == ca_drawing_context &&
                ca_parameters[i].function == function && ca_parameters[i].count == want)
                values = ca_parameters[i].value;
        if (!values) return ca_skip(function, 5, function == 28 ? "blur offsets unavailable" :
            "color matrix parameters unavailable");
    }
    GLuint *program = colorMatrix ? &ctx->_caColorProgram :
        function == 28 ? &ctx->_caBlurProgram : &ctx->_caCopyProgram;
    BOOL *failed = colorMatrix ? &ctx->_caColorFailed :
        function == 28 ? &ctx->_caBlurFailed : &ctx->_caCopyFailed;
    if (!*program && !*failed) {
        *program = ca_program(colorMatrix ? ca_color_source :
            function == 28 ? ca_blur_source : ca_copy_source);
        *failed = !*program;
        plog("t290eagl: CA function %u replacement program %u", function, *program);
    }
    if (!*program) return CA_PASS_SKIP;
    gl.UseProgram(*program);
    gl.UniformMatrix4fv(gl.GetUniformLocation(*program, "mvp"), 1, 0, matrix);
    gl.Uniform2f(gl.GetUniformLocation(*program, "invSize"), 1.f / w, 1.f / h);
    gl.Uniform1i(gl.GetUniformLocation(*program, "src"), 0);
    if (values && colorMatrix) gl.Uniform4fv(gl.GetUniformLocation(*program, "cols"), 5, values);
    if (values && function == 28) gl.Uniform4fv(gl.GetUniformLocation(*program, "offs"), 2, values);
    return CA_PASS_PROGRAM;
}

/* The guard exercises the production path with a small synthetic CA state.
 * This entry point cannot enable the hook in another process/firmware. */
void T290EAGLTestCA(void *context, const GLfloat *values);
void T290EAGLTestCA(void *context, const GLfloat *values)
{
    if (strcmp(getprogname(), "eagltest") && strcmp(getprogname(), "host-eagltest")) return;
    ca_drawing_context = context;
    if (context && values) ca_remember(context, 0, 4, 5, values);
}
