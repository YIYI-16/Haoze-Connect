import 'package:fl_clash/core/desktop/windows_privileges.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WindowsTunPrivilege decision(String directory, {bool elevated = false}) =>
      windowsTunPrivilege(
        elevated: elevated,
        executableDirectory: directory,
        programDirectories: [r'C:\Program Files', r'C:\Program Files (x86)'],
      );
  test('an elevated portable process uses its own direct core', () {
    expect(
      decision(r'C:\Users\User\Downloads\Haoze', elevated: true),
      WindowsTunPrivilege.direct,
    );
  });
  test('only the protected installation requests a persistent helper', () {
    expect(
      decision(r'C:\Program Files\HaozeConnectMihomoPreview'),
      WindowsTunPrivilege.helper,
    );
    expect(
      decision(r'c:\PROGRAM FILES\HaozeConnectMihomoPreview'),
      WindowsTunPrivilege.helper,
    );
  });
  test('portable and relative paths cannot register the helper', () {
    for (final path in [r'C:\Users\User\Downloads\Haoze', r'Haoze\bin']) {
      expect(decision(path), WindowsTunPrivilege.administratorRequired);
    }
  });
  test('path-prefix lookalikes and traversal are rejected', () {
    for (final path in [
      r'C:\Program Files Evil\Haoze',
      r'C:\Program Files\..\Users\User\Haoze',
    ]) {
      expect(decision(path), WindowsTunPrivilege.administratorRequired);
    }
  });
  test('missing protected roots fail closed', () {
    expect(
      windowsTunPrivilege(
        elevated: false,
        executableDirectory: r'C:\Program Files\Haoze',
        programDirectories: [],
      ),
      WindowsTunPrivilege.administratorRequired,
    );
  });
}
