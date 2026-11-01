import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/features/haoze/account.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoze_xboard/account.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:mocktail/mocktail.dart';
import 'package:yaml/yaml.dart';

import '../../helpers/app_paths.dart';

const _subscription = '''
proxies:
  - {name: Node, type: ss, server: 192.0.2.1, port: 443, cipher: aes-128-gcm, password: unit}
proxy-groups:
  - {name: Proxy, type: select, proxies: [Node]}
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
''';

class _Storage extends Mock implements FlutterSecureStorage {}

class _Downloads extends Mock implements StrictIoXboardTransport {}

class _Core extends Mock implements CoreController {}

class _Profiles extends Profiles {
  _Profiles(this.initial);
  final List<Profile> initial;
  bool fail = false;
  int writes = 0;
  void drop() => state = [];
  @override
  List<Profile> build() => initial;
  @override
  Future<void> putManaged(Profile profile) async {
    writes++;
    if (fail) throw StateError('database');
    state = state.copyAndPut(profile, (item) => item.id == profile.id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'advertised subscription core version matches native build configuration',
    () {
      final config =
          loadYaml(File('build_config.yaml').readAsStringSync()) as YamlMap;
      expect(haozeCoreVersion, config['core_version']);
    },
  );

  group('secure account persistence', () {
    late _Storage storage;
    late SecureAccountStore store;
    String? disk;
    setUp(() {
      storage = _Storage();
      store = SecureAccountStore(storage: storage);
      disk = null;
      when(
        () => storage.read(key: any(named: 'key')),
      ).thenAnswer((_) async => disk);
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer(
        (invocation) async =>
            disk = invocation.namedArguments[#value] as String?,
      );
      when(
        () => storage.delete(key: any(named: 'key')),
      ).thenAnswer((_) async => disk = null);
    });
    XboardSavedAccount account() => XboardSavedAccount(
      origin: 'https://example.com',
      email: 'user@example.com',
      profileId: 42,
      session: XboardSession(
        authorization: 'Bearer test',
        subscriptionToken: 'subscription',
      ),
    );
    test(
      'round trip contains only credentials and managed identity, never password',
      () async {
        await store.write(account());
        expect((jsonDecode(disk!) as Map).keys.toSet(), {
          'origin',
          'email',
          'authorization',
          'subscriptionToken',
          'profileId',
          'subscriptionHost',
        });
        final loaded = await store.read();
        expect(loaded?.profileId, 42);
        expect(loaded?.session.authorization, 'Bearer test');
        expect(loaded.toString(), isNot(contains('Bearer')));
      },
    );
    test('delete failure leaves a durable revocation marker', () async {
      await store.write(account());
      when(
        () => storage.delete(key: any(named: 'key')),
      ).thenThrow(StateError('delete'));
      await store.clear();
      expect(disk, 'revoked');
      expect(await store.read(), isNull);
    });
    test(
      'delete fallback clears credentials when tombstone write fails',
      () async {
        await store.write(account());
        when(
          () => storage.write(
            key: any(named: 'key'),
            value: 'revoked',
          ),
        ).thenThrow(StateError('write'));
        await store.clear();
        expect(disk, isNull);
      },
    );
    test('both revocation paths failing remains an explicit failure', () async {
      await store.write(account());
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: 'revoked',
        ),
      ).thenThrow(StateError('write'));
      when(
        () => storage.delete(key: any(named: 'key')),
      ).thenThrow(StateError('delete'));
      await expectLater(store.clear(), throwsStateError);
      expect(await store.read(), isNotNull);
    });
  });

  group('managed profile bridge', () {
    late Directory directory;
    late ProviderContainer container;
    late _Downloads downloads;
    late _Core core;
    late _Profiles profiles;
    late HaozeManagedProfile bridge;
    final old = Profile.normal(label: 'Account').copyWith(
      id: 42,
      selectedMap: {'Proxy': 'Selected'},
      currentGroupName: 'Proxy',
      autoUpdate: false,
    );
    final uri = Uri.https('example.com', '/s/test');
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('haoze-profile-test-');
      await useAppPaths(directory);
      downloads = _Downloads();
      core = _Core();
      profiles = _Profiles([old]);
      when(
        () => downloads.download(uri),
      ).thenAnswer((_) async => Uint8List.fromList(utf8.encode(_subscription)));
      when(
        () => core.validateProfile(any(), any()),
      ).thenAnswer((_) async => '');
      container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => profiles),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          coreHandlerProvider.overrideWithValue(core),
        ],
      );
      container.listen(profilesProvider, (_, _) {});
      container.listen(currentProfileIdProvider, (_, _) {});
      final holder = Provider((ref) => HaozeManagedProfile(ref, downloads));
      bridge = container.read(holder);
      final file = File(await appPath.getProfilePath('42'));
      await file.parent.create(recursive: true);
      await file.writeAsBytes([9, 8, 7]);
    });
    tearDown(() async {
      container.dispose();
      await directory.delete(recursive: true);
    });
    test(
      'fresh installation downloads and selects a first managed profile',
      () async {
        profiles.drop();
        final folder = Directory(await appPath.profilesPath);
        await folder.delete(recursive: true);
        final id = await bridge.prepare(uri, null);
        await bridge.activate(id);
        expect(await File(await appPath.getProfilePath('$id')).exists(), true);
        expect(container.read(profilesProvider).single.id, id);
        expect(container.read(currentProfileIdProvider), id);
        expect(profiles.writes, 1);
      },
    );
    test(
      'download validates before replacing and preserves node selection',
      () async {
        expect(await bridge.prepare(uri, 42), 42);
        final config =
            loadYaml(
                  await File(await appPath.getProfilePath('42')).readAsString(),
                )
                as YamlMap;
        expect(config['proxies'][0]['name'], 'Node');
        final profile = container.read(profilesProvider).single;
        expect(profile.selectedMap, old.selectedMap);
        expect(profile.currentGroupName, 'Proxy');
        expect(profile.url, isEmpty);
        expect(profile.autoUpdate, false);
        expect(profiles.writes, 1);
      },
    );
    test(
      'identical data avoids validation, metadata update and reapply',
      () async {
        await bridge.prepare(uri, 42);
        clearInteractions(core);
        await bridge.prepare(uri, 42);
        expect(profiles.writes, 1);
        verifyNever(() => core.validateProfile(any(), any()));
      },
    );
    test(
      'invalid replacement preserves working file and cleans temporary data',
      () async {
        when(
          () => core.validateProfile(any(), any()),
        ).thenAnswer((_) async => 'invalid');
        await expectLater(
          bridge.prepare(uri, 42),
          throwsA(isA<XboardException>()),
        );
        expect(await File(await appPath.getProfilePath('42')).readAsBytes(), [
          9,
          8,
          7,
        ]);
        expect(profiles.writes, 0);
        expect(
          directory
              .listSync(recursive: true)
              .where((e) => e.path.endsWith('.tmp')),
          isEmpty,
        );
      },
    );
    test(
      'failed durable metadata commit rolls back validated file replacement',
      () async {
        profiles.fail = true;
        await expectLater(bridge.prepare(uri, 42), throwsStateError);
        expect(await File(await appPath.getProfilePath('42')).readAsBytes(), [
          9,
          8,
          7,
        ]);
        expect(
          directory
              .listSync(recursive: true)
              .where((e) => e.path.endsWith('.tmp')),
          isEmpty,
        );
      },
    );
    test(
      'node selection edited during download wins over the captured snapshot',
      () async {
        when(() => downloads.download(uri)).thenAnswer((_) async {
          await profiles.putManaged(
            old.copyWith(
              selectedMap: {'Proxy': 'New selection'},
              currentGroupName: 'New group',
            ),
          );
          return Uint8List.fromList(utf8.encode(_subscription));
        });
        await bridge.prepare(uri, 42);
        final profile = container.read(profilesProvider).single;
        expect(profile.selectedMap, {'Proxy': 'New selection'});
        expect(profile.currentGroupName, 'New group');
      },
    );
    test('a deletion during download cannot resurrect the profile', () async {
      when(() => downloads.download(uri)).thenAnswer((_) async {
        profiles.drop();
        return Uint8List.fromList(utf8.encode(_subscription));
      });
      await expectLater(bridge.prepare(uri, 42), throwsStateError);
      expect(container.read(profilesProvider), isEmpty);
      expect(await File(await appPath.getProfilePath('42')).readAsBytes(), [
        9,
        8,
        7,
      ]);
    });
  });
}
