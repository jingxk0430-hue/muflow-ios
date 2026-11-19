#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="${1:-$task_root/build}"
mkdir -p "$task_output"
task_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang++ -std=c++17 -fobjc-arc -fblocks -arch arm64 \
  -miphoneos-version-min=18.0 -isysroot "$task_sdk" -dynamiclib \
  -framework Foundation -framework UIKit -framework QuartzCore \
  -framework UniformTypeIdentifiers -O2 -Wall -Wextra \
  -Wno-unused-parameter -Wno-deprecated-declarations \
  -install_name @rpath/InfuseDanmaku.dylib \
  "$task_root/Source/InfuseDanmaku.mm" -o "$task_output/InfuseDanmaku.dylib"
file "$task_output/InfuseDanmaku.dylib"
shasum -a 256 "$task_output/InfuseDanmaku.dylib"
