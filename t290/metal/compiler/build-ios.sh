#!/bin/bash
# iPadOS arm64 build of airglc: libairglc.a (for T290Metal.bundle) and the airglc CLI
# (on-device test), linked against the LLVM libraries from t290/metal/llvm-ios/build-llvm.sh.
# Run in WSL; does not install anything.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
toolroot=${T290_TOOLCHAIN:-$HOME/t290-toolchain}
sdk=${T290_IOS_SDK:-$toolroot/iPhoneOS16.5.sdk}
llvm_src=${LLVM_SRC:-$HOME/llvm-ios/llvm-14.0.6.src}
llvm_build=${LLVM_IOS_BUILD:-$HOME/llvm-ios/build}
ld=${LD64:-ld64.lld-14}
ldid=${LDID:-$toolroot/ldid-src/ldid}
out=${1:-$toolroot/build-airglc}
mkdir -p "$out"
flags=(-target arm64-apple-ios16.0 -isysroot "$sdk" -mcpu=cortex-a53 -stdlib=libc++ -std=c++17 -Os
	-fno-rtti -fexceptions -I"$llvm_src/include" -I"$llvm_build/include" -D__STDC_CONSTANT_MACROS
	-D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS)
clang++-14 "${flags[@]}" -c "$here/airglc.cpp" -o "$out/airglc.o"
clang++-14 "${flags[@]}" -c "$here/main.cpp" -o "$out/main.o"
libs=(Passes ipo Instrumentation Vectorize ObjCARCOpts Coroutines Linker IRReader AsmParser BitReader
	CodeGen Target ScalarOpts InstCombine AggressiveInstCombine TransformUtils Analysis ProfileData
	Object MC MCParser BitWriter FrontendOpenMP CFGuard Symbolize DebugInfoDWARF DebugInfoPDB DebugInfoMSF TextAPI BitstreamReader Core Remarks BinaryFormat DebugInfoCodeView Demangle Support)
archives=()
for l in "${libs[@]}"; do
	test -f "$llvm_build/lib/libLLVM$l.a" && archives+=("$llvm_build/lib/libLLVM$l.a")
done
# one archive for the driver: our object plus every LLVM member it needs is resolved at bundle link time
llvm-ar-14 rcs "$out/libairglc.a" "$out/airglc.o"
"$ld" -arch arm64 -platform_version ios 16.0 16.5 -syslibroot "$sdk" -dead_strip \
	-o "$out/airglc" "$out/main.o" "$out/airglc.o" "${archives[@]}" -lc++ -lSystem
"$ldid" -S -Cadhoc -Hsha256 "$out/airglc"
(cd "$out" && sha256sum airglc libairglc.a > SHA256SUMS)
ls -la "$out/airglc" "$out/libairglc.a"
