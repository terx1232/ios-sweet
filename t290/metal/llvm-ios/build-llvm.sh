#!/bin/bash
# Cross-build the LLVM 14.0.6 libraries t290metalc needs (IR/bitcode reading, the
# new pass manager and scalar/IPO transforms) as iOS arm64 static libraries.
# Run in WSL: bash t290/metal/llvm-ios/build-llvm.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export PATH=$HOME/.local/bin:$PATH
export T290_IOS_SDK=${T290_IOS_SDK:-$HOME/t290-toolchain/iPhoneOS16.5.sdk}
src=${LLVM_SRC:-$HOME/llvm-ios/llvm-14.0.6.src}
out=${1:-$HOME/llvm-ios/build}
test -f "$T290_IOS_SDK/SDKSettings.plist"
mkdir -p "$out"
cmake -G Ninja -S "$src" -B "$out" \
	-DCMAKE_TOOLCHAIN_FILE="$here/ios-toolchain.cmake" \
	-DCMAKE_BUILD_TYPE=MinSizeRel \
	-DLLVM_TARGETS_TO_BUILD="" \
	-DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios16.0 \
	-DLLVM_HOST_TRIPLE=arm64-apple-ios16.0 \
	-DLLVM_TABLEGEN=/usr/bin/llvm-tblgen-14 \
	-DLLVM_ENABLE_ASSERTIONS=OFF \
	-DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_LIBXML2=OFF \
	-DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_ZSTD=OFF \
	-DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
	-DLLVM_INCLUDE_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_INCLUDE_DOCS=OFF \
	-DLLVM_BUILD_TOOLS=OFF -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_OCAMLDOC=OFF \
	-DLLVM_ENABLE_PIC=ON -DLLVM_ENABLE_RTTI=OFF -DLLVM_ENABLE_EH=OFF \
	-DLLVM_ENABLE_PLUGINS=OFF -DLLVM_ENABLE_THREADS=ON
# static-library targets do not pull in their link dependencies: list the closure
ninja -C "$out" LLVMPasses LLVMIRReader LLVMBitReader LLVMAsmParser LLVMTransformUtils \
	LLVMScalarOpts LLVMInstCombine LLVMipo LLVMAnalysis LLVMCore LLVMSupport \
	LLVMAggressiveInstCombine LLVMCoroutines LLVMObjCARCOpts LLVMVectorize LLVMInstrumentation \
	LLVMTarget LLVMLinker LLVMBitWriter LLVMFrontendOpenMP LLVMProfileData LLVMObject LLVMMC \
	LLVMMCParser LLVMTextAPI LLVMBitstreamReader LLVMRemarks LLVMBinaryFormat LLVMDemangle \
	LLVMDebugInfoDWARF LLVMDebugInfoCodeView LLVMDebugInfoMSF LLVMDebugInfoPDB \
	LLVMSymbolize LLVMCFGuard LLVMCodeGen
ls -la "$out/lib"/*.a | awk '{s+=$5} END {print NR " libraries, " s/1048576 " MiB"}'
