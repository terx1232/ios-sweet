/* T290Metal command buffers and encoders. Encoders snapshot their state per
 * draw (copy on write) and record blocks; the command buffer runs them on the
 * GL thread, waits for the GPU with a fence, then writes back CPU-copied
 * IOSurfaces and calls the completion handlers. */
#import "t290mtl.h"
#include <IOSurface/IOSurfaceRef.h>
#include <stdatomic.h>

/* ------------------------------------------------------------------ state */

enum { VS = T290_STAGE_VERTEX, FS = T290_STAGE_FRAGMENT, CS = T290_STAGE_COMPUTE, NSTAGES = 3 };

@interface T290State : NSObject <NSCopying> {
@public
	BOOL frozen;
	T290RenderPipeline *pipe;
	T290ComputePipeline *cpipe;
	T290DepthStencil *ds;
	__strong id buf[NSTAGES][T290_MAX_BUFFERS];      /* T290Buffer or NSData */
	NSUInteger off[NSTAGES][T290_MAX_BUFFERS];
	__strong T290Texture *tex[NSTAGES][T290_MAX_TEXTURES];
	__strong T290Sampler *smp[NSTAGES][T290_MAX_SAMPLERS];
	MTLViewport vp;
	BOOL vpSet, scSet;
	MTLScissorRect sc;
	MTLCullMode cull;
	MTLWinding winding;
	MTLTriangleFillMode fill;
	float bias, slope, clamp;
	float blend[4];
	uint32_t refFront, refBack;
}
@end

@implementation T290State
- (id)copyWithZone:(NSZone *)z
{
	(void)z;
	T290State *s = [T290State new];
	s->pipe = pipe; s->cpipe = cpipe; s->ds = ds;
	for (int st = 0; st < NSTAGES; st++) {
		for (int i = 0; i < T290_MAX_BUFFERS; i++) { s->buf[st][i] = buf[st][i]; s->off[st][i] = off[st][i]; }
		for (int i = 0; i < T290_MAX_TEXTURES; i++) s->tex[st][i] = tex[st][i];
		for (int i = 0; i < T290_MAX_SAMPLERS; i++) s->smp[st][i] = smp[st][i];
	}
	s->vp = vp; s->vpSet = vpSet; s->scSet = scSet; s->sc = sc;
	s->cull = cull; s->winding = winding; s->fill = fill;
	s->bias = bias; s->slope = slope; s->clamp = clamp;
	memcpy(s->blend, blend, sizeof(blend));
	s->refFront = refFront; s->refBack = refBack;
	return s;
}
@end

static const uint8_t *bytes_of(id b, NSUInteger off, size_t *len)
{
	if ([b isKindOfClass:[T290Buffer class]]) {
		T290Buffer *x = b;
		*len = off < x->_length ? x->_length - off : 0;
		return (const uint8_t *)x->_bytes + off;
	}
	if ([b isKindOfClass:[NSData class]]) {
		NSData *d = b;
		*len = off < d.length ? d.length - off : 0;
		return (const uint8_t *)d.bytes + off;
	}
	*len = 0;
	return NULL;
}

/* ------------------------------------------------------------------ GL-side execution */

/* the render pass being executed (GL thread only) */
static struct {
	GLuint fbo;
	GLsizei width, height;
	T290Texture *color[8];
	NSUInteger colorLevel[8], colorSlice[8];
	unsigned ncolor;
} pass;

static void pass_reset(void)
{
	pass.fbo = 0;
	pass.width = pass.height = 0;
	pass.ncolor = 0;
	for (int i = 0; i < 8; i++) { pass.color[i] = nil; pass.colorLevel[i] = pass.colorSlice[i] = 0; }
}

static GLuint tbo_tex[64];
static GLuint fb_copy[8], fb_copy_fbo[8];
static GLsizei fb_copy_w[8], fb_copy_h[8];
static GLenum fb_copy_fmt[8];
static GLuint vao;
static uint32_t attribs_enabled;

static void bind_buffers(T290State *s, T290Program *prog, uint8_t only)
{
	static const uint8_t zeros[16384];
	for (unsigned k = 0; k < prog->_nbind; k++) {
		struct t290_binding *b = &prog->_bind[k];
		if (only != 255 && b->stage != only) continue;
		size_t len = 0;
		const uint8_t *p = bytes_of(s->buf[b->stage][b->index], s->off[b->stage][b->index], &len);
		if (!p) {
			static unsigned n;
			if (n++ < 16) t290_log("T290Metal: stage %u buffer %u not bound", b->stage, b->index);
			p = zeros; len = 0;
		}
		if (b->kind == T290_BIND_UBO) {
			size_t size = (size_t)b->bytes;
			GLintptr pos;
			if (len >= size) pos = t290_ring_put(p, size, (size_t)t290_caps.uboAlign);
			else {
				uint8_t *tmp = calloc(1, size);
				memcpy(tmp, p, len);
				pos = t290_ring_put(tmp, size, (size_t)t290_caps.uboAlign);
				free(tmp);
			}
			gl.BindBufferRange(GL_UNIFORM_BUFFER, b->slot, t290_ring_buffer(), pos, (GLsizeiptr)size);
		} else if (b->kind == T290_BIND_TBO) {
			size_t size = len & ~(size_t)3;
			size_t max = (size_t)t290_caps.maxTboTexels * 4;
			if (max && size > max) size = max;
			if (!size) { p = zeros; size = 16; }
			GLintptr pos = t290_ring_put(p, size, (size_t)t290_caps.tboAlign);
			if (b->slot >= 64) continue;
			if (!tbo_tex[b->slot]) gl.GenTextures(1, &tbo_tex[b->slot]);
			gl.ActiveTexture(GL_TEXTURE0 + b->slot);
			gl.BindTexture(GL_TEXTURE_BUFFER_EXT, tbo_tex[b->slot]);
			if (gl.TexBufferRangeEXT)
				gl.TexBufferRangeEXT(GL_TEXTURE_BUFFER_EXT, GL_R32UI, t290_ring_buffer(), pos, (GLsizeiptr)size);
		} else {
			size_t size = len ? len : 16;
			GLintptr pos = t290_ring_put(len ? p : zeros, size, 256);
			gl.BindBufferRange(GL_SHADER_STORAGE_BUFFER, b->slot, t290_ring_buffer(), pos, (GLsizeiptr)size);
		}
	}
}

static void bind_textures(T290State *s, T290Program *prog)
{
	for (unsigned k = 0; k < prog->_npairs; k++) {
		struct t290_pair *x = &prog->_pairs[k];
		T290Texture *t = s->tex[x->stage][x->texture];
		gl.ActiveTexture(GL_TEXTURE0 + x->unit);
		if (!t) {
			static unsigned n;
			if (n++ < 16) t290_log("T290Metal: stage %u texture %u not bound", x->stage, x->texture);
			gl.BindTexture(x->is3D ? GL_TEXTURE_3D : GL_TEXTURE_2D, 0);
			continue;
		}
		[t prepare];
		gl.BindTexture(t->_target, t->_tex);
		GLuint smp = 0;
		if (x->sampler == INT16_MAX) smp = 0;
		else if (x->sampler < 0) smp = prog->_constSamplers[-1 - x->sampler];
		else if (x->sampler < T290_MAX_SAMPLERS && s->smp[x->stage][x->sampler]) smp = s->smp[x->stage][x->sampler]->_sampler;
		gl.BindSampler(x->unit, smp);
	}
}

/* programmable blending: the shader reads a copy of the attachment */
static void bind_fb_inputs(T290Program *prog)
{
	for (unsigned k = 0; k < prog->_nfb; k++) {
		int rt = prog->_fbInput[k];
		T290Texture *a = rt < 8 ? pass.color[rt] : nil;
		GLuint unit = prog->_fbUnit[k];
		if (!a) continue;
		if (!fb_copy[k] || fb_copy_w[k] != pass.width || fb_copy_h[k] != pass.height || fb_copy_fmt[k] != a->_fmt->internal) {
			if (fb_copy[k]) gl.DeleteTextures(1, &fb_copy[k]);
			gl.GenTextures(1, &fb_copy[k]);
			gl.BindTexture(GL_TEXTURE_2D, fb_copy[k]);
			gl.TexStorage2D(GL_TEXTURE_2D, 1, a->_fmt->internal, pass.width, pass.height);
			if (!fb_copy_fbo[k]) gl.GenFramebuffers(1, &fb_copy_fbo[k]);
			gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, fb_copy_fbo[k]);
			gl.FramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fb_copy[k], 0);
			fb_copy_w[k] = pass.width; fb_copy_h[k] = pass.height; fb_copy_fmt[k] = a->_fmt->internal;
		}
		gl.BindFramebuffer(GL_READ_FRAMEBUFFER, pass.fbo);
		gl.ReadBuffer(GL_COLOR_ATTACHMENT0 + (GLenum)rt);
		gl.BindFramebuffer(GL_DRAW_FRAMEBUFFER, fb_copy_fbo[k]);
		gl.Disable(GL_SCISSOR_TEST);
		gl.BlitFramebuffer(0, 0, pass.width, pass.height, 0, 0, pass.width, pass.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
		gl.BindFramebuffer(GL_FRAMEBUFFER, pass.fbo);
		gl.ActiveTexture(GL_TEXTURE0 + unit);
		gl.BindTexture(GL_TEXTURE_2D, fb_copy[k]);
		gl.BindSampler(unit, 0);
		gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	}
}

struct draw {
	MTLPrimitiveType prim;
	NSUInteger start, count, instances, baseInstance;
	NSInteger baseVertex;
	BOOL indexed;
	MTLIndexType indexType;
};

static GLenum gl_prim(MTLPrimitiveType p)
{
	switch (p) {
	case MTLPrimitiveTypePoint: return GL_POINTS;
	case MTLPrimitiveTypeLine: return GL_LINES;
	case MTLPrimitiveTypeLineStrip: return GL_LINE_STRIP;
	case MTLPrimitiveTypeTriangleStrip: return GL_TRIANGLE_STRIP;
	default: return GL_TRIANGLES;
	}
}

static void apply_raster(T290State *s, T290RenderPipeline *p)
{
	if (s->vpSet) {
		gl.Viewport((GLint)s->vp.originX, (GLint)s->vp.originY, (GLsizei)s->vp.width, (GLsizei)s->vp.height);
		gl.DepthRangef((float)s->vp.znear, (float)s->vp.zfar);
	} else {
		gl.Viewport(0, 0, pass.width, pass.height);
		gl.DepthRangef(0, 1);
	}
	gl.Enable(GL_SCISSOR_TEST);
	if (s->scSet) gl.Scissor((GLint)s->sc.x, (GLint)s->sc.y, (GLsizei)s->sc.width, (GLsizei)s->sc.height);
	else gl.Scissor(0, 0, pass.width, pass.height);
	if (s->cull == MTLCullModeNone) gl.Disable(GL_CULL_FACE);
	else { gl.Enable(GL_CULL_FACE); gl.CullFace(s->cull == MTLCullModeFront ? GL_FRONT : GL_BACK); }
	gl.FrontFace(s->winding == MTLWindingClockwise ? GL_CCW : GL_CW);     /* y is flipped */
	if (s->bias != 0 || s->slope != 0) { gl.Enable(GL_POLYGON_OFFSET_FILL); gl.PolygonOffset(s->slope, s->bias); }
	else gl.Disable(GL_POLYGON_OFFSET_FILL);
	T290DepthStencil *ds = s->ds;
	if (ds && ds->_depthTest) { gl.Enable(GL_DEPTH_TEST); gl.DepthFunc(ds->_depthFunc); }
	else gl.Disable(GL_DEPTH_TEST);
	gl.DepthMask(ds && ds->_depthWrite);
	if (ds && ds->_stencil) {
		gl.Enable(GL_STENCIL_TEST);
		GLenum faces[2] = {GL_FRONT, GL_BACK};
		uint32_t refs[2] = {s->refFront, s->refBack};
		for (int i = 0; i < 2; i++) {
			gl.StencilFuncSeparate(faces[i], ds->_face[i].func, (GLint)refs[i], ds->_face[i].read);
			gl.StencilOpSeparate(faces[i], ds->_face[i].fail, ds->_face[i].zfail, ds->_face[i].pass);
			gl.StencilMaskSeparate(faces[i], ds->_face[i].write);
		}
	} else gl.Disable(GL_STENCIL_TEST);
	if (p->_ncolor && p->_color[0].blend) {
		gl.Enable(GL_BLEND);
		gl.BlendEquationSeparate(p->_color[0].rgbOp, p->_color[0].alphaOp);
		gl.BlendFuncSeparate(p->_color[0].srcRGB, p->_color[0].dstRGB, p->_color[0].srcA, p->_color[0].dstA);
		gl.BlendColor(s->blend[0], s->blend[1], s->blend[2], s->blend[3]);
	} else gl.Disable(GL_BLEND);
	if (p->_ncolor) gl.ColorMask(p->_color[0].mask[0], p->_color[0].mask[1], p->_color[0].mask[2], p->_color[0].mask[3]);
	if (p->_alphaToCoverage) gl.Enable(GL_SAMPLE_ALPHA_TO_COVERAGE); else gl.Disable(GL_SAMPLE_ALPHA_TO_COVERAGE);
	if (!p->_rasterEnabled) gl.Enable(GL_RASTERIZER_DISCARD); else gl.Disable(GL_RASTERIZER_DISCARD);
}

static void exec_draw(T290State *s, struct draw d, id indexBuf, NSUInteger indexOff)
{
	T290RenderPipeline *p = s->pipe;
	if (!p || !pass.fbo) return;
	T290Program *prog = p->_prog;
	if (!vao) gl.GenVertexArrays(1, &vao);
	gl.BindVertexArray(vao);
	gl.UseProgram(prog->_program);
	bind_buffers(s, prog, 255);
	bind_textures(s, prog);
	bind_fb_inputs(prog);
	if (prog->_rtHeight >= 0) gl.Uniform1f(prog->_rtHeight, (float)pass.height);
	apply_raster(s, p);
	/* indices */
	GLenum itype = d.indexType == MTLIndexTypeUInt16 ? GL_UNSIGNED_SHORT : GL_UNSIGNED_INT;
	size_t isize = d.indexType == MTLIndexTypeUInt16 ? 2 : 4;
	GLintptr ipos = 0;
	NSUInteger maxVertex = d.start + d.count ? d.start + d.count - 1 : 0;
	if (d.indexed) {
		size_t len = 0;
		const uint8_t *ib = bytes_of(indexBuf, indexOff, &len);
		if (!ib || len < d.count * isize) { t290_log("T290Metal: index buffer too short"); return; }
		maxVertex = 0;
		uint32_t restart = isize == 2 ? 0xffff : 0xffffffff;
		for (NSUInteger i = 0; i < d.count; i++) {
			uint32_t v = isize == 2 ? ((const uint16_t *)ib)[i] : ((const uint32_t *)ib)[i];
			if (v != restart && v > maxVertex) maxVertex = v;
		}
		ipos = t290_ring_put(ib, d.count * isize, 4);
		gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, t290_ring_buffer());
		gl.Enable(GL_PRIMITIVE_RESTART_FIXED_INDEX);
		if (d.baseVertex > 0) maxVertex += (NSUInteger)d.baseVertex;
	}
	/* vertex attributes: upload each vertex buffer once */
	GLintptr vpos[T290_MAX_BUFFERS];
	uint32_t uploaded = 0, used = 0;
	gl.BindBuffer(GL_ARRAY_BUFFER, t290_ring_buffer());
	for (unsigned k = 0; k < p->_nattribs; k++) {
		struct t290_attrib *a = &p->_attribs[k];
		unsigned bi = a->buffer;
		if (bi >= T290_MAX_BUFFERS) continue;
		NSUInteger stride = p->_layouts[bi].stride;
		MTLVertexStepFunction step = p->_layouts[bi].step;
		NSUInteger rate = p->_layouts[bi].rate ?: 1;
		if (!(uploaded & (1u << bi))) {
			size_t len = 0;
			const uint8_t *vb = bytes_of(s->buf[VS][bi], s->off[VS][bi], &len);
			size_t need = step == MTLVertexStepFunctionPerInstance ? ((d.baseInstance + (d.instances ? d.instances - 1 : 0)) / rate + 1) * stride :
			    step == MTLVertexStepFunctionConstant ? (stride ?: 16) : (maxVertex + 1) * stride + 64;
			if (need > len) need = len;
			if (!vb || !need) { t290_log("T290Metal: vertex buffer %u not bound", bi); continue; }
			vpos[bi] = t290_ring_put(vb, need, 16);
			uploaded |= 1u << bi;
		}
		GLintptr ptr = vpos[bi] + a->offset;
		if (step == MTLVertexStepFunctionPerVertex && d.indexed && d.baseVertex) ptr += d.baseVertex * (NSInteger)stride;
		if (step == MTLVertexStepFunctionPerInstance) ptr += (GLintptr)(d.baseInstance / rate * stride);
		GLsizei gstride = (GLsizei)(step == MTLVertexStepFunctionConstant ? 0 : stride);
		if (a->integer) gl.VertexAttribIPointer(a->location, a->size, a->type, gstride, (const void *)ptr);
		else gl.VertexAttribPointer(a->location, a->size, a->type, a->normalized, gstride, (const void *)ptr);
		gl.VertexAttribDivisor(a->location, step == MTLVertexStepFunctionPerInstance ? (GLuint)rate :
		    step == MTLVertexStepFunctionConstant ? 0x7fffffff : 0);
		used |= 1u << a->location;
	}
	for (unsigned l = 0; l < 16; l++) {
		if ((used & (1u << l)) && !(attribs_enabled & (1u << l))) gl.EnableVertexAttribArray(l);
		if (!(used & (1u << l)) && (attribs_enabled & (1u << l))) gl.DisableVertexAttribArray(l);
	}
	attribs_enabled = used;
	GLsizei inst = (GLsizei)(d.instances ?: 1);
	if (d.indexed) gl.DrawElementsInstanced(gl_prim(d.prim), (GLsizei)d.count, itype, (const void *)ipos, inst);
	else gl.DrawArraysInstanced(gl_prim(d.prim), (GLint)d.start, (GLsizei)d.count, inst);
	GLenum err = gl.GetError();
	if (err) {
		static unsigned n;
		if (n++ < 32) t290_log("T290Metal: draw error %#x (pipeline %s)", err, p.label.UTF8String ?: "?");
	}
}

/* ------------------------------------------------------------------ command buffer */

@implementation T290CommandBuffer {
	T290CommandQueue *_queue;
	_Atomic MTLCommandBufferStatus _status;
	NSMutableArray *_scheduled, *_completed, *_signals, *_drawables;
	dispatch_semaphore_t _done;
	CFTimeInterval _start, _end;
	NSError *_error;
}
- (instancetype)initWithQueue:(T290CommandQueue *)queue
{
	if (!(self = [super initWithDevice:(T290Device *)queue.device])) return nil;
	_queue = queue;
	_commands = [NSMutableArray array];
	_written = [NSMutableSet set];
	_scheduled = [NSMutableArray array];
	_completed = [NSMutableArray array];
	_signals = [NSMutableArray array];
	_drawables = [NSMutableArray array];
	_done = dispatch_semaphore_create(0);
	atomic_store(&_status, MTLCommandBufferStatusNotEnqueued);
	return self;
}
- (void)record:(void (^)(void))command { [_commands addObject:[command copy]]; }
- (id<MTLCommandQueue>)commandQueue { return _queue; }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }
- (MTLCommandBufferStatus)status { return atomic_load(&_status); }
- (NSError *)error { return _error; }
- (CFTimeInterval)kernelStartTime { return _start; }
- (CFTimeInterval)kernelEndTime { return _end; }
- (CFTimeInterval)GPUStartTime { return _start; }
- (CFTimeInterval)GPUEndTime { return _end; }
- (id<MTLLogContainer>)logs { return nil; }
- (void)pushDebugGroup:(NSString *)s { (void)s; }
- (void)popDebugGroup {}

- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{
	return [[T290RenderEncoder alloc] initWithCommandBuffer:self pass:d];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder { return [[T290BlitEncoder alloc] initWithCommandBuffer:self]; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)d { (void)d; return [self blitCommandEncoder]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoder { return [[T290ComputeEncoder alloc] initWithCommandBuffer:self]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)t { (void)t; return [self computeCommandEncoder]; }
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)d { (void)d; return [self computeCommandEncoder]; }
- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d
{
	(void)d;
	t290_log("T290Metal: parallel render encoders unsupported");
	return nil;
}

- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value
{
	[_signals addObject:@[event, @(value)]];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value
{
	T290Event *e = (T290Event *)event;
	[self record:^{
		CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
		while (e.signaledValue < value) {
			if (CFAbsoluteTimeGetCurrent() - t0 > 1.0) {
				t290_log("T290Metal: wait for event value %llu timed out (at %llu)", value, e.signaledValue);
				break;
			}
			usleep(200);
		}
	}];
}
- (void)presentDrawable:(id<MTLDrawable>)d { [_drawables addObject:d]; }
- (void)presentDrawable:(id<MTLDrawable>)d atTime:(CFTimeInterval)t { (void)t; [_drawables addObject:d]; }
- (void)presentDrawable:(id<MTLDrawable>)d afterMinimumDuration:(CFTimeInterval)t { (void)t; [_drawables addObject:d]; }
- (void)addScheduledHandler:(MTLCommandBufferHandler)block { @synchronized(self) { [_scheduled addObject:[block copy]]; } }
- (void)addCompletedHandler:(MTLCommandBufferHandler)block { @synchronized(self) { [_completed addObject:[block copy]]; } }
- (void)enqueue { atomic_store(&_status, MTLCommandBufferStatusEnqueued); }

- (void)commit
{
	atomic_store(&_status, MTLCommandBufferStatusCommitted);
	NSArray *commands = [_commands copy];
	[_commands removeAllObjects];
	t290_gl_async(^{
		self->_start = CFAbsoluteTimeGetCurrent();
		atomic_store(&self->_status, MTLCommandBufferStatusScheduled);
		NSArray *scheduled;
		@synchronized(self) { scheduled = [self->_scheduled copy]; }
		for (MTLCommandBufferHandler h in scheduled) h(self);
		for (void (^c)(void) in commands) c();
		GLsync fence = gl.FenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
		gl.Flush();
		if (gl.ClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 2000000000ull) == GL_TIMEOUT_EXPIRED)
			t290_log("T290Metal: GPU fence timed out");
		gl.DeleteSync(fence);
		for (T290Texture *t in self->_written) [t writeBack];
		self->_end = CFAbsoluteTimeGetCurrent();
		atomic_store(&self->_status, MTLCommandBufferStatusCompleted);
		for (NSArray *s in self->_signals) [(T290Event *)s[0] setSignaledValue:[s[1] unsignedLongLongValue]];
		NSArray *completed, *drawables = [self->_drawables copy];
		@synchronized(self) { completed = [self->_completed copy]; }
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
			for (id<MTLDrawable> d in drawables) [d present];
			for (MTLCommandBufferHandler h in completed) h(self);
			dispatch_semaphore_signal(self->_done);
		});
	});
}
- (void)waitUntilScheduled
{
	while (atomic_load(&_status) < MTLCommandBufferStatusScheduled) usleep(100);
}
- (void)waitUntilCompleted
{
	if (atomic_load(&_status) < MTLCommandBufferStatusCommitted) return;
	dispatch_semaphore_wait(_done, DISPATCH_TIME_FOREVER);
	dispatch_semaphore_signal(_done);       /* later waiters */
}
@end

/* ------------------------------------------------------------------ render encoder */

static void begin_pass(MTLRenderPassDescriptor *d, T290CommandBuffer *cb, NSArray *colors, NSArray *loads,
                       T290Texture *depth, T290Texture *stencil)
{
	pass_reset();
	gl.GenFramebuffers(1, &pass.fbo);
	gl.BindFramebuffer(GL_FRAMEBUFFER, pass.fbo);
	GLenum bufs[8];
	GLsizei w = (GLsizei)d.renderTargetWidth, h = (GLsizei)d.renderTargetHeight;
	for (unsigned i = 0; i < 8; i++) {
		MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
		T290Texture *t = (T290Texture *)c.texture;
		bufs[i] = GL_NONE;
		if (![t isKindOfClass:[T290Texture class]]) continue;
		T290Texture *root = t->_parent ?: t;
		[root prepare];
		NSUInteger slice = t->_type == MTLTextureType3D ? c.depthPlane : c.slice;
		if (root->_target == GL_TEXTURE_2D_ARRAY || root->_target == GL_TEXTURE_3D)
			gl.FramebufferTextureLayer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i, root->_tex, (GLint)c.level, (GLint)slice);
		else
			gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + i,
			    root->_target == GL_TEXTURE_CUBE_MAP ? GL_TEXTURE_CUBE_MAP_POSITIVE_X + (GLenum)slice : GL_TEXTURE_2D, root->_tex, (GLint)c.level);
		bufs[i] = GL_COLOR_ATTACHMENT0 + i;
		pass.color[i] = root;
		pass.colorLevel[i] = c.level;
		pass.colorSlice[i] = slice;
		pass.ncolor = i + 1;
		if (!w) { w = (GLsizei)MAX(root->_width >> c.level, 1u); h = (GLsizei)MAX(root->_height >> c.level, 1u); }
		[root rendered];
		if (root->_shadow) [cb->_written addObject:root];
	}
	T290Texture *ds[2] = {depth, stencil};
	for (int k = 0; k < 2; k++) {
		T290Texture *t = ds[k];
		if (!t || (k == 1 && t == depth)) continue;
		GLenum att = t->_fmt->depth && t->_fmt->stencil ? GL_DEPTH_STENCIL_ATTACHMENT : k ? GL_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT;
		if (t->_fmt->stencil && !t->_fmt->depth) att = GL_DEPTH_STENCIL_ATTACHMENT;       /* Stencil8 is stored as D24S8 */
		gl.FramebufferTexture2D(GL_FRAMEBUFFER, att, GL_TEXTURE_2D, t->_tex, 0);
		if (!w) { w = (GLsizei)t->_width; h = (GLsizei)t->_height; }
	}
	pass.width = w ?: 1;
	pass.height = h ?: 1;
	gl.DrawBuffers((GLsizei)MAX(pass.ncolor, 1u), bufs);
	GLenum st = gl.CheckFramebufferStatus(GL_FRAMEBUFFER);
	if (st != GL_FRAMEBUFFER_COMPLETE) t290_log("T290Metal: render pass framebuffer incomplete %#x", st);
	/* clears */
	gl.Disable(GL_SCISSOR_TEST);
	gl.Disable(GL_RASTERIZER_DISCARD);
	gl.ColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	for (unsigned i = 0; i < pass.ncolor; i++) {
		if (!pass.color[i] || [loads[i] intValue] != MTLLoadActionClear) continue;
		MTLClearColor cc = d.colorAttachments[i].clearColor;
		if (pass.color[i]->_fmt->kind == T290_F_UINT) {
			GLuint v[4] = {(GLuint)cc.red, (GLuint)cc.green, (GLuint)cc.blue, (GLuint)cc.alpha};
			gl.ClearBufferuiv(GL_COLOR, (GLint)i, v);
		} else if (pass.color[i]->_fmt->kind == T290_F_SINT) {
			GLint v[4] = {(GLint)cc.red, (GLint)cc.green, (GLint)cc.blue, (GLint)cc.alpha};
			gl.ClearBufferiv(GL_COLOR, (GLint)i, v);
		} else {
			GLfloat v[4] = {(float)cc.red, (float)cc.green, (float)cc.blue, (float)cc.alpha};
			if (pass.color[i]->_fmt->alphaOnly) { v[0] = v[3]; }
			gl.ClearBufferfv(GL_COLOR, (GLint)i, v);
		}
	}
	BOOL cd = depth && d.depthAttachment.loadAction == MTLLoadActionClear;
	BOOL cs = stencil && d.stencilAttachment.loadAction == MTLLoadActionClear;
	gl.DepthMask(GL_TRUE);
	gl.StencilMaskSeparate(GL_FRONT_AND_BACK, 0xff);
	float dv = (float)d.depthAttachment.clearDepth;
	GLint sv = (GLint)d.stencilAttachment.clearStencil;
	if (cd && cs && depth == stencil) gl.ClearBufferfi(GL_DEPTH_STENCIL, 0, dv, sv);
	else {
		if (cd) gl.ClearBufferfv(GL_DEPTH, 0, &dv);
		if (cs) gl.ClearBufferiv(GL_STENCIL, 0, &sv);
	}
	(void)colors;
}

static void end_pass(MTLRenderPassDescriptor *d)
{
	for (unsigned i = 0; i < pass.ncolor; i++) {
		T290Texture *r = (T290Texture *)d.colorAttachments[i].resolveTexture;
		if (!pass.color[i] || ![r isKindOfClass:[T290Texture class]]) continue;
		gl.BindFramebuffer(GL_READ_FRAMEBUFFER, pass.fbo);
		gl.ReadBuffer(GL_COLOR_ATTACHMENT0 + i);
		t290_fbo_for(r->_parent ?: r, d.colorAttachments[i].resolveLevel, d.colorAttachments[i].resolveSlice, GL_DRAW_FRAMEBUFFER);
		gl.Disable(GL_SCISSOR_TEST);
		gl.BlitFramebuffer(0, 0, pass.width, pass.height, 0, 0, pass.width, pass.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
		[(r->_parent ?: r) rendered];
	}
	gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
	gl.DeleteFramebuffers(1, &pass.fbo);
	pass_reset();
}

@implementation T290RenderEncoder {
	T290CommandBuffer *_cb;
	T290State *_s;
	MTLRenderPassDescriptor *_pass;
}
- (instancetype)initWithCommandBuffer:(T290CommandBuffer *)cb pass:(MTLRenderPassDescriptor *)d
{
	if (!(self = [super initWithDevice:(T290Device *)cb.device])) return nil;
	_cb = cb;
	_s = [T290State new];
	_s->winding = MTLWindingClockwise;
	MTLRenderPassDescriptor *pd = [d copy];
	NSMutableArray *colors = [NSMutableArray array], *loads = [NSMutableArray array];
	for (unsigned i = 0; i < 8; i++) {
		[colors addObject:(id)pd.colorAttachments[i].texture ?: (id)[NSNull null]];
		[loads addObject:@(pd.colorAttachments[i].loadAction)];
	}
	T290Texture *depth = (T290Texture *)pd.depthAttachment.texture, *stencil = (T290Texture *)pd.stencilAttachment.texture;
	[cb record:^{ begin_pass(pd, cb, colors, loads, depth, stencil); }];
	_pass = pd;
	return self;
}
- (void)endEncoding
{
	MTLRenderPassDescriptor *pd = _pass;
	[_cb record:^{ end_pass(pd); }];
}
- (void)insertDebugSignpost:(NSString *)s { (void)s; }
- (void)pushDebugGroup:(NSString *)s { (void)s; }
- (void)popDebugGroup {}

/* copy on write: draws keep the state they saw */
- (T290State *)w
{
	if (_s->frozen) _s = [_s copy];
	return _s;
}

- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p { [self w]->pipe = (T290RenderPipeline *)p; }
- (void)setDepthStencilState:(id<MTLDepthStencilState>)d { [self w]->ds = (T290DepthStencil *)d; }
- (void)setViewport:(MTLViewport)v { T290State *s = [self w]; s->vp = v; s->vpSet = YES; }
- (void)setViewports:(const MTLViewport *)v count:(NSUInteger)n { if (n) [self setViewport:v[0]]; }
- (void)setScissorRect:(MTLScissorRect)r { T290State *s = [self w]; s->sc = r; s->scSet = YES; }
- (void)setScissorRects:(const MTLScissorRect *)r count:(NSUInteger)n { if (n) [self setScissorRect:r[0]]; }
- (void)setFrontFacingWinding:(MTLWinding)w { [self w]->winding = w; }
- (void)setCullMode:(MTLCullMode)c { [self w]->cull = c; }
- (void)setDepthClipMode:(MTLDepthClipMode)m { (void)m; }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c { T290State *x = [self w]; x->bias = b; x->slope = s; x->clamp = c; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m
{
	if (m != MTLTriangleFillModeFill) t290_log("T290Metal: line fill mode unsupported");
	[self w]->fill = m;
}
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a
{
	T290State *s = [self w];
	s->blend[0] = r; s->blend[1] = g; s->blend[2] = b; s->blend[3] = a;
}
- (void)setStencilReferenceValue:(uint32_t)v { T290State *s = [self w]; s->refFront = s->refBack = v; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { T290State *s = [self w]; s->refFront = f; s->refBack = b; }
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)m offset:(NSUInteger)o { (void)m; (void)o; }
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i { (void)a; (void)i; }
- (void)setDepthStoreAction:(MTLStoreAction)a { (void)a; }
- (void)setStencilStoreAction:(MTLStoreAction)a { (void)a; }
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)o atIndex:(NSUInteger)i { (void)o; (void)i; }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)o { (void)o; }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)o { (void)o; }

static void set_buffer(T290State *s, int st, id b, NSUInteger off, NSUInteger i)
{
	if (i >= T290_MAX_BUFFERS) return;
	s->buf[st][i] = b;
	s->off[st][i] = off;
}

- (void)setVertexBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i { set_buffer([self w], VS, [NSData dataWithBytes:b length:n], 0, i); }
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { set_buffer([self w], VS, b, o, i); }
- (void)setVertexBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { if (i < T290_MAX_BUFFERS) [self w]->off[VS][i] = o; }
- (void)setVertexBuffers:(id<MTLBuffer> const *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{
	T290State *s = [self w];
	for (NSUInteger k = 0; k < r.length; k++) set_buffer(s, VS, b[k], o[k], r.location + k);
}
- (void)setVertexTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { if (i < T290_MAX_TEXTURES) [self w]->tex[VS][i] = (T290Texture *)t; }
- (void)setVertexTextures:(id<MTLTexture> const *)t withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setVertexTexture:t[k] atIndex:r.location + k];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { if (i < T290_MAX_SAMPLERS) [self w]->smp[VS][i] = (T290Sampler *)s; }
- (void)setVertexSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i
{
	(void)a; (void)b;
	[self setVertexSamplerState:s atIndex:i];
}
- (void)setVertexSamplerStates:(id<MTLSamplerState> const *)s withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setVertexSamplerState:s[k] atIndex:r.location + k];
}
- (void)setFragmentBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i { set_buffer([self w], FS, [NSData dataWithBytes:b length:n], 0, i); }
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { set_buffer([self w], FS, b, o, i); }
- (void)setFragmentBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { if (i < T290_MAX_BUFFERS) [self w]->off[FS][i] = o; }
- (void)setFragmentBuffers:(id<MTLBuffer> const *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{
	T290State *s = [self w];
	for (NSUInteger k = 0; k < r.length; k++) set_buffer(s, FS, b[k], o[k], r.location + k);
}
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { if (i < T290_MAX_TEXTURES) [self w]->tex[FS][i] = (T290Texture *)t; }
- (void)setFragmentTextures:(id<MTLTexture> const *)t withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setFragmentTexture:t[k] atIndex:r.location + k];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { if (i < T290_MAX_SAMPLERS) [self w]->smp[FS][i] = (T290Sampler *)s; }
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i
{
	(void)a; (void)b;
	[self setFragmentSamplerState:s atIndex:i];
}
- (void)setFragmentSamplerStates:(id<MTLSamplerState> const *)s withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setFragmentSamplerState:s[k] atIndex:r.location + k];
}

- (void)record:(struct draw)d index:(id)ib offset:(NSUInteger)io
{
	T290State *s = _s;
	s->frozen = YES;
	[_cb record:^{ exec_draw(s, d, ib, io); }];
}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i baseInstance:(NSUInteger)b
{
	if (!n || !i) return;
	struct draw d = {p, v, n, i, b, 0, NO, MTLIndexTypeUInt16};
	[self record:d index:nil offset:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i
{
	[self drawPrimitives:p vertexStart:v vertexCount:n instanceCount:i baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n
{
	[self drawPrimitives:p vertexStart:v vertexCount:n instanceCount:1 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)ib
            indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)i baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi
{
	if (!n || !i) return;
	struct draw d = {p, 0, n, i, bi, bv, YES, t};
	[self record:d index:ib offset:o];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)ib
            indexBufferOffset:(NSUInteger)o instanceCount:(NSUInteger)i
{
	[self drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:ib indexBufferOffset:o instanceCount:i baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)ib
            indexBufferOffset:(NSUInteger)o
{
	[self drawIndexedPrimitives:p indexCount:n indexType:t indexBuffer:ib indexBufferOffset:o instanceCount:1 baseVertex:0 baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)p indirectBuffer:(id<MTLBuffer>)b indirectBufferOffset:(NSUInteger)o
{
	const uint32_t *a = (const uint32_t *)((uint8_t *)b.contents + o);     /* read at encode time */
	[self drawPrimitives:p vertexStart:a[2] vertexCount:a[0] instanceCount:a[1] baseInstance:a[3]];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexType:(MTLIndexType)t indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)io
               indirectBuffer:(id<MTLBuffer>)b indirectBufferOffset:(NSUInteger)o
{
	const uint32_t *a = (const uint32_t *)((uint8_t *)b.contents + o);
	NSUInteger isz = t == MTLIndexTypeUInt16 ? 2 : 4;
	[self drawIndexedPrimitives:p indexCount:a[0] indexType:t indexBuffer:ib indexBufferOffset:io + a[2] * isz
	              instanceCount:a[1] baseVertex:(int32_t)a[3] baseInstance:a[4]];
}
- (void)textureBarrier {}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s afterStages:(MTLRenderStages)a beforeStages:(MTLRenderStages)b { (void)s; (void)a; (void)b; }
- (void)updateFence:(id<MTLFence>)f afterStages:(MTLRenderStages)s { (void)f; (void)s; }
- (void)waitForFence:(id<MTLFence>)f beforeStages:(MTLRenderStages)s { (void)f; (void)s; }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { (void)r; (void)u; }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)s { (void)r; (void)u; (void)s; }
- (void)useResources:(const id<MTLResource> *)r count:(NSUInteger)n usage:(MTLResourceUsage)u { (void)r; (void)n; (void)u; }
- (void)useResources:(const id<MTLResource> *)r count:(NSUInteger)n usage:(MTLResourceUsage)u stages:(MTLRenderStages)s
{
	(void)r; (void)n; (void)u; (void)s;
}
- (void)useHeap:(id<MTLHeap>)h { (void)h; }
- (void)useHeap:(id<MTLHeap>)h stages:(MTLRenderStages)s { (void)h; (void)s; }
- (void)setVertexAmplificationCount:(NSUInteger)n viewMappings:(const MTLVertexAmplificationViewMapping *)m { (void)n; (void)m; }
@end

/* ------------------------------------------------------------------ blit encoder */

@implementation T290BlitEncoder {
	T290CommandBuffer *_cb;
}
- (instancetype)initWithCommandBuffer:(T290CommandBuffer *)cb
{
	if ((self = [super initWithDevice:(T290Device *)cb.device])) _cb = cb;
	return self;
}
- (void)endEncoding {}
- (void)insertDebugSignpost:(NSString *)s { (void)s; }
- (void)pushDebugGroup:(NSString *)s { (void)s; }
- (void)popDebugGroup {}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so
             sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl
      destinationOrigin:(MTLOrigin)dorg
{
	T290Texture *s = (T290Texture *)src, *d = (T290Texture *)dst;
	T290CommandBuffer *cb = _cb;
	[cb record:^{
		T290Texture *sr = s->_parent ?: s, *dr = d->_parent ?: d;
		[sr prepare];
		[dr prepare];
		GLbitfield mask = sr->_fmt->depth || sr->_fmt->stencil ? (GLbitfield)((sr->_fmt->depth ? GL_DEPTH_BUFFER_BIT : 0) |
		    (sr->_fmt->stencil ? GL_STENCIL_BUFFER_BIT : 0)) : GL_COLOR_BUFFER_BIT;
		for (NSUInteger z = 0; z < MAX(size.depth, 1u); z++) {
			t290_fbo_for(sr, sl, ss + so.z + z, GL_READ_FRAMEBUFFER);
			t290_fbo_for(dr, dl, ds + dorg.z + z, GL_DRAW_FRAMEBUFFER);
			gl.Disable(GL_SCISSOR_TEST);
			gl.BlitFramebuffer((GLint)so.x, (GLint)so.y, (GLint)(so.x + size.width), (GLint)(so.y + size.height),
			    (GLint)dorg.x, (GLint)dorg.y, (GLint)(dorg.x + size.width), (GLint)(dorg.y + size.height), mask, GL_NEAREST);
		}
		[dr rendered];
		if (dr->_shadow) [cb->_written addObject:dr];
		GLenum e = gl.GetError();
		if (e) t290_log("T290Metal: texture copy error %#x (%lu -> %lu)", e, (unsigned long)sr->_fmt->mtl, (unsigned long)dr->_fmt->mtl);
	}];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl sliceCount:(NSUInteger)sc levelCount:(NSUInteger)lc
{
	for (NSUInteger l = 0; l < lc; l++)
		for (NSUInteger s = 0; s < sc; s++)
			[self copyFromTexture:src sourceSlice:ss + s sourceLevel:sl + l sourceOrigin:MTLOriginMake(0, 0, 0)
			           sourceSize:MTLSizeMake(MAX(src.width >> (sl + l), 1u), MAX(src.height >> (sl + l), 1u), 1)
			            toTexture:dst destinationSlice:ds + s destinationLevel:dl + l destinationOrigin:MTLOriginMake(0, 0, 0)];
}
- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst
{
	[self copyFromTexture:src sourceSlice:0 sourceLevel:0 toTexture:dst destinationSlice:0 destinationLevel:0
	           sliceCount:src.arrayLength levelCount:MIN(src.mipmapLevelCount, dst.mipmapLevelCount)];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)img
            sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl
     destinationOrigin:(MTLOrigin)dorg options:(MTLBlitOption)o
{
	(void)o; (void)img;
	T290Buffer *b = (T290Buffer *)src;
	T290Texture *d = (T290Texture *)dst;
	T290CommandBuffer *cb = _cb;
	[cb record:^{
		T290Texture *dr = d->_parent ?: d;
		MTLRegion r = {dorg, size};
		if (dr->_image) {
			gl.Finish();
			[dr replaceRegion:r mipmapLevel:dl slice:ds withBytes:(uint8_t *)b->_bytes + so bytesPerRow:row bytesPerImage:img];
		} else {
			t290_write_texture(dr, dl, ds, r, (uint8_t *)b->_bytes + so, row);
			[dr rendered];
			if (dr->_shadow) [cb->_written addObject:dr];
		}
	}];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)img
            sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl
     destinationOrigin:(MTLOrigin)dorg
{
	[self copyFromBuffer:src sourceOffset:so sourceBytesPerRow:row sourceBytesPerImage:img sourceSize:size toTexture:dst
	    destinationSlice:ds destinationLevel:dl destinationOrigin:dorg options:MTLBlitOptionNone];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so
             sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)doff
 destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)img options:(MTLBlitOption)o
{
	(void)o; (void)img;
	T290Texture *s = (T290Texture *)src;
	T290Buffer *b = (T290Buffer *)dst;
	[_cb record:^{
		T290Texture *sr = s->_parent ?: s;
		[sr prepare];
		MTLRegion r = {so, size};
		if (sr->_image) {
			gl.Finish();
			[sr getBytes:(uint8_t *)b->_bytes + doff bytesPerRow:row bytesPerImage:img fromRegion:r mipmapLevel:sl slice:ss];
		} else
			t290_read_texture(sr, sl, ss, r, (uint8_t *)b->_bytes + doff, row);
	}];
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl sourceOrigin:(MTLOrigin)so
             sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)doff
 destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)img
{
	[self copyFromTexture:src sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:size toBuffer:dst destinationOffset:doff
	    destinationBytesPerRow:row destinationBytesPerImage:img options:MTLBlitOptionNone];
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)so toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)doff size:(NSUInteger)n
{
	T290Buffer *s = (T290Buffer *)src, *d = (T290Buffer *)dst;
	[_cb record:^{ memmove((uint8_t *)d->_bytes + doff, (uint8_t *)s->_bytes + so, n); }];
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)r value:(uint8_t)v
{
	T290Buffer *b = (T290Buffer *)buffer;
	[_cb record:^{ memset((uint8_t *)b->_bytes + r.location, v, r.length); }];
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture
{
	T290Texture *t = (T290Texture *)texture;
	[_cb record:^{
		T290Texture *r = t->_parent ?: t;
		[r prepare];
		gl.BindTexture(r->_target, r->_tex);
		gl.GenerateMipmap(r->_target);
	}];
}
- (void)synchronizeResource:(id<MTLResource>)r { (void)r; }
- (void)synchronizeTexture:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { (void)t; (void)s; (void)l; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t { (void)t; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { (void)t; (void)s; (void)l; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t { (void)t; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)t slice:(NSUInteger)s level:(NSUInteger)l { (void)t; (void)s; (void)l; }
- (void)updateFence:(id<MTLFence>)f { (void)f; }
- (void)waitForFence:(id<MTLFence>)f { (void)f; }
@end

/* ------------------------------------------------------------------ compute encoder */

@implementation T290ComputeEncoder {
	T290CommandBuffer *_cb;
	T290State *_s;
}
- (instancetype)initWithCommandBuffer:(T290CommandBuffer *)cb
{
	if (!(self = [super initWithDevice:(T290Device *)cb.device])) return nil;
	_cb = cb;
	_s = [T290State new];
	return self;
}
- (T290State *)w
{
	if (_s->frozen) _s = [_s copy];
	return _s;
}
- (void)endEncoding {}
- (void)insertDebugSignpost:(NSString *)s { (void)s; }
- (void)pushDebugGroup:(NSString *)s { (void)s; }
- (void)popDebugGroup {}
- (MTLDispatchType)dispatchType { return MTLDispatchTypeSerial; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)p { [self w]->cpipe = (T290ComputePipeline *)p; }
- (void)setBytes:(const void *)b length:(NSUInteger)n atIndex:(NSUInteger)i { set_buffer([self w], CS, [NSData dataWithBytes:b length:n], 0, i); }
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i { set_buffer([self w], CS, b, o, i); }
- (void)setBufferOffset:(NSUInteger)o atIndex:(NSUInteger)i { if (i < T290_MAX_BUFFERS) [self w]->off[CS][i] = o; }
- (void)setBuffers:(id<MTLBuffer> const *)b offsets:(const NSUInteger *)o withRange:(NSRange)r
{
	T290State *s = [self w];
	for (NSUInteger k = 0; k < r.length; k++) set_buffer(s, CS, b[k], o[k], r.location + k);
}
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { if (i < T290_MAX_TEXTURES) [self w]->tex[CS][i] = (T290Texture *)t; }
- (void)setTextures:(id<MTLTexture> const *)t withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setTexture:t[k] atIndex:r.location + k];
}
- (void)setSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i { if (i < T290_MAX_SAMPLERS) [self w]->smp[CS][i] = (T290Sampler *)s; }
- (void)setSamplerStates:(id<MTLSamplerState> const *)s withRange:(NSRange)r
{
	for (NSUInteger k = 0; k < r.length; k++) [self setSamplerState:s[k] atIndex:r.location + k];
}
- (void)setSamplerState:(id<MTLSamplerState>)s lodMinClamp:(float)a lodMaxClamp:(float)b atIndex:(NSUInteger)i
{
	(void)a; (void)b;
	[self setSamplerState:s atIndex:i];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)n atIndex:(NSUInteger)i { (void)n; (void)i; }
- (void)setStageInRegion:(MTLRegion)r { (void)r; }

static void exec_dispatch(T290State *s, MTLSize groups, MTLSize tg)
{
	T290ComputePipeline *cp = s->cpipe;
	T290Program *prog = [cp programForSize:tg];
	if (!prog) return;
	gl.UseProgram(prog->_program);
	bind_buffers(s, prog, CS);
	bind_textures(s, prog);
	for (unsigned k = 0; k < prog->_nimages; k++) {
		T290Texture *t = s->tex[CS][prog->_images[k]];
		if (!t) continue;
		T290Texture *r = t->_parent ?: t;
		gl.BindImageTexture(k, r->_tex, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA8);
		[r rendered];
	}
	gl.DispatchCompute((GLuint)groups.width, (GLuint)groups.height, (GLuint)groups.depth);
	gl.MemoryBarrier(GL_ALL_BARRIER_BITS);
	for (unsigned k = 0; k < prog->_nbind; k++)
		if (prog->_bind[k].kind == T290_BIND_SSBO) {
			static unsigned n;
			if (n++ < 8) t290_log("T290Metal: compute buffer writes are not copied back yet");
		}
}

- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)tg
{
	T290State *s = _s;
	s->frozen = YES;
	[_cb record:^{ exec_dispatch(s, groups, tg); }];
}
- (void)dispatchThreads:(MTLSize)threads threadsPerThreadgroup:(MTLSize)tg
{
	MTLSize g = MTLSizeMake((threads.width + tg.width - 1) / MAX(tg.width, 1u), (threads.height + tg.height - 1) / MAX(tg.height, 1u),
	    (threads.depth + tg.depth - 1) / MAX(tg.depth, 1u));
	[self dispatchThreadgroups:g threadsPerThreadgroup:tg];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)s { (void)s; }
- (void)memoryBarrierWithResources:(const id<MTLResource> *)r count:(NSUInteger)n { (void)r; (void)n; }
- (void)updateFence:(id<MTLFence>)f { (void)f; }
- (void)waitForFence:(id<MTLFence>)f { (void)f; }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u { (void)r; (void)u; }
- (void)useResources:(const id<MTLResource> *)r count:(NSUInteger)n usage:(MTLResourceUsage)u { (void)r; (void)n; (void)u; }
- (void)useHeap:(id<MTLHeap>)h { (void)h; }
- (void)useHeaps:(const id<MTLHeap> *)h count:(NSUInteger)n { (void)h; (void)n; }
@end
