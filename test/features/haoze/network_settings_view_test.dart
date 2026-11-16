import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/features/haoze/network_settings.dart';
import 'package:fl_clash/features/haoze/network_settings_view.dart';
import 'package:fl_clash/features/haoze/network_transport.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

void main() {
  Future<void> open(
    WidgetTester tester, {
    AccountNetworkSettings settings = const AccountNetworkSettings(),
    Future<void> Function(String)? write,
    AccountDohProbe? probe,
    AccountRouteProbe? routeProbe,
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TestApp(
        locale: const Locale('en'),
        theme: ThemeData().withAppShapes.withAppTypography.withAppSurfaces,
        overrides: [
          haozeNetworkProvider.overrideWithValue(
            AccountNetworkController(
              read: () async => jsonEncode(settings.toJson()),
              write: write ?? (_) async {},
            ),
          ),
          accountRouteProbeProvider.overrideWithValue(
            routeProbe ?? ({required settings}) async => 48,
          ),
          accountDohProbeProvider.overrideWithValue(
            probe ?? ({required options}) async => 32,
          ),
        ],
        child: Builder(
          builder: (context) => CommonScaffold(
            title: 'test',
            body: TextButton(
              onPressed: () => showFormSheet<void>(
                context: context,
                builder: (_) => const AccountNetworkSettingsPage(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('default form and automatic provider measurements', (
    tester,
  ) async {
    final probes = <String>[];
    await open(
      tester,
      probe: ({required options}) async {
        probes.add(options.dohProvider);
        if (options.dohProvider == 'google') throw StateError('offline');
        return 32;
      },
    );
    expect(find.text('Network settings'), findsOneWidget);
    expect(find.text('Alibaba Cloud · 223.5.5.5 (default)'), findsOneWidget);
    final switches = tester
        .widgetList<CommonSwitch>(find.byType(CommonSwitch))
        .toList();
    expect(switches.map((item) => item.value), [true, false]);
    await tester.tap(find.text('DoH provider'));
    await tester.pumpAndSettle();
    expect(probes.toSet(), {'alibaba', 'cloudflare', 'google', 'tencent'});
    expect(find.text('32 ms'), findsNWidgets(3));
    expect(find.text('Unavailable'), findsOneWidget);
    await tester.tap(find.text('1.1.1.1'));
    await tester.pumpAndSettle();
    expect(find.text('1.1.1.1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('proxy fields validate and save failure retains the form', (
    tester,
  ) async {
    String? stored;
    bool fail = true;
    await open(
      tester,
      settings: const AccountNetworkSettings(
        proxyEnabled: true,
        proxyKind: AccountProxyKind.socks5,
        proxyUsername: 'user',
        proxyPassword: 'secret',
      ),
      write: (value) async {
        if (fail) throw StateError('locked');
        stored = value;
      },
    );
    await tester.scrollUntilVisible(
      find.text('SOCKS5'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('SOCKS5'), findsOneWidget);
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(4));
    expect(
      tester.widget<EditableText>(find.byType(EditableText).last).obscureText,
      isTrue,
    );
    await tester.enterText(fields.at(1), '0');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('Enter a valid proxy host'),
      -300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a valid proxy host'), findsOneWidget);
    expect(stored, isNull);
    await tester.scrollUntilVisible(
      find.text('Port'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(fields.at(1), '1080');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Secure storage could not be updated. Please retry.'),
      -300,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Secure storage could not be updated. Please retry.'),
      findsOneWidget,
    );
    fail = false;
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    final saved = AccountNetworkSettings.fromJson(
      jsonDecode(stored!) as Map<String, dynamic>,
    );
    expect(saved.proxyUrl, 'socks5h://127.0.0.1:1080');
    expect(saved.proxyPassword, 'secret');
    expect(find.byType(AccountNetworkSettingsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'routes measure defaults, preserve custom switches and save the selected route',
    (tester) async {
      final measured = <AccountNetworkSettings>[];
      String? stored;
      await open(
        tester,
        settings: const AccountNetworkSettings(
          primaryDohEnabled: false,
          primaryEchEnabled: true,
          secondaryDohEnabled: false,
          secondaryEchEnabled: false,
          dohProvider: AccountDohProvider.google,
          proxyEnabled: true,
        ),
        routeProbe: ({required settings}) async {
          measured.add(settings);
          if (settings.route == AccountRoute.secondary) {
            throw StateError('unreachable');
          }
          return 48;
        },
        write: (value) async => stored = value,
      );
      await tester.tap(find.text('Content route'));
      await tester.pumpAndSettle();
      expect(measured.length, 2);
      expect(measured.map((value) => value.dohEnabled), [true, true]);
      expect(measured.map((value) => value.echEnabled), [false, true]);
      expect(measured.every((value) => value.proxyEnabled), isTrue);
      expect(
        measured.every(
          (value) => value.dohProvider == AccountDohProvider.alibaba,
        ),
        isTrue,
      );
      expect(find.text('48 ms'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
      await tester.tap(find.text('Route 2 · alt.haoze.cyou'));
      await tester.pumpAndSettle();
      var switches = tester
          .widgetList<CommonSwitch>(find.byType(CommonSwitch))
          .toList();
      expect(switches.map((item) => item.value), [false, false]);
      switches[1].onChanged!(true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Content route'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Route 1 · www.haoze.cyou'));
      await tester.pumpAndSettle();
      switches = tester
          .widgetList<CommonSwitch>(find.byType(CommonSwitch))
          .toList();
      expect(switches.map((item) => item.value), [false, true]);
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      final saved = AccountNetworkSettings.fromJson(
        jsonDecode(stored!) as Map<String, dynamic>,
      );
      expect(saved.route, AccountRoute.primary);
      expect(saved.primaryDohEnabled, isFalse);
      expect(saved.primaryEchEnabled, isTrue);
      expect(saved.secondaryDohEnabled, isFalse);
      expect(saved.secondaryEchEnabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing pending probes does not update a disposed page', (
    tester,
  ) async {
    final pending = Completer<int>();
    final urls = <String?>[];
    await open(
      tester,
      settings: const AccountNetworkSettings(proxyEnabled: true),
      probe: ({required options}) {
        urls.add(options.proxyUrl);
        return pending.future;
      },
    );
    await tester.tap(find.text('DoH provider'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(urls, List.filled(4, 'http://127.0.0.1:7890'));
    await tester.tap(find.text('1.1.1.1'));
    await tester.pumpAndSettle();
    pending.complete(24);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(360, 640), const Size(1280, 800)]) {
    testWidgets('proxy form fits $size', (tester) async {
      await open(
        tester,
        size: size,
        settings: const AccountNetworkSettings(proxyEnabled: true),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
