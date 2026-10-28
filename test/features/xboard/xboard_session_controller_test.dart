import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_profile_bridge.dart';
import 'package:hiddify/features/xboard/data/xboard_session_store.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';

void main() {
  late XboardClientConfig config;
  late _FakeApi api;
  late _FakeStore store;
  late _FakeBridge bridge;

  setUp(() {
    config = XboardClientConfig.parse(baseUrl: 'https://panel.example.com', appName: 'Test Connect');
    api = _FakeApi();
    store = _FakeStore();
    bridge = _FakeBridge();
  });

  XboardSessionController buildController() {
    return XboardSessionController(api: api, store: store, profiles: bridge, config: config);
  }

  XboardStoredSession storedSession({String email = 'a@example.com', String? profileId}) {
    return XboardStoredSession(
      origin: config.origin,
      authData: 'Bearer stored-token',
      email: email,
      profileId: profileId,
    );
  }

  XboardSubscriptionPayload subscription({
    bool hasPlan = true,
    bool expired = false,
    bool longTerm = false,
    int upload = 100,
    int download = 50,
    int total = 1000,
    String? url = 'https://sub.example.net/api/v1/client/subscribe?token=abc',
  }) {
    final expiresAt = longTerm
        ? null
        : (expired ? DateTime.now().subtract(const Duration(hours: 1)) : DateTime.now().add(const Duration(days: 30)));
    final remaining = math.max(0, total - upload - download);
    return XboardSubscriptionPayload(
      subscription: XboardSubscription(
        upload: upload,
        download: download,
        total: total,
        remaining: remaining,
        expiresAt: expiresAt,
        nextResetAt: DateTime.now().add(const Duration(days: 10)),
        planName: hasPlan ? 'Monthly' : null,
        isExpired: expiresAt != null && !expiresAt.isAfter(DateTime.now()),
        hasPlan: hasPlan,
        hasTraffic: total > 0 && remaining > 0,
      ),
      subscribeUrl: url,
    );
  }

  test('login stores only the Bearer session and activates the managed profile', () async {
    api.loginResult = const XboardAuthResult(authData: 'Bearer token-123', email: 'a@example.com');
    api.subscriptionPayload = subscription();
    final controller = buildController();

    await controller.initialize();
    await controller.login('a@example.com', 'password1');

    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.email, 'a@example.com');
    expect(controller.state.subscriptionReady, isTrue);
    expect(controller.state.subscription?.remaining, 850);
    expect(controller.state.error, isNull);
    expect(store.session?.authData, 'Bearer token-123');
    expect(store.session?.profileId, 'profile-1');
    expect(bridge.activeProfileId, 'profile-1');
    expect(bridge.applyCalls, 1);
  });

  test('new registration without a plan still logs in and does not download a profile', () async {
    api.registerResult = const XboardAuthResult(authData: 'Bearer new-token', email: 'new@example.com');
    api.subscriptionPayload = subscription(hasPlan: false, total: 0, url: null);
    final controller = buildController();

    await controller.register(email: 'new@example.com', password: 'password1', inviteCode: 'invite');

    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.subscriptionReady, isFalse);
    expect(controller.state.subscription?.hasPlan, isFalse);
    expect(controller.state.error, isNull);
    expect(bridge.applyCalls, 0);
    expect(api.registerCalls, 1);
    expect(store.session?.authData, 'Bearer new-token');
  });

  test('registration enforces email verification, invite and captcha switches', () async {
    api.publicConfig = const XboardPublicConfig(emailVerify: true, inviteForce: false, captchaEnabled: false);
    final verifyController = buildController();
    await expectLater(
      verifyController.register(email: 'a@example.com', password: 'password1'),
      throwsA(isA<XboardException>().having((e) => e.message, 'message', contains('邮箱验证码'))),
    );
    expect(api.registerCalls, 0);

    api.publicConfig = const XboardPublicConfig(emailVerify: false, inviteForce: true, captchaEnabled: false);
    final inviteController = buildController();
    await expectLater(
      inviteController.register(email: 'a@example.com', password: 'password1'),
      throwsA(isA<XboardException>().having((e) => e.message, 'message', contains('邀请码'))),
    );
    expect(api.registerCalls, 0);

    api.publicConfig = const XboardPublicConfig(emailVerify: false, inviteForce: false, captchaEnabled: true);
    final captchaController = buildController();
    await expectLater(
      captchaController.register(email: 'a@example.com', password: 'password1'),
      throwsA(isA<XboardException>().having((e) => e.message, 'message', contains('网页'))),
    );
    await expectLater(
      captchaController.sendEmailCode('a@example.com'),
      throwsA(isA<XboardException>().having((e) => e.message, 'message', contains('人机验证'))),
    );
    expect(api.registerCalls, 0);
    expect(api.sendEmailCodeCalls, 0);
  });

  test('expired or exhausted accounts remove the old profile instead of downloading it', () async {
    store.session = storedSession(profileId: 'old-profile');
    api.subscriptionPayload = subscription(expired: true, upload: 10, download: 10);
    final controller = buildController();

    await controller.initialize();

    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.subscriptionReady, isFalse);
    expect(controller.state.error, contains('过期'));
    expect(bridge.applyCalls, 0);
    expect(bridge.events, contains('stop'));
    expect(bridge.events, contains('remove:old-profile'));
    expect(bridge.activeProfileId, isNull);
    expect(store.session?.profileId, isNull);
  });

  test('network failure preserves the session; authenticated 403 clears it', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();
    expect(controller.state.subscriptionReady, isTrue);

    api.subscriptionError = const XboardException('无法连接面板，请检查网络后重试', kind: XboardFailureKind.network);
    await expectLater(controller.refresh(), throwsA(isA<XboardException>()));
    expect(controller.state.isAuthenticated, isTrue);
    expect(store.session, isNotNull);
    expect(bridge.events.where((event) => event.startsWith('remove:')), isEmpty);

    api.subscriptionError = const XboardException('登录状态已失效，请重新登录', kind: XboardFailureKind.unauthorized);
    await expectLater(controller.refresh(), throwsA(isA<XboardException>()));
    expect(controller.state.isAuthenticated, isFalse);
    expect(controller.state.error, contains('失效'));
    expect(store.session, isNull);
    expect(bridge.events, contains('stop'));
    expect(bridge.events, contains('remove:profile-1'));
    expect(bridge.activeProfileId, isNull);
  });

  test('logout stops the tunnel before clearing storage and removing the profile', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();

    await controller.logout();

    expect(controller.state.isAuthenticated, isFalse);
    expect(controller.state.subscription, isNull);
    expect(store.session, isNull);
    expect(bridge.activeProfileId, isNull);
    final stopIndex = bridge.events.indexOf('stop');
    final removeIndex = bridge.events.indexOf('remove:profile-1');
    expect(stopIndex, isNonNegative);
    expect(removeIndex, greaterThan(stopIndex));
  });

  test('a failed native stop keeps the account and profile available for logout retry', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();
    bridge.stopError = const XboardException('native stop failed');
    await expectLater(controller.logout(), throwsA(isA<XboardException>()));
    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.subscriptionReady, isFalse);
    expect(store.session?.profileId, 'profile-1');
    expect(bridge.activeProfileId, 'profile-1');
    expect(bridge.events.where((event) => event.startsWith('remove:')), isEmpty);
    bridge.stopError = null;
    await controller.logout();
    expect(controller.state.isAuthenticated, isFalse);
    expect(store.session, isNull);
  });

  test('a rejected token with failed stop retains the account page and disables starts', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();
    bridge.stopError = const XboardException('native stop failed');
    api.subscriptionError = const XboardException('rejected', kind: XboardFailureKind.unauthorized);
    await expectLater(controller.refresh(), throwsA(isA<XboardException>()));
    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.subscriptionReady, isFalse);
    expect(controller.state.error, contains('无法确认代理已停止'));
    expect(store.session?.profileId, 'profile-1');
    expect(bridge.activeProfileId, 'profile-1');
    bridge.stopError = null;
    await controller.logout();
    expect(store.session, isNull);
  });

  test('a failed secure-storage revoke never silently discards a still-restorable token', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();

    store.failClear = true;
    store.failWrite = true;
    await expectLater(
      controller.logout(),
      throwsA(isA<XboardException>().having((e) => e.message, 'message', contains('无法清除'))),
    );

    // The session is still there, so the account page can show the error and
    // the user can try again.
    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.error, contains('无法清除'));
    expect(store.session?.authData, 'Bearer stored-token');

    // Retry succeeds and is a real logout.
    store.failClear = false;
    store.failWrite = false;
    await controller.logout();
    expect(controller.state.isAuthenticated, isFalse);
    expect(store.session, isNull);
  });

  test('a revoke tombstone wins when deletion fails', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();

    store.failClear = true;
    await controller.logout();

    expect(controller.state.isAuthenticated, isFalse);
    expect(store.session?.revoked, isTrue);
    expect(store.session?.authData, isEmpty);
  });

  test('logout waits for a stale native apply and leaves no active profile', () async {
    store.session = storedSession(profileId: 'old-profile');
    api.subscriptionError = const XboardException('无法连接面板，请检查网络后重试', kind: XboardFailureKind.network);
    final controller = buildController();
    await controller.initialize();

    api.subscriptionError = null;
    api.subscriptionPayload = subscription();
    bridge.applyGate = Completer<String>();
    final refreshFuture = controller.refresh();
    while (bridge.applyCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }

    final logoutFuture = controller.logout();
    bridge.applyGate!.complete('stale-profile');
    await refreshFuture;
    await logoutFuture;

    expect(controller.state.isAuthenticated, isFalse);
    expect(store.session, isNull);
    expect(bridge.activeProfileId, isNull);
    expect(bridge.events, contains('remove:stale-profile'));
  });

  test('concurrent refresh calls share a single panel request', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();

    final callsBefore = api.subscriptionCalls;
    bridge.applyGate = Completer<String>();
    final first = controller.refresh();
    final second = controller.refresh();
    while (api.subscriptionCalls == callsBefore) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.subscriptionCalls, callsBefore + 1);
    bridge.applyGate!.complete('profile-1');
    await Future.wait([first, second]);
    expect(api.subscriptionCalls, callsBefore + 1);
  });

  test('account switch cleanup failure keeps the previous session retryable', () async {
    store.session = storedSession(email: 'old@example.com', profileId: 'old-profile');
    api.subscriptionError = const XboardException('无法连接面板，请检查网络后重试', kind: XboardFailureKind.network);
    final controller = buildController();
    await controller.initialize();
    expect(controller.state.isAuthenticated, isTrue);

    api.loginResult = const XboardAuthResult(authData: 'Bearer new-token', email: 'new@example.com');
    bridge.removeError = const XboardException('清理失败');
    await expectLater(
      controller.login('new@example.com', 'password1'),
      throwsA(isA<XboardException>().having((e) => e.message, 'message', contains('切换账号失败'))),
    );

    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.email, 'old@example.com');
    expect(store.session?.authData, 'Bearer stored-token');
    expect(store.session?.email, 'old@example.com');

    bridge.removeError = null;
    api.subscriptionPayload = subscription(hasPlan: false, total: 0, url: null);
    await controller.login('new@example.com', 'password1');
    expect(controller.state.email, 'new@example.com');
    expect(store.session?.authData, 'Bearer new-token');
    expect(bridge.activeProfileId, isNull);
  });

  test('session bound to a foreign panel origin is revoked without API calls', () async {
    store.session = const XboardStoredSession(
      origin: 'https://other.example.com',
      authData: 'Bearer foreign',
      email: 'a@example.com',
      profileId: 'foreign-profile',
    );
    final controller = buildController();

    await controller.initialize();

    expect(controller.state.isAuthenticated, isFalse);
    expect(controller.state.initialized, isTrue);
    expect(api.subscriptionCalls, 0);
    expect(store.session, isNull);
    expect(bridge.applyCalls, 0);
  });

  test('restores a persisted session and profile id across restarts', () async {
    store.session = storedSession(profileId: 'profile-1');
    api.subscriptionPayload = subscription();
    final controller = buildController();

    await controller.initialize();

    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.subscriptionReady, isTrue);
    expect(bridge.applyCalls, 1);
    expect(bridge.activeProfileId, 'profile-1');
    expect(store.session?.profileId, 'profile-1');
    expect(controller.managedProfileId, 'profile-1');
  });

  test('a rejected stored token finishes initialization so the login page can be used', () async {
    store.session = storedSession(profileId: 'stale-profile');
    api.subscriptionError = const XboardException('登录状态已失效，请重新登录', kind: XboardFailureKind.unauthorized);
    final controller = buildController();

    await controller.initialize();

    // The router waits for `initialized` before it leaves /login, so an
    // invalid token must not leave the app in its loading gate forever.
    expect(controller.state.initialized, isTrue);
    expect(controller.state.isAuthenticated, isFalse);
    expect(controller.state.error, contains('失效'));
    expect(store.session, isNull);
    expect(bridge.events, contains('stop'));
    expect(bridge.events, contains('remove:stale-profile'));

    // And the user can sign in again on the very same controller.
    api.subscriptionError = null;
    api.loginResult = const XboardAuthResult(authData: 'Bearer fresh-token', email: 'a@example.com');
    api.subscriptionPayload = subscription();
    await controller.login('a@example.com', 'password1');

    expect(controller.state.initialized, isTrue);
    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.subscriptionReady, isTrue);
    expect(store.session?.authData, 'Bearer fresh-token');
  });

  test('an account switch never shows the usage of the previous account', () async {
    store.session = storedSession(email: 'old@example.com', profileId: 'old-profile');
    api.subscriptionPayload = subscription();
    final controller = buildController();
    await controller.initialize();

    expect(controller.state.subscription, isNotNull);
    expect(controller.state.subscriptionReady, isTrue);
    expect(controller.state.lastUpdated, isNotNull);

    api.loginResult = const XboardAuthResult(authData: 'Bearer new-token', email: 'new@example.com');
    api.subscriptionError = const XboardException('无法连接面板，请检查网络后重试', kind: XboardFailureKind.network);
    await controller.login('new@example.com', 'password1');

    expect(controller.state.email, 'new@example.com');
    expect(controller.state.isAuthenticated, isTrue);
    // The old plan, traffic and "ready" state are gone: the new account has
    // nothing to show until its own subscription arrives.
    expect(controller.state.subscription, isNull);
    expect(controller.state.subscriptionReady, isFalse);
    expect(controller.state.lastUpdated, isNull);
    expect(controller.state.error, contains('无法连接'));
    expect(store.session?.authData, 'Bearer new-token');
  });

  test('the connection gate follows the account state', () {
    const ready = XboardSessionState(
      initialized: true,
      isAuthenticated: true,
      subscriptionReady: true,
      subscription: XboardSubscription(
        upload: 1,
        download: 1,
        total: 100,
        remaining: 98,
        isExpired: false,
        hasPlan: true,
        hasTraffic: true,
      ),
    );

    expect(xboardAllowsConnection(ready), isTrue);
    expect(xboardAllowsConnection(ready.copyWith(isAuthenticated: false)), isFalse);
    expect(xboardAllowsConnection(ready.copyWith(initialized: false)), isFalse);
    expect(xboardAllowsConnection(ready.copyWith(subscriptionReady: false)), isFalse);
    expect(
      xboardAllowsConnection(ready.copyWith(subscription: ready.subscription!.copyWith(isExpired: true))),
      isFalse,
    );
    expect(
      xboardAllowsConnection(
        ready.copyWith(subscription: ready.subscription!.copyWith(hasTraffic: false, remaining: 0)),
      ),
      isFalse,
    );
  });
}

class _FakeApi implements XboardApi {
  XboardPublicConfig publicConfig = const XboardPublicConfig(
    emailVerify: false,
    inviteForce: false,
    captchaEnabled: false,
  );
  XboardAuthResult? loginResult;
  XboardAuthResult? registerResult;
  XboardSubscriptionPayload? subscriptionPayload;
  XboardException? publicConfigError;
  XboardException? loginError;
  XboardException? registerError;
  XboardException? subscriptionError;

  int publicConfigCalls = 0;
  int loginCalls = 0;
  int registerCalls = 0;
  int sendEmailCodeCalls = 0;
  int subscriptionCalls = 0;
  String? lastEmailCode;
  String? lastInviteCode;

  @override
  Future<XboardPublicConfig> fetchPublicConfig() async {
    publicConfigCalls++;
    if (publicConfigError != null) throw publicConfigError!;
    return publicConfig;
  }

  @override
  Future<XboardAuthResult> login({required String email, required String password}) async {
    loginCalls++;
    if (loginError != null) throw loginError!;
    return loginResult ?? XboardAuthResult(authData: 'Bearer token', email: email);
  }

  @override
  Future<XboardAuthResult> register({
    required String email,
    required String password,
    String? emailCode,
    String? inviteCode,
  }) async {
    registerCalls++;
    lastEmailCode = emailCode;
    lastInviteCode = inviteCode;
    if (registerError != null) throw registerError!;
    return registerResult ?? XboardAuthResult(authData: 'Bearer token', email: email);
  }

  @override
  Future<void> sendEmailCode(String email) async {
    sendEmailCodeCalls++;
  }

  @override
  Future<XboardSubscriptionPayload> fetchSubscription(String authData) async {
    subscriptionCalls++;
    if (subscriptionError != null) throw subscriptionError!;
    return subscriptionPayload ?? _emptySubscription();
  }

  XboardSubscriptionPayload _emptySubscription() {
    return const XboardSubscriptionPayload(
      subscription: XboardSubscription(
        upload: 0,
        download: 0,
        total: 0,
        remaining: 0,
        isExpired: false,
        hasPlan: false,
        hasTraffic: false,
      ),
      subscribeUrl: null,
    );
  }

  @override
  void close() {}
}

class _FakeStore implements XboardSessionStore {
  XboardStoredSession? session;
  bool failRead = false;
  bool failWrite = false;
  bool failClear = false;

  @override
  Future<XboardStoredSession?> read() async {
    if (failRead) throw StateError('secure storage unavailable');
    final value = session;
    if (value == null || value.revoked) return null;
    return value;
  }

  @override
  Future<void> write(XboardStoredSession value) async {
    if (failWrite) throw StateError('secure storage write failed');
    session = value;
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('secure storage delete failed');
    session = null;
  }
}

class _FakeBridge implements XboardProfileBridge {
  String? activeProfileId;
  final List<String> events = [];
  Completer<String>? applyGate;
  XboardException? applyError;
  XboardException? removeError;
  XboardException? stopError;
  int applyCalls = 0;

  @override
  Future<String> apply({required String subscribeUrl, String? previousProfileId}) async {
    applyCalls++;
    events.add('apply:$subscribeUrl');
    if (applyGate != null) {
      final id = await applyGate!.future;
      activeProfileId = id;
      return id;
    }
    if (applyError != null) throw applyError!;
    final id = 'profile-$applyCalls';
    if (previousProfileId != null && previousProfileId != id) {
      events.add('drop:$previousProfileId');
    }
    activeProfileId = id;
    return id;
  }

  @override
  Future<void> remove(String? profileId) async {
    if (profileId == null || profileId.isEmpty) return;
    events.add('remove:$profileId');
    if (removeError != null) throw removeError!;
    if (activeProfileId == profileId) activeProfileId = null;
  }

  @override
  Future<void> stopVpn() async {
    events.add('stop');
    if (stopError != null) throw stopError!;
  }
}
