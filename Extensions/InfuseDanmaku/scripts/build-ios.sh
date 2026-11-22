#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="${1:-$task_root/build}"
mkdir -p "$task_output"
task_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
task_repo="$(cd "$task_root/../.." && pwd)"
xcrun --sdk iphoneos swiftc -sdk "$task_sdk" -target arm64-apple-ios18.0 \
  -swift-version 5 -parse-as-library -emit-module -module-name DanmakuCore \
  -emit-module-path "$task_output/DanmakuCore.swiftmodule" -c -O \
  "$task_repo/Packages/DanmakuCore/Sources/DanmakuCore/Danmaku.swift" \
  -o "$task_output/DanmakuCore.o"
xcrun --sdk iphoneos clang++ -std=c++17 -fobjc-arc -fblocks -arch arm64 \
  -miphoneos-version-min=18.0 -isysroot "$task_sdk" -c \
  -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  "$task_root/Source/InfuseDanmaku.mm" -o "$task_output/InfuseDanmaku.o"
xcrun --sdk iphoneos swiftc -sdk "$task_sdk" -target arm64-apple-ios18.0 \
  -swift-version 5 -parse-as-library -emit-library -module-name InfuseDanmaku -O \
  -I "$task_output" "$task_output/DanmakuCore.o" "$task_output/InfuseDanmaku.o" \
  "$task_root/Source/BilibiliSource.swift" "$task_root/Source/OnlineSourceBridge.swift" "$task_root/Source/SiteHTTP.swift" \
  "$task_repo/App/Services/DanmakuService.swift" "$task_repo/App/Services/DanmakuSourceLink.swift" \
  "$task_repo/App/Services/NativeDanmakuService.swift" "$task_repo/App/Services/YoukuDanmakuService.swift" \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics -framework CoreText \
  -framework UniformTypeIdentifiers -lc++ -lz \
  -Xlinker -install_name -Xlinker @rpath/InfuseDanmaku.dylib \
  -o "$task_output/InfuseDanmaku.dylib"
file "$task_output/InfuseDanmaku.dylib"
shasum -a 256 "$task_output/InfuseDanmaku.dylib"
