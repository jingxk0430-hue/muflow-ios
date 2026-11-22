#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="$task_root/build/mac-tests"
mkdir -p "$task_output"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$task_root/Source/SiteHTTP.swift" "$task_root/Source/BilibiliSource.swift" \
  "$task_root/Tests/BilibiliSourceTests.swift" -o "$task_output/bilibili-tests"
"$task_output/bilibili-tests"
