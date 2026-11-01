import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fl_clash/features/haoze/account.dart';
import 'package:fl_clash/features/haoze/account_view.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haoze_xboard/account.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

class _Store implements XboardAccountStore {
  XboardSavedAccount? account;
  @override
  Future<XboardSavedAccount?> read() async => account;
  @override
  Future<void> write(XboardSavedAccount value) async => account = value;
  @override
  Future<void> clear() async => account = null;
}

class _Profiles implements XboardManagedProfile {
  int preparations = 0;
  @override
  Future<bool> exists(int id) async => true;
  @override
  Future<int> prepare(Uri uri, int? previousId) async {
    preparations++;
    return 42;
  }

  @override
  Future<void> activate(int id) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> remove(int id) async {}
}

class _Transport implements XboardTransport {
  bool rejectLogin = false;
  Map<String, Object?>? registrationBody;
  bool configFailure = false;
  final config = <String, dynamic>{'is_email_verify': 0, 'is_captcha': 0};
  final paths = <String>[];
  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    paths.add(uri.path);
    if (uri.path.endsWith('/register')) registrationBody = body;
    if (uri.path.endsWith('/login') || uri.path.endsWith('/register')) {
      return XboardResponse(rejectLogin ? 422 : 200, const {
        'data': {'auth_data': 'Bearer unit', 'token': 'unit-subscription'},
      });
    }
    if (uri.path.endsWith('/config')) {
      if (configFailure) throw const XboardException(XboardFailure.timeout);
      return XboardResponse(200, {'data': config});
    }
    if (uri.path.endsWith('/info')) {
      return const XboardResponse(200, {
        'data': {'banned': 0},
      });
    }
    return const XboardResponse(200, {
      'data': {
        'u': 1024,
        'd': 1024,
        'transfer_enable': 4096,
        'expired_at': null,
        'subscribe_url': 'https://example.com/s/unit',
      },
    });
  }

  @override
  void close() {}
}

class _Account extends HaozeAccount {
  _Account(this.engine);
  final XboardAccountController engine;
  @override
  XboardAccountState build() {
    controller = engine;
    engine.onChanged = (value) {
      if (ref.mounted) state = value;
    };
    ref.onDispose(engine.close);
    return engine.state;
  }
}

class _NoTraffic extends CommonAction {
  @override
  Future<void> updateTraffic() async {}
}

class _FailedProfileSetup extends SetupAction {
  final events = <String>[];
  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    events.add('apply');
    return false;
  }

  @override
  Future<bool> setCoreRunning(bool running) async {
    events.add(running ? 'start' : 'stop');
    return true;
  }

  @override
  void resetCoreTraffic() {}
}

class _DeniedAuthorizationSetup extends _FailedProfileSetup {
  @override
  Future<AuthorizeCode> authorizeCore() async => AuthorizeCode.error;

  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async {
    events.add('authorize');
    await requestAdmin(true);
    return true;
  }
}

class _NativeVpnAuthorizationSetup extends _DeniedAuthorizationSetup {
  int desktopRequests = 0;
  @override
  bool get usesNativeVpnPermission => true;
  @override
  Future<AuthorizeCode> authorizeCore() async {
    desktopRequests++;
    return AuthorizeCode.error;
  }
}

void main() {
  const captures = String.fromEnvironment('HAOZE_PREVIEW_DIR');
  final boundaryKey = GlobalKey();
  setUpAll(() async {
    const fontPath = String.fromEnvironment('HAOZE_PREVIEW_FONT');
    if (captures.isNotEmpty && fontPath.isNotEmpty) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
      await loader.load();
    }
  });
  late _Transport transport;
  late _Profiles profiles;
  late XboardAccountController engine;
  setUp(() async {
    transport = _Transport();
    profiles = _Profiles();
    engine = XboardAccountController(
      client: XboardClient(
        panelOrigin: Uri.https('example.com'),
        transport: transport,
      ),
      store: _Store(),
      profiles: profiles,
      origin: Uri.https('example.com'),
      coreVersion: 'v1.19.33',
    );
    await engine.restore();
    await engine.loadConfig();
  });
  tearDown(() => engine.close());

  Future<void> open(
    WidgetTester tester, {
    bool account = false,
    Size size = const Size(390, 844),
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TestApp(
        locale: const Locale('en'),
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
        ).withAppShapes.withAppTypography.withAppSurfaces,
        overrides: [
          haozeAccountProvider.overrideWith(() => _Account(engine)),
          initProvider.overrideWithBuild((_, _) => true),
          viewSizeProvider.overrideWithBuild((_, _) => size),
        ],
        child: RepaintBoundary(
          key: boundaryKey,
          child: account
              ? const HaozeAccountView()
              : const HaozeAccountGate(child: Text('authenticated-home')),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    if (captures.isNotEmpty) {
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(captures);
        await directory.create(recursive: true);
        final file = File(
          '$captures/${account ? 'account' : 'login'}-${size.width.toInt()}-${dark ? 'dark' : 'light'}.png',
        );
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  }

  Future<void> credentials(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('haoze-email')),
      'user@example.com',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('haoze-password')),
        matching: find.byType(EditableText),
      ),
      'example-password',
    );
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('haoze-submit')));
    await tester.tap(find.byKey(const ValueKey('haoze-submit')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'login activates automatic subscription without asking for a URL',
    (tester) async {
      await open(tester);
      await credentials(tester);
      await submit(tester);
      expect(find.text('authenticated-home'), findsOneWidget);
      expect(profiles.preparations, 1);
    },
  );
  testWidgets('failed login shows error and allows retry', (tester) async {
    transport.rejectLogin = true;
    await open(tester);
    await credentials(tester);
    await submit(tester);
    expect(
      find.textContaining('Sign-in or registration was rejected'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('haoze-submit')))
          .onPressed,
      isNotNull,
    );
    transport.rejectLogin = false;
    await submit(tester);
    expect(find.text('authenticated-home'), findsOneWidget);
  });
  testWidgets(
    'captcha registration is blocked while password login remains available',
    (tester) async {
      transport.config['is_captcha'] = 1;
      await tester.runAsync(engine.loadConfig);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('haoze-auth-toggle')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This panel requires a security check'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('haoze-submit')))
            .onPressed,
        isNull,
      );
      expect(transport.paths.any((path) => path.endsWith('/register')), false);
    },
  );
  testWidgets('registration config failures expose a retry', (tester) async {
    transport.configFailure = true;
    // Keep the failure state while starting from a controller with no cached config.
    engine.close();
    engine = XboardAccountController(
      client: XboardClient(
        panelOrigin: Uri.https('example.com'),
        transport: transport,
      ),
      store: _Store(),
      profiles: profiles,
      origin: Uri.https('example.com'),
      coreVersion: 'v1.19.33',
    );
    await tester.runAsync(engine.restore);
    await tester.runAsync(engine.loadConfig);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('haoze-auth-toggle')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(
      find.text('Registration settings could not be loaded.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    transport.configFailure = false;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(
      find.text('Registration settings could not be loaded.'),
      findsNothing,
    );
  });

  testWidgets(
    'registration enforces terms and forwards required email and invitation codes',
    (tester) async {
      transport.config.addAll({
        'is_email_verify': 1,
        'is_invite_force': 1,
        'tos_url': 'https://example.com/terms',
      });
      await tester.runAsync(engine.loadConfig);
      await open(tester, size: const Size(1200, 1000));
      await tester.tap(find.byKey(const ValueKey('haoze-auth-toggle')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('haoze-submit')))
            .onPressed,
        isNull,
      );
      await credentials(tester);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('haoze-confirmation')),
          matching: find.byType(EditableText),
        ),
        'example-password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('haoze-email-code')),
        '123456',
      );
      await tester.enterText(
        find.byKey(const ValueKey('haoze-invite')),
        'invite',
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await submit(tester);
      expect(find.text('authenticated-home'), findsOneWidget);
      expect(transport.registrationBody?['email_code'], '123456');
      expect(transport.registrationBody?['invite_code'], 'invite');
    },
  );
  test(
    'managed tunnel never starts while applying its profile fails',
    () async {
      await engine.login('user@example.com', 'example-password');
      final setup = _FailedProfileSetup();
      final container = ProviderContainer(
        overrides: [
          haozeAccountProvider.overrideWith(() => _Account(engine)),
          setupActionProvider.overrideWith(() => setup),
          commonActionProvider.overrideWith(_NoTraffic.new),
          currentProfileIdProvider.overrideWithBuild((_, _) => 42),
          initProvider.overrideWithBuild((_, _) => true),
        ],
      );
      addTearDown(container.dispose);
      container.read(haozeAccountProvider);
      expect(
        await container.read(setupActionProvider.notifier).setRunning(true),
        false,
      );
      expect(setup.events, ['apply', 'stop']);
    },
  );

  test(
    'native mobile VPN never enters desktop administrator authorization',
    () async {
      final setup = _NativeVpnAuthorizationSetup();
      final container = ProviderContainer(
        overrides: [setupActionProvider.overrideWith(() => setup)],
      );
      addTearDown(container.dispose);
      container.listen(patchClashConfigProvider, (_, _) {});
      container
          .read(patchClashConfigProvider.notifier)
          .update((value) => value.copyWith.tun(enable: true));
      expect(
        await container.read(setupActionProvider.notifier).requestAdmin(true),
        true,
      );
      expect(setup.desktopRequests, 0);
      expect(container.read(patchClashConfigProvider).tun.enable, true);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.none,
      );
    },
  );
  test(
    'managed permission denial stops without downgrading to proxy only',
    () async {
      await engine.login('user@example.com', 'example-password');
      final setup = _DeniedAuthorizationSetup();
      final container = ProviderContainer(
        overrides: [
          haozeAccountProvider.overrideWith(() => _Account(engine)),
          setupActionProvider.overrideWith(() => setup),
          commonActionProvider.overrideWith(_NoTraffic.new),
          currentProfileIdProvider.overrideWithBuild((_, _) => 42),
          initProvider.overrideWithBuild((_, _) => true),
        ],
      );
      addTearDown(container.dispose);
      container.read(haozeAccountProvider);
      container
          .read(patchClashConfigProvider.notifier)
          .update((value) => value.copyWith.tun(enable: true));
      expect(
        await container.read(setupActionProvider.notifier).setRunning(true),
        false,
      );
      expect(container.read(patchClashConfigProvider).tun.enable, true);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.none,
      );
      expect(setup.events, ['authorize', 'stop']);
    },
  );
  for (final dark in [false, true]) {
    for (final size in [const Size(390, 844), const Size(1200, 900)]) {
      testWidgets('login layout fits ${size.width} dp, dark=$dark', (
        tester,
      ) async {
        await open(tester, size: size, dark: dark);
        expect(find.byKey(const ValueKey('haoze-submit')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
      testWidgets(
        'usage view fits ${size.width} dp, dark=$dark and refresh does not reapply',
        (tester) async {
          await tester.runAsync(
            () => engine.login('user@example.com', 'example-password'),
          );
          await open(tester, account: true, size: size, dark: dark);
          expect(find.text('Remaining: 2.00 KiB'), findsOneWidget);
          expect(find.text('Expires: No expiry'), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, 'Refresh usage'));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          expect(profiles.preparations, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
