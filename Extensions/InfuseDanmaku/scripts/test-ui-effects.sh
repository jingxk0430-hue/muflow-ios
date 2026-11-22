#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_output="$task_root/build/ui-tests"
task_app="$task_output/EffectTests.app"
mkdir -p "$task_app"
task_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
task_arch="$(uname -m)"
xcrun --sdk iphonesimulator clang++ -std=c++17 -fobjc-arc -fblocks -arch "$task_arch" \
  -mios-simulator-version-min=18.0 -isysroot "$task_sdk" -O2 -Wall -Wextra \
  -Wno-unused-parameter -Wno-deprecated-declarations "$task_root/Tests/effect_ui_test.mm" \
  -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -framework CoreText -lz -framework UniformTypeIdentifiers -o "$task_app/EffectTests"
cp "$task_root/Tests/Fixtures/effects-demo.xml" "$task_root/Tests/Fixtures/bas-native-demo.bas" "$task_app/"
python3 - "$task_app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'CFBundleIdentifier':'com.muflow.effecttests','CFBundleName':'EffectTests','CFBundleExecutable':'EffectTests',
 'CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSRequiresIPhoneOS':True,
 'UILaunchScreen':{},'UIDeviceFamily':[1],'UISupportedInterfaceOrientations':['UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight']},f)
PY
codesign --force --sign - "$task_app"
xcrun simctl list runtimes --json > "$task_output/runtimes.json"
xcrun simctl list devicetypes --json > "$task_output/devicetypes.json"
task_runtime="$(python3 - "$task_output/runtimes.json" <<'PY'
import json,sys
print(next(r['identifier'] for r in json.load(open(sys.argv[1]))['runtimes'] if r.get('isAvailable') and 'iOS' in r['name']))
PY
)"
task_type="$(python3 - "$task_output/devicetypes.json" <<'PY'
import json,sys
print(next(r['identifier'] for r in json.load(open(sys.argv[1]))['devicetypes'] if r['name']=='iPhone 16'))
PY
)"
task_device="$(xcrun simctl create InfuseEffectTests "$task_type" "$task_runtime")"
trap 'xcrun simctl shutdown "$task_device" >/dev/null 2>&1 || true; xcrun simctl delete "$task_device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$task_device"
xcrun simctl bootstatus "$task_device" -b
xcrun simctl install "$task_device" "$task_app"
xcrun simctl launch "$task_device" com.muflow.effecttests
task_container="$(xcrun simctl get_app_container "$task_device" com.muflow.effecttests data)"
python3 - "$task_container/Documents/effect-ui-result.json" <<'PY'
import sys,time,json
from pathlib import Path
p=Path(sys.argv[1])
for _ in range(90):
 if p.exists():
  r=json.loads(p.read_text());assert r['passed'];print(json.dumps(r));break
 time.sleep(1)
else:raise SystemExit('UIKit effect tests did not finish; check simulator crash reports')
PY
cp "$task_container/Documents/"effect-ui-* "$task_container/Documents/bas-ui-preview.png" "$task_root/build/"
