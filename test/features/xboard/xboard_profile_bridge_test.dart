import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_data_providers.dart';
import 'package:hiddify/features/xboard/data/xboard_session_store.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late _Profiles profiles;
  late _Connections connections;
  late _Store store;
  late _Api api;
  late ProviderContainer container;
  final config = XboardClientConfig.parse(baseUrl: 'https://panel.example.com', appName: 'Test');

  setUp(() async {
    SharedPreferences.setMockInitialValues({'haptic_feedback': false});
    profiles = _Profiles();
    connections = _Connections();
    store = _Store(
      XboardStoredSession(
        origin: config.origin,
        authData: 'Bearer test',
        email: 'test@example.com',
        profileId: 'managed-1',
      ),
    );
    api = _Api();
    container = ProviderContainer(
      overrides: [
        xboardClientConfigProvider.overrideWithValue(config),
        xboardApiProvider.overrideWithValue(api),
        xboardSessionStoreProvider.overrideWithValue(store),
        profileRepositoryProvider.overrideWith((ref) => Future<ProfileRepository>.value(profiles)),
        profileDataSourceProvider.overrideWithValue(_DataSource(profiles)),
        connectionRepositoryProvider.overrideWithValue(connections),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      ],
    );
    await container.read(sharedPreferencesProvider.future);
    await container.read(connectionNotifierProvider.future);
    await container.read(xboardSessionProvider.notifier).initialize();
  });

  tearDown(() async {
    container.dispose();
    await profiles.changes.close();
  });

  test('real bridge reloads same URL and ID once, and rotation once after ownership commit', () async {
    final controller = container.read(xboardSessionProvider.notifier);
    expect(controller.state.subscriptionReady, isTrue);
    expect(connections.reloadedIds, ['managed-1']);

    await controller.refresh();
    expect(connections.reloadedIds, ['managed-1', 'managed-1']);
    expect(store.session?.profileId, 'managed-1');

    profiles.nextId = 'managed-2';
    api.url = 'https://sub.example.com/rotated';
    await controller.refresh();
    // Drain delayed database events as well: they must not trigger a second reload.
    await Future<void>.delayed(Duration.zero);
    expect(connections.reloadedIds, ['managed-1', 'managed-1', 'managed-2']);
    expect(store.session?.profileId, 'managed-2');
    expect(controller.state.subscriptionReady, isTrue);
  });

  test('native reload Left leaves the subscription unavailable and surfaces an error', () async {
    connections.failReload = true;
    final controller = container.read(xboardSessionProvider.notifier);
    await controller.refresh();
    expect(controller.state.subscriptionReady, isFalse);
    expect(controller.state.error, contains('无法应用'));
  });

  test('a rejected token with native stop Left retains retryable cleanup and blocks starts', () async {
    connections.failStop = true;
    api.rejectToken = true;
    final controller = container.read(xboardSessionProvider.notifier);
    await expectLater(controller.refresh(), throwsA(isA<XboardException>()));
    expect(controller.state.isAuthenticated, isTrue);
    expect(container.read(xboardConnectionAllowedProvider), isFalse);
    expect(controller.state.error, contains('无法确认代理已停止'));
    expect(store.session?.profileId, 'managed-1');
    expect(profiles.deleted, isEmpty);
    connections.failStop = false;
    await controller.logout();
    expect(store.session, isNull);
    expect(profiles.deleted, ['managed-1']);
  });

  test('logout retries credential cleanup after the profile row was already removed', () async {
    store.failRevoke = true;
    final controller = container.read(xboardSessionProvider.notifier);
    await expectLater(controller.logout(), throwsA(isA<XboardException>()));
    expect(controller.state.isAuthenticated, isTrue);
    expect(profiles.entry, isNull);
    expect(store.session, isNotNull);
    store.failRevoke = false;
    await controller.logout();
    expect(store.session, isNull);
    expect(profiles.deleted, ['managed-1']);
  });

  test('real bridge preserves token and profile after native stop Left and retries from AsyncError', () async {
    connections.failStop = true;
    final controller = container.read(xboardSessionProvider.notifier);
    await expectLater(controller.logout(), throwsA(isA<XboardException>()));
    expect(connections.stopCalls, 1);
    expect(container.read(connectionNotifierProvider).hasError, isTrue);
    expect(store.session?.profileId, 'managed-1');
    expect(profiles.deleted, isEmpty);
    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.subscriptionReady, isFalse);

    connections.failStop = false;
    await controller.logout();
    expect(connections.stopCalls, 2);
    expect(profiles.deleted, ['managed-1']);
    expect(store.session, isNull);
    expect(controller.state.isAuthenticated, isFalse);
  });
}

class _Api implements XboardApi {
  String url = 'https://sub.example.com/current';
  bool rejectToken = false;

  @override
  Future<XboardPublicConfig> fetchPublicConfig() async =>
      const XboardPublicConfig(emailVerify: false, inviteForce: false, captchaEnabled: false);

  @override
  Future<XboardSubscriptionPayload> fetchSubscription(String authData) async {
    if (rejectToken) throw const XboardException('rejected', kind: XboardFailureKind.unauthorized);
    return XboardSubscriptionPayload(
      subscription: const XboardSubscription(
        upload: 0,
        download: 0,
        total: 1000,
        remaining: 1000,
        isExpired: false,
        hasPlan: true,
        hasTraffic: true,
      ),
      subscribeUrl: url,
    );
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements XboardSessionStore {
  _Store(this.session);
  XboardStoredSession? session;
  bool failRevoke = false;
  @override
  Future<XboardStoredSession?> read() async => session;
  @override
  Future<void> write(XboardStoredSession value) async {
    if (failRevoke) throw StateError('storage unavailable');
    session = value;
  }

  @override
  Future<void> clear() async {
    if (failRevoke) throw StateError('storage unavailable');
    session = null;
  }
}

class _Profiles implements ProfileRepository {
  String nextId = 'managed-1';
  int updates = 0;
  ProfileEntry? entry = ProfileEntry(
    id: 'managed-1',
    type: ProfileType.remote,
    active: true,
    name: 'Managed',
    url: 'https://sub.example.com/current',
    lastUpdate: DateTime(2026),
    pinned: false,
  );
  final changes = StreamController<ProfileEntry?>.broadcast();
  final deleted = <String>[];

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken}) =>
      TaskEither(() async {
        entry = entry!.copyWith(id: nextId, url: Value(url), lastUpdate: DateTime(2026, 1, 1, 0, 0, ++updates));
        changes.add(entry);
        return right(unit);
      });

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) => TaskEither.of(entry?.toEntity());

  @override
  TaskEither<ProfileFailure, Unit> setAsActive(String id) => TaskEither(() async {
    changes.add(entry);
    return right(unit);
  });

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) => TaskEither(() async {
    deleted.add(id);
    if (entry?.id == id) {
      entry = null;
      changes.add(null);
    }
    return right(unit);
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DataSource implements ProfileDataSource {
  _DataSource(this.profiles);
  final _Profiles profiles;
  @override
  Future<ProfileEntry?> getByUrl(String url) async => profiles.entry;
  @override
  Stream<ProfileEntry?> watchActiveProfile() async* {
    yield profiles.entry;
    yield* profiles.changes.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connections implements ConnectionRepository {
  bool failStop = false;
  bool failReload = false;
  int stopCalls = 0;
  final reloadedIds = <String>[];
  @override
  SingboxConfigOption? get configOptionsSnapshot => null;
  @override
  Stream<ConnectionStatus> watchConnectionStatus() => Stream.value(const Connected());
  @override
  TaskEither<ConnectionFailure, Unit> disconnect() {
    stopCalls++;
    return failStop ? TaskEither.left(const ConnectionFailure.unexpected('stop failed')) : TaskEither.of(unit);
  }

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity profile, bool disableMemoryLimit) {
    reloadedIds.add(profile.id);
    return failReload ? TaskEither.left(const ConnectionFailure.unexpected('reload failed')) : TaskEither.of(unit);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
