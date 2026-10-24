/*
 * t290gputests: the backboardd guard test of t290launch (--test). Runs
 * /usr/bin/eagltest and returns its status, so the GLES bridge gate is
 * unchanged. Before that, once per marker (/private/var/tmp/t290mtltest.done
 * absent), runs the Metal driver test /usr/bin/t290mtltest /usr/lib/T290Metal
 * with a 180 s limit; its result never affects the gate. Both run before
 * backboardd, so the GPU has a single client at a time. Kernel log lines
 * through SweetGPU selector 7.
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

/* exit status, or -1 if it could not run / was killed */
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
	const char *marker = "/private/var/tmp/t290mtltest.done";
	if (access(marker, F_OK) != 0 && access("/usr/bin/t290mtltest", X_OK) == 0) {
		int fd = open(marker, O_WRONLY | O_CREAT, 0644);     /* once, even if it crashes the boot */
		if (fd >= 0)
			close(fd);
		klog("t290gputests: running t290mtltest");
		char *mt[] = {"/usr/bin/t290mtltest", "/usr/lib/T290Metal", NULL};
		int r = run(mt, 180);
		snprintf(msg, sizeof(msg), "t290gputests: t290mtltest exit %d (%s)", r,
		    r == 0 ? "PASS" : r == -2 ? "TIMEOUT, killed" : "FAIL");
		klog(msg);
	}
	char *eg[] = {"/usr/bin/eagltest", NULL};
	int r = run(eg, 0);
	snprintf(msg, sizeof(msg), "t290gputests: eagltest exit %d", r);
	klog(msg);
	return r;
}
