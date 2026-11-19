#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_repo="$(cd "$task_root/../.." && pwd)"
task_output="$task_root/build/mac-tests"
mkdir -p "$task_output"
task_target="$(uname -m)-apple-macosx15.0"
xcrun swiftc -target "$task_target" -swift-version 5 -parse-as-library -emit-module -module-name DanmakuCore \
  -emit-module-path "$task_output/DanmakuCore.swiftmodule" -c \
  "$task_repo/Packages/DanmakuCore/Sources/DanmakuCore/Danmaku.swift" -o "$task_output/DanmakuCore.o"
xcrun swiftc -target "$task_target" -swift-version 5 -parse-as-library -I "$task_output" "$task_output/DanmakuCore.o" \
  "$task_root/Source/OnlineSourceBridge.swift" "$task_root/Source/SiteHTTP.swift" \
  "$task_repo/App/Services/DanmakuService.swift" "$task_repo/App/Services/DanmakuSourceLink.swift" \
  "$task_repo/App/Services/NativeDanmakuService.swift" "$task_repo/App/Services/YoukuDanmakuService.swift" \
  "$task_root/Tests/OnlineSourceTests.swift" -lz -o "$task_output/online-tests"
python3 "$task_repo/scripts/webdav_fixture.py" > "$task_output/fixture.log" 2>&1 &
task_fixture_pid=$!
trap 'kill "$task_fixture_pid" 2>/dev/null || true' EXIT
python3 - <<'PY'
import urllib.request,time
for attempt in range(25):
    try:
        with urllib.request.urlopen('http://127.0.0.1:18765/youku/meta',timeout=1) as reply:
            assert reply.status==200
        break
    except Exception:
        time.sleep(.2)
else:
    raise SystemExit('Fixture did not become ready')
PY
"$task_output/online-tests"
