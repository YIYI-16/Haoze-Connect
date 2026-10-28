import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_data_providers.dart';
import 'package:hiddify/features/xboard/data/xboard_session_store.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';
import 'package:hiddify/features/xboard/widget/xboard_account_page.dart';
import 'package:hiddify/features/xboard/widget/xboard_login_page.dart';
import 'package:hiddify/features/xboard/widget/xboard_register_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'xboard_test_fakes.dart';

/// Behavior tests of the real Xboard screens.
///
/// The controller is the real one; the panel, the secure store and the profile
/// bridge are fakes injected through provider overrides. Nothing here talks to
/// a real panel, registers an account or sends an email.
void main() {
  late FakeXboardApi api;
  late FakeXboardStore store;
  late FakeXboardProfileBridge bridge;

  setUp(() {
    api = FakeXboardApi(subscriptionPayload: fakeSubscriptionPayload());
    store = FakeXboardStore();
    bridge = FakeXboardProfileBridge();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    required String initialLocation,
    Size size = const Size(360, 800),
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(path: '/login', builder: (_, _) => const XboardLoginPage()),
        GoRoute(path: '/register', builder: (_, _) => const XboardRegisterPage()),
        GoRoute(path: '/account', builder: (_, _) => const XboardAccountPage()),
        GoRoute(path: '/home', builder: (_, _) => const Scaffold(body: Center(child: Text('HOME-SENTINEL')))),
        GoRoute(path: '/home/proxies', builder: (_, _) => const Scaffold(body: Center(child: Text('PROXIES-SENTINEL')))),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          xboardClientConfigProvider.overrideWithValue(testXboardConfig()),
          xboardApiProvider.overrideWithValue(api),
          xboardSessionStoreProvider.overrideWithValue(store),
          xboardProfileBridgeProvider.overrideWithValue(bridge),
        ],
        // The platform comes from the theme: the debug override would trip the
        // framework's "a foundation debug variable was changed" invariant.
        child: MaterialApp.router(routerConfig: router, theme: ThemeData(platform: platform)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the login screen renders on a narrow Android screen without overflow', (tester) async {
    await pumpScreen(tester, initialLocation: '/login');

    expect(find.text('欢迎回来'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the login screen renders on a wide Windows screen without overflow', (tester) async {
    await pumpScreen(
      tester,
      initialLocation: '/login',
      size: const Size(1280, 900),
      platform: TargetPlatform.windows,
    );

    expect(find.text('欢迎回来'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the register screen renders on a narrow Android screen without overflow', (tester) async {
    await pumpScreen(tester, initialLocation: '/register');

    expect(find.text('创建账号'), findsOneWidget);
    expect(find.text('注册并登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the register screen renders on a wide Windows screen without overflow', (tester) async {
    await pumpScreen(
      tester,
      initialLocation: '/register',
      size: const Size(1280, 900),
      platform: TargetPlatform.windows,
    );

    expect(find.text('创建账号'), findsOneWidget);
    expect(find.text('注册并登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mismatched confirmation password never reaches the panel', (tester) async {
    await pumpScreen(tester, initialLocation: '/register');

    await tester.enterText(find.byType(TextFormField).at(0), 'user@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.enterText(find.byType(TextFormField).at(2), 'password456');
    await tester.tap(find.text('注册并登录'));
    await tester.pumpAndSettle();

    expect(find.text('两次输入的密码不一致'), findsOneWidget);
    expect(api.registerCalls, 0);
  });

  testWidgets('a panel without a reachable config offers a retry instead of a form', (tester) async {
    api.publicConfigError = const XboardException('无法连接面板，请检查网络后重试', kind: XboardFailureKind.network);
    await pumpScreen(tester, initialLocation: '/register');

    expect(find.text('无法获取面板配置，请稍后重试'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
    expect(api.registerCalls, 0);
  });

  testWidgets('the email verification switch adds the code field', (tester) async {
    api.publicConfig = const XboardPublicConfig(emailVerify: true, inviteForce: false, captchaEnabled: false);
    await pumpScreen(tester, initialLocation: '/register');

    expect(find.widgetWithText(TextFormField, '邮箱验证码'), findsOneWidget);
    expect(find.text('获取验证码'), findsOneWidget);
    // The invite code stays optional when the panel does not force it.
    expect(find.widgetWithText(TextFormField, '邀请码（选填）'), findsOneWidget);
  });

  testWidgets('the invite switch makes the invite code mandatory', (tester) async {
    api.publicConfig = const XboardPublicConfig(emailVerify: false, inviteForce: true, captchaEnabled: false);
    await pumpScreen(tester, initialLocation: '/register');

    expect(find.widgetWithText(TextFormField, '邀请码'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), 'user@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.enterText(find.byType(TextFormField).at(2), 'password123');
    await tester.tap(find.text('注册并登录'));
    await tester.pumpAndSettle();

    expect(find.text('该面板需要邀请码'), findsOneWidget);
    expect(api.registerCalls, 0);
  });

  testWidgets('the captcha switch blocks the registration and points to the website', (tester) async {
    api.publicConfig = const XboardPublicConfig(emailVerify: false, inviteForce: false, captchaEnabled: true);
    await pumpScreen(tester, initialLocation: '/register');

    expect(find.text('该面板开启了人机验证'), findsOneWidget);
    expect(find.text('打开网站注册'), findsOneWidget);

    // The submit button is disabled, so nothing is sent to the panel.
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '注册并登录'));
    expect(button.onPressed, isNull);
    expect(api.registerCalls, 0);
  });

  testWidgets('a successful login lands on the home screen', (tester) async {
    await pumpScreen(tester, initialLocation: '/login');

    await tester.enterText(find.byType(TextFormField).at(0), 'user@example.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(api.loginCalls, 1);
    expect(api.lastEmail, 'user@example.com');
    expect(find.text('HOME-SENTINEL'), findsOneWidget);
  });

  testWidgets('a logout that cannot clear the storage keeps the account page and shows the error', (tester) async {
    store.session = const XboardStoredSession(
      origin: 'https://panel.example.com',
      authData: 'Bearer stored-token',
      email: 'user@example.com',
      profileId: 'profile-1',
    );
    await pumpScreen(tester, initialLocation: '/account');

    expect(find.text('user@example.com'), findsOneWidget);

    store.failClear = true;
    store.failWrite = true;

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();

    // The account page is still there with the error, and the app did not
    // navigate to the login screen.
    expect(find.text('我的账户'), findsOneWidget);
    expect(find.text('无法清除本地登录状态，请重试退出登录'), findsOneWidget);
    expect(find.text('HOME-SENTINEL'), findsNothing);
  });
}
