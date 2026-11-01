import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:fl_clash/features/update/update_installer.dart';
import 'package:fl_clash/features/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late File file;
  late UpdateRelease release;
  setUp(() async {
    directory = Directory.systemTemp.createTempSync('haoze-install-test');
    file = File('${directory.path}/update.exe');
    await file.writeAsString('verified');
    final digest = sha256.convert(await file.readAsBytes()).toString();
    final service = HaozeUpdateService(
      transport: IoUpdateTransport(),
      platform: UpdatePlatform.windows,
      identity: const UpdateIdentity(version: '6.0.3', versionCode: 62003),
      directory: () async => directory,
    );
    release = service.parseManifest({
      'schema': 1,
      'channel': 'stable',
      'version': '6.0.4',
      'platforms': {
        'windows': {
          'name': 'HaozeConnect-Windows-Setup-x64-6.0.4.exe',
          'bytes': 8,
          'sha256': digest,
        },
      },
    }, '6.0.4');
  });
  tearDown(() => directory.deleteSync(recursive: true));
  test('failed or denied Windows handoff leaves the app running', () async {
    var exits = 0;
    var launches = 0;
    final gateway = SystemUpdateInstallGateway(
      exitWindows: () async {
        exits++;
      },
      launchWindows: (_) async {
        launches++;
        return false;
      },
    );
    await expectLater(
      gateway.install(file, release),
      throwsA(isA<UpdateException>()),
    );
    expect(launches, 1);
    expect(exits, 0);
  });
  test('accepted handoff performs normal shutdown after launch', () async {
    final calls = <String>[];
    final gateway = SystemUpdateInstallGateway(
      exitWindows: () async {
        calls.add('exit');
      },
      launchWindows: (path) async {
        expect(path, file.path);
        calls.add('launch');
        return true;
      },
    );
    await gateway.install(file, release);
    expect(calls, ['launch', 'exit']);
  });
  test('changed or missing files never reach elevation', () async {
    var launches = 0;
    final gateway = SystemUpdateInstallGateway(
      exitWindows: () async {},
      launchWindows: (_) async {
        launches++;
        return true;
      },
    );
    await file.writeAsString('tampered');
    await expectLater(
      gateway.install(file, release),
      throwsA(isA<UpdateException>()),
    );
    await file.delete();
    await expectLater(
      gateway.install(file, release),
      throwsA(isA<UpdateException>()),
    );
    expect(launches, 0);
  });
}
