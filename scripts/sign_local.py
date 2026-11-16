#!/usr/bin/env python3
"""Sign an unsigned IPA locally. Signing secrets never enter the source tree or argv."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import warnings
import zipfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.serialization import pkcs12


def signing_material(archive_path):
    with zipfile.ZipFile(archive_path) as archive:
        profiles = [item for item in archive.infolist() if item.filename.lower().endswith('.mobileprovision')]
        identities = [item for item in archive.infolist() if item.filename.lower().endswith(('.p12', '.pfx'))]
        if len(profiles) != 1 or len(identities) != 1:
            raise ValueError('Expected exactly one P12 identity and one provisioning profile.')
        if any(item.file_size > 1024 * 1024 for item in profiles + identities):
            raise ValueError('Signing material is unexpectedly large.')
        profile_bytes = archive.read(profiles[0])
        identity = archive.read(identities[0])
        candidates = [None, b'']
        for item in archive.infolist():
            if item.filename.lower().endswith('.txt') and item.file_size < 4096:
                text = archive.read(item).decode('utf-8-sig').strip()
                if text:
                    candidates.append(text.encode())
                for line in text.splitlines():
                    match = re.fullmatch(r'(?:密码|证书密码|password|p12password)\s*[:：=]\s*(.+)', line.strip(), re.I)
                    if match:
                        candidates.append(match.group(1).strip().encode())
    verified = subprocess.run(['openssl', 'cms', '-verify', '-inform', 'DER', '-noverify', '-binary'],
                              input=profile_bytes, capture_output=True, timeout=20)
    if verified.returncode:
        raise ValueError('Provisioning profile CMS signature verification failed.')
    profile = plistlib.loads(verified.stdout)
    now = dt.datetime.now(dt.timezone.utc)
    def utc(value):
        return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value
    if not utc(profile['CreationDate']) <= now < utc(profile['ExpirationDate']):
        raise ValueError('Provisioning profile is outside its validity period.')
    unlocked = None
    for password in candidates:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                unlocked = pkcs12.load_key_and_certificates(identity, password)
            break
        except (ValueError, TypeError):
            continue
    if unlocked is None:
        raise ValueError('Cannot unlock P12 using the supplied password material.')
    key, cert, chain = unlocked
    if key is None or cert is None:
        raise ValueError('P12 must contain both a private key and certificate.')
    if not cert.not_valid_before_utc <= now < cert.not_valid_after_utc:
        raise ValueError('Signing certificate is outside its validity period.')
    public_format = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    if key.public_key().public_bytes(*public_format) != cert.public_key().public_bytes(*public_format):
        raise ValueError('Signing key and certificate do not match.')
    if not any(x509.load_der_x509_certificate(item).fingerprint(hashes.SHA256()) == cert.fingerprint(hashes.SHA256())
               for item in profile.get('DeveloperCertificates', [])):
        raise ValueError('Certificate is not allowed by the provisioning profile.')
    entitlements = profile['Entitlements']
    application_id = entitlements['application-identifier']
    bundle_id = application_id.split('.', 1)[1]
    if '*' in bundle_id:
        raise ValueError('This first-release signer requires an explicit application identifier.')
    minimal = {
        'application-identifier': application_id,
        'com.apple.developer.team-identifier': entitlements['com.apple.developer.team-identifier'],
        'get-task-allow': False,
        'keychain-access-groups': [application_id],
    }
    return profile_bytes, profile, key, cert, minimal, bundle_id


def ipa_metadata(path):
    with zipfile.ZipFile(path) as archive:
        infos = [name for name in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
        if len(infos) != 1:
            raise ValueError('IPA must contain exactly one top-level app.')
        for member in archive.infolist():
            parts = Path(member.filename).parts
            if member.filename.startswith('/') or '..' in parts:
                raise ValueError('Unsafe IPA archive path.')
        root = infos[0].rsplit('/', 1)[0]
        info = plistlib.loads(archive.read(infos[0]))
        profile = archive.read(root + '/embedded.mobileprovision') if root + '/embedded.mobileprovision' in archive.namelist() else None
    return info, profile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--certificate-archive', required=True, type=Path)
    parser.add_argument('--inspect', action='store_true')
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--zsign', type=Path)
    args = parser.parse_args()
    profile_bytes, profile, key, cert, entitlements, bundle_id = signing_material(args.certificate_archive)
    if args.inspect:
        print(json.dumps({
            'offline_material_checks': 'passed',
            'registered_device_count': len(profile.get('ProvisionedDevices', [])),
            'explicit_application_identifier': True,
            'expires_utc': cert.not_valid_after_utc.isoformat(),
            'online_revocation_status': 'not_checked',
            'signing_performed': False,
        }))
        return
    if not args.input or not args.output or not args.zsign:
        parser.error('--input, --output and --zsign are required for signing')
    info, _ = ipa_metadata(args.input)
    if info.get('CFBundleIdentifier') != 'com.muflow.player':
        raise ValueError('Input is not the expected MuFlow unsigned app.')
    output = args.output.resolve()
    if output.exists():
        raise ValueError('Output already exists; choose a new output path.')
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # TemporaryDirectory is mode 0700. The decrypted private key is removed on exit.
    with tempfile.TemporaryDirectory(prefix='muflow-sign-') as temp:
        folder = Path(temp)
        materials = {
            'identity.pem': key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()),
            'certificate.pem': cert.public_bytes(serialization.Encoding.PEM),
            'profile.mobileprovision': profile_bytes,
            'entitlements.plist': plistlib.dumps(entitlements),
        }
        for name, contents in materials.items():
            target = folder / name
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(contents)
        result = subprocess.run([
            str(args.zsign.resolve()), '-q', '-f', '-k', str(folder / 'identity.pem'),
            '-c', str(folder / 'certificate.pem'), '-m', str(folder / 'profile.mobileprovision'),
            '-e', str(folder / 'entitlements.plist'), '-b', bundle_id,
            '-n', '幕流', '-o', str(output), '-t', str(folder / 'work'), str(args.input.resolve())
        ], capture_output=True, timeout=300)
        if result.returncode:
            if output.exists():
                output.unlink()
            raise RuntimeError('Local signing failed; no signing secrets were printed. Exit code: ' + str(result.returncode))
    signed_info, signed_profile = ipa_metadata(output)
    if signed_info.get('CFBundleIdentifier') != bundle_id or signed_profile != profile_bytes:
        raise ValueError('Signed IPA independent metadata readback failed.')
    output.chmod(0o600)
    with output.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    print(json.dumps({'signed_ipa': str(output), 'profile_and_bundle_readback': 'passed',
                      'sha256': digest,
                      'installed': False, 'runtime_validated': False}, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Exception messages are controlled above; never dump source credential bytes.
        if isinstance(error, (ValueError, RuntimeError)):
            raise SystemExit(str(error))
        raise SystemExit('Signing operation could not complete (' + type(error).__name__ + ').')
