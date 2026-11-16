#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --spec project.yml
python3 scripts/webdav_fixture.py &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
simulator_id=$(python3 - <<'PY'
import json
import subprocess
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
for runtime in sorted(devices, reverse=True):
    if 'iOS' not in runtime:
        continue
    for device in devices[runtime]:
        if device['name'].startswith('iPhone') and device.get('isAvailable'):
            print(device['udid'])
            raise SystemExit(0)
raise SystemExit('No available iPhone simulator')
PY
)
xcrun simctl boot "$simulator_id" 2>/dev/null || true
xcodebuild test -project MuFlow.xcodeproj -scheme MuFlow -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath build/DerivedData -resultBundlePath build/FileImportUITests.xcresult \
  -parallel-testing-enabled NO -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
