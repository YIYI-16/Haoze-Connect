import 'dart:math' as math;

import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_profile_bridge.dart';
import 'package:hiddify/features/xboard/data/xboard_session_store.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';

/// Test doubles for the panel.
///
/// They live in the test tree only: the app itself never contains a fake
/// backend, and no test ever talks to a real panel.

/// A panel that answers from memory.
class FakeXboardApi implements XboardApi {
  FakeXboardApi({
    this.publicConfig = const XboardPublicConfig(emailVerify: false, inviteForce: false, captchaEnabled: false),
    this.subscriptionPayload,
    this.loginError,
    this.registerError,
    this.publicConfigError,
  });

  XboardPublicConfig publicConfig;
  XboardSubscriptionPayload? subscriptionPayload;
  XboardException? loginError;
  XboardException? registerError;
  XboardException? publicConfigError;

  int loginCalls = 0;
  int registerCalls = 0;
  int sendEmailCodeCalls = 0;
  int subscriptionCalls = 0;
  String? lastEmail;
  String? lastPassword;
  String? lastEmailCode;
  String? lastInviteCode;

  @override
  Future<XboardPublicConfig> fetchPublicConfig() async {
    if (publicConfigError != null) throw publicConfigError!;
    return publicConfig;
  }

  @override
  Future<XboardAuthResult> login({required String email, required String password}) async {
    loginCalls++;
    lastEmail = email;
    lastPassword = password;
    if (loginError != null) throw loginError!;
    return XboardAuthResult(authData: 'Bearer fake-token', email: email);
  }

  @override
  Future<XboardAuthResult> register({
    required String email,
    required String password,
    String? emailCode,
    String? inviteCode,
  }) async {
    registerCalls++;
    lastEmail = email;
    lastPassword = password;
    lastEmailCode = emailCode;
    lastInviteCode = inviteCode;
    if (registerError != null) throw registerError!;
    return XboardAuthResult(authData: 'Bearer fake-register-token', email: email);
  }

  @override
  Future<void> sendEmailCode(String email) async {
    sendEmailCodeCalls++;
    lastEmail = email;
  }

  @override
  Future<XboardSubscriptionPayload> fetchSubscription(String authData) async {
    subscriptionCalls++;
    return subscriptionPayload ?? emptySubscription();
  }

  @override
  void close() {}
}

/// A subscription with a plan that has traffic left.
XboardSubscriptionPayload fakeSubscriptionPayload({
  String url = 'https://sub.example.net/api/v1/client/subscribe?token=abc',
  String planName = 'Monthly',
}) {
  const total = 1000;
  const upload = 100;
  const download = 50;
  return XboardSubscriptionPayload(
    subscription: XboardSubscription(
      upload: upload,
      download: download,
      total: total,
      remaining: math.max(total - upload - download, 0),
      expiresAt: DateTime.now().add(const Duration(days: 30)),
      nextResetAt: DateTime.now().add(const Duration(days: 10)),
      planName: planName,
      isExpired: false,
      hasPlan: true,
      hasTraffic: true,
    ),
    subscribeUrl: url,
  );
}

/// A subscription without a plan, as a fresh account has.
XboardSubscriptionPayload emptySubscription() {
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

/// A secure store that can also fail, to exercise the logout paths.
class FakeXboardStore implements XboardSessionStore {
  FakeXboardStore({this.session});

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

/// A profile bridge that only remembers what it was told to do.
class FakeXboardProfileBridge implements XboardProfileBridge {
  String? activeProfileId;
  final List<String> events = [];
  int applyCalls = 0;
  int profileCounter = 0;

  @override
  Future<String> apply({required String subscribeUrl, String? previousProfileId}) async {
    applyCalls++;
    events.add('apply:$subscribeUrl');
    final id = 'profile-${++profileCounter}';
    activeProfileId = id;
    return id;
  }

  @override
  Future<void> remove(String? profileId) async {
    if (profileId == null || profileId.isEmpty) return;
    events.add('remove:$profileId');
    if (activeProfileId == profileId) activeProfileId = null;
  }

  @override
  Future<void> stopVpn() async {
    events.add('stop');
  }
}

/// The panel the tests talk to.
XboardClientConfig testXboardConfig() {
  return XboardClientConfig.parse(baseUrl: 'https://panel.example.com', appName: 'Test Connect');
}
