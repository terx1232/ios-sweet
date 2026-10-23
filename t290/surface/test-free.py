"""Compile the actual kernel release path; busy buffers must remain mapped."""
import pathlib,sys,tempfile,subprocess
s=pathlib.Path(sys.argv[1]).read_text()
a=s.index('bool\nSweetGPUUserClient::release_buffer(')
z=s.index('void\nSweetGPUUserClient::free(',a)
stub=r'''
#include <stdint.h>
#include <stddef.h>
#include <assert.h>
#include <stdio.h>
static unsigned unmapped,freed,budget,completed,released,surface_released,retained,terminated;
static bool finished;
static uint32_t sweet_gpu_last_submit(){return 42;}
static uint32_t sweet_gpu_fence(){return finished?42:41;}
static int sweet_gpu_wait(uint32_t seq,unsigned ms){assert(seq==42&&ms==5000);return finished?0:-1;}
static void sweet_gpu_unmap(uint64_t,uint64_t){++unmapped;}
static void sweet_gpu_va_free(uint64_t,uint64_t){++freed;}
static void sweet_graphics_release(uint64_t bytes){budget+=bytes;}
template<class... A> static void IOLog(const char*,A...){}
struct MD {void complete(){++completed;} void release(){++released;}};
struct Surface {void release(){++surface_released;}};
using IOReturn=int;
static const int kIOReturnSuccess=0;
static void IOLockLock(void*){}
static void IOLockUnlock(void*){}
#define SWEET_GPU_MAX_BUFFERS 4
#define OSSafeReleaseNULL(p) do{if(p){p->release();p=nullptr;}}while(0)
struct SweetGPUUserClient {
 struct Buffer {MD *md;Surface *surface;uint64_t gpuaddr,size;uintptr_t kva;bool imported;uint32_t pending;};
 Buffer fBuf[4]={};uint32_t fPrepared[4]={},fNumPrepared=0;void *fLock=nullptr;bool fQuarantined=false;
 void retain(){++retained;} void terminate(){++terminated;}
 bool release_buffer(uint32_t);
 IOReturn clientClose();
};
'''
tests=r'''
int main(){
 SweetGPUUserClient c;MD md;Surface surf;
 c.fBuf[0]={&md,nullptr,0x10000000,4096,0,false,42};
 c.fPrepared[0]=0;c.fPrepared[1]=2;c.fNumPrepared=2;
 finished=false;assert(!c.release_buffer(0));
 assert(c.fBuf[0].md==&md && c.fNumPrepared==2);
 assert(!unmapped&&!freed&&!budget&&!released);
 finished=true;assert(c.release_buffer(0));
 assert(unmapped==1&&freed==1&&budget==4096&&released==1&&!completed);
 assert(c.fNumPrepared==1&&c.fPrepared[0]==2&&!c.fBuf[0].md);
 assert(c.release_buffer(0)&&unmapped==1);
 c.fBuf[1]={&md,&surf,0x10100000,8192,0,true,42};
 assert(c.release_buffer(1));
 assert(completed==1&&surface_released==1&&budget==4096&&released==2);
 c.fBuf[3]={&md,nullptr,0x10200000,4096,0,false,42};
 finished=false;assert(c.clientClose()==0&&c.fQuarantined&&retained==1&&terminated==1);
 assert(c.fBuf[3].md==&md&&released==2&&unmapped==2);
 assert(c.clientClose()==0&&retained==1&&terminated==2);
 finished=true;assert(c.clientClose()==0&&!c.fBuf[3].md&&released==3&&unmapped==3);
 puts("PASS actual release/close: busy memory retained, completed memory released, imports, prepared handles, timed-out close retained once");
}
'''
with tempfile.TemporaryDirectory(prefix='t290-free-') as t:
 p=pathlib.Path(t); (p/'test.cpp').write_text(stub+s[a:z]+tests)
 subprocess.run(['clang++','-std=c++17','-O1','-fsanitize=address,undefined','-no-pie',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
