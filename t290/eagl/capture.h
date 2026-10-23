/* Opt-in real compositor capture. Marker '2'; normal/test processes skip it.
 * Readbacks synchronize the GPU: captured performance is not a benchmark.
 * File: 16-byte header, then 128-byte little-endian record headers + payloads.
 * Keep below the SD transfer's 16 MiB GET capacity. */
static int capture_fd = -1;
static size_t capture_bytes;
static unsigned capture_records;
static pthread_mutex_t capture_mutex = PTHREAD_MUTEX_INITIALIZER;
static const size_t capture_limit = 15 * 1024 * 1024;

/* Send compressed records through the existing read-only USB log too, so
 * inspecting pixels normally does not require two more SD-transfer boots.
 * Each record has a length and FNV checksum; a dropped USB block cannot
 * silently turn an incomplete capture into valid pixels. */
static void capture_stream(const uint32_t *header, const void *data, size_t size)
{
    static size_t wire_bytes;
    NSMutableData *raw = [NSMutableData dataWithBytes:header length:128];
    if (size) [raw appendBytes:data length:size];
    NSData *packed = [raw compressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:NULL];
    if (!packed) return;
    NSString *encoded = [packed base64EncodedStringWithOptions:0];
    size_t length = [encoded length];
    pthread_mutex_lock(&capture_mutex);
    BOOL skip = wire_bytes + length > 2 * 1024 * 1024;
    if (!skip) wire_bytes += length;
    pthread_mutex_unlock(&capture_mutex);
    if (skip) return; /* full record is still in the bounded file */
    uint32_t hash = 2166136261u;
    const uint8_t *bytes = [raw bytes];
    for (NSUInteger i = 0; i < [raw length]; i++) hash = (hash ^ bytes[i]) * 16777619u;
    const char *base64 = [encoded UTF8String];
    size_t count = (length + 759) / 760;
    plog("CAPBEGIN %u %zu %zu %zu %08x", header[3], count, [packed length], [raw length], hash);
    for (size_t part = 0; part < count; part++) {
        size_t offset = part * 760, n = MIN((size_t)760, length - offset);
        plog("CAPDATA %u %zu %.*s", header[3], part, (int)n, base64 + offset);
    }
}

static BOOL capture_write_all(const void *data, size_t size)
{
    const uint8_t *p = data;
    while (size) {
        ssize_t n = write(capture_fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += n; size -= (size_t)n;
    }
    return YES;
}

/* Header fields: magic, header-size, kind, sequence, draw, api, fbo,
 * texture, surface, width, height, stride, format, type, level, x, y,
 * flags, program, unit0, unit1, error, ctx-lo, ctx-hi, viewport[4],
 * payload-size, reserved[3]. Kinds:1 upload,2 draw,3 IOSurface input,
 * 4 completed surface1,5 GL state. Flag1 means format is a FourCC. */
static void capture_record(T290Context *ctx, unsigned kind, GLuint texture,
    uint32_t surface, unsigned w, unsigned h, unsigned stride, unsigned format,
    unsigned type, int level, int x, int y, unsigned flags, unsigned error,
    const void *data, size_t size)
{
    if (!capture_render || size > capture_limit) return;
    pthread_mutex_lock(&capture_mutex);
    if (capture_fd == -1) {
        capture_fd = open("/private/var/tmp/t290eagl-capture.bin", O_WRONLY | O_CREAT | O_TRUNC, 0600);
        const uint32_t file_header[] = {0x30393254, 0x31504143, 1, 128}; /* T290CAP1 */
        if (capture_fd >= 0 && capture_write_all(file_header, sizeof(file_header)))
            capture_bytes = sizeof(file_header);
        else { if (capture_fd >= 0) close(capture_fd); capture_fd = -2; }
    }
    if (capture_fd < 0 || capture_records >= 256 ||
        capture_bytes + 128 + size > capture_limit) {
        pthread_mutex_unlock(&capture_mutex);
        return;
    }
    uintptr_t context = (uintptr_t)(__bridge void *)ctx;
    GLint program = 0;
    gl.GetIntegerv(0x8b8d, &program);
    uint32_t header[32] = {0x31504354, 128, kind, ++capture_records,
        ctx->_drawCount, ctx.API, ctx->_drawFbo, texture, surface, w, h, stride,
        format, type, (uint32_t)level, (uint32_t)x, (uint32_t)y, flags, (uint32_t)program,
        ctx->_boundName[0], ctx->_boundName[1], error, (uint32_t)context, (uint32_t)(context >> 32),
        (uint32_t)ctx->_viewport[0], (uint32_t)ctx->_viewport[1],
        (uint32_t)ctx->_viewport[2], (uint32_t)ctx->_viewport[3], (uint32_t)size};
    BOOL ok = capture_write_all(header, sizeof(header)) && capture_write_all(data, size);
    if (ok) {
        capture_bytes += sizeof(header) + size;
        if (kind == 4 || !(capture_records % 16)) fsync(capture_fd);
    }
    else { close(capture_fd); capture_fd = -2; }
    pthread_mutex_unlock(&capture_mutex);
    plog("CAPTURE record %u kind %u draw %u fbo %u tex %u surface %u %ux%u bytes %zu error %#x write %d",
        header[3], kind, ctx->_drawCount, ctx->_drawFbo, texture, surface, w, h, size, error, ok);
    if (ok) capture_stream(header, data, size);
}

static void *capture_vm_copy(const void *source, size_t size)
{
    if (!source || !size || size > 8 * 1024 * 1024) return NULL;
    void *copy = malloc(size);
    if (!copy) return NULL;
    vm_size_t copied = 0;
    kern_return_t result = vm_read_overwrite(mach_task_self(),
        (vm_address_t)(uintptr_t)source, size, (vm_address_t)(uintptr_t)copy, &copied);
    if (result || copied != size) { free(copy); return NULL; }
    return copy;
}

static void t290_capture_upload(GLenum target, GLint level, GLint x, GLint y,
    GLsizei w, GLsizei h, GLenum format, GLenum type, const void *pixels)
{
    static unsigned uploads;
    if (!capture_render || target != 0x0de1 || level != 0 || !pixels ||
        w <= 0 || h <= 0 || w > 512 || h > 512 ||
        __atomic_load_n(&uploads, __ATOMIC_RELAXED) >= 64) return;
    T290Context *ctx = current_ctx();
    GLint pbo = 0, alignment = 4, rowLength = 0, skipRows = 0, skipPixels = 0, texture = 0;
    if (ctx.API >= 3) {
        gl.GetIntegerv(0x88ef, &pbo); /* PIXEL_UNPACK_BUFFER_BINDING */
        gl.GetIntegerv(0x0cf2, &rowLength);
        gl.GetIntegerv(0x0cf3, &skipRows);
        gl.GetIntegerv(0x0cf4, &skipPixels);
    }
    if (pbo || rowLength < 0 || skipRows < 0 || skipPixels < 0) return;
    gl.GetIntegerv(0x0cf5, &alignment);
    gl.GetIntegerv(0x8069, &texture);
    unsigned channels = format == 0x1908 || format == 0x80e1 ? 4 :
        format == 0x190a || format == 0x8227 ? 2 :
        format == 0x1906 || format == 0x1909 || format == 0x1903 ? 1 : 0;
    unsigned bytes = type == 0x1401 ? 1 : type == 0x140b || type == 0x8d61 ? 2 : 0;
    if (!channels || !bytes || (alignment != 1 && alignment != 2 && alignment != 4 && alignment != 8)) return;
    size_t cpp = channels * bytes, stride = ((size_t)(rowLength ?: w) * cpp + alignment - 1) & ~(size_t)(alignment - 1);
    if (stride > 1024 * 1024 || (size_t)skipPixels * cpp + (size_t)w * cpp > stride) return;
    uint8_t *copy = malloc((size_t)w * h * cpp);
    if (!copy) return;
    for (GLsizei row = 0; row < h; row++) {
        uintptr_t start = (uintptr_t)pixels + ((size_t)skipRows + row) * stride + (size_t)skipPixels * cpp;
        vm_size_t got = 0;
        if (vm_read_overwrite(mach_task_self(), start, (size_t)w * cpp,
            (vm_address_t)(uintptr_t)(copy + (size_t)row * w * cpp), &got) || got != (size_t)w * cpp) {
            free(copy); return;
        }
    }
    if (__atomic_fetch_add(&uploads, 1, __ATOMIC_RELAXED) >= 64) { free(copy); return; }
    capture_record(ctx, 1, texture, 0, w, h, w * cpp, format, type, level, x, y, 0, 0, copy, (size_t)w * h * cpp);
    free(copy);
}

static void t290_capture_sources(T290Context *ctx)
{
    if (!capture_render) return;
    static NSMutableSet *seen;
    for (GLuint u = 0; u < ctx->_units; u++) {
        T290SurfaceImage *img = ctx.sharegroup.textures[@(ctx->_boundName[u])];
        if (!img || IOSurfaceGetPlaneCount(img->source)) continue;
        size_t w = IOSurfaceGetWidth(img->source), h = IOSurfaceGetHeight(img->source);
        if (!w || !h || w > 512 || h > 512) continue;
        uint32_t sid = IOSurfaceGetID(img->source), seed = IOSurfaceGetSeed(img->source);
        NSString *key = [NSString stringWithFormat:@"%u:%u", sid, seed];
        pthread_mutex_lock(&capture_mutex);
        if (!seen) seen = [NSMutableSet set];
        BOOL skip = seen.count >= 32 || [seen containsObject:key];
        if (!skip) [seen addObject:key];
        pthread_mutex_unlock(&capture_mutex);
        if (skip) continue;
        size_t stride = IOSurfaceGetBytesPerRow(img->source);
        void *copy = capture_vm_copy(IOSurfaceGetBaseAddress(img->source), stride * h);
        if (!copy) continue;
        capture_record(ctx, 3, ctx->_boundName[u], sid, (unsigned)w, (unsigned)h,
            (unsigned)stride, img->pixelFormat, 0x1401, 0, 0, 0, 1, 0, copy, stride * h);
        free(copy);
    }
}

static const char *const capture_uniforms[] = {"vertex_matrix", "texmat0", "texmat1",
    "texmatD", "texmatW", "coord_arg", "function_arg", "color_matrix[0]",
    "color_matrix[1]", "color_matrix[2]", "color_matrix[3]", "texture0"};

static void t290_capture_after_draw(T290Context *ctx)
{
    if (!capture_render || !gl.ReadPixels || !gl.PixelStorei || !gl.BindBuffer) return;
    unsigned n = ctx->_drawCount;
    if (n > 64 && (n > 1024 || (n & (n - 1)))) return;
    GLint viewport[4] = {0};
    gl.GetIntegerv(0x0ba2, viewport);
    GLint w = viewport[2], h = viewport[3];
    if (viewport[0] || viewport[1] || w <= 0 || h <= 0 || w > 512 || h > 512) return;
    GLenum pending = gl.GetError();
    if (pending >= 0x500 && pending < 0x520) ctx->_errors |= 1u << (pending - 0x500);
    GLint pack[5] = {0}, readFbo = 0;
    gl.GetIntegerv(0x0d05, &pack[0]);
    if (ctx.API >= 3) {
        gl.GetIntegerv(0x0d02, &pack[1]);
        gl.GetIntegerv(0x0d03, &pack[2]);
        gl.GetIntegerv(0x0d04, &pack[3]);
        gl.GetIntegerv(0x88ed, &pack[4]);
        gl.GetIntegerv(0x8caa, &readFbo);
    }
    uint8_t *pixels = malloc((size_t)w * h * 4);
    if (!pixels) return;
    gl.PixelStorei(0x0d05, 1);
    if (ctx.API >= 3) {
        gl.PixelStorei(0x0d02, 0); gl.PixelStorei(0x0d03, 0); gl.PixelStorei(0x0d04, 0);
        gl.BindBuffer(0x88eb, 0);
        gl.BindFramebuffer(0x8ca8, ctx->_drawFbo);
    }
    gl.ReadPixels(0, 0, w, h, 0x1908, 0x1401, pixels);
    GLenum error = gl.GetError();
    gl.PixelStorei(0x0d05, pack[0]);
    if (ctx.API >= 3) {
        gl.PixelStorei(0x0d02, pack[1]); gl.PixelStorei(0x0d03, pack[2]); gl.PixelStorei(0x0d04, pack[3]);
        gl.BindBuffer(0x88eb, pack[4]);
        gl.BindFramebuffer(0x8ca8, readFbo);
    }
    capture_record(ctx, 2, 0, 0, w, h, w * 4, 0x1908, 0x1401, 0, 0, 0, 0, error,
        pixels, error ? 0 : (size_t)w * h * 4);
    free(pixels);
    struct { GLint ints[16]; GLfloat values[12][16]; } state = {0};
    const GLenum queries[] = {0x0be2,0x80c9,0x80c8,0x80cb,0x80ca,0x8009,0x883d,0x0c11};
    for (unsigned i = 0; i < 8; i++) gl.GetIntegerv(queries[i], &state.ints[i]);
    gl.GetIntegerv(0x0c10, state.ints + 8);
    memcpy(state.ints + 12, viewport, sizeof(viewport));
    GLint program = 0; unsigned mask = 0;
    gl.GetIntegerv(0x8b8d, &program);
    if (program && gl.GetUniformfv) for (unsigned i = 0; i < 12; i++) {
        GLint loc = gl.GetUniformLocation(program, capture_uniforms[i]);
        if (loc < 0) continue;
        mask |= 1u << i;
        if (i == 11 && gl.GetUniformiv) { GLint sampler = 0;
            gl.GetUniformiv(program, loc, &sampler); state.values[i][0] = sampler; }
        else gl.GetUniformfv(program, loc, state.values[i]);
    }
    GLenum diagnostic = gl.GetError();
    capture_record(ctx, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, mask, diagnostic, &state, sizeof(state));
    if (diagnostic) plog("CAPTURE diagnostic error %#x", diagnostic);
}

static void t290_capture_present(T290Context *ctx)
{
    static BOOL saved;
    if (!capture_render || __atomic_load_n(&saved, __ATOMIC_RELAXED)) return;
    T290SurfaceImage *img = ctx.sharegroup.display;
    if (!img) return;
    size_t w = IOSurfaceGetWidth(img->source), h = IOSurfaceGetHeight(img->source);
    size_t stride = IOSurfaceGetBytesPerRow(img->source);
    if (w > 2048 || h > 2048 || stride > 32768) return;
    void *copy = capture_vm_copy(IOSurfaceGetBaseAddress(img->source), stride * h);
    if (!copy) return;
    if (__atomic_exchange_n(&saved, YES, __ATOMIC_RELAXED)) { free(copy); return; }
    capture_record(ctx, 4, 0, IOSurfaceGetID(img->source), (unsigned)w, (unsigned)h,
        (unsigned)stride, img->pixelFormat, 0x1401, 0, 0, 0, 1, 0, copy, stride * h);
    free(copy);
}
