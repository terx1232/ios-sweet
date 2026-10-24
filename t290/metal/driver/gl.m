/* T290Metal infrastructure: log, the GL worker thread on Mesa, streaming
 * buffer, pixel formats, function-constant recording. */
#import "t290mtl.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdarg.h>
#include <unistd.h>

struct t290_gl gl;
struct t290_caps t290_caps;

/* ------------------------------------------------------------------ log */

typedef mach_port_t io_object_t;
extern const mach_port_t kIOMasterPortDefault;
CFMutableDictionaryRef IOServiceMatching(const char *);
io_object_t IOServiceGetMatchingService(mach_port_t, CFDictionaryRef);
kern_return_t IOServiceOpen(io_object_t, mach_port_t, uint32_t, mach_port_t *);
kern_return_t IOObjectRelease(io_object_t);
kern_return_t IOConnectCallStructMethod(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);

static int log_fd = -1;
static mach_port_t log_conn;

static void log_open(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		io_object_t s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetGPU"));
		if (s) { IOServiceOpen(s, mach_task_self(), 0, &log_conn); IOObjectRelease(s); }
		log_fd = open("/private/var/tmp/t290metal.log", O_WRONLY | O_CREAT | O_APPEND, 0666);
	});
}

void t290_log(const char *fmt, ...)
{
	log_open();
	char buf[1000];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
	va_end(ap);
	size_t n = strlen(buf);
	if (log_conn) IOConnectCallStructMethod(log_conn, 7, buf, n, NULL, NULL);
	buf[n++] = '\n';
	if (log_fd >= 0) write(log_fd, buf, n);
}

/* ------------------------------------------------------------------ crash log */

/* In processes that use the device: on a fatal signal, log the fault
 * address, registers, the selector in x1 and a frame-pointer backtrace with
 * image names, then let the default action run (crash report as before). */
static struct sigaction old_actions[32];

static void frame_log(const char *what, uintptr_t pc)
{
	Dl_info info;
	if (dladdr((void *)pc, &info) && info.dli_fname) {
		const char *img = strrchr(info.dli_fname, '/');
		t290_log("T290Metal: crash %s %#lx %s+%#lx %s+%#lx", what, (unsigned long)pc, img ? img + 1 : info.dli_fname,
		    (unsigned long)(pc - (uintptr_t)info.dli_fbase), info.dli_sname ?: "?",
		    (unsigned long)(pc - (uintptr_t)info.dli_saddr));
	} else {
		t290_log("T290Metal: crash %s %#lx (no image)", what, (unsigned long)pc);
	}
}

static void crash_handler(int sig, siginfo_t *si, void *ctx)
{
	ucontext_t *uc = ctx;
	_STRUCT_ARM_THREAD_STATE64 *ss = &uc->uc_mcontext->__ss;
	uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(*ss);
	uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(*ss);
	uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(*ss);
	t290_log("T290Metal: crash in %s: signal %d addr %p x0 %#llx x1 %#llx x2 %#llx x8 %#llx", getprogname(), sig,
	    si->si_addr, ss->__x[0], ss->__x[1], ss->__x[2], ss->__x[8]);
	frame_log("pc", pc);
	frame_log("lr", lr);
	Dl_info info;
	if (ss->__x[1] && dladdr((void *)(uintptr_t)ss->__x[1], &info))
		t290_log("T290Metal: crash x1 as selector: %.80s", (const char *)(uintptr_t)ss->__x[1]);
	for (int i = 0; i < 24 && fp && !(fp & 7); i++) {
		uintptr_t *f = (uintptr_t *)fp;
		if (!f[1]) break;
		frame_log("bt", f[1]);
		if (f[0] <= fp) break;
		fp = f[0];
	}
	sigaction(sig, &old_actions[sig], NULL);
}

void t290_install_crash_log(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE};
		for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
			struct sigaction sa;
			memset(&sa, 0, sizeof(sa));
			sa.sa_sigaction = crash_handler;
			sa.sa_flags = SA_SIGINFO | SA_RESETHAND;
			sigaction(sigs[i], &sa, &old_actions[sigs[i]]);
		}
	});
}

/* which processes load the bundle at all (Metal device discovery) */
__attribute__((constructor)) static void t290_loaded(void)
{
	t290_log("T290Metal: bundle loaded into %s pid %d", getprogname(), getpid());
	/* Metal's plugin check: the device class must adopt its SPI protocols */
	Class c = objc_getClass("T290MetalDevice");
	const char *protos[] = {"MTLDeviceSPI", "MTLDevice", "MTLDeviceSPIInternal"};
	for (size_t i = 0; c && i < sizeof(protos) / sizeof(protos[0]); i++) {
		Protocol *p = objc_getProtocol(protos[i]);
		BOOL added = p && class_addProtocol(c, p);
		t290_log("T290Metal: protocol %s %s", protos[i], !p ? "not in runtime" : added ? "added" : "already adopted");
	}
}

NSError *t290_error(NSString *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	t290_log("T290Metal: error: %s", s.UTF8String);
	return [NSError errorWithDomain:@"T290Metal" code:1 userInfo:@{NSLocalizedDescriptionKey: s}];
}

/* ------------------------------------------------------------------ Mesa + GL thread */

static void *(*mesa_proc)(const char *);
static void *(*mesa_create)(unsigned, void *);
static GLboolean (*mesa_current)(void *, void *, GLenum, GLsizei, GLsizei);
static void *(*mesa_image)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
static void (*mesa_image_destroy)(void *);
static void *mesa_ctx;
static uint32_t mesa_dummy;

static pthread_t gl_thread;
static pthread_mutex_t gl_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gl_cond = PTHREAD_COND_INITIALIZER;
static NSMutableArray *gl_jobs;
static BOOL gl_ok, gl_ready;

BOOL t290_on_gl_thread(void) { return gl_thread && pthread_equal(pthread_self(), gl_thread); }

static void caps_init(void)
{
	const char *r = (const char *)gl.GetString(GL_RENDERER), *v = (const char *)gl.GetString(GL_VERSION);
	const char *ext = (const char *)gl.GetString(GL_EXTENSIONS);
	snprintf(t290_caps.renderer, sizeof(t290_caps.renderer), "%s", r ?: "?");
	snprintf(t290_caps.version, sizeof(t290_caps.version), "%s", v ?: "?");
	gl.GetIntegerv(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT, &t290_caps.uboAlign);
	gl.GetIntegerv(GL_TEXTURE_BUFFER_OFFSET_ALIGNMENT_EXT, &t290_caps.tboAlign);
	gl.GetIntegerv(GL_MAX_TEXTURE_BUFFER_SIZE_EXT, &t290_caps.maxTboTexels);
	gl.GetIntegerv(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &t290_caps.maxUnits);
	gl.GetIntegerv(GL_MAX_VERTEX_ATTRIBS, &t290_caps.maxVertexAttribs);
	gl.GetError();
	if (t290_caps.uboAlign <= 0) t290_caps.uboAlign = 256;
	if (t290_caps.tboAlign <= 0) t290_caps.tboAlign = 256;
	t290_caps.tbo = ext && strstr(ext, "GL_EXT_texture_buffer") && gl.TexBufferRangeEXT;
	t290_caps.drawBuffersIndexed = ext && strstr(ext, "GL_OES_draw_buffers_indexed");
	t290_caps.bgraRead = ext && strstr(ext, "GL_EXT_read_format_bgra");
	t290_log("T290Metal: %s / %s; ubo align %d, tbo %d align %d max %d texels, units %d, attribs %d",
	    t290_caps.renderer, t290_caps.version, t290_caps.uboAlign, t290_caps.tbo, t290_caps.tboAlign,
	    t290_caps.maxTboTexels, t290_caps.maxUnits, t290_caps.maxVertexAttribs);
	t290_log("T290Metal: extensions %.900s", ext ?: "");
}

static void *gl_main(void *arg)
{
	(void)arg;
	pthread_setname_np("T290Metal GL");
	BOOL ok = mesa_current(mesa_ctx, &mesa_dummy, GL_UNSIGNED_BYTE, 1, 1);
	if (ok) caps_init();
	pthread_mutex_lock(&gl_lock);
	gl_ok = ok;
	gl_ready = YES;
	pthread_cond_broadcast(&gl_cond);
	if (!ok) { pthread_mutex_unlock(&gl_lock); return NULL; }
	for (;;) {
		while (!gl_jobs.count) pthread_cond_wait(&gl_cond, &gl_lock);
		void (^job)(void) = gl_jobs.firstObject;
		[gl_jobs removeObjectAtIndex:0];
		pthread_mutex_unlock(&gl_lock);
		@autoreleasepool { job(); }
		pthread_mutex_lock(&gl_lock);
	}
	return NULL;
}

BOOL t290_gl_start(void)
{
	static dispatch_once_t once;
	static BOOL started;
	dispatch_once(&once, ^{
		void *lib = dlopen(getenv("T290_MESA_LIB") ?: "/usr/lib/libOSMesa.8.dylib", RTLD_NOW | RTLD_LOCAL);
		if (!lib) { t290_log("T290Metal: dlopen Mesa failed: %s", dlerror()); return; }
		mesa_proc = dlsym(lib, "OSMesaGetProcAddress");
		mesa_create = dlsym(lib, "OSMesaT290CreateContext");
		mesa_current = dlsym(lib, "OSMesaMakeCurrent");
		mesa_image = dlsym(lib, "OSMesaT290CreateImage");
		mesa_image_destroy = dlsym(lib, "OSMesaT290DestroyImage");
		if (!mesa_proc || !mesa_create || !mesa_current || !mesa_image || !mesa_image_destroy) {
			t290_log("T290Metal: Mesa lacks the T290 entry points");
			return;
		}
		unsigned missing = 0;
#define T290_GL_LOAD(name, type) \
		gl.name = (type)mesa_proc("gl" #name); \
		if (!gl.name) { missing++; t290_log("T290Metal: missing gl%s", #name); }
		T290_GL_FUNCS(T290_GL_LOAD)
#undef T290_GL_LOAD
		if (missing > 1 || !gl.EGLImageTargetTexture2DOES) return;     /* TexBufferRangeEXT is optional */
		mesa_ctx = mesa_create(3, NULL);
		if (!mesa_ctx) { t290_log("T290Metal: GLES 3 context failed"); return; }
		gl_jobs = [NSMutableArray new];
		pthread_attr_t attr;
		pthread_attr_init(&attr);
		pthread_attr_setstacksize(&attr, 8 << 20);        /* LLVM recursion on big shaders */
		pthread_create(&gl_thread, &attr, gl_main, NULL);
		pthread_mutex_lock(&gl_lock);
		while (!gl_ready) pthread_cond_wait(&gl_cond, &gl_lock);
		started = gl_ok;
		pthread_mutex_unlock(&gl_lock);
		t290_log("T290Metal: GL thread %s", started ? "ready" : "FAILED");
	});
	return started;
}

void t290_gl_async(void (^block)(void))
{
	pthread_mutex_lock(&gl_lock);
	[gl_jobs addObject:[block copy]];
	pthread_cond_broadcast(&gl_cond);
	pthread_mutex_unlock(&gl_lock);
}

void t290_gl_sync(void (^block)(void))
{
	if (t290_on_gl_thread()) { block(); return; }
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	t290_gl_async(^{ block(); dispatch_semaphore_signal(done); });
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

void *t290_mesa_image(uint32_t surface, uint32_t w, uint32_t h, uint32_t stride, uint32_t offset, uint32_t fourcc)
{
	return mesa_image(surface, w, h, stride, offset, fourcc);
}

void t290_mesa_image_destroy(void *image) { if (image) mesa_image_destroy(image); }

/* ------------------------------------------------------------------ streaming buffer */

#define RING_SIZE (16u << 20)
static GLuint ring;
static GLintptr ring_pos;

GLuint t290_ring_buffer(void)
{
	if (!ring) {
		gl.GenBuffers(1, &ring);
		gl.BindBuffer(GL_COPY_WRITE_BUFFER, ring);
		gl.BufferData(GL_COPY_WRITE_BUFFER, RING_SIZE, NULL, GL_STREAM_DRAW);
	}
	return ring;
}

GLintptr t290_ring_put(const void *data, size_t size, size_t align)
{
	t290_ring_buffer();
	if (!size) size = 4;
	if (size > RING_SIZE) {
		t290_log("T290Metal: upload of %zu bytes exceeds the ring", size);
		size = RING_SIZE;
	}
	GLintptr pos = (ring_pos + (GLintptr)align - 1) / (GLintptr)align * (GLintptr)align;
	gl.BindBuffer(GL_COPY_WRITE_BUFFER, ring);
	if (pos + (GLintptr)size > RING_SIZE) {
		/* orphan: draws already submitted keep the old storage */
		gl.BufferData(GL_COPY_WRITE_BUFFER, RING_SIZE, NULL, GL_STREAM_DRAW);
		pos = 0;
	}
	if (data) gl.BufferSubData(GL_COPY_WRITE_BUFFER, pos, (GLsizeiptr)size, data);
	ring_pos = pos + (GLintptr)size;
	return pos;
}

/* ------------------------------------------------------------------ formats */

#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

static const struct t290_format formats[] = {
	{MTLPixelFormatA8Unorm, GL_R8, GL_RED, GL_UNSIGNED_BYTE, 1, 1, T290_F_UNORM8, 0, 1, 0, 0, FOURCC('A', '0', '0', '8')},
	{MTLPixelFormatR8Unorm, GL_R8, GL_RED, GL_UNSIGNED_BYTE, 1, 1, T290_F_UNORM8, 0, 0, 0, 0, FOURCC('R', '0', '0', '8')},
	{MTLPixelFormatR8Uint, GL_R8UI, GL_RED_INTEGER, GL_UNSIGNED_BYTE, 1, 1, T290_F_UINT, 0, 0, 0, 0, 0},
	{MTLPixelFormatR16Float, GL_R16F, GL_RED, GL_HALF_FLOAT, 2, 1, T290_F_HALF, 0, 0, 0, 0, 0},
	{MTLPixelFormatRG8Unorm, GL_RG8, GL_RG, GL_UNSIGNED_BYTE, 2, 2, T290_F_UNORM8, 0, 0, 0, 0, FOURCC('R', 'G', '8', '8')},
	{MTLPixelFormatR16Uint, GL_R16UI, GL_RED_INTEGER, GL_UNSIGNED_SHORT, 2, 1, T290_F_UINT, 0, 0, 0, 0, 0},
	{MTLPixelFormatR32Uint, GL_R32UI, GL_RED_INTEGER, GL_UNSIGNED_INT, 4, 1, T290_F_UINT, 0, 0, 0, 0, 0},
	{MTLPixelFormatR32Sint, GL_R32I, GL_RED_INTEGER, GL_INT, 4, 1, T290_F_SINT, 0, 0, 0, 0, 0},
	{MTLPixelFormatR32Float, GL_R32F, GL_RED, GL_FLOAT, 4, 1, T290_F_FLOAT, 0, 0, 0, 0, 0},
	{MTLPixelFormatRG16Float, GL_RG16F, GL_RG, GL_HALF_FLOAT, 4, 2, T290_F_HALF, 0, 0, 0, 0, 0},
	{MTLPixelFormatRGBA8Unorm, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 4, 4, T290_F_UNORM8, 0, 0, 0, 0, FOURCC('R', 'G', 'B', 'A')},
	{MTLPixelFormatRGBA8Unorm_sRGB, GL_SRGB8_ALPHA8, GL_RGBA, GL_UNSIGNED_BYTE, 4, 4, T290_F_UNORM8, 0, 0, 0, 0, 0},
	{MTLPixelFormatBGRA8Unorm, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 4, 4, T290_F_UNORM8, 1, 0, 0, 0, FOURCC('B', 'G', 'R', 'A')},
	{MTLPixelFormatBGRA8Unorm_sRGB, GL_SRGB8_ALPHA8, GL_RGBA, GL_UNSIGNED_BYTE, 4, 4, T290_F_UNORM8, 1, 0, 0, 0, 0},
	{MTLPixelFormatRGB10A2Unorm, GL_RGB10_A2, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, 4, 4, T290_F_PACKED, 0, 0, 0, 0, 0},
	{MTLPixelFormatBGR10A2Unorm, GL_RGB10_A2, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, 4, 4, T290_F_PACKED, 0, 0, 0, 0, 0},
	{MTLPixelFormatRG11B10Float, GL_R11F_G11F_B10F, GL_RGB, GL_UNSIGNED_INT_10F_11F_11F_REV, 4, 3, T290_F_PACKED, 0, 0, 0, 0, 0},
	{MTLPixelFormatRG32Float, GL_RG32F, GL_RG, GL_FLOAT, 8, 2, T290_F_FLOAT, 0, 0, 0, 0, 0},
	{MTLPixelFormatRGBA16Float, GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, 8, 4, T290_F_HALF, 0, 0, 0, 0, 0},
	{MTLPixelFormatRGBA32Float, GL_RGBA32F, GL_RGBA, GL_FLOAT, 16, 4, T290_F_FLOAT, 0, 0, 0, 0, 0},
	{MTLPixelFormatDepth16Unorm, GL_DEPTH_COMPONENT16, GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, 2, 1, T290_F_DEPTH, 0, 0, 1, 0, 0},
	{MTLPixelFormatDepth32Float, GL_DEPTH_COMPONENT32F, GL_DEPTH_COMPONENT, GL_FLOAT, 4, 1, T290_F_DEPTH, 0, 0, 1, 0, 0},
	{MTLPixelFormatStencil8, GL_DEPTH24_STENCIL8, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, 1, 1, T290_F_DEPTH, 0, 0, 0, 1, 0},
	{MTLPixelFormatDepth32Float_Stencil8, GL_DEPTH32F_STENCIL8, GL_DEPTH_STENCIL, GL_FLOAT_32_UNSIGNED_INT_24_8_REV, 8, 2, T290_F_DEPTH, 0, 0, 1, 1, 0},
};

const struct t290_format *t290_format(MTLPixelFormat f)
{
	for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++)
		if (formats[i].mtl == f) return &formats[i];
	return NULL;
}

void t290_pixels_to_gl(const struct t290_format *f, const void *src, size_t srcRow, void *dst, size_t w, size_t h)
{
	size_t row = w * f->bytes;
	for (size_t y = 0; y < h; y++) {
		const uint8_t *s = (const uint8_t *)src + y * srcRow;
		uint8_t *d = (uint8_t *)dst + y * row;
		memcpy(d, s, row);
		if (f->swapRB && f->bytes == 4)
			for (size_t x = 0; x < w; x++) { uint8_t t = d[4 * x]; d[4 * x] = d[4 * x + 2]; d[4 * x + 2] = t; }
	}
}

void t290_pixels_from_gl(const struct t290_format *f, const void *src, void *dst, size_t dstRow, size_t w, size_t h)
{
	size_t row = w * f->bytes;
	for (size_t y = 0; y < h; y++) {
		const uint8_t *s = (const uint8_t *)src + y * row;
		uint8_t *d = (uint8_t *)dst + y * dstRow;
		memcpy(d, s, row);
		if (f->swapRB && f->bytes == 4)
			for (size_t x = 0; x < w; x++) { uint8_t t = d[4 * x]; d[4 * x] = d[4 * x + 2]; d[4 * x + 2] = t; }
	}
}

/* ------------------------------------------------------------------ function constants */

static char constants_key;

static NSMutableDictionary *values_of(id obj)
{
	NSMutableDictionary *d = objc_getAssociatedObject(obj, &constants_key);
	if (!d) {
		d = [NSMutableDictionary new];
		objc_setAssociatedObject(obj, &constants_key, d, OBJC_ASSOCIATION_RETAIN);
	}
	return d;
}

/* MTLDataType -> element kind, count, element size */
static BOOL data_type(MTLDataType t, int *kind, int *count, int *size)
{
	struct { MTLDataType base; int kind, size; } tab[] = {
		{MTLDataTypeFloat, 'f', 4}, {MTLDataTypeHalf, 'h', 2}, {MTLDataTypeInt, 'i', 4}, {MTLDataTypeUInt, 'u', 4},
		{MTLDataTypeShort, 'i', 2}, {MTLDataTypeUShort, 'u', 2}, {MTLDataTypeChar, 'i', 1}, {MTLDataTypeUChar, 'u', 1},
		{MTLDataTypeBool, 'b', 1},
	};
	for (size_t i = 0; i < sizeof(tab) / sizeof(tab[0]); i++)
		if (t >= tab[i].base && t <= tab[i].base + 3) {
			*kind = tab[i].kind; *count = (int)(t - tab[i].base) + 1; *size = tab[i].size;
			return YES;
		}
	if (t == MTLDataTypeLong || t == MTLDataTypeULong) { *kind = t == MTLDataTypeLong ? 'i' : 'u'; *count = 1; *size = 8; return YES; }
	return NO;
}

static NSArray *decode(const void *p, MTLDataType type, size_t *stride)
{
	int kind, count, size;
	if (!p || !data_type(type, &kind, &count, &size)) return nil;
	NSMutableArray *v = [NSMutableArray array];
	const uint8_t *b = p;
	for (int i = 0; i < count; i++, b += size) {
		double x = 0;
		switch (kind) {
		case 'f': x = *(const float *)b; break;
		case 'h': x = *(const __fp16 *)b; break;
		case 'b': x = *b != 0; break;
		case 'i': x = size == 1 ? *(const int8_t *)b : size == 2 ? *(const int16_t *)b : size == 4 ? *(const int32_t *)b : (double)*(const int64_t *)b; break;
		case 'u': x = size == 1 ? *b : size == 2 ? *(const uint16_t *)b : size == 4 ? *(const uint32_t *)b : (double)*(const uint64_t *)b; break;
		}
		[v addObject:@(x)];
	}
	if (stride) *stride = (size_t)size * (count == 3 ? 4 : count);
	return v;
}

static IMP orig_at_index, orig_with_name, orig_range, orig_reset;

static void hook_at_index(id self, SEL _cmd, const void *value, MTLDataType type, NSUInteger index)
{
	((void (*)(id, SEL, const void *, MTLDataType, NSUInteger))orig_at_index)(self, _cmd, value, type, index);
	NSArray *v = decode(value, type, NULL);
	if (v) values_of(self)[@(index)] = v;
}

static void hook_with_name(id self, SEL _cmd, const void *value, MTLDataType type, NSString *name)
{
	((void (*)(id, SEL, const void *, MTLDataType, NSString *))orig_with_name)(self, _cmd, value, type, name);
	NSArray *v = decode(value, type, NULL);
	if (v && name) values_of(self)[[name copy]] = v;
}

static void hook_range(id self, SEL _cmd, const void *values, MTLDataType type, NSRange range)
{
	((void (*)(id, SEL, const void *, MTLDataType, NSRange))orig_range)(self, _cmd, values, type, range);
	const uint8_t *p = values;
	for (NSUInteger i = 0; i < range.length; i++) {
		size_t stride = 0;
		NSArray *v = decode(p, type, &stride);
		if (!v) break;
		values_of(self)[@(range.location + i)] = v;
		p += stride;
	}
}

static void hook_reset(id self, SEL _cmd)
{
	((void (*)(id, SEL))orig_reset)(self, _cmd);
	[values_of(self) removeAllObjects];
}

static IMP swap(Class c, SEL sel, IMP imp)
{
	Method m = class_getInstanceMethod(c, sel);
	if (!m) { t290_log("T290Metal: MTLFunctionConstantValues lacks %s", sel_getName(sel)); return NULL; }
	return method_setImplementation(m, imp);
}

void t290_hook_constant_values(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		Class c = [MTLFunctionConstantValues class];
		/* the class may be a cluster: patch what +new really returns */
		Class real = [[MTLFunctionConstantValues new] class];
		if (real && real != c) t290_log("T290Metal: constant values class %s", class_getName(real));
		if (real) c = real;
		orig_at_index = swap(c, @selector(setConstantValue:type:atIndex:), (IMP)hook_at_index);
		orig_with_name = swap(c, @selector(setConstantValue:type:withName:), (IMP)hook_with_name);
		orig_range = swap(c, @selector(setConstantValues:type:withRange:), (IMP)hook_range);
		orig_reset = swap(c, @selector(reset), (IMP)hook_reset);
	});
}

NSDictionary *t290_constant_values(MTLFunctionConstantValues *values)
{
	if (!values) return @{};
	return [objc_getAssociatedObject(values, &constants_key) copy] ?: @{};
}
