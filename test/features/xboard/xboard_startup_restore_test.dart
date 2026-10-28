import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_session_store.dart';
import 'package:hiddify/features/xboard/data/xboard_startup_restore.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';

import '../xboard_ui/xboard_test_fakes.dart';

void main() {
  late _StartupApi api;
  late FakeXboardStore store;
  late FakeXboardProfileBridge bridge;
  late XboardSessionController controller;

  setUp(() {
    api = _StartupApi();
    store = FakeXboardStore(
      session: const XboardStoredSession(
        origin: 'https://panel.example.com',
        authData: 'Bearer saved-test-token',
        email: 'user@example.com',
        profileId: 'saved-profile',
      ),
    );
    bridge = FakeXboardProfileBridge();
    controller = XboardSessionController(api: api, store: store, profiles: bridge, config: testXboardConfig());
    addTearDown(controller.dispose);
  });

  test('a slow panel still restores once after the saved account becomes ready', () async {
    final config = Completer<XboardPublicConfig>();
    api.configGate = config;
    var restored = 0;

    final pending = restoreXboardConnectionOnStartup(
      session: controller,
      connectionAllowed: () => xboardAllowsConnection(controller.state),
      activeProfileId: () async => bridge.activeProfileId,
      restoreConnection: () async {
        expect(xboardAllowsConnection(controller.state), isTrue);
        restored++;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.isAuthenticated, isTrue);
    expect(controller.state.initialized, isFalse);
    expect(restored, 0);

    config.complete(api.publicConfig);
    await pending;
    expect(controller.state.initialized, isTrue);
    expect(controller.managedProfileId, bridge.activeProfileId);
    expect(restored, 1);
  });

  test('a rejected saved token never reaches the connection restore callback', () async {
    api.rejectSubscription = true;
    var restored = 0;
    await restoreXboardConnectionOnStartup(
      session: controller,
      connectionAllowed: () => xboardAllowsConnection(controller.state),
      activeProfileId: () async => 'saved-profile',
      restoreConnection: () async => restored++,
    );
    expect(controller.state.initialized, isTrue);
    expect(controller.state.isAuthenticated, isFalse);
    expect(restored, 0);
  });

  test('an unrelated active profile is not restored for the saved account', () async {
    var restored = 0;
    await restoreXboardConnectionOnStartup(
      session: controller,
      connectionAllowed: () => xboardAllowsConnection(controller.state),
      activeProfileId: () async => 'unmanaged-profile',
      restoreConnection: () async => restored++,
    );
    expect(xboardAllowsConnection(controller.state), isTrue);
    expect(restored, 0);
  });

  test('a fresh installation does not attempt a previous connection', () async {
    store.session = null;
    var restored = 0;
    await restoreXboardConnectionOnStartup(
      session: controller,
      connectionAllowed: () => xboardAllowsConnection(controller.state),
      activeProfileId: () async => 'unmanaged-profile',
      restoreConnection: () async => restored++,
    );
    expect(controller.state.initialized, isTrue);
    expect(restored, 0);
  });

  test('logout while the active profile is loading cancels restoration', () async {
    final lookupStarted = Completer<void>();
    final activeId = Completer<String?>();
    var restored = 0;
    final pending = restoreXboardConnectionOnStartup(
      session: controller,
      connectionAllowed: () => xboardAllowsConnection(controller.state),
      activeProfileId: () {
        lookupStarted.complete();
        return activeId.future;
      },
      restoreConnection: () async => restored++,
    );
    await lookupStarted.future;
    final previousId = controller.managedProfileId;
    await controller.logout();
    activeId.complete(previousId);
    await pending;
    expect(controller.state.isAuthenticated, isFalse);
    expect(restored, 0);
  });
}

class _StartupApi extends FakeXboardApi {
  _StartupApi() : super(subscriptionPayload: fakeSubscriptionPayload());

  Completer<XboardPublicConfig>? configGate;
  bool rejectSubscription = false;

  @override
  Future<XboardPublicConfig> fetchPublicConfig() => configGate?.future ?? super.fetchPublicConfig();

  @override
  Future<XboardSubscriptionPayload> fetchSubscription(String authData) {
    if (rejectSubscription) {
      throw const XboardException('登录状态已失效，请重新登录', kind: XboardFailureKind.unauthorized);
    }
    return super.fetchSubscription(authData);
  }
}
