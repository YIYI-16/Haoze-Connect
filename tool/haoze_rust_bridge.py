"""Generate and verify the Rust loader contract before packaging clients."""
import argparse
from pathlib import Path
import re
import subprocess
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'plugins/rust_api'


def check(root=ROOT, apk=None):
    plugin = root / 'plugins/rust_api'
    manifest = tomllib.loads((plugin / 'rust/Cargo.toml').read_text())
    expected = manifest['lib']['name'].replace('-', '_')
    generated = (plugin / 'lib/src/rust/frb_generated.dart').read_text()
    match = re.search(r"ExternalLibraryLoaderConfig\(\s*stem:\s*'([^']+)'", generated)
    if match is None or match[1] != expected:
        raise ValueError('Generated Rust loader does not match Cargo library: ' + expected)
    if apk:
        with zipfile.ZipFile(apk) as archive:
            names = set(archive.namelist())
            abis = {name.split('/')[1] for name in names
                    if name.startswith('lib/') and name.endswith('/libapp.so')}
            if not abis or any(f'lib/{abi}/lib{expected}.so' not in names for abi in abis):
                raise ValueError('APK is missing the Rust library requested by its loader')
    return expected


def generate():
    subprocess.run(['cargo', 'metadata', '--locked', '--format-version', '1',
                    '--manifest-path', str(PLUGIN / 'rust/Cargo.toml')],
                   check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['flutter_rust_bridge_codegen', 'generate'], cwd=PLUGIN, check=True)
    return check()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'generate'])
    parser.add_argument('--apk', type=Path)
    args = parser.parse_args()
    stem = generate() if args.action == 'generate' else check(apk=args.apk)
    print('Rust loader contract verified: ' + stem)


if __name__ == '__main__':
    main()
