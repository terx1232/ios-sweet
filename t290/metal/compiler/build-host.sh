#!/bin/bash
# Host (WSL, llvm-14-dev) build of the airglc CLI for testing against t290/metal/airgl.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$HOME/airglc-host}
mkdir -p "$out"
clang++-14 -std=c++17 -O1 -g -fno-rtti $(llvm-config-14 --cxxflags | sed 's/-fno-exceptions//; s/-std=c++14//') -fexceptions \
	"$here/airglc.cpp" "$here/main.cpp" -o "$out/airglc" $(llvm-config-14 --ldflags --libs core irreader bitreader passes)
echo "$out/airglc"
