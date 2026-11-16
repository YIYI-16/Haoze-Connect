"""Install a test APK on an emulator and require the actual login screen."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE = 'com.haoze.connect'
COMPONENT = PACKAGE + '/com.follow.clash.MainActivity'


def validate_ui(xml):
    root = ET.fromstring(xml)
    labels = '\n'.join(value for node in root.iter() for value in node.attrib.values())
    if any(value in labels for value in ['Startup failed', '启动失败', 'libUNKNOWN', 'Failed to load dynamic library']):
        raise ValueError('Android displayed its initialization failure screen')
    return 'Sign in with Haoze' in labels and PACKAGE in labels


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--serial', default='emulator-5554')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.serial.startswith('emulator-'):
        raise ValueError('Startup acceptance only runs on an emulator')
    args.output.mkdir(parents=True, exist_ok=True)

    def adb(*parts, check=True):
        result = subprocess.run(['adb', '-s', args.serial, *parts], capture_output=True, timeout=45)
        if check and result.returncode:
            raise RuntimeError('ADB command failed: ' + ' '.join(parts[:3]))
        return result.stdout

    started = False
    try:
        adb('install', '-r', str(args.apk.resolve()))
        adb('shell', 'pm', 'grant', PACKAGE, 'android.permission.POST_NOTIFICATIONS', check=False)
        adb('logcat', '-c')
        adb('shell', 'wm', 'dismiss-keyguard', check=False)
        adb('shell', 'am', 'start', '-W', '-n', COMPONENT)
        started = True
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            time.sleep(2)
            adb('shell', 'uiautomator', 'dump', '/sdcard/haoze-startup.xml', check=False)
            xml = adb('exec-out', 'cat', '/sdcard/haoze-startup.xml', check=False)
            if not xml.strip():
                continue
            (args.output / 'startup-ui.xml').write_bytes(xml)
            try:
                ready = validate_ui(xml)
            except ET.ParseError:
                continue
            if ready:
                pid = adb('shell', 'pidof', PACKAGE).decode().strip()
                if not pid:
                    raise RuntimeError('Android app exited after reaching login')
                proof = dict(package=PACKAGE, startup='PASS', loginScreen='PASS',
                             defaultRustLoader='PASS', device=args.serial,
                             abi=adb('shell', 'getprop', 'ro.product.cpu.abi').decode().strip(),
                             variant='release-safe-mode')
                (args.output / 'android-startup.json').write_text(json.dumps(proof, indent=2)+'\n')
                print(json.dumps(proof))
                return
        raise RuntimeError('Android did not reach the login screen within 120 seconds')
    finally:
        (args.output / 'startup.png').write_bytes(adb('exec-out', 'screencap', '-p', check=False))
        (args.output / 'startup-logcat.txt').write_bytes(adb('logcat', '-d', '-s', 'flutter', 'AndroidRuntime', check=False))
        if started:
            adb('shell', 'am', 'force-stop', PACKAGE, check=False)


if __name__ == '__main__':
    main()
