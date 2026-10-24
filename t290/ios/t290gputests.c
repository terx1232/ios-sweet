/*
 * t290gputests: the backboardd guard test of t290launch (--test). Runs
 * /usr/bin/eagltest and returns its status, so the GLES bridge gate is
 * unchanged. Before that it runs the Metal driver test
 * (/usr/bin/t290mtltest, 90 s limit) on every backboardd start: a failure
 * writes /private/var/tmp/t290metal.failed, which makes T290Metal refuse
 * the device so CoreAnimation stays on GLES; a pass removes it. The driver
 * lives in /System/Library/Extensions/T290Metal.bundle (or /usr/lib/T290Metal
 * as a bare Mach-O). Both tests run before backboardd, so the GPU has a
 * single client at a time. Kernel log lines through SweetGPU selector 7.
 */
#include <mach/mach.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>

extern char **environ;
extern const mach_port_t kIOMasterPortDefault;
CFMutableDictionaryRef IOServiceMatching(const char *name);
mach_port_t IOServiceGetMatchingService(mach_port_t main, CFDictionaryRef matching);
kern_return_t IOServiceOpen(mach_port_t service, mach_port_t task, uint32_t type, mach_port_t *conn);
kern_return_t IOServiceClose(mach_port_t conn);
kern_return_t IOObjectRelease(mach_port_t object);
kern_return_t IOConnectCallStructMethod(mach_port_t conn, uint32_t sel, const void *in, size_t inSize,
    void *out, size_t *outSize);

static void
klog(const char *msg)
{
	mach_port_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("SweetGPU"));
	mach_port_t conn = 0;
	if (!svc)
		return;
	if (IOServiceOpen(svc, mach_task_self(), 0, &conn) == KERN_SUCCESS) {
		IOConnectCallStructMethod(conn, 7, msg, strlen(msg), NULL, NULL);
		IOServiceClose(conn);
	}
	IOObjectRelease(svc);
}

/* exit status, or -1 if it could not run / was killed, -2 on timeout */
static int
run(char *const argv[], int limit)
{
	pid_t child;
	int status = 0;
	if (posix_spawn(&child, argv[0], NULL, NULL, argv, environ))
		return -1;
	time_t start = time(NULL);
	for (;;) {
		pid_t w = waitpid(child, &status, limit ? WNOHANG : 0);
		if (w == child)
			break;
		if (w < 0 && errno != EINTR)
			return -1;
		if (limit && time(NULL) - start > limit) {
			kill(child, SIGKILL);
			waitpid(child, &status, 0);
			return -2;
		}
		if (limit)
			usleep(200000);
	}
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int
main(void)
{
	char msg[256];
	const char *failed = "/private/var/tmp/t290metal.failed";
	char *bundle = access("/System/Library/Extensions/T290Metal.bundle/T290Metal", F_OK) == 0 ?
	    "/System/Library/Extensions/T290Metal.bundle" : "/usr/lib/T290Metal";
	if (access("/usr/bin/t290mtltest", X_OK) == 0) {
		char *mt[] = {"/usr/bin/t290mtltest", bundle, NULL};
		int r = run(mt, 90);
		if (r == 0) {
			unlink(failed);
		} else {
			int fd = open(failed, O_WRONLY | O_CREAT, 0644);
			if (fd >= 0)
				close(fd);
		}
		snprintf(msg, sizeof(msg), "t290gputests: t290mtltest %s exit %d (%s)", bundle, r,
		    r == 0 ? "PASS, Metal allowed" : r == -2 ? "TIMEOUT, Metal disabled" : "FAIL, Metal disabled");
		klog(msg);
	}
	char *eg[] = {"/usr/bin/eagltest", NULL};
	int r = run(eg, 0);
	snprintf(msg, sizeof(msg), "t290gputests: eagltest exit %d", r);
	klog(msg);
	return r;
}
