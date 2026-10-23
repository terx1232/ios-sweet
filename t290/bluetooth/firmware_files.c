/* Pronto file-loader preflight, opt-in t290btfiles=1. Does not write device
 * memory or invoke PIL. Hash both files before any later DMA/authentication.
 * Expected files come from prepare_firmware.py; signed metadata is unchanged.
 */
#if defined(ARM64_BOARD_CONFIG_SWEET) && defined(SWEET_T290)
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/vnode.h>
#include <sys/vnode_internal.h>
#include <sys/fcntl.h>
#include <sys/uio.h>
#include <kern/thread.h>
#include <kern/clock.h>
#include <kern/sched_prim.h>
#include <IOKit/IOLib.h>
#include <libkern/crypto/sha2.h>
#include <pexpert/pexpert.h>

void sweet_t290_bt_files_start(void);
extern int sweet_t290_bt_pas6_supported(void);

static const struct {
    const char *path;
    unsigned size;
    uint8_t digest[32];
} files[] = {
    {"/usr/lib/wcnss-t290-memory.bin", 6574080,
     {0x3f,0xf1,0xec,0xc2,0x79,0xb4,0xb6,0x89,0x4c,0x1a,0x6f,0x60,0x7b,0xdb,0xc9,0xcb,
      0xc0,0xa4,0x28,0xa3,0xcd,0x25,0x5e,0x4c,0x05,0x5a,0x41,0x1f,0x8a,0x68,0x74,0x2e}},
    {"/usr/lib/wcnss-t290-auth.bin", 7324,
     {0x73,0xc9,0xcf,0x39,0x43,0x0f,0xb1,0x86,0x5c,0x93,0x42,0x15,0x1d,0xcb,0xa6,0x63,
      0x55,0xc5,0xf5,0x42,0xba,0x56,0x1f,0x0a,0x99,0x90,0x5b,0x84,0xcc,0x11,0x5f,0xaf}}
};

/* The metadata digest is 64 hexadecimal digits: keep it generated/verified
 * against the local manifest when this firmware version changes. */
static int check_file(unsigned index, void *buffer)
{
    vfs_context_t ctx = vfs_context_kernel();
    vnode_t vp = NULLVP;
    int err = vnode_open(files[index].path, FREAD, 0, 0, &vp, ctx);
    if (err) return err;
    struct vnode_attr attr;
    VATTR_INIT(&attr); VATTR_WANTED(&attr, va_data_size);
    err = vnode_getattr(vp, &attr, ctx);
    if (!err && (!VATTR_IS_SUPPORTED(&attr,va_data_size) || attr.va_data_size != files[index].size))
        err = EINVAL;
    SHA256_CTX hash;
    SHA256_Init(&hash);
    for (unsigned offset = 0; !err && offset < files[index].size;) {
        unsigned want = MIN(65536u, files[index].size - offset);
        int resid = 0;
        err = vn_rdwr(UIO_READ, vp, buffer, (int)want, offset, UIO_SYSSPACE,
            IO_NOAUTH, vfs_context_ucred(ctx), &resid, vfs_context_proc(ctx));
        if (resid) err = EIO;
        if (err) break;
        SHA256_Update(&hash, buffer, want);
        offset += want;
    }
    uint8_t digest[32];
    SHA256_Final(digest, &hash);
    if (!err && memcmp(digest, files[index].digest, sizeof(digest))) err = EINVAL;
    vnode_close(vp, FREAD, ctx);
    return err;
}

static void files_thread(__unused void *arg, __unused wait_result_t wr)
{
    /* Root mount and the existing SD file-transfer worker must finish first. */
    int channel;
    uint64_t deadline;
    clock_interval_to_deadline(60, NSEC_PER_SEC, &deadline);
    (void)assert_wait_deadline(&channel, THREAD_UNINT, deadline);
    thread_block(THREAD_CONTINUE_NULL);
    int supported = sweet_t290_bt_pas6_supported();
    if (supported != 1) {
        printf("SWEET BT: firmware preflight stopped: PAS6 unsupported/query failed\n");
        thread_terminate(current_thread());
        return;
    }
    void *buffer = IOMalloc(65536);
    if (!buffer) {
        printf("SWEET BT: firmware file buffer allocation failed\n");
    } else {
        int image = check_file(0, buffer), metadata = check_file(1, buffer);
        printf("SWEET BT: firmware files image=%d metadata=%d; no hardware load/authentication\n", image, metadata);
        bzero(buffer,65536);
        IOFree(buffer,65536);
    }
    thread_terminate(current_thread());
}

void sweet_t290_bt_files_start(void)
{
    int enable = 0;
    PE_parse_boot_argn("t290btfiles", &enable, sizeof(enable));
    if (!enable) return;
    thread_t thread;
    kern_return_t kr = kernel_thread_start(files_thread, NULL, &thread);
    if (kr == KERN_SUCCESS) thread_deallocate(thread);
    else printf("SWEET BT: firmware file worker start error=%d\n",kr);
}
#endif
