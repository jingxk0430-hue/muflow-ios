#!/usr/bin/env python3
"""Select an installed Xcode with Swift 6.3+, as required by the pinned MPVUI."""
from pathlib import Path
import re
import subprocess
import os

candidates = list(Path('/Applications').glob('Xcode*.app/Contents/Developer'))
viable = []
for candidate in candidates:
    env = dict(os.environ, DEVELOPER_DIR=str(candidate))
    result = subprocess.run(['xcrun', 'swift', '--version'], env=env, capture_output=True, text=True)
    match = re.search(r'Swift version (\d+)\.(\d+)', result.stdout)
    if result.returncode == 0 and match:
        version = tuple(map(int, match.groups()))
        if version >= (6, 3):
            viable.append((version, candidate))
if not viable:
    raise SystemExit('No installed Xcode provides Swift 6.3+. Select a newer standard macOS runner image.')
selected = max(viable, key=lambda entry: entry[0])[1]
subprocess.run(['sudo', 'xcode-select', '-s', str(selected)], check=True)
print('Selected Xcode with Swift 6.3 or newer.')
