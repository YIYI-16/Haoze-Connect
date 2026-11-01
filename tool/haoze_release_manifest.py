"""Build the public updater contract from the verified release artifacts."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from haoze_android_signing import PACKAGE, pinned_certificate

ROOT = Path(__file__).resolve().parents[1]


def build_manifest(android, windows, verification, source):
    version_match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)',
                              (ROOT / 'pubspec.yaml').read_text(), re.MULTILINE)
    if not version_match or not re.fullmatch(r'[0-9a-f]{40}', source):
        raise ValueError('Invalid source/version for release manifest')
    version, build = version_match.groups()
    identity = json.loads(verification.read_text())
    with android.open('rb') as stream:
        sha = hashlib.file_digest(stream, 'sha256').hexdigest()
    if (identity['package'] != PACKAGE or identity['version'] != version or
            identity['version_code'] != int(build) + 2000 or identity['debuggable'] is not False or
            identity['certificate_sha256'] != pinned_certificate() or
            identity['signature_v2_verified'] is not True or identity['sha256'] != sha or
            identity['bytes'] != android.stat().st_size):
        raise ValueError('Android artifact does not match verified production metadata')
    with windows.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError('Windows installer is not a PE file')
    with windows.open('rb') as stream:
        windows_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'schema': 1, 'channel': 'stable', 'version': version, 'source_commit': source,
            'platforms': {
                'android': {'name': f'HaozeConnect-Android-arm64-{version}.apk',
                            'bytes': android.stat().st_size, 'sha256': sha, 'package': PACKAGE,
                            'version_code': identity['version_code'],
                            'certificate_sha256': pinned_certificate()},
                'windows': {'name': f'HaozeConnect-Windows-Setup-x64-{version}.exe',
                            'bytes': windows.stat().st_size,
                            'sha256': windows_digest}}}


def main():
    parser = argparse.ArgumentParser()
    for name in ['android', 'windows', 'verification', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--source', required=True)
    args = parser.parse_args()
    try:
        result = build_manifest(args.android, args.windows, args.verification, args.source)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
        print('Stable update manifest generated from verified artifacts')
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit('Manifest rejected: ' + str(error))


if __name__ == '__main__':
    main()
