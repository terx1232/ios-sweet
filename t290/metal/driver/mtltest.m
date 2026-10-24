/* mtltest [BUNDLE]: standalone hardware test of T290Metal.bundle (phase 3).
 * Loads the bundle like Metal would (principal class, -initWithAcceleratorPort:
 * options:) and checks real pixels: clears, texture upload/readback, IOSurface
 * textures, blits, and draws with CoreAnimation's own shaders from
 * QuartzCore's default.metallib (translated on the device by airglc).
 * Exit 0 only if every check passes. Log: stdout and /private/var/tmp/t290mtltest.log. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurfaceRef.h>
#import <objc/runtime.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>

static int log_fd = -1, failures;

@interface NSObject (T290MetalPlugin)
- (id)initWithAcceleratorPort:(mach_port_t)port options:(NSDictionary *)options;
@end

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	char buf[1200];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
	va_end(ap);
	strcat(buf, "\n");
	fputs(buf, stdout);
	fflush(stdout);
	if (log_fd >= 0) write(log_fd, buf, strlen(buf));
}

static void check(BOOL ok, const char *what)
{
	say("%s %s", ok ? "PASS" : "FAIL", what);
	if (!ok) failures++;
}

static BOOL near(int a, int b) { return abs(a - b) <= 2; }

static id<MTLTexture> texture(id<MTLDevice> dev, MTLPixelFormat f, NSUInteger w, NSUInteger h)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	return [dev newTextureWithDescriptor:d];
}

static void clear(id<MTLCommandQueue> q, id<MTLTexture> t, MTLClearColor c)
{
	MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
	p.colorAttachments[0].texture = t;
	p.colorAttachments[0].loadAction = MTLLoadActionClear;
	p.colorAttachments[0].storeAction = MTLStoreActionStore;
	p.colorAttachments[0].clearColor = c;
	id<MTLCommandBuffer> cb = [q commandBuffer];
	[[cb renderCommandEncoderWithDescriptor:p] endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
}

static void test_basics(id<MTLDevice> dev, id<MTLCommandQueue> q)
{
	id<MTLBuffer> b = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
	memset(b.contents, 0x5a, 4096);
	check(b && ((uint8_t *)b.contents)[4095] == 0x5a, "buffer contents");

	id<MTLTexture> t = texture(dev, MTLPixelFormatBGRA8Unorm, 64, 32);
	uint8_t px[64 * 32 * 4], back[64 * 32 * 4];
	for (unsigned i = 0; i < sizeof(px); i++) px[i] = (uint8_t)(i * 7 + i / 256);
	[t replaceRegion:MTLRegionMake2D(0, 0, 64, 32) mipmapLevel:0 withBytes:px bytesPerRow:64 * 4];
	memset(back, 0, sizeof(back));
	[t getBytes:back bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 32) mipmapLevel:0];
	check(t && !memcmp(px, back, sizeof(px)), "BGRA8 replaceRegion/getBytes round trip");

	clear(q, t, MTLClearColorMake(0.25, 0.5, 0.75, 1.0));
	[t getBytes:back bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 32) mipmapLevel:0];
	say("  clear BGRA8 pixel %u %u %u %u (want 191 128 64 255)", back[0], back[1], back[2], back[3]);
	check(near(back[0], 191) && near(back[1], 128) && near(back[2], 64) && back[3] == 255 &&
	    near(back[sizeof(back) - 4], 191), "BGRA8 clear pass");

	id<MTLTexture> r8 = texture(dev, MTLPixelFormatR8Unorm, 16, 16);
	clear(q, r8, MTLClearColorMake(0.5, 0, 0, 1));
	uint8_t r[256];
	[r8 getBytes:r bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0];
	check(near(r[0], 128) && near(r[255], 128), "R8 clear pass");

	/* blit: copy a 16x8 corner of t into a fresh texture */
	id<MTLTexture> t2 = texture(dev, MTLPixelFormatBGRA8Unorm, 16, 8);
	clear(q, t2, MTLClearColorMake(0, 0, 0, 0));
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
	[bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(4, 4, 0) sourceSize:MTLSizeMake(16, 8, 1)
	          toTexture:t2 destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[bl endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	uint8_t c[16 * 8 * 4];
	[t2 getBytes:c bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, 16, 8) mipmapLevel:0];
	check(near(c[0], 191) && c[3] == 255 && near(c[sizeof(c) - 2], 64), "texture-to-texture blit");

	/* buffer -> texture */
	id<MTLBuffer> src = [dev newBufferWithLength:16 * 8 * 4 options:0];
	for (unsigned i = 0; i < 16 * 8; i++) ((uint32_t *)src.contents)[i] = 0xff102030u + i;
	cb = [q commandBuffer];
	bl = [cb blitCommandEncoder];
	[bl copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:64 sourceBytesPerImage:64 * 8 sourceSize:MTLSizeMake(16, 8, 1)
	         toTexture:t2 destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[bl endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	[t2 getBytes:c bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, 16, 8) mipmapLevel:0];
	check(!memcmp(c, src.contents, sizeof(c)), "buffer-to-texture blit");
}

static void test_iosurface(id<MTLDevice> dev, id<MTLCommandQueue> q)
{
	for (int aligned = 1; aligned >= 0; aligned--) {
		size_t w = aligned ? 256 : 100, h = 64, row = aligned ? w * 4 : w * 4 + 16;
		IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{
			(__bridge id)kIOSurfaceWidth: @(w), (__bridge id)kIOSurfaceHeight: @(h),
			(__bridge id)kIOSurfaceBytesPerElement: @4, (__bridge id)kIOSurfaceBytesPerRow: @(row),
			(__bridge id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
		});
		if (!s) { check(NO, "IOSurfaceCreate"); continue; }
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
		d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
		id<MTLTexture> t = [dev newTextureWithDescriptor:d iosurface:s plane:0];
		clear(q, t, MTLClearColorMake(1, 0, 0, 1));
		IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
		const uint8_t *p = IOSurfaceGetBaseAddress(s);
		const uint8_t *last = p + (h - 1) * IOSurfaceGetBytesPerRow(s) + (w - 1) * 4;
		say("  IOSurface %s: first %u %u %u %u last %u %u %u %u (want 0 0 255 255)", aligned ? "aligned" : "unaligned",
		    p[0], p[1], p[2], p[3], last[0], last[1], last[2], last[3]);
		BOOL ok = t && p[0] == 0 && p[2] == 255 && p[3] == 255 && last[2] == 255 && last[0] == 0;
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
		check(ok, aligned ? "IOSurface render target (direct import)" : "IOSurface render target (CPU copy)");
		CFRelease(s);
	}
}

/* std_vert0_lpf (position/texcoord/color, matrix in buffer 2) +
 * attachment_clear_frag_lpf (writes 0): a quad over the top-left quadrant of a
 * white target must leave exactly that quadrant at 0 - checks the AIR -> GLSL
 * path on the device, vertex fetch, uniform buffers and the y orientation. */
static void test_ca_shaders(id<MTLDevice> dev, id<MTLCommandQueue> q)
{
	NSError *e = nil;
	id<MTLLibrary> lib = [dev newLibraryWithFile:@"/System/Library/Frameworks/QuartzCore.framework/default.metallib" error:&e];
	check(lib != nil, "QuartzCore default.metallib");
	if (!lib) { say("  %s", e.localizedDescription.UTF8String); return; }
	say("  %lu functions", (unsigned long)lib.functionNames.count);
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"std_vert0_lpf"];
	pd.fragmentFunction = [lib newFunctionWithName:@"attachment_clear_frag_lpf"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
	vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
	vd.attributes[1].format = MTLVertexFormatFloat2; vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 0;
	vd.attributes[3].format = MTLVertexFormatFloat4; vd.attributes[3].offset = 24; vd.attributes[3].bufferIndex = 0;
	vd.layouts[0].stride = 40;
	pd.vertexDescriptor = vd;
	CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
	id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
	say("  pipeline in %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000);
	check(ps != nil, "pipeline std_vert0_lpf + attachment_clear_frag_lpf");
	if (!ps) { say("  %s", e.localizedDescription.UTF8String); return; }
	id<MTLTexture> t = texture(dev, MTLPixelFormatBGRA8Unorm, 64, 64);
	float v[4][10];
	float corners[4][2] = {{-1, 0}, {0, 0}, {-1, 1}, {0, 1}};       /* x in [-1,0], y in [0,1]: top-left */
	for (int i = 0; i < 4; i++) {
		float row[10] = {corners[i][0], corners[i][1], 0, 1, 0, 0, 1, 1, 1, 1};
		memcpy(v[i], row, sizeof(row));
	}
	float identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}, zero4[4] = {0};
	MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
	p.colorAttachments[0].texture = t;
	p.colorAttachments[0].loadAction = MTLLoadActionClear;
	p.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:p];
	[enc setRenderPipelineState:ps];
	[enc setVertexBytes:v length:sizeof(v) atIndex:0];
	[enc setVertexBytes:identity length:sizeof(identity) atIndex:2];
	[enc setVertexBytes:zero4 length:sizeof(zero4) atIndex:3];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[enc endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	uint8_t px[64 * 64 * 4];
	[t getBytes:px bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
	int bad = 0;
	for (int y = 0; y < 64; y++)
		for (int x = 0; x < 64; x++) {
			const uint8_t *q4 = px + (y * 64 + x) * 4;
			BOOL inside = x < 32 && y < 32;
			if (inside ? (q4[0] | q4[1] | q4[2] | q4[3]) != 0 : (q4[0] & q4[1] & q4[2] & q4[3]) != 255) bad++;
		}
	say("  quad: (8,8) %u %u %u %u  (40,8) %u %u %u %u  (8,40) %u %u %u %u; %d wrong pixels",
	    px[(8 * 64 + 8) * 4], px[(8 * 64 + 8) * 4 + 1], px[(8 * 64 + 8) * 4 + 2], px[(8 * 64 + 8) * 4 + 3],
	    px[(8 * 64 + 40) * 4], px[(8 * 64 + 40) * 4 + 1], px[(8 * 64 + 40) * 4 + 2], px[(8 * 64 + 40) * 4 + 3],
	    px[(40 * 64 + 8) * 4], px[(40 * 64 + 8) * 4 + 1], px[(40 * 64 + 8) * 4 + 2], px[(40 * 64 + 8) * 4 + 3], bad);
	check(bad == 0, "CA shaders draw the top-left quadrant");

	/* on-device specialization speed of the layer uber shaders */
	MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
	uint8_t zero = 0;
	BOOL no = NO;
	[cv setConstantValue:&zero type:MTLDataTypeUChar withName:@"fc_generic"];
	[cv setConstantValue:&no type:MTLDataTypeBool withName:@"fc_has_lut_tex"];
	t0 = CFAbsoluteTimeGetCurrent();
	MTLRenderPipelineDescriptor *fd = [MTLRenderPipelineDescriptor new];
	fd.vertexFunction = [lib newFunctionWithName:@"fixed_vert_lph_spc" constantValues:cv error:&e];
	fd.fragmentFunction = [lib newFunctionWithName:@"fixed_frag_lph_cpf" constantValues:cv error:&e];
	fd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	id<MTLRenderPipelineState> s = [dev newRenderPipelineStateWithDescriptor:fd error:&e];
	say("  fixed_vert_lph_spc + fixed_frag_lph_cpf: %s in %.0f ms%s%s", s ? "compiled" : "FAILED",
	    (CFAbsoluteTimeGetCurrent() - t0) * 1000, s ? "" : ": ", s ? "" : e.localizedDescription.UTF8String);
	check(s != nil, "uber shader specialization and link");
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		log_fd = open("/private/var/tmp/t290mtltest.log", O_WRONLY | O_CREAT | O_TRUNC, 0666);
		NSString *path = argc > 1 ? @(argv[1]) : @"/System/Library/Extensions/T290Metal.bundle";
		NSBundle *b = [NSBundle bundleWithPath:path];
		NSError *e = nil;
		if (![b loadAndReturnError:&e]) {
			say("FAIL load %s: %s", path.UTF8String, e.localizedDescription.UTF8String);
			return 2;
		}
		Class c = b.principalClass;
		say("mtltest: bundle %s, principal class %s", path.UTF8String, c ? class_getName(c) : "(none)");
		id<MTLDevice> dev = [(id)[c alloc] initWithAcceleratorPort:0 options:nil];
		check(dev != nil, "device");
		if (!dev) return 3;
		say("  device %s", dev.name.UTF8String);
		id<MTLCommandQueue> q = [dev newCommandQueue];
		test_basics(dev, q);
		test_iosurface(dev, q);
		test_ca_shaders(dev, q);
		say("mtltest: %d failure(s)", failures);
		return failures ? 1 : 0;
	}
}
