/* T290MetalDevice: the principal class of T290Metal.bundle. Metal creates it
 * with -initWithAcceleratorPort:options: for the kernel's IOAcceleratorES
 * service (MetalPluginClassName); tests create it directly. */
#import "t290mtl.h"
#include <objc/runtime.h>

@interface T290Buffer (Init)
- (instancetype)initWithDevice:(T290Device *)device length:(NSUInteger)length options:(MTLResourceOptions)options
                         bytes:(void *)bytes deallocator:(void (^)(void *, NSUInteger))dealloc;
@end
@interface T290Texture (Init)
- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLTextureDescriptor *)d
                       surface:(IOSurfaceRef)surface plane:(NSUInteger)plane;
@end
@interface T290Sampler (Init)
- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLSamplerDescriptor *)d;
@end
@interface T290DepthStencil (Init)
- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLDepthStencilDescriptor *)d;
@end
@interface T290RenderPipeline (Init)
- (instancetype)initWithDevice:(T290Device *)device descriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error;
@end
@interface T290ComputePipeline (Init)
- (instancetype)initWithDevice:(T290Device *)device function:(T290Function *)f error:(NSError **)error;
@end

@implementation T290CommandQueue
- (id<MTLCommandBuffer>)commandBuffer { return [[T290CommandBuffer alloc] initWithQueue:self]; }
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)d { (void)d; return [self commandBuffer]; }
- (void)insertDebugCaptureBoundary {}
/* SPI CoreAnimation sets on its queues; completion handlers already run on
 * a global queue */
- (void)setSubmissionQueue:(dispatch_queue_t)q { (void)q; }
- (void)setCompletionQueue:(dispatch_queue_t)q { (void)q; }
@end

/*
 * Fallback to CoreAnimation's GLES renderer (no Metal device):
 *   /private/var/tmp/t290metal.off     set by hand (SD transfer) to disable
 *   /private/var/tmp/t290metal.failed  written by t290gputests when mtltest fails
 *   backboardd crash loop: every start increments t290metal.backboardd, a
 *   start that lives 90 s resets it; at 3 the device is refused.
 * mtltest itself (getprogname t290mtltest) is never refused.
 */
#define T290_FLAG_DIR "/private/var/tmp/"
static BOOL t290_metal_check(void);
static BOOL t290_metal_allowed(void)
{
	static dispatch_once_t once;
	static BOOL allowed;
	dispatch_once(&once, ^{ allowed = t290_metal_check(); });       /* one count per process */
	return allowed;
}
/* Processes that may get the device: backboardd (CoreAnimation's render
 * server) and the tests; others get nil and keep their non-Metal paths
 * (mediaserverd and contextstored aborted on the first Metal boot). More
 * names, one per line, in /private/var/tmp/t290metal.allow. */
static BOOL process_allowed(void)
{
	const char *me = getprogname();
	if (!strcmp(me, "backboardd") || !strcmp(me, "t290mtltest") || !strcmp(me, "t290mtlprobe")) return YES;
	FILE *f = fopen(T290_FLAG_DIR "t290metal.allow", "r");
	char line[128];
	BOOL yes = NO;
	while (f && fgets(line, sizeof(line), f)) {
		line[strcspn(line, "\r\n")] = 0;
		if (!strcmp(line, me)) yes = YES;
	}
	if (f) fclose(f);
	return yes;
}

static BOOL t290_metal_check(void)
{
	if (!process_allowed()) {
		t290_log("T290Metal: no device for %s (not in the allow list)", getprogname());
		return NO;
	}
	t290_install_crash_log();
	if (!strcmp(getprogname(), "t290mtltest")) return YES;
	if (!access(T290_FLAG_DIR "t290metal.off", F_OK) || !access(T290_FLAG_DIR "t290metal.failed", F_OK)) {
		t290_log("T290Metal: disabled by %s in %s", access(T290_FLAG_DIR "t290metal.off", F_OK) ? "t290metal.failed" : "t290metal.off",
		    getprogname());
		return NO;
	}
	if (strcmp(getprogname(), "backboardd")) return YES;
	const char *counter = T290_FLAG_DIR "t290metal.backboardd";
	int n = 0;
	FILE *f = fopen(counter, "r");
	if (f) { if (fscanf(f, "%d", &n) != 1) n = 0; fclose(f); }
	if (n >= 3) {
		t290_log("T290Metal: backboardd failed %d starts on Metal: using GLES (delete %s to retry)", n, counter);
		return NO;
	}
	if ((f = fopen(counter, "w"))) { fprintf(f, "%d\n", n + 1); fclose(f); }
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		FILE *g = fopen(counter, "w");
		if (g) { fprintf(g, "0\n"); fclose(g); }
		t290_log("T290Metal: backboardd stable on Metal for 90 s");
	});
	return YES;
}

@implementation T290MetalDevice {
	NSString *_name;
}

static T290MetalDevice *shared_device;

- (instancetype)initWithAcceleratorPort:(mach_port_t)port options:(NSDictionary *)options
{
	(void)port; (void)options;
	if (!(self = [super init])) return nil;
	t290_log("T290Metal: device init in %s pid %d", getprogname(), getpid());
	if (!t290_metal_allowed()) return nil;
	if (!t290_gl_start()) return nil;
	t290_hook_constant_values();
	_name = [NSString stringWithFormat:@"T290 %s", t290_caps.renderer];
	shared_device = self;
	return self;
}
- (instancetype)init { return [self initWithAcceleratorPort:0 options:nil]; }
/* other initializers Metal.framework / IOGPU.framework know */
- (instancetype)initWithAcceleratorPort:(mach_port_t)port { return [self initWithAcceleratorPort:port options:nil]; }
- (instancetype)initWithAcceleratorPort:(mach_port_t)port simultaneousInstances:(BOOL)multi
{
	(void)multi;
	return [self initWithAcceleratorPort:port options:nil];
}

/* Discovery diagnostics: what does Metal ask the plugin class? Its SPI
 * protocols are added at load (t290_loaded) when the runtime has them. */
static unsigned class_queries;
+ (BOOL)conformsToProtocol:(Protocol *)p
{
	BOOL yes = [super conformsToProtocol:p];
	if (class_queries++ < 64) t290_log("T290Metal: +conformsToProtocol:%s -> %d", protocol_getName(p), yes);
	return yes;
}
+ (BOOL)instancesRespondToSelector:(SEL)sel
{
	BOOL yes = [super instancesRespondToSelector:sel];
	if (class_queries++ < 64) t290_log("T290Metal: +instancesRespondToSelector:%s -> %d", sel_getName(sel), yes);
	return yes;
}
+ (BOOL)respondsToSelector:(SEL)sel
{
	BOOL yes = [super respondsToSelector:sel];
	if (class_queries++ < 64) t290_log("T290Metal: +respondsToSelector:%s -> %d", sel_getName(sel), yes);
	return yes;
}
+ (BOOL)isSubclassOfClass:(Class)c
{
	BOOL yes = [super isSubclassOfClass:c];
	if (class_queries++ < 64) t290_log("T290Metal: +isSubclassOfClass:%s -> %d", class_getName(c), yes);
	return yes;
}
+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
	t290_log("T290Metal: +allocWithZone in %s", getprogname());
	return [super allocWithZone:zone];
}

/* ---- identity and limits */
- (NSString *)name { return _name; }
- (NSString *)familyName { return @"Apple3"; }
- (NSString *)productName { return @"T290 Adreno 504"; }
- (uint64_t)registryID { return 0x7290; }
- (MTLSize)maxThreadsPerThreadgroup { return MTLSizeMake(512, 512, 64); }
- (BOOL)isLowPower { return YES; }
- (BOOL)isHeadless { return NO; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return YES; }
- (uint64_t)recommendedMaxWorkingSetSize { return 512ull << 20; }
- (BOOL)isDepth24Stencil8PixelFormatSupported { return NO; }
- (MTLReadWriteTextureTier)readWriteTextureSupport { return MTLReadWriteTextureTierNone; }
- (MTLArgumentBuffersTier)argumentBuffersSupport { return MTLArgumentBuffersTier1; }
- (BOOL)areRasterOrderGroupsSupported { return NO; }
- (BOOL)supports32BitFloatFiltering { return NO; }
- (BOOL)supports32BitMSAA { return NO; }
- (BOOL)supportsQueryTextureLOD { return NO; }
- (BOOL)supportsBCTextureCompression { return NO; }
- (BOOL)supportsPullModelInterpolation { return NO; }
- (BOOL)areBarycentricCoordsSupported { return NO; }
- (BOOL)supportsShaderBarycentricCoordinates { return NO; }
- (NSUInteger)currentAllocatedSize { return 0; }
- (NSUInteger)maxThreadgroupMemoryLength { return 16384; }
- (NSUInteger)maxArgumentBufferSamplerCount { return 16; }
- (BOOL)areProgrammableSamplePositionsSupported { return NO; }
- (NSUInteger)sparseTileSizeInBytes { return 0; }
- (NSUInteger)maxBufferLength { return 256u << 20; }
- (NSArray *)counterSets { return @[]; }
- (BOOL)supportsDynamicLibraries { return NO; }
- (BOOL)supportsRenderDynamicLibraries { return NO; }
- (BOOL)supportsRaytracing { return NO; }
- (BOOL)supportsFunctionPointers { return NO; }
- (BOOL)supportsFunctionPointersFromRender { return NO; }
- (BOOL)supportsRaytracingFromRender { return NO; }
- (BOOL)supportsPrimitiveMotionBlur { return NO; }
- (BOOL)supportsFamily:(MTLGPUFamily)f
{
	BOOL yes = f == MTLGPUFamilyApple1 || f == MTLGPUFamilyApple2 || f == MTLGPUFamilyApple3 ||
	    f == MTLGPUFamilyCommon1 || f == MTLGPUFamilyCommon2;
	static unsigned n;
	if (n++ < 16) t290_log("T290Metal: supportsFamily %ld -> %d", (long)f, yes);
	return yes;
}
- (BOOL)supportsFeatureSet:(MTLFeatureSet)fs
{
	/* iOS GPU families 1-3 (A7-A9), versions 1-4 */
	BOOL yes = fs <= MTLFeatureSet_iOS_GPUFamily3_v4 && fs != (MTLFeatureSet)6;
	static unsigned n;
	if (n++ < 16) t290_log("T290Metal: supportsFeatureSet %lu -> %d", (unsigned long)fs, yes);
	return yes;
}
- (BOOL)supportsTextureSampleCount:(NSUInteger)n { return n == 1; }
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)n { return n == 1; }
- (BOOL)supportsCounterSampling:(MTLCounterSamplingPoint)p { (void)p; return NO; }
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)f { (void)f; return 256; }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)f { (void)f; return 256; }
- (void)getDefaultSamplePositions:(MTLSamplePosition *)p count:(NSUInteger)n
{
	for (NSUInteger i = 0; i < n; i++) p[i] = MTLSamplePositionMake(0.5f, 0.5f);
}
- (NSUInteger)sparseTileSizeInBytesForSparsePageSize:(MTLSparsePageSize)s { (void)s; return 0; }

/* ---- queues */
- (id<MTLCommandQueue>)newCommandQueue { return [[T290CommandQueue alloc] initWithDevice:(T290Device *)self]; }
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)n { (void)n; return [self newCommandQueue]; }

/* ---- buffers */
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [[T290Buffer alloc] initWithDevice:(T290Device *)self length:length options:options bytes:NULL deallocator:nil];
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options
{
	return [[T290Buffer alloc] initWithDevice:(T290Device *)self length:length options:options bytes:(void *)bytes deallocator:nil];
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options
                              deallocator:(void (^)(void *, NSUInteger))dealloc
{
	return [[T290Buffer alloc] initWithDevice:(T290Device *)self length:length options:options bytes:bytes
	                              deallocator:dealloc ?: ^(void *p, NSUInteger n) { (void)p; (void)n; }];
}
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)o
{
	(void)o;
	MTLSizeAndAlign s = {(length + 255) & ~(NSUInteger)255, 256};
	return s;
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)d
{
	const struct t290_format *f = t290_format(d.pixelFormat);
	NSUInteger n = d.width * d.height * d.depth * d.arrayLength * (f ? f->bytes : 4) * 2;
	MTLSizeAndAlign s = {(n + 4095) & ~(NSUInteger)4095, 4096};
	return s;
}
- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)d
{
	t290_log("T290Metal: heaps unsupported (size %lu)", (unsigned long)d.size);
	return nil;
}

/* ---- textures */
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d
{
	return [[T290Texture alloc] initWithDevice:(T290Device *)self descriptor:d surface:NULL plane:0];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)d iosurface:(IOSurfaceRef)s plane:(NSUInteger)plane
{
	if (!s) return nil;
	return [[T290Texture alloc] initWithDevice:(T290Device *)self descriptor:d surface:s plane:plane];
}
- (id<MTLTexture>)newSharedTextureWithDescriptor:(MTLTextureDescriptor *)d { return [self newTextureWithDescriptor:d]; }
- (id<MTLTexture>)newSharedTextureWithHandle:(MTLSharedTextureHandle *)h
{
	(void)h;
	t290_log("T290Metal: shared texture handles unsupported");
	return nil;
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)d
{
	return [[T290Sampler alloc] initWithDevice:(T290Device *)self descriptor:d];
}
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)d
{
	return [[T290DepthStencil alloc] initWithDevice:(T290Device *)self descriptor:d];
}

/* ---- libraries */
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error
{
	NSMutableData *copy = [NSMutableData dataWithCapacity:dispatch_data_get_size(data)];
	dispatch_data_apply(data, ^bool(dispatch_data_t r, size_t o, const void *b, size_t n) {
		(void)r; (void)o;
		[copy appendBytes:b length:n];
		return true;
	});
	return [[T290Library alloc] initWithDevice:(T290Device *)self data:copy error:error];
}
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)path error:(NSError **)error
{
	NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
	t290_log("T290Metal: library %s (%lu bytes)", path.UTF8String, (unsigned long)d.length);
	return d ? [[T290Library alloc] initWithDevice:(T290Device *)self data:d error:error] : nil;
}
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error { return [self newLibraryWithFile:url.path error:error]; }
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error
{
	NSString *path = [bundle pathForResource:@"default" ofType:@"metallib"];
	if (!path) {
		if (error) *error = t290_error(@"no default.metallib in %@", bundle.bundlePath);
		return nil;
	}
	return [self newLibraryWithFile:path error:error];
}
- (id<MTLLibrary>)newDefaultLibrary { return [self newDefaultLibraryWithBundle:[NSBundle mainBundle] error:nil]; }
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)s options:(MTLCompileOptions *)o error:(NSError **)error
{
	(void)s; (void)o;
	if (error) *error = t290_error(@"Metal source compilation is unsupported (%lu chars)", (unsigned long)s.length);
	return nil;
}
- (void)newLibraryWithSource:(NSString *)s options:(MTLCompileOptions *)o completionHandler:(MTLNewLibraryCompletionHandler)h
{
	NSError *e = nil;
	id<MTLLibrary> l = [self newLibraryWithSource:s options:o error:&e];
	h(l, e);
}

/* ---- pipelines */
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d error:(NSError **)error
{
	static unsigned traced;
	if (traced++ < 24) t290_log("T290Metal: render pipeline %s + %s", d.vertexFunction.name.UTF8String ?: "-",
	    d.fragmentFunction.name.UTF8String ?: "-");
	return [[T290RenderPipeline alloc] initWithDevice:(T290Device *)self descriptor:d error:error];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)o
                                                        reflection:(MTLAutoreleasedRenderPipelineReflection *)r error:(NSError **)error
{
	(void)o;
	if (r) *r = nil;
	return [self newRenderPipelineStateWithDescriptor:d error:error];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d completionHandler:(MTLNewRenderPipelineStateCompletionHandler)h
{
	NSError *e = nil;
	id<MTLRenderPipelineState> p = [self newRenderPipelineStateWithDescriptor:d error:&e];
	h(p, e);
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)o
                           completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)h
{
	(void)o;
	NSError *e = nil;
	id<MTLRenderPipelineState> p = [self newRenderPipelineStateWithDescriptor:d error:&e];
	h(p, nil, e);
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f error:(NSError **)error
{
	return [[T290ComputePipeline alloc] initWithDevice:(T290Device *)self function:(T290Function *)f error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)f options:(MTLPipelineOption)o
                                                        reflection:(MTLAutoreleasedComputePipelineReflection *)r error:(NSError **)error
{
	(void)o;
	if (r) *r = nil;
	return [self newComputePipelineStateWithFunction:f error:error];
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)f completionHandler:(MTLNewComputePipelineStateCompletionHandler)h
{
	NSError *e = nil;
	id<MTLComputePipelineState> p = [self newComputePipelineStateWithFunction:f error:&e];
	h(p, e);
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)f options:(MTLPipelineOption)o
                          completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)h
{
	(void)o;
	NSError *e = nil;
	id<MTLComputePipelineState> p = [self newComputePipelineStateWithFunction:f error:&e];
	h(p, nil, e);
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)o
                                                          reflection:(MTLAutoreleasedComputePipelineReflection *)r error:(NSError **)error
{
	(void)o;
	if (r) *r = nil;
	return [self newComputePipelineStateWithFunction:d.computeFunction error:error];
}
- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)o
                            completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)h
{
	(void)o;
	NSError *e = nil;
	id<MTLComputePipelineState> p = [self newComputePipelineStateWithFunction:d.computeFunction error:&e];
	h(p, nil, e);
}

/* ---- sync */
- (id<MTLFence>)newFence { return [[T290Fence alloc] initWithDevice:(T290Device *)self]; }
- (id<MTLEvent>)newEvent { return [[T290Event alloc] initWithDevice:(T290Device *)self]; }
- (id<MTLSharedEvent>)newSharedEvent { return [[T290Event alloc] initWithDevice:(T290Device *)self]; }
- (id<MTLSharedEvent>)newSharedEventWithHandle:(MTLSharedEventHandle *)h
{
	(void)h;
	t290_log("T290Metal: shared event handles unsupported");
	return nil;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithArguments:(NSArray<MTLArgumentDescriptor *> *)a
{
	t290_log("T290Metal: argument encoders unsupported (%lu arguments)", (unsigned long)a.count);
	return nil;
}

/* ---- diagnostics: what does the caller want that we do not have? */
- (BOOL)respondsToSelector:(SEL)sel
{
	BOOL yes = [super respondsToSelector:sel];
	if (!yes) t290_log("T290Metal: device lacks %s", sel_getName(sel));
	return yes;
}
T290_FORWARD_UNKNOWN
@end
