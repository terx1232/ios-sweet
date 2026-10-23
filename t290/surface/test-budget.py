"""Compile the actual kernel reservation functions with atomic host adapters."""
import pathlib,subprocess,tempfile
p=pathlib.Path(__import__('sys').argv[1]);s=p.read_text()
a=s.index('#define T290_GRAPHICS_CAP');z=s.index('#endif',a)
functions=s[a:z]
prefix=r"""
#include <cstdint>
#include <cstdio>
#include <cassert>
#include <thread>
#include <vector>
using SInt64 = int64_t;
#define IOLog(...) std::printf(__VA_ARGS__)
#define OSCompareAndSwap64(a,b,p) __sync_bool_compare_and_swap(p,a,b)
#define OSAddAtomic64(a,p) __sync_fetch_and_add(p,a)
"""
test=r"""
int main() {
 uint64_t stats[4];
 assert(!sweet_graphics_reserve(0));
 assert(!sweet_graphics_reserve(UINT64_MAX));
 assert(sweet_graphics_reserve(T290_GRAPHICS_CAP));
 assert(!sweet_graphics_reserve(1));
 sweet_graphics_release(T290_GRAPHICS_CAP);
 std::vector<std::thread> threads;
 for(unsigned t=0;t<8;t++) threads.emplace_back([t] {
  for(unsigned n=0;n<20000;n++) {
   uint64_t bytes=((n+t)%64+1)*1024*1024ull;
   if(sweet_graphics_reserve(bytes)) sweet_graphics_release(bytes);
  }
 });
 for(auto &t:threads)t.join();
 sweet_graphics_stats(stats);
 assert(stats[0]==0 && stats[1]<=stats[2] && stats[2]==T290_GRAPHICS_CAP);
 puts("PASS actual graphics quota: overflow, exact cap, rejection, 160000 concurrent reserve/release pairs");
}
"""
with tempfile.TemporaryDirectory(prefix='t290-budget-') as d:
 cpp=pathlib.Path(d)/'test.cpp';exe=pathlib.Path(d)/'test'
 cpp.write_text(prefix+functions+test)
 subprocess.run(['clang++','-std=c++17','-O1','-pthread','-fsanitize=address,undefined','-fno-pie','-no-pie',str(cpp),'-o',str(exe)],check=True)
 subprocess.run([str(exe)],check=True)
