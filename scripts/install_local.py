#!/usr/bin/env python3
"""Install only this signed MuFlow app on its registered USB device, then read it back."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

from sign_local import ipa_metadata, signing_material


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--certificate-archive', required=True, type=Path)
    parser.add_argument('--tools-root', required=True, type=Path,
                        help='Directory containing extracted Ubuntu usr/bin and usr/lib')
    parser.add_argument('--inspect-only', action='store_true')
    parser.add_argument('--input', type=Path)
    parser.add_argument('--replace-existing-muflow', action='store_true')
    args = parser.parse_args()
    profile_bytes, profile, _, _, _, bundle_id = signing_material(args.certificate_archive)
    env = dict(os.environ)
    libraries = args.tools_root / 'usr/lib/x86_64-linux-gnu'
    if libraries.is_dir():
        env['LD_LIBRARY_PATH'] = str(libraries) + (':' + env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')

    def command(name, *arguments, timeout=30):
        path = args.tools_root / 'usr/bin' / name
        result = subprocess.run([str(path), *map(str, arguments)], capture_output=True, env=env, timeout=timeout)
        if result.returncode:
            raise RuntimeError(name + ' did not complete; unlock and reconnect the registered iPhone.')
        return result.stdout

    identifiers = command('idevice_id', '-l').decode().strip().splitlines()
    if len(identifiers) != 1:
        raise ValueError('Exactly one USB iPhone must be connected.')
    udid = identifiers[0]
    if udid.lower() not in {value.lower() for value in profile.get('ProvisionedDevices', [])}:
        raise ValueError('The connected iPhone is not included in this provisioning profile.')
    version = command('ideviceinfo', '-u', udid, '-k', 'ProductVersion').decode().strip()
    developer_mode = command('ideviceinfo', '-u', udid, '-q', 'com.apple.security.mac.amfi',
                             '-k', 'DeveloperModeStatus').decode().strip().lower() == 'true'

    def lookup():
        output = command('ideviceinstaller', '-u', udid, 'list', '--xml', '-b', bundle_id,
                         '-a', 'CFBundleIdentifier', '-a', 'CFBundleName', '-a', 'CFBundleVersion',
                         '-a', 'CFBundleShortVersionString')
        start = output.find(b'<?xml')
        if start < 0:
            raise ValueError('Installed-app lookup did not return a verifiable property list.')
        value = plistlib.loads(output[start:])
        if isinstance(value, dict):
            return value.get(bundle_id)
        if isinstance(value, list):
            return next((item for item in value if item.get('CFBundleIdentifier') == bundle_id), None)
        raise ValueError('Unknown installed-app lookup response.')

    old = lookup()
    if args.inspect_only:
        print(json.dumps({'usb_device_count': 1, 'device_in_profile': True, 'ios_version': version,
                          'developer_mode_enabled': developer_mode, 'target_app_present': old is not None,
                          'device_modified': False}))
        return
    if args.input is None:
        parser.error('--input is required for installation')
    if not developer_mode:
        raise ValueError('Enable Developer Mode on the phone before installing.')
    expected, embedded = ipa_metadata(args.input)
    if embedded != profile_bytes or expected.get('CFBundleIdentifier') != bundle_id:
        raise ValueError('IPA is not signed with the supplied explicit provisioning profile.')
    if expected.get('CFBundleName') != 'MuFlow':
        raise ValueError('The signed package is not the expected MuFlow app.')
    if old is not None:
        if old.get('CFBundleName') != 'MuFlow':
            raise ValueError('Another app already uses this signing identifier; installation stopped to preserve it.')
        if not args.replace_existing_muflow:
            raise ValueError('MuFlow is already installed; use --replace-existing-muflow for an intentional update.')
    with args.input.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    command('ideviceinstaller', '-u', udid, 'upgrade' if old else 'install', args.input.resolve(), timeout=300)
    actual = lookup()
    if actual is None or any(actual.get(key) != expected.get(key) for key in
                             ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString']):
        raise ValueError('Installation result is not yet verified; do not retry before checking the device.')
    receipt = {'installed_and_read_back': True, 'version': actual.get('CFBundleShortVersionString'),
               'build': actual.get('CFBundleVersion'), 'ios_version': version, 'ipa_sha256': digest,
               'checked_at_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
               'playback_validated': False, 'danmaku_validated': False}
    output = args.input.parent / 'install-receipt.json'
    output.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + '\n')
    output.chmod(0o600)
    print(json.dumps(receipt, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if isinstance(error, (ValueError, RuntimeError)):
            raise SystemExit(str(error))
        raise SystemExit('Device operation could not complete (' + type(error).__name__ + ').')
