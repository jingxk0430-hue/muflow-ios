#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'iOS packaging requires macOS with Xcode. Run the GitHub Actions workflow.' >&2
  exit 2
fi
mkdir -p build
xcodegen generate --spec project.yml
xcodebuild -resolvePackageDependencies -project MuFlow.xcodeproj -scheme MuFlow
xcodebuild archive -project MuFlow.xcodeproj -scheme MuFlow -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/MuFlow.xcarchive \
  -derivedDataPath build/DerivedData -jobs 2 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
mkdir -p build/unsigned/Payload
ditto build/MuFlow.xcarchive/Products/Applications/MuFlow.app build/unsigned/Payload/MuFlow.app
ditto -c -k --keepParent build/unsigned/Payload build/MuFlow-unsigned.ipa
shasum -a 256 build/MuFlow-unsigned.ipa
