#!/bin/bash
# Build T290Metal.bundle (driver + airglc + LLVM, one Mach-O bundle) and the
# mtltest hardware test for iPadOS arm64 in WSL. Needs the LLVM libraries from
# t290/metal/llvm-ios/build-llvm.sh and airglc.o from t290/metal/compiler/build-ios.sh.
# Does not install anything.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
toolroot=${T290_TOOLCHAIN:-$HOME/t290-toolchain}
sdk=${T290_IOS_SDK:-$toolroot/iPhoneOS16.5.sdk}
gles=${T290_GLES_HEADERS:-$HOME/mesa-src/mesa-24.2.8/include}
llvm_build=${LLVM_IOS_BUILD:-$HOME/llvm-ios/build}
airglc=${AIRGLC_BUILD:-$toolroot/build-airglc}
ld=${LD64:-ld64.lld-14}
ldid=${LDID:-$toolroot/ldid-src/ldid}
out=${1:-$toolroot/build-metal}
test -f "$sdk/SDKSettings.plist"
test -f "$gles/GLES3/gl31.h"
test -f "$airglc/airglc.o"
mkdir -p "$out/obj" "$out/T290Metal.bundle"
flags=(-target arm64-apple-ios16.0 -isysroot "$sdk" -mcpu=cortex-a53 -O2 -g -Wall -Wextra -Wno-unused-parameter
	-Wno-protocol -Wno-objc-protocol-property-synthesis -Wno-objc-property-synthesis -Wno-missing-field-initializers -Wno-nullability-completeness -Wno-deprecated-declarations -Wno-mismatched-parameter-types
	-fobjc-arc -I"$gles" -I"$here")
for f in gl resources library device commands; do
	clang-14 "${flags[@]}" -c "$here/$f.m" -o "$out/obj/$f.o"
done
libs=(Passes ipo Instrumentation Vectorize ObjCARCOpts Coroutines Linker IRReader AsmParser BitReader BitWriter
	FrontendOpenMP CodeGen Target ScalarOpts InstCombine AggressiveInstCombine CFGuard TransformUtils Analysis ProfileData
	Symbolize DebugInfoDWARF DebugInfoPDB DebugInfoMSF DebugInfoCodeView Object MC MCParser TextAPI BitstreamReader
	Core Remarks BinaryFormat Demangle Support)
archives=()
for l in "${libs[@]}"; do
	test -f "$llvm_build/lib/libLLVM$l.a" && archives+=("$llvm_build/lib/libLLVM$l.a")
done
link=(-arch arm64 -platform_version ios 16.0 16.5 -syslibroot "$sdk")
"$ld" "${link[@]}" -bundle -dead_strip -o "$out/T290Metal.bundle/T290Metal" "$out"/obj/{gl,resources,library,device,commands}.o \
	"$airglc/airglc.o" "${archives[@]}" -framework Foundation -framework CoreFoundation -framework Metal \
	-framework IOSurface -framework IOKit -lobjc -lc++ -lSystem
cp "$here/Info.plist" "$out/T290Metal.bundle/Info.plist"
"$ldid" -S -Cadhoc -Hsha256 "$out/T290Metal.bundle/T290Metal"
clang-14 "${flags[@]}" -c "$here/mtltest.m" -o "$out/obj/mtltest.o"
"$ld" "${link[@]}" -o "$out/mtltest" "$out/obj/mtltest.o" -framework Foundation -framework CoreFoundation \
	-framework Metal -framework IOSurface -lobjc -lSystem
"$ldid" -S"$here/../../ios/ent.plist" -Cadhoc -Hsha256 "$out/mtltest"
(cd "$out" && sha256sum T290Metal.bundle/T290Metal T290Metal.bundle/Info.plist mtltest > SHA256SUMS)
ls -la "$out/T290Metal.bundle" "$out/mtltest"
