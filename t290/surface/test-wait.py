"""Run the actual GPU fence-wait function against a deterministic clock/fence."""
import pathlib,sys,subprocess,tempfile
s=pathlib.Path(sys.argv[1]).read_text();a=s.index('int\nsweet_gpu_wait(');z=s.index('/*\n * gfx3d',a)
prefix=r"""
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <assert.h>
static int gpu_up=1;
static uint64_t ticks,finish_at;
static uint32_t fence,ring_wptr,registers[32];
static volatile uint32_t *gpu_fence_cpu=&fence;
static uintptr_t gpu_cb=(uintptr_t)registers;
static uint32_t gpu_rd(unsigned x) {return 0;}
#define CP_RB_RPTR 0
#define RBBM_STATUS 0
#define NSEC_PER_MSEC 1000000
static uint64_t mach_absolute_time(void) {return ticks;}
static void clock_interval_to_deadline(unsigned ms, unsigned scale, uint64_t *d) {*d=ticks+(uint64_t)ms*1000;}
static void delay(unsigned us) {ticks+=us; if(finish_at && ticks>=finish_at)fence=100;}
static void IOSleep(unsigned ms) {ticks+=(uint64_t)ms*1000; if(finish_at && ticks>=finish_at)fence=100;}
"""
tests=r"""
int main(void) {
 fence=10; assert(!sweet_gpu_wait(10,0) && ticks==0);
 fence=0; assert(sweet_gpu_wait(11,0)==-1 && ticks==0);
 ticks=0;finish_at=5000;assert(!sweet_gpu_wait(12,100) && ticks>=5000 && ticks<10000);
 ticks=0;finish_at=0;fence=0;assert(sweet_gpu_wait(13,UINT32_MAX)==-1);
 assert(ticks>=5000000 && ticks<5002000);
 fence=0;assert(!sweet_gpu_wait(UINT32_MAX,0));
 gpu_up=0;assert(sweet_gpu_wait(1,10)==-1);
 puts("PASS actual GPU wait: completion, nonblocking timeout, delayed fence, finite infinite-request cap and sequence wrap");
}
"""
with tempfile.TemporaryDirectory(prefix='t290-wait-') as d:
 c=pathlib.Path(d)/'wait.c';exe=pathlib.Path(d)/'wait';c.write_text(prefix+s[a:z]+tests)
 subprocess.run(['clang','-std=c11','-O1','-fsanitize=address,undefined','-fno-pie','-no-pie',str(c),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
