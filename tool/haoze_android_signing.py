"""Prepare protected signing inputs and verify the Android release identity."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / 'android/release-certificate.sha256'
PACKAGE = 'com.haoze.connect'
SIGNING_NAMES = ('HAOZE_ANDROID_STORE_PASSWORD', 'HAOZE_ANDROID_KEY_ALIAS',
                 'HAOZE_ANDROID_KEY_PASSWORD')


def pinned_certificate(path=PIN):
    value = path.read_text().strip()
    if not re.fullmatch(r'[0-9a-f]{64}', value):
        raise ValueError('Invalid pinned Android certificate')
    return value


def secret_environment():
    if any(not os.environ.get(name, '').strip() for name in SIGNING_NAMES):
        raise ValueError('All Android release signing inputs are required')


def run_checked(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise ValueError('Android signing tool failed; secret output suppressed')
    return result.stdout


def prepare(directory, github_env=None):
    secret_environment()
    encoded = os.environ.get('HAOZE_ANDROID_KEYSTORE_BASE64', '')
    if not encoded:
        raise ValueError('Fixed Android release keystore is required')
    raw = base64.b64decode(encoded, validate=True)
    if not 256 <= len(raw) <= 32768:
        raise ValueError('Invalid release keystore size')
    if directory.is_symlink():
        raise ValueError('Signing directory must not be a link')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    key = directory / 'release.p12'
    fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
        common = ['-keystore', str(key), '-storetype', 'PKCS12',
                  '-storepass:env', 'HAOZE_ANDROID_STORE_PASSWORD',
                  '-alias', os.environ['HAOZE_ANDROID_KEY_ALIAS']]
        pem = run_checked(['keytool', '-exportcert', '-rfc', *common])
        actual = hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()
        if actual != pinned_certificate():
            raise ValueError('Release keystore certificate does not match the pinned identity')
        run_checked(['keytool', '-certreq', *common,
                     '-keypass:env', 'HAOZE_ANDROID_KEY_PASSWORD'])
        if github_env:
            with github_env.open('a') as stream:
                stream.write(f'HAOZE_ANDROID_KEYSTORE_PATH={key.resolve()}\n')
        print('Fixed Android release certificate verified: ' + actual)
        return key
    except BaseException:
        key.unlink(missing_ok=True)
        raise


def android_tools():
    sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
    if not sdk:
        raise ValueError('Android SDK is required')
    versions = [p for p in (Path(sdk) / 'build-tools').iterdir()
                if re.fullmatch(r'\d+\.\d+\.\d+', p.name)]
    versions.sort(key=lambda p: tuple(map(int, p.name.split('.'))), reverse=True)
    for directory in versions:
        if (directory / 'apksigner').is_file() and (directory / 'aapt').is_file():
            return directory / 'apksigner', directory / 'aapt'
    raise ValueError('Android signing and metadata tools are missing')


def verify_signature_output(signatures):
    lines = [line for line in signatures.splitlines()
             if ' certificate SHA-256 digest:' in line and not line.startswith('Source Stamp Signer')]
    pattern = re.compile(r'^(?:Signer (?:#1|\(minSdkVersion=\d+(?: \(dev release=true\))?, maxSdkVersion=\d+\))|V[1-4](?:\.[0-9]+)? Signer(?: #[0-9]+| \(minSdkVersion=[^\r\n]+\))?):? certificate SHA-256 digest: ([0-9a-fA-F]{64})$')
    matches = [pattern.fullmatch(line) for line in lines]
    certificates = [match[1].lower() for match in matches if match]
    if ('Number of signers: 1' not in signatures.splitlines() or not lines or
            len(certificates) != len(lines) or
            any(value != pinned_certificate() for value in certificates)):
        raise ValueError('APK signer does not match the fixed release identity; observed certificates: ' +
                         ','.join(certificates or ['unrecognized output']))
    if 'Verified using v2 scheme (APK Signature Scheme v2): true' not in signatures:
        raise ValueError('APK v2 verification failed')


def verify(apk, output, expected_code=None):
    signer, aapt = android_tools()
    signatures = run_checked([str(signer), 'verify', '--verbose', '--print-certs', str(apk)])
    verify_signature_output(signatures)
    metadata = run_checked([str(aapt), 'dump', 'badging', str(apk)])
    package = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", metadata)
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)',
                        (ROOT / 'pubspec.yaml').read_text(), re.MULTILINE)
    if not package or not version:
        raise ValueError('Release version metadata is missing')
    expected_code = expected_code if expected_code is not None else int(version[2]) + 2000
    if package[1] != PACKAGE or package[3] != version[1] or int(package[2]) != expected_code:
        raise ValueError('APK package or version is not the intended production release')
    if expected_code <= 62001 or 'application-debuggable' in metadata:
        raise ValueError('APK must be a newer, non-debuggable production build')
    if "native-code: 'arm64-v8a'" not in metadata:
        raise ValueError('Expected the arm64 release APK')
    with apk.open('rb') as stream:
        apk_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    result = {'package': package[1], 'version': package[3], 'version_code': int(package[2]),
              'certificate_sha256': pinned_certificate(), 'debuggable': False,
              'bytes': apk.stat().st_size,
              'sha256': apk_digest,
              'channel': 'stable', 'signature_v2_verified': True}
    output.write_text(json.dumps(result, indent=2) + '\n')
    print('Production APK signature, package and version verified')
    return result


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare')
    prep.add_argument('--directory', type=Path, required=True)
    prep.add_argument('--github-env', type=Path)
    check = commands.add_parser('verify')
    check.add_argument('--apk', type=Path, required=True)
    check.add_argument('--output', type=Path, required=True)
    check.add_argument('--expected-code', type=int)
    args = parser.parse_args()
    try:
        if args.command == 'prepare':
            prepare(args.directory, args.github_env)
        else:
            verify(args.apk, args.output, args.expected_code)
    except (ValueError, OSError, ssl.SSLError) as error:
        print('Release signing rejected: ' + str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
