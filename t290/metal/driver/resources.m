/* T290Metal resources: buffers, textures (incl. IOSurface), samplers,
 * depth/stencil states, events, fences. */
#import "t290mtl.h"
#include <IOSurface/IOSurfaceRef.h>
#include <mach/mach.h>
#include <stdatomic.h>

@implementation T290Object {
	__weak T290Device *_dev;
}
- (instancetype)initWithDevice:(T290Device *)device
{
	if ((self = [super init])) _dev = device;
	return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_dev; }
T290_FORWARD_UNKNOWN
@end

/* ------------------------------------------------------------------ buffers */

@implementation T290Buffer {
	void (^_dealloc)(void *, NSUInteger);
	BOOL _owned;
}
- (instancetype)initWithDevice:(T290Device *)device length:(NSUInteger)length options:(MTLResourceOptions)options
                         bytes:(void *)bytes deallocator:(void (^)(void *, NSUInteger))dealloc
{
	if (!(self = [super initWithDevice:device])) return nil;
	_length = length;
	_options = options;
	if (bytes && dealloc) {
		_bytes = bytes;
		_dealloc = [dealloc copy];
	} else {
		vm_address_t a = 0;
		if (vm_allocate(mach_task_self(), &a, round_page(length ?: 1), VM_FLAGS_ANYWHERE)) return nil;
		_bytes = (void *)a;
		_owned = YES;
		if (bytes) memcpy(_bytes, bytes, length);
	}
	return self;
}
- (void)dealloc
{
	if (_owned) vm_deallocate(mach_task_self(), (vm_address_t)_bytes, round_page(_length ?: 1));
	else if (_dealloc) _dealloc(_bytes, _length);
}
- (NSUInteger)length { return _length; }
- (void *)contents { return _bytes; }
- (void)didModifyRange:(NSRange)range { (void)range; }
- (uint64_t)gpuAddress { return (uint64_t)(uintptr_t)_bytes; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)(_options & MTLResourceCPUCacheModeMask); }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { (void)state; return MTLPurgeableStateNonVolatile; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)allocatedSize { return round_page(_length); }
- (void)makeAliasable {}
- (BOOL)isAliasable { return NO; }
- (void)addDebugMarker:(NSString *)marker range:(NSRange)range { (void)marker; (void)range; }
- (void)removeAllDebugMarkers {}
- (id<MTLBuffer>)newRemoteBufferViewForDevice:(id<MTLDevice>)device { (void)device; return nil; }
- (id<MTLBuffer>)remoteStorageBuffer { return nil; }
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d offset:(NSUInteger)offset bytesPerRow:(NSUInteger)row
{
	T290Texture *t = (T290Texture *)[(id<MTLDevice>)self.device newTextureWithDescriptor:d];
	if (!t) return nil;
	t->_buffer = self;
	t->_bufferOffset = offset;
	t->_bufferRow = row;
	return t;
}
@end

/* ------------------------------------------------------------------ textures */

static GLenum gl_target(MTLTextureType t)
{
	switch (t) {
	case MTLTextureType2DArray: return GL_TEXTURE_2D_ARRAY;
	case MTLTextureType3D: return GL_TEXTURE_3D;
	case MTLTextureTypeCube: return GL_TEXTURE_CUBE_MAP;
	default: return GL_TEXTURE_2D;
	}
}

static GLuint scratch_fbo[2];

GLuint t290_fbo_for(T290Texture *t, NSUInteger level, NSUInteger slice, GLenum target)
{
	int k = target == GL_DRAW_FRAMEBUFFER;
	if (!scratch_fbo[k]) gl.GenFramebuffers(1, &scratch_fbo[k]);
	gl.BindFramebuffer(target, scratch_fbo[k]);
	GLenum att = t->_fmt->depth && t->_fmt->stencil ? GL_DEPTH_STENCIL_ATTACHMENT :
	    t->_fmt->depth ? GL_DEPTH_ATTACHMENT : t->_fmt->stencil ? GL_DEPTH_STENCIL_ATTACHMENT : GL_COLOR_ATTACHMENT0;
	if (att != GL_COLOR_ATTACHMENT0) gl.FramebufferTexture2D(target, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
	else gl.FramebufferTexture2D(target, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, 0, 0);
	if (t->_target == GL_TEXTURE_2D_ARRAY || t->_target == GL_TEXTURE_3D)
		gl.FramebufferTextureLayer(target, att, t->_tex, (GLint)level, (GLint)slice);
	else
		gl.FramebufferTexture2D(target, att, t->_target == GL_TEXTURE_CUBE_MAP ? GL_TEXTURE_CUBE_MAP_POSITIVE_X + (GLenum)slice :
		    GL_TEXTURE_2D, t->_tex, (GLint)level);
	if (target == GL_READ_FRAMEBUFFER) gl.ReadBuffer(att == GL_COLOR_ATTACHMENT0 ? GL_COLOR_ATTACHMENT0 : GL_NONE);
	return scratch_fbo[k];
}

static inline uint16_t half_of(float f)
{
	__fp16 h = (__fp16)f;
	uint16_t u;
	memcpy(&u, &h, 2);
	return u;
}

void t290_read_texture(T290Texture *t, NSUInteger level, NSUInteger slice, MTLRegion r, void *dst, size_t row)
{
	const struct t290_format *f = t->_fmt;
	if (f->depth || f->stencil) { t290_log("T290Metal: depth/stencil readback unsupported"); return; }
	t290_fbo_for(t, level, slice + r.origin.z, GL_READ_FRAMEBUFFER);
	size_t w = r.size.width, h = r.size.height;
	gl.PixelStorei(GL_PACK_ALIGNMENT, 1);
	GLenum format = GL_RGBA, type = GL_UNSIGNED_BYTE;
	size_t texel = 4;
	if (f->kind == T290_F_FLOAT || f->kind == T290_F_HALF) { type = GL_FLOAT; texel = 16; }
	else if (f->kind == T290_F_UINT) { format = GL_RGBA_INTEGER; type = GL_UNSIGNED_INT; texel = 16; }
	else if (f->kind == T290_F_SINT) { format = GL_RGBA_INTEGER; type = GL_INT; texel = 16; }
	else if (f->type == GL_UNSIGNED_INT_2_10_10_10_REV) type = GL_UNSIGNED_INT_2_10_10_10_REV;
	else if (f->kind == T290_F_PACKED) { type = GL_FLOAT; texel = 16; }
	uint8_t *tmp = malloc(w * h * texel ?: 1);
	gl.ReadPixels((GLint)r.origin.x, (GLint)r.origin.y, (GLsizei)w, (GLsizei)h, format, type, tmp);
	for (size_t y = 0; y < h; y++) {
		uint8_t *d = (uint8_t *)dst + y * row;
		const uint8_t *s = tmp + y * w * texel;
		for (size_t x = 0; x < w; x++, d += f->bytes, s += texel) {
			if (type == GL_UNSIGNED_INT_2_10_10_10_REV) { memcpy(d, s, 4); continue; }
			if (f->kind == T290_F_UNORM8) {
				if (f->alphaOnly) d[0] = s[0];
				else if (f->swapRB) { d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3]; }
				else memcpy(d, s, f->comps);
			} else if (f->kind == T290_F_FLOAT) memcpy(d, s, 4u * f->comps);
			else if (f->kind == T290_F_HALF) {
				for (unsigned c = 0; c < f->comps; c++) {
					float v;
					memcpy(&v, s + 4 * c, 4);
					uint16_t hv = half_of(v);
					memcpy(d + 2 * c, &hv, 2);
				}
			} else if (f->kind == T290_F_UINT || f->kind == T290_F_SINT) {
				unsigned es = f->bytes / f->comps;
				for (unsigned c = 0; c < f->comps; c++) memcpy(d + es * c, s + 4 * c, es);     /* little endian */
			} else memset(d, 0, f->bytes);
		}
	}
	free(tmp);
}

void t290_write_texture(T290Texture *t, NSUInteger level, NSUInteger slice, MTLRegion r, const void *src, size_t row)
{
	const struct t290_format *f = t->_fmt;
	size_t w = r.size.width, h = r.size.height, d = r.size.depth ?: 1;
	uint8_t *tmp = malloc(w * h * f->bytes ?: 1);
	gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
	gl.BindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
	gl.BindTexture(t->_target, t->_tex);
	for (size_t z = 0; z < d; z++) {
		t290_pixels_to_gl(f, (const uint8_t *)src + z * row * h, row, tmp, w, h);
		if (t->_target == GL_TEXTURE_2D_ARRAY || t->_target == GL_TEXTURE_3D)
			gl.TexSubImage3D(t->_target, (GLint)level, (GLint)r.origin.x, (GLint)r.origin.y,
			    (GLint)(t->_target == GL_TEXTURE_3D ? r.origin.z + z : slice + z), (GLsizei)w, (GLsizei)h, 1, f->format, f->type, tmp);
		else
			gl.TexSubImage2D(t->_target == GL_TEXTURE_CUBE_MAP ? GL_TEXTURE_CUBE_MAP_POSITIVE_X + (GLenum)slice : GL_TEXTURE_2D,
			    (GLint)level, (GLint)r.origin.x, (GLint)r.origin.y, (GLsizei)w, (GLsizei)h, f->format, f->type, tmp);
	}
	free(tmp);
}

@implementation T290Texture

- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLTextureDescriptor *)d
                       surface:(IOSurfaceRef)surface plane:(NSUInteger)plane
{
	if (!(self = [super initWithDevice:device])) return nil;
	_fmt = t290_format(d.pixelFormat);
	if (!_fmt) {
		t290_log("T290Metal: unsupported pixel format %lu", (unsigned long)d.pixelFormat);
		return nil;
	}
	_type = d.textureType;
	_target = gl_target(_type);
	_width = d.width ?: 1;
	_height = d.height ?: 1;
	_depth = d.depth ?: 1;
	_levels = d.mipmapLevelCount ?: 1;
	_arrayLength = d.arrayLength ?: 1;
	_samples = d.sampleCount ?: 1;
	_usage = d.usage;
	_storage = d.storageMode;
	if (surface) {
		_surface = (IOSurfaceRef)CFRetain(surface);
		_plane = plane;
		_levels = 1;
		_target = GL_TEXTURE_2D;
	}
	__block BOOL ok = YES;
	t290_gl_sync(^{ ok = [self createGL]; });
	if (!ok) return nil;
	return self;
}

- (BOOL)createGL
{
	gl.GenTextures(1, &_tex);
	gl.BindTexture(_target, _tex);
	if (_surface) {
		size_t planes = IOSurfaceGetPlaneCount(_surface);
		size_t stride = planes ? IOSurfaceGetBytesPerRowOfPlane(_surface, _plane) : IOSurfaceGetBytesPerRow(_surface);
		uint8_t *base = IOSurfaceGetBaseAddress(_surface);
		uint8_t *pbase = planes ? IOSurfaceGetBaseAddressOfPlane(_surface, _plane) : base;
		size_t offset = base && pbase ? (size_t)(pbase - base) : 0;
		if (_fmt->fourcc && stride % (64u * _fmt->bytes) == 0) {
			_image = t290_mesa_image(IOSurfaceGetID(_surface), (uint32_t)_width, (uint32_t)_height,
			    (uint32_t)stride, (uint32_t)offset, _fmt->fourcc);
			if (_image) gl.EGLImageTargetTexture2DOES(GL_TEXTURE_2D, _image);
		}
		if (!_image) {
			_shadow = YES;
			gl.TexStorage2D(GL_TEXTURE_2D, 1, _fmt->internal, (GLsizei)_width, (GLsizei)_height);
			_seed = IOSurfaceGetSeed(_surface) - 1;
		}
		static unsigned n;
		if (n++ < 32)
			t290_log("T290Metal: IOSurface %u plane %zu %zux%zu fmt %lu stride %zu: %s", IOSurfaceGetID(_surface),
			    (size_t)_plane, (size_t)_width, (size_t)_height, (unsigned long)_fmt->mtl, stride, _image ? "direct" : "copy");
	} else if (_target == GL_TEXTURE_2D_ARRAY || _target == GL_TEXTURE_3D) {
		gl.TexStorage3D(_target, (GLsizei)_levels, _fmt->internal, (GLsizei)_width, (GLsizei)_height,
		    (GLsizei)(_target == GL_TEXTURE_3D ? _depth : _arrayLength));
	} else {
		gl.TexStorage2D(_target, (GLsizei)_levels, _fmt->internal, (GLsizei)_width, (GLsizei)_height);
	}
	gl.TexParameteri(_target, GL_TEXTURE_MAX_LEVEL, (GLint)_levels - 1);
	if (_fmt->alphaOnly) {
		gl.TexParameteri(_target, GL_TEXTURE_SWIZZLE_R, GL_ZERO);
		gl.TexParameteri(_target, GL_TEXTURE_SWIZZLE_G, GL_ZERO);
		gl.TexParameteri(_target, GL_TEXTURE_SWIZZLE_B, GL_ZERO);
		gl.TexParameteri(_target, GL_TEXTURE_SWIZZLE_A, GL_RED);
	}
	GLenum err = gl.GetError();
	if (err) {
		t290_log("T290Metal: texture %zux%zu fmt %lu type %lu: GL error %#x", (size_t)_width, (size_t)_height,
		    (unsigned long)_fmt->mtl, (unsigned long)_type, err);
		return NO;
	}
	return YES;
}

- (void)dealloc
{
	GLuint tex = _tex;
	void *image = _image;
	if (!_parent && (tex || image))
		t290_gl_async(^{ gl.DeleteTextures(1, &tex); t290_mesa_image_destroy(image); });
	if (_surface) CFRelease(_surface);
}

- (void)prepare
{
	if (_parent) { [_parent prepare]; return; }
	if (_buffer) {
		MTLRegion r = MTLRegionMake2D(0, 0, _width, _height);
		t290_write_texture(self, 0, 0, r, (uint8_t *)_buffer->_bytes + _bufferOffset, _bufferRow);
		return;
	}
	if (!_shadow || _gpuDirty) return;
	uint32_t seed = IOSurfaceGetSeed(_surface);
	if (seed == _seed) return;
	IOSurfaceLock(_surface, kIOSurfaceLockReadOnly, NULL);
	size_t planes = IOSurfaceGetPlaneCount(_surface);
	const uint8_t *p = planes ? IOSurfaceGetBaseAddressOfPlane(_surface, _plane) : IOSurfaceGetBaseAddress(_surface);
	size_t stride = planes ? IOSurfaceGetBytesPerRowOfPlane(_surface, _plane) : IOSurfaceGetBytesPerRow(_surface);
	t290_write_texture(self, 0, 0, MTLRegionMake2D(0, 0, _width, _height), p, stride);
	IOSurfaceUnlock(_surface, kIOSurfaceLockReadOnly, NULL);
	_seed = IOSurfaceGetSeed(_surface);
}

- (void)rendered
{
	if (_parent) { [_parent rendered]; return; }
	if (_shadow) _gpuDirty = YES;
}

- (void)writeBack
{
	if (!_shadow || !_gpuDirty) return;
	IOSurfaceLock(_surface, 0, NULL);
	size_t planes = IOSurfaceGetPlaneCount(_surface);
	uint8_t *p = planes ? IOSurfaceGetBaseAddressOfPlane(_surface, _plane) : IOSurfaceGetBaseAddress(_surface);
	size_t stride = planes ? IOSurfaceGetBytesPerRowOfPlane(_surface, _plane) : IOSurfaceGetBytesPerRow(_surface);
	t290_read_texture(self, 0, 0, MTLRegionMake2D(0, 0, _width, _height), p, stride);
	IOSurfaceUnlock(_surface, 0, NULL);
	_seed = IOSurfaceGetSeed(_surface);
	_gpuDirty = NO;
}

static void surface_rows(T290Texture *t, MTLRegion r, void *bytes, size_t row, BOOL write)
{
	size_t planes = IOSurfaceGetPlaneCount(t->_surface);
	uint8_t *p = planes ? IOSurfaceGetBaseAddressOfPlane(t->_surface, t->_plane) : IOSurfaceGetBaseAddress(t->_surface);
	size_t stride = planes ? IOSurfaceGetBytesPerRowOfPlane(t->_surface, t->_plane) : IOSurfaceGetBytesPerRow(t->_surface);
	size_t n = r.size.width * t->_fmt->bytes;
	for (size_t y = 0; y < r.size.height; y++) {
		uint8_t *s = p + (r.origin.y + y) * stride + r.origin.x * t->_fmt->bytes;
		uint8_t *b = (uint8_t *)bytes + y * row;
		if (write) memcpy(s, b, n); else memcpy(b, s, n);
	}
}

- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image fromRegion:(MTLRegion)r
     mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
{
	(void)image;
	if (_image) {          /* linear memory shared with the GPU */
		t290_gl_sync(^{ gl.Finish(); });
		surface_rows(self, r, bytes, row, NO);
		return;
	}
	T290Texture *t = _parent ?: self;
	t290_gl_sync(^{ t290_read_texture(t, level, slice, r, bytes, row); });
}
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)row fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level
{
	[self getBytes:bytes bytesPerRow:row bytesPerImage:row * r.size.height fromRegion:r mipmapLevel:level slice:0];
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)bytes
          bytesPerRow:(NSUInteger)row bytesPerImage:(NSUInteger)image
{
	(void)image;
	if (_image) {
		t290_gl_sync(^{ gl.Finish(); });
		surface_rows(self, r, (void *)bytes, row, YES);
		return;
	}
	T290Texture *t = _parent ?: self;
	t290_gl_sync(^{ t290_write_texture(t, level, slice, r, bytes, row); });
}
- (void)replaceRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level withBytes:(const void *)bytes bytesPerRow:(NSUInteger)row
{
	[self replaceRegion:r mipmapLevel:level slice:0 withBytes:bytes bytesPerRow:row bytesPerImage:row * r.size.height];
}

- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format
{
	return [self newTextureViewWithPixelFormat:format textureType:_type levels:NSMakeRange(0, _levels)
	                                    slices:NSMakeRange(0, _arrayLength)];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type
                                         levels:(NSRange)levels slices:(NSRange)slices
{
	const struct t290_format *f = t290_format(format);
	if (!f || f->internal != _fmt->internal || levels.location || slices.location)
		t290_log("T290Metal: approximate texture view %lu -> %lu (levels %lu slices %lu)", (unsigned long)_fmt->mtl,
		    (unsigned long)format, (unsigned long)levels.location, (unsigned long)slices.location);
	if (!f) return nil;
	T290Texture *v = [[T290Texture alloc] initWithDevice:(T290Device *)self.device];
	T290Texture *root = _parent ?: self;
	v->_parent = root;
	v->_tex = root->_tex;
	v->_target = root->_target;
	v->_image = root->_image;
	v->_surface = _surface ? (IOSurfaceRef)CFRetain(_surface) : NULL;
	v->_plane = _plane;
	v->_fmt = f;
	v->_type = type;
	v->_width = _width; v->_height = _height; v->_depth = _depth;
	v->_levels = levels.length; v->_arrayLength = slices.length; v->_samples = _samples;
	v->_usage = _usage; v->_storage = _storage;
	return v;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)format textureType:(MTLTextureType)type
                                         levels:(NSRange)levels slices:(NSRange)slices swizzle:(MTLTextureSwizzleChannels)swizzle
{
	(void)swizzle;
	t290_log("T290Metal: texture view swizzle ignored");
	return [self newTextureViewWithPixelFormat:format textureType:type levels:levels slices:slices];
}

- (MTLTextureType)textureType { return _type; }
- (MTLPixelFormat)pixelFormat { return _fmt->mtl; }
- (NSUInteger)width { return _width; }
- (NSUInteger)height { return _height; }
- (NSUInteger)depth { return _depth; }
- (NSUInteger)mipmapLevelCount { return _levels; }
- (NSUInteger)sampleCount { return _samples; }
- (NSUInteger)arrayLength { return _arrayLength; }
- (MTLTextureUsage)usage { return _usage; }
- (BOOL)isShareable { return NO; }
- (BOOL)isFramebufferOnly { return NO; }
- (NSUInteger)firstMipmapInTail { return 0; }
- (NSUInteger)tailSizeInBytes { return 0; }
- (BOOL)isSparse { return NO; }
- (BOOL)allowGPUOptimizedContents { return YES; }
- (MTLTextureCompressionType)compressionType { return MTLTextureCompressionTypeLossless; }
- (MTLResourceID)gpuResourceID { MTLResourceID r = {(uint64_t)_tex}; return r; }
- (id<MTLResource>)rootResource { return _parent; }
- (id<MTLTexture>)parentTexture { return _parent; }
- (NSUInteger)parentRelativeLevel { return 0; }
- (NSUInteger)parentRelativeSlice { return 0; }
- (id<MTLBuffer>)buffer { return _buffer; }
- (NSUInteger)bufferOffset { return _bufferOffset; }
- (NSUInteger)bufferBytesPerRow { return _bufferRow; }
- (IOSurfaceRef)iosurface { return _surface; }
- (NSUInteger)iosurfacePlane { return _plane; }
- (MTLTextureSwizzleChannels)swizzle { return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha); }
- (MTLStorageMode)storageMode { return _storage; }
- (MTLCPUCacheMode)cpuCacheMode { return MTLCPUCacheModeDefaultCache; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return (MTLResourceOptions)_storage << MTLResourceStorageModeShift; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { (void)state; return MTLPurgeableStateNonVolatile; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)allocatedSize { return _width * _height * _depth * _arrayLength * _fmt->bytes; }
- (void)makeAliasable {}
- (BOOL)isAliasable { return NO; }
- (MTLSharedTextureHandle *)newSharedTextureHandle { return nil; }
@end

/* ------------------------------------------------------------------ samplers */

static GLenum gl_wrap(MTLSamplerAddressMode m)
{
	switch (m) {
	case MTLSamplerAddressModeRepeat: return GL_REPEAT;
	case MTLSamplerAddressModeMirrorRepeat: return GL_MIRRORED_REPEAT;
	default: return GL_CLAMP_TO_EDGE;           /* no border clamp on ES 3.1 */
	}
}

GLenum t290_compare(MTLCompareFunction f)
{
	static const GLenum t[] = {GL_NEVER, GL_LESS, GL_EQUAL, GL_LEQUAL, GL_GREATER, GL_NOTEQUAL, GL_GEQUAL, GL_ALWAYS};
	return f < 8 ? t[f] : GL_ALWAYS;
}

@implementation T290Sampler
- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLSamplerDescriptor *)d
{
	if (!(self = [super initWithDevice:device])) return nil;
	self.label = d.label;
	if (!d.normalizedCoordinates) t290_log("T290Metal: sampler with pixel coordinates (unsupported)");
	MTLSamplerMinMagFilter minf = d.minFilter, magf = d.magFilter;
	MTLSamplerMipFilter mip = d.mipFilter;
	GLint min = mip == MTLSamplerMipFilterNotMipmapped ? (minf ? GL_LINEAR : GL_NEAREST) :
	    mip == MTLSamplerMipFilterNearest ? (minf ? GL_LINEAR_MIPMAP_NEAREST : GL_NEAREST_MIPMAP_NEAREST) :
	    (minf ? GL_LINEAR_MIPMAP_LINEAR : GL_NEAREST_MIPMAP_LINEAR);
	GLint mag = magf ? GL_LINEAR : GL_NEAREST;
	GLint s = (GLint)gl_wrap(d.sAddressMode), t = (GLint)gl_wrap(d.tAddressMode), r = (GLint)gl_wrap(d.rAddressMode);
	float lmin = d.lodMinClamp, lmax = d.lodMaxClamp;
	NSUInteger aniso = d.maxAnisotropy;
	MTLCompareFunction cmp = d.compareFunction;
	t290_gl_sync(^{
		gl.GenSamplers(1, &self->_sampler);
		GLuint o = self->_sampler;
		gl.SamplerParameteri(o, GL_TEXTURE_MIN_FILTER, min);
		gl.SamplerParameteri(o, GL_TEXTURE_MAG_FILTER, mag);
		gl.SamplerParameteri(o, GL_TEXTURE_WRAP_S, s);
		gl.SamplerParameteri(o, GL_TEXTURE_WRAP_T, t);
		gl.SamplerParameteri(o, GL_TEXTURE_WRAP_R, r);
		gl.SamplerParameterf(o, GL_TEXTURE_MIN_LOD, lmin);
		gl.SamplerParameterf(o, GL_TEXTURE_MAX_LOD, lmax);
		if (aniso > 1) gl.SamplerParameterf(o, GL_TEXTURE_MAX_ANISOTROPY_EXT, (float)aniso);
		if (cmp != MTLCompareFunctionNever) {
			gl.SamplerParameteri(o, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE);
			gl.SamplerParameteri(o, GL_TEXTURE_COMPARE_FUNC, (GLint)t290_compare(cmp));
		}
		gl.GetError();
	});
	return self;
}
- (void)dealloc
{
	GLuint o = _sampler;
	if (o) t290_gl_async(^{ gl.DeleteSamplers(1, &o); });
}
- (MTLResourceID)gpuResourceID { MTLResourceID r = {(uint64_t)_sampler}; return r; }
@end

/* ------------------------------------------------------------------ depth/stencil */

static GLenum gl_stencil_op(MTLStencilOperation o)
{
	static const GLenum t[] = {GL_KEEP, GL_ZERO, GL_REPLACE, GL_INCR, GL_DECR, GL_INVERT, GL_INCR_WRAP, GL_DECR_WRAP};
	return o < 8 ? t[o] : GL_KEEP;
}

@implementation T290DepthStencil
- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLDepthStencilDescriptor *)d
{
	if (!(self = [super initWithDevice:device])) return nil;
	self.label = d.label;
	_depthFunc = t290_compare(d.depthCompareFunction);
	_depthWrite = d.depthWriteEnabled;
	_depthTest = d.depthCompareFunction != MTLCompareFunctionAlways || d.depthWriteEnabled;
	MTLStencilDescriptor *f[2] = {d.frontFaceStencil, d.backFaceStencil};
	for (int i = 0; i < 2; i++) {
		MTLStencilDescriptor *s = f[i];
		if (!s) {
			_face[i].func = GL_ALWAYS; _face[i].fail = _face[i].zfail = _face[i].pass = GL_KEEP;
			_face[i].read = _face[i].write = 0xff;
			continue;
		}
		_stencil = YES;
		_face[i].func = t290_compare(s.stencilCompareFunction);
		_face[i].fail = gl_stencil_op(s.stencilFailureOperation);
		_face[i].zfail = gl_stencil_op(s.depthFailureOperation);
		_face[i].pass = gl_stencil_op(s.depthStencilPassOperation);
		_face[i].read = s.readMask;
		_face[i].write = s.writeMask;
	}
	return self;
}
@end

/* ------------------------------------------------------------------ events, fences */

@implementation T290Event {
	_Atomic uint64_t _value;
	NSMutableArray *_listeners;     /* @[value, listener, block] */
}
- (instancetype)initWithDevice:(T290Device *)device
{
	if ((self = [super initWithDevice:device])) _listeners = [NSMutableArray new];
	return self;
}
- (uint64_t)signaledValue { return atomic_load(&_value); }
- (void)setSignaledValue:(uint64_t)v
{
	atomic_store(&_value, v);
	NSArray *fire;
	@synchronized(_listeners) {
		NSIndexSet *due = [_listeners indexesOfObjectsPassingTest:^BOOL(NSArray *l, NSUInteger i, BOOL *stop) {
			(void)i; (void)stop;
			return [l[0] unsignedLongLongValue] <= v;
		}];
		fire = [_listeners objectsAtIndexes:due];
		[_listeners removeObjectsAtIndexes:due];
	}
	for (NSArray *l in fire) {
		MTLSharedEventListener *listener = l[1];
		MTLSharedEventNotificationBlock block = l[2];
		dispatch_async(listener.dispatchQueue, ^{ block(self, v); });
	}
}
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block
{
	if (atomic_load(&_value) >= value) {
		uint64_t v = atomic_load(&_value);
		dispatch_async(listener.dispatchQueue, ^{ block(self, v); });
		return;
	}
	@synchronized(_listeners) { [_listeners addObject:@[@(value), listener, [block copy]]]; }
}
- (MTLSharedEventHandle *)newSharedEventHandle { t290_log("T290Metal: shared event handle unsupported"); return nil; }
@end

@implementation T290Fence
@end
