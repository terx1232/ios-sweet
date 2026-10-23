/* SM-T290: feed measured gravity into backboardd's normal orientation manager.
 * Exact iPadOS 16.7 ABI checked at runtime. Never call its synchronous queue
 * entry from the HID input callback: one bounded worker job avoids lock cycles.
 */
#include "orientation_filter.h"
#include <objc/message.h>

#if TARGET_OS_IPHONE
static NSInteger (*t290_motion_original)(id, SEL, void *const *, id, id);
static uint32_t (*t290_motion_type)(const void *);
static double (*t290_motion_float)(const void *, uint32_t);
static uint64_t (*t290_motion_stamp)(const void *);
static uint64_t (*t290_motion_sender)(const void *);
static CFMutableDictionaryRef (*t290_motion_id_match)(uint64_t);
static CFTypeRef (*t290_motion_property)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t);
static Ivar t290_motion_manager;
static dispatch_queue_t t290_motion_queue;
static pthread_mutex_t t290_motion_lock = PTHREAD_MUTEX_INITIALIZER;
static T290OrientationFilter t290_motion_filter;
static bool t290_motion_pending;
static uint64_t t290_motion_known_sender;
static bool t290_motion_sender_ok;
static mach_timebase_info_data_t t290_motion_timebase;

static bool t290_motion_our_sensor(uint64_t sender)
{
    pthread_mutex_lock(&t290_motion_lock);
    if (sender == t290_motion_known_sender) {
        bool ok = t290_motion_sender_ok;
        pthread_mutex_unlock(&t290_motion_lock);
        return ok;
    }
    pthread_mutex_unlock(&t290_motion_lock);
    if (!sender) return false;
    mach_port_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                     t290_motion_id_match(sender));
    bool ok = false;
    if (service) {
        CFTypeRef product = t290_motion_property(service, CFSTR("Product"), kCFAllocatorDefault, 0);
        if (product) {
            ok = CFGetTypeID(product) == CFStringGetTypeID() &&
                 CFEqual(product, CFSTR("SM-T290 KXTJ3"));
            CFRelease(product);
        }
        IOObjectRelease(service);
    }
    pthread_mutex_lock(&t290_motion_lock);
    t290_motion_known_sender = sender; t290_motion_sender_ok = ok;
    pthread_mutex_unlock(&t290_motion_lock);
    if (ok) plog("t290motion: verified KXTJ3 sender %llu", sender);
    return ok;
}

static NSInteger t290_motion_process(id self, SEL cmd, void *const *eventp,
                                    id sender, id dispatcher)
{
    /* The original may replace/release *eventp. Read scalar values first. */
    bool accel = eventp && *eventp && t290_motion_type(*eventp) == 13;
    double x = 0, y = 0, z = 0;
    uint64_t stamp = 0, sender_id = 0;
    if (accel) {
        x = t290_motion_float(*eventp, 13U << 16);
        y = t290_motion_float(*eventp, (13U << 16) | 1);
        z = t290_motion_float(*eventp, (13U << 16) | 2);
        stamp = t290_motion_stamp(*eventp);
        sender_id = t290_motion_sender(*eventp);
    }
    NSInteger result = t290_motion_original(self, cmd, eventp, sender, dispatcher);
    if (!accel || __atomic_load_n(&t290_motion_pending, __ATOMIC_ACQUIRE) ||
        !t290_motion_our_sensor(sender_id)) return result;
    id manager = object_getIvar(self, t290_motion_manager);
    if (!manager) return result;
    uint64_t ns = (uint64_t)((double)stamp * t290_motion_timebase.numer /
                              t290_motion_timebase.denom);
    pthread_mutex_lock(&t290_motion_lock);
    int pose = 0;
    if (!__atomic_load_n(&t290_motion_pending, __ATOMIC_RELAXED)) {
        pose = t290_orientation_step(&t290_motion_filter, x, y, z, ns);
        if (pose) __atomic_store_n(&t290_motion_pending, true, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&t290_motion_lock);
    if (pose) {
        /* ARC retains manager until the job completes. At most one job can be
         * pending, even if backboardd's orientation queue stops responding. */
        dispatch_async(t290_motion_queue, ^{
            @autoreleasepool {
                @try {
                    ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(manager,
                        sel_registerName("updateDeviceOrientation:changeSource:"), pose, 1);
                    plog("t290motion: delivered measured orientation %d", pose);
                } @catch (NSException *exception) {
                    plog("t290motion: orientation delivery exception %s", exception.name.UTF8String);
                }
                __atomic_store_n(&t290_motion_pending, false, __ATOMIC_RELEASE);
            }
        });
    }
    return result;
}

static void t290_motion_install(void)
{
    if (strcmp(getprogname(), "backboardd")) return;
    Class input = objc_getClass("BKAccelerometerInterface");
    Class manager = objc_getClass("BKOrientationManager");
    Method process = class_getInstanceMethod(input, sel_registerName("processEvent:sender:dispatcher:"));
    Method update = class_getInstanceMethod(manager, sel_registerName("updateDeviceOrientation:changeSource:"));
    Ivar ivar = class_getInstanceVariable(input, "_lock_orientationManager");
    if (!process || !update || !ivar ||
        strcmp(method_getTypeEncoding(process), "q40@0:8N^^{__IOHIDEvent}16@24@32") ||
        strcmp(method_getTypeEncoding(update), "v32@0:8q16q24") ||
        ivar_getOffset(ivar) != 0x20 || strcmp(ivar_getTypeEncoding(ivar), "@\"BKOrientationManager\"")) {
        plog("t290motion: skipped, backboardd orientation ABI mismatch");
        return;
    }
#define T290_MOTION_LOAD(var, name) var = dlsym(RTLD_DEFAULT, name)
    T290_MOTION_LOAD(t290_motion_type, "IOHIDEventGetType");
    T290_MOTION_LOAD(t290_motion_float, "IOHIDEventGetFloatValue");
    T290_MOTION_LOAD(t290_motion_stamp, "IOHIDEventGetTimeStamp");
    T290_MOTION_LOAD(t290_motion_sender, "IOHIDEventGetSenderID");
    T290_MOTION_LOAD(t290_motion_id_match, "IORegistryEntryIDMatching");
    T290_MOTION_LOAD(t290_motion_property, "IORegistryEntryCreateCFProperty");
#undef T290_MOTION_LOAD
    if (!t290_motion_type || !t290_motion_float || !t290_motion_stamp ||
        !t290_motion_sender || !t290_motion_id_match || !t290_motion_property ||
        mach_timebase_info(&t290_motion_timebase) != KERN_SUCCESS || !t290_motion_timebase.denom) {
        plog("t290motion: skipped, required HID API unavailable");
        return;
    }
    t290_motion_manager = ivar;
    t290_motion_queue = dispatch_queue_create("org.sweet.t290.orientation", DISPATCH_QUEUE_SERIAL);
    if (!t290_motion_queue) return;
    t290_motion_original = (void *)method_getImplementation(process);
    method_setImplementation(process, (IMP)t290_motion_process);
    plog("t290motion: normal orientation manager bridge installed");
}
#else
static void t290_motion_install(void) { }
#endif
