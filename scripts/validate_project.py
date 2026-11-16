#!/usr/bin/env python3
"""Preflight source packaging. Does not pretend to type-check or compile Swift."""
from pathlib import Path
import json
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = {'.p12', '.pfx', '.mobileprovision', '.pem', '.key', '.cer', '.ipa'}
violations = []
for path in ROOT.rglob('*'):
    relative = path.relative_to(ROOT)
    if any(part in {'.git', '.build', 'build', 'dist', '__pycache__'} for part in relative.parts):
        continue
    if path.is_file() and path.suffix.lower() in FORBIDDEN:
        violations.append(str(relative))
    if path.is_file() and path.suffix in {'.swift', '.py', '.yml', '.md'}:
        text = path.read_text(encoding='utf-8')
        if '-----BEGIN PRIVATE KEY-----' in text or '-----BEGIN RSA PRIVATE KEY-----' in text:
            # The guard itself contains only quoted marker strings, not a PEM block.
            if path.name != 'validate_project.py':
                violations.append(str(relative) + ': private key marker')
for path in (ROOT / 'App').rglob('Contents.json'):
    json.loads(path.read_text())
for path in (ROOT / 'App').rglob('*.plist'):
    plistlib.loads(path.read_bytes())
required = ['project.yml', 'App/MuFlowApp.swift', '.github/workflows/ios-build.yml',
            'Packages/DanmakuCore/Package.swift', 'LICENSE', 'THIRD_PARTY_NOTICES.md']
violations.extend('missing ' + path for path in required if not (ROOT / path).is_file())
tracked = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '-z'], capture_output=True)
if tracked.returncode == 0:
    for name in tracked.stdout.decode().split('\0'):
        if name and Path(name).suffix.lower() in FORBIDDEN:
            violations.append('tracked signing/binary material: ' + name)
if violations:
    print('\n'.join(violations), file=sys.stderr)
    raise SystemExit(1)
print('Source packaging checks passed; signing material is excluded. Swift compilation remains a separate check.')
