/* t290mtlprobe: why does Metal not create T290MetalDevice? Logs to the
 * kernel log (SweetGPU selector 7): the IOAcceleratorES node and its
 * properties, MTLCreateSystemDefaultDevice / MTLCopyAllDevices, whether the
 * bundle image got loaded, and a manual NSBundle load with its error. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <stdarg.h>

extern const mach_port_t kIOMasterPortDefault;
CFMutableDictionaryRef IOServiceMatching(const char *name);
mach_port_t IOServiceGetMatchingService(mach_port_t main, CFDictionaryRef matching);
kern_return_t IOServiceOpen(mach_port_t service, mach_port_t task, uint32_t type, mach_port_t *conn);
kern_return_t IOServiceClose(mach_port_t conn);
kern_return_t IOObjectRelease(mach_port_t object);
kern_return_t IOObjectGetClass(mach_port_t object, char *name);
CFTypeRef IORegistryEntryCreateCFProperty(mach_port_t entry, CFStringRef key, CFAllocatorRef a, uint32_t options);
kern_return_t IOConnectCallStructMethod(mach_port_t conn, uint32_t sel, const void *in, size_t inSize,
    void *out, size_t *outSize);

static void klog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void klog(const char *fmt, ...)
{
	char buf[900] = "t290mtlprobe: ";
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf + strlen(buf), sizeof(buf) - strlen(buf), fmt, ap);
	va_end(ap);
	mach_port_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetGPU"));
	mach_port_t conn = 0;
	if (svc && IOServiceOpen(svc, mach_task_self(), 0, &conn) == KERN_SUCCESS) {
		IOConnectCallStructMethod(conn, 7, buf, strlen(buf), NULL, NULL);
		IOServiceClose(conn);
	}
	if (svc) IOObjectRelease(svc);
	puts(buf);
}

static void images(const char *when)
{
	unsigned n = _dyld_image_count(), hits = 0;
	for (unsigned i = 0; i < n; i++) {
		const char *p = _dyld_get_image_name(i);
		if (p && (strstr(p, "T290Metal") || strstr(p, "IOGPU") || strstr(p, "AGX") || strstr(p, "/Metal."))) {
			klog("%s image %s", when, p);
			hits++;
		}
	}
	klog("%s: %u images, %u relevant", when, n, hits);
}

int main(void)
{
	@autoreleasepool {
		mach_port_t s = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOAcceleratorES"));
		char cls[128] = "?";
		if (s) IOObjectGetClass(s, cls);
		NSString *pn = s ? CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("MetalPluginName"), NULL, 0)) : nil;
		NSString *pc = s ? CFBridgingRelease(IORegistryEntryCreateCFProperty(s, CFSTR("MetalPluginClassName"), NULL, 0)) : nil;
		klog("IOAcceleratorES service %#x class %s MetalPluginName %s (%s) MetalPluginClassName %s", s, cls,
		    pn.description.UTF8String ?: "-", pn ? object_getClassName(pn) : "-", pc.description.UTF8String ?: "-");
		images("before");
		id<MTLDevice> d = MTLCreateSystemDefaultDevice();
		klog("MTLCreateSystemDefaultDevice -> %s %s", d ? object_getClassName(d) : "nil", d ? d.name.UTF8String : "");
		NSArray *(*copy_all)(void) = (NSArray *(*)(void))dlsym(RTLD_DEFAULT, "MTLCopyAllDevices");
		NSArray *all = copy_all ? copy_all() : nil;
		klog("MTLCopyAllDevices -> %lu", (unsigned long)all.count);
		for (id<MTLDevice> x in all) klog("  device %s %s", object_getClassName(x), x.name.UTF8String);
		images("after");
		klog("class T290MetalDevice %s", NSClassFromString(@"T290MetalDevice") ? "present" : "absent");
		if (!NSClassFromString(@"T290MetalDevice")) {
			NSBundle *b = [NSBundle bundleWithPath:@"/System/Library/Extensions/T290Metal.bundle"];
			NSError *e = nil;
			BOOL ok = [b loadAndReturnError:&e];
			klog("manual NSBundle %s load %d principal %s error %s", b ? "found" : "missing", ok,
			    b.principalClass ? class_getName(b.principalClass) : "-", e.description.UTF8String ?: "-");
		}
		if (s) IOObjectRelease(s);
	}
	return 0;
}
