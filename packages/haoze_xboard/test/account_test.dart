import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoze_xboard/account.dart';
import 'package:haoze_xboard/haoze_xboard.dart';

class MemoryStore implements XboardAccountStore {
  XboardSavedAccount? value;
  bool failWrite = false;
  bool failClear = false;
  @override
  Future<XboardSavedAccount?> read() async => value;
  @override
  Future<void> write(XboardSavedAccount account) async {
    if (failWrite) throw StateError('storage');
    value = account;
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('storage');
    value = null;
  }
}

class Profiles implements XboardManagedProfile {
  final events = <String>[];
  bool available = true;
  bool failPrepare = false;
  Completer<void>? preparing;
  @override
  Future<bool> exists(int id) async => available;
  @override
  Future<int> prepare(Uri uri, int? previousId) async {
    events.add('prepare');
    await preparing?.future;
    if (failPrepare) throw StateError('profile');
    return previousId ?? 42;
  }

  @override
  Future<void> activate(int id) async => events.add('activate:$id');
  @override
  Future<void> disconnect() async => events.add('disconnect');
  @override
  Future<void> remove(int id) async => events.add('remove:$id');
}

class Transport implements XboardTransport {
  int userStatus = 200;
  int authStatus = 200;
  bool networkFailure = false;
  int total = 100;
  Completer<void>? pending;
  final requests = <String>[];
  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    requests.add(uri.path);
    if (uri.path.endsWith('/login') || uri.path.endsWith('/register')) {
      return XboardResponse(authStatus, {
        'data': {'auth_data': 'Bearer example', 'token': 'subscription'},
      });
    }
    if (uri.path.endsWith('/config')) {
      return const XboardResponse(200, {
        'data': {'is_captcha': 1},
      });
    }
    await pending?.future;
    if (networkFailure) throw const XboardException(XboardFailure.timeout);
    if (uri.path.endsWith('/info')) {
      return XboardResponse(userStatus, const {
        'data': {'banned': 0},
      });
    }
    return XboardResponse(200, {
      'data': {
        'u': 10,
        'd': 20,
        'transfer_enable': total,
        'expired_at': null,
        'subscribe_url': 'https://example.com/s/private',
      },
    });
  }

  @override
  void close() {}
}

void main() {
  late MemoryStore store;
  late Profiles profiles;
  late Transport transport;
  late XboardAccountController controller;
  setUp(() {
    store = MemoryStore();
    profiles = Profiles();
    transport = Transport();
    controller = XboardAccountController(
      client: XboardClient(
        panelOrigin: Uri.https('example.com'),
        transport: transport,
      ),
      store: store,
      profiles: profiles,
      origin: Uri.https('example.com'),
      coreVersion: 'v1.19.33',
    );
  });
  tearDown(() => controller.close());

  XboardSavedAccount saved({String origin = 'https://example.com'}) =>
      XboardSavedAccount(
        origin: origin,
        email: 'user@example.com',
        session: XboardSession(
          authorization: 'Bearer stored',
          subscriptionToken: 'sub',
        ),
        profileId: 42,
      );

  test(
    'login securely persists before activating one managed profile',
    () async {
      await controller.restore();
      await controller.login('user@example.com', 'secret');
      expect(controller.state.authenticated, true);
      expect(controller.state.subscription?.remaining, 70);
      expect(store.value?.profileId, 42);
      expect(profiles.events, ['prepare', 'activate:42']);
    },
  );
  test(
    'Xboard rejected login is a credential error and permits retry',
    () async {
      for (final status in [400, 401, 403, 422]) {
        transport.authStatus = status;
        await controller.login('user@example.com', 'incorrect');
        expect(controller.state.issue, XboardAccountIssue.credentials);
        expect(controller.state.authenticated, false);
        expect(store.value, isNull);
        expect(profiles.events, isEmpty);
      }
      transport.authStatus = 200;
      await controller.login('user@example.com', 'correct');
      expect(controller.state.authenticated, true);
      expect(controller.state.profileReady, true);
    },
  );
  test('ordinary quota refresh never reapplies profile', () async {
    await controller.login('user@example.com', 'secret');
    profiles.events.clear();
    await controller.refresh();
    expect(profiles.events, isEmpty);
  });
  test(
    'restore is offline, origin-bound and always completes initialization',
    () async {
      store.value = saved();
      await controller.restore();
      expect(transport.requests, isEmpty);
      expect(controller.state.initialized, true);
      expect(controller.state.profileReady, true);
    },
  );
  test(
    'different panel origin cannot restore credentials or managed profile',
    () async {
      store.value = saved(origin: 'https://other.example');
      await controller.restore();
      expect(controller.state.authenticated, false);
      expect(store.value, isNull);
      expect(profiles.events, ['disconnect', 'remove:42']);
    },
  );
  test('expired restored session permits another login', () async {
    store.value = saved();
    await controller.restore();
    transport.userStatus = 403;
    await controller.refresh();
    expect(controller.state.authenticated, false);
    expect(controller.state.initialized, true);
    expect(controller.state.issue, XboardAccountIssue.expiredSession);
    transport.userStatus = 200;
    await controller.login('new@example.com', 'secret');
    expect(controller.state.email, 'new@example.com');
    expect(controller.state.initialized, true);
  });
  test('network failure preserves last quota and local session', () async {
    await controller.login('user@example.com', 'secret');
    transport.networkFailure = true;
    await controller.refresh();
    expect(controller.state.authenticated, true);
    expect(controller.state.subscription?.remaining, 70);
    expect(controller.state.issue, XboardAccountIssue.network);
  });
  test(
    'subscription apply failure is not reported as account expiry',
    () async {
      profiles.failPrepare = true;
      await controller.login('user@example.com', 'secret');
      expect(controller.state.authenticated, true);
      expect(controller.state.profileReady, false);
      expect(controller.state.issue, XboardAccountIssue.profile);
    },
  );
  test(
    'no package login keeps account and skips subscription download',
    () async {
      transport.total = 0;
      await controller.login('user@example.com', 'secret');
      expect(controller.state.authenticated, true);
      expect(controller.state.profileReady, false);
      expect(profiles.events, ['disconnect']);
    },
  );
  test(
    'quota exhaustion stops tunnel and removes only managed profile',
    () async {
      await controller.login('user@example.com', 'secret');
      profiles.events.clear();
      transport.total = 30;
      await controller.refresh();
      expect(profiles.events, ['disconnect', 'remove:42']);
      expect(controller.state.authenticated, true);
      expect(controller.state.profileReady, false);
    },
  );
  test('refresh callers share a single operation', () async {
    store.value = saved();
    await controller.restore();
    transport.pending = Completer<void>();
    final first = controller.refresh();
    final second = controller.refresh();
    expect(identical(first, second), true);
    transport.pending!.complete();
    await first;
    expect(
      transport.requests.where((path) => path.endsWith('/info')).length,
      1,
    );
  });
  test('logout cannot race a pending native profile apply', () async {
    profiles.preparing = Completer<void>();
    final login = controller.login('user@example.com', 'secret');
    await Future<void>.delayed(Duration.zero);
    final logout = controller.logout();
    profiles.preparing!.complete();
    await Future.wait([login, logout]);
    expect(profiles.events, ['prepare', 'disconnect', 'remove:42']);
    expect(controller.state.authenticated, false);
    expect(store.value, isNull);
  });
  test('secure storage failure prevents login and activation', () async {
    store.failWrite = true;
    await controller.login('user@example.com', 'secret');
    expect(controller.state.authenticated, false);
    expect(controller.state.issue, XboardAccountIssue.storage);
    expect(profiles.events, isEmpty);
  });
  test('failed credential deletion cannot claim a successful logout', () async {
    await controller.login('user@example.com', 'secret');
    store.failClear = true;
    await controller.logout();
    expect(controller.state.authenticated, true);
    expect(controller.state.profileReady, false);
    expect(controller.state.issue, XboardAccountIssue.storage);
  });
  test(
    'captcha registration is blocked locally without sending credentials',
    () async {
      await controller.loadConfig();
      await controller.register('user@example.com', 'secret');
      expect(controller.state.authenticated, false);
      expect(controller.state.issue, XboardAccountIssue.credentials);
      expect(
        transport.requests.any((path) => path.endsWith('/register')),
        false,
      );
    },
  );
  test(
    'failed logout locks all subsequent refresh and connection attempts',
    () async {
      await controller.login('user@example.com', 'secret');
      profiles.events.clear();
      store.failClear = true;
      await controller.logout();
      await controller.refresh(syncProfile: true);
      await controller.reconcileProfile();
      expect(controller.canResumeProfile(42), false);
      expect(profiles.events, ['disconnect', 'remove:42']);
      store.failClear = false;
      await controller.logout();
      await controller.login('new@example.com', 'secret');
      expect(controller.canResumeProfile(42), true);
    },
  );
  test(
    'restored identity reconciles a missing selection without downloading',
    () async {
      store.value = saved();
      await controller.restore();
      await controller.reconcileProfile();
      expect(profiles.events, ['activate:42']);
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'crash recovery requires explicit subscription synchronization',
    () async {
      store.value = saved();
      await controller.restore();
      controller.holdProfileRecovery();
      await controller.reconcileProfile();
      await controller.refresh();
      expect(controller.canResumeProfile(42), false);
      expect(profiles.events, isEmpty);
      await controller.refresh(syncProfile: true);
      expect(profiles.events, ['prepare', 'activate:42']);
      expect(controller.canResumeProfile(42), true);
    },
  );
  test(
    'optional update metadata failure does not change account or quota',
    () async {
      await controller.login('user@example.com', 'secret');
      transport.networkFailure = true;
      expect(await controller.appVersion('windows'), isNull);
      expect(controller.state.authenticated, true);
      expect(controller.state.subscription?.remaining, 70);
      expect(controller.state.issue, isNull);
    },
  );
}
