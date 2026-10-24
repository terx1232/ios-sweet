/* T290Metal: Metal driver for the SM-T290 (Adreno 504) on Mesa GLES 3.1.
 *
 * Every GL call runs on one worker thread (t290_gl_sync/async). Encoders record
 * commands as blocks; -commit hands them to the worker in submission order.
 * Shaders: AIR bitcode from metallibs, specialized and translated to GLSL by
 * t290/metal/compiler (airglc) when a pipeline is created.
 *
 * Orientation: Metal clip space is drawn with y negated (in the translated
 * vertex shader), so GL texture memory rows have Metal's order (row 0 = top).
 * Viewports and scissors therefore keep Metal's y; winding flips. */
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "t290gl.h"

#define T290_MAX_BUFFERS 31
#define T290_MAX_TEXTURES 31
#define T290_MAX_SAMPLERS 16

void t290_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
BOOL t290_gl_start(void);
void t290_gl_sync(void (^block)(void));
void t290_gl_async(void (^block)(void));
BOOL t290_on_gl_thread(void);
void *t290_mesa_image(uint32_t surface, uint32_t w, uint32_t h, uint32_t stride, uint32_t offset, uint32_t fourcc);
void t290_mesa_image_destroy(void *image);

struct t290_caps {
	GLint uboAlign, tboAlign, maxTboTexels, maxUnits, maxVertexAttribs;
	BOOL tbo, drawBuffersIndexed, bgraRead;
	char renderer[128], version[128];
};
extern struct t290_caps t290_caps;

/* Streaming GL buffer for per-draw uploads (vertex data, UBO/TBO windows). GL thread. */
GLuint t290_ring_buffer(void);
GLintptr t290_ring_put(const void *data, size_t size, size_t align);

/* pixel formats */
enum { T290_F_UNORM8, T290_F_FLOAT, T290_F_HALF, T290_F_UINT, T290_F_SINT, T290_F_DEPTH, T290_F_PACKED };
struct t290_format {
	MTLPixelFormat mtl;
	GLenum internal, format, type;
	uint8_t bytes;          /* per pixel, Metal layout */
	uint8_t comps;          /* components in Metal layout */
	uint8_t kind;
	uint8_t swapRB;         /* Metal BGRA, stored RGBA */
	uint8_t alphaOnly;      /* A8: stored in R */
	uint8_t depth, stencil;
	uint32_t fourcc;        /* IOSurface import (OSMesaT290CreateImage), 0: CPU copy */
};
const struct t290_format *t290_format(MTLPixelFormat f);
/* Metal pixels -> GL upload layout (RGBA order, tight) and back. */
void t290_pixels_to_gl(const struct t290_format *f, const void *src, size_t srcRow, void *dst, size_t w, size_t h);
void t290_pixels_from_gl(const struct t290_format *f, const void *src, void *dst, size_t dstRow, size_t w, size_t h);

NSError *t290_error(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
GLenum t290_compare(MTLCompareFunction f);

@class T290MetalDevice;
#define T290Device T290MetalDevice

/* MTLFunctionConstantValues does not expose what was set: the driver records
 * it (index or name -> NSArray of doubles). */
void t290_hook_constant_values(void);
NSDictionary *t290_constant_values(MTLFunctionConstantValues *values);

@interface T290Object : NSObject
@property (nullable, copy, atomic) NSString *label;
@property (readonly) id<MTLDevice> device;
- (instancetype)initWithDevice:(T290Device *)device;
@end

/* Metal accepts a plugin device class only if it is a subclass of its
 * private base class (+isSubclassOfClass:_MTLDevice; seen on the tablet).
 * Exported by Metal.framework (Metal.tbd); its ivars are laid out at run time. */
@interface _MTLDevice : NSObject <MTLDevice>
@end

@interface T290MetalDevice : _MTLDevice
- (instancetype)initWithAcceleratorPort:(mach_port_t)port options:(NSDictionary *)options;
@end

@interface T290Buffer : T290Object <MTLBuffer> {
@public
	void *_bytes;
	NSUInteger _length;
	MTLResourceOptions _options;
}
@end

@interface T290Texture : T290Object <MTLTexture> {
@public
	GLuint _tex;
	GLenum _target;
	const struct t290_format *_fmt;
	MTLTextureType _type;
	NSUInteger _width, _height, _depth, _levels, _arrayLength, _samples;
	MTLTextureUsage _usage;
	MTLStorageMode _storage;
	IOSurfaceRef _surface;
	NSUInteger _plane;
	void *_image;           /* Mesa image of a directly imported IOSurface */
	BOOL _shadow;           /* IOSurface copied through the CPU */
	uint32_t _seed;
	BOOL _gpuDirty;         /* shadow written by the GPU, not yet copied back */
	T290Texture *_parent;   /* views */
	T290Buffer *_buffer;    /* linear textures */
	NSUInteger _bufferOffset, _bufferRow;
}
- (void)prepare;            /* GL thread: shadow upload before use */
- (void)rendered;           /* GL thread: the GPU wrote it */
- (void)writeBack;          /* GL thread: shadow -> IOSurface */
@end

@interface T290Sampler : T290Object <MTLSamplerState> {
@public
	GLuint _sampler;
}
@end

@interface T290DepthStencil : T290Object <MTLDepthStencilState> {
@public
	GLenum _depthFunc;
	BOOL _depthWrite, _depthTest, _stencil;
	struct { GLenum func, fail, zfail, pass; GLuint read, write; } _face[2]; /* front, back */
}
@end

@interface T290Library : T290Object <MTLLibrary>
- (instancetype)initWithDevice:(T290Device *)device data:(NSData *)data error:(NSError **)error;
@end

@interface T290Function : T290Object <MTLFunction> {
@public
	NSData *_bitcode;
	NSString *_name;
	MTLFunctionType _type;
	NSArray *_constants;            /* from airglc_constants */
	NSDictionary *_values;          /* NSNumber index -> NSArray<NSNumber> */
	__weak T290Library *_library;
}
@end

/* one compiled stage */
@interface T290Shader : NSObject {
@public
	NSString *glsl;
	NSDictionary *refl;
}
+ (T290Shader *)compile:(T290Function *)f error:(NSError **)error;
@end

enum { T290_STAGE_VERTEX, T290_STAGE_FRAGMENT, T290_STAGE_COMPUTE };
enum { T290_BIND_UBO, T290_BIND_TBO, T290_BIND_SSBO };
struct t290_binding {           /* buffer argument */
	uint8_t stage, kind, index;
	GLuint slot;                /* UBO/SSBO binding or texture unit */
	GLsizeiptr bytes;           /* UBO size */
};
struct t290_pair {              /* combined texture + sampler */
	uint8_t stage, texture;
	int16_t sampler;            /* argument index, or -1 - const sampler */
	GLuint unit;
	BOOL is3D;
};
struct t290_attrib {
	GLuint location;
	uint8_t buffer;
	GLint size;
	GLenum type;
	GLboolean normalized, integer;
	GLuint offset;
};

@interface T290Program : NSObject {
@public
	GLuint _program;
	struct t290_binding _bind[48];
	unsigned _nbind;
	struct t290_pair _pairs[32];
	unsigned _npairs;
	GLuint _fbUnit[8];          /* framebuffer-fetch copies, 0 = none */
	int8_t _fbInput[8];
	unsigned _nfb;
	GLuint _images[8];
	unsigned _nimages;
	GLint _rtHeight;
	GLuint _constSamplers[16];
	unsigned _nconstSamplers;
}
- (BOOL)linkStages:(NSArray<T290Shader *> *)shaders error:(NSError **)error;
@end

@interface T290RenderPipeline : T290Object <MTLRenderPipelineState> {
@public
	T290Program *_prog;
	struct t290_attrib _attribs[16];
	unsigned _nattribs;
	struct { NSUInteger stride; MTLVertexStepFunction step; NSUInteger rate; } _layouts[T290_MAX_BUFFERS];
	BOOL _hasVertexDescriptor;
	struct {
		BOOL blend;
		GLenum rgbOp, alphaOp, srcRGB, dstRGB, srcA, dstA;
		GLboolean mask[4];
		MTLPixelFormat format;
	} _color[8];
	unsigned _ncolor;
	MTLPixelFormat _depthFormat, _stencilFormat;
	BOOL _rasterEnabled, _alphaToCoverage;
}
@end

@interface T290ComputePipeline : T290Object <MTLComputePipelineState> {
@public
	T290Program *_prog;
	NSUInteger _threads;
}
- (T290Program *)programForSize:(MTLSize)size;
@end

@interface T290Event : T290Object <MTLSharedEvent>
@end

@interface T290Fence : T290Object <MTLFence>
@end

@interface T290CommandQueue : T290Object <MTLCommandQueue>
@end

@interface T290CommandBuffer : T290Object <MTLCommandBuffer> {
@public
	NSMutableArray *_commands;          /* blocks run on the GL thread */
	NSMutableSet *_written;             /* textures to write back on completion */
}
- (instancetype)initWithQueue:(T290CommandQueue *)queue;
- (void)record:(void (^)(void))command;
@end

@interface T290RenderEncoder : T290Object <MTLRenderCommandEncoder>
- (instancetype)initWithCommandBuffer:(T290CommandBuffer *)cb pass:(MTLRenderPassDescriptor *)pass;
@end

@interface T290BlitEncoder : T290Object <MTLBlitCommandEncoder>
- (instancetype)initWithCommandBuffer:(T290CommandBuffer *)cb;
@end

@interface T290ComputeEncoder : T290Object <MTLComputeCommandEncoder>
- (instancetype)initWithCommandBuffer:(T290CommandBuffer *)cb;
@end

/* GL helpers (GL thread) */
GLuint t290_fbo_for(T290Texture *t, NSUInteger level, NSUInteger slice, GLenum target);
void t290_read_texture(T290Texture *t, NSUInteger level, NSUInteger slice, MTLRegion r, void *dst, size_t row);
void t290_write_texture(T290Texture *t, NSUInteger level, NSUInteger slice, MTLRegion r, const void *src, size_t row);

/* Unimplemented selectors are logged and answered with 0 instead of raising. */
#define T290_FORWARD_UNKNOWN \
	- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { \
		NSMethodSignature *s = [super methodSignatureForSelector:sel]; \
		return s ?: [NSMethodSignature signatureWithObjCTypes:"@@:"]; \
	} \
	- (void)forwardInvocation:(NSInvocation *)inv { \
		t290_log("T290Metal: unimplemented -[%s %s]", object_getClassName(self), sel_getName(inv.selector)); \
		if (inv.methodSignature.methodReturnLength) { \
			char zero[64] = {0}; \
			if (inv.methodSignature.methodReturnLength <= sizeof(zero)) [inv setReturnValue:zero]; \
		} \
	}
