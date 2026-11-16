import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/features/haoze/network_settings.dart';
import 'package:fl_clash/features/haoze/network_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:rust_api/rust_api.dart' as native;

Matcher failure(XboardFailure kind) =>
    isA<XboardException>().having((error) => error.kind, 'kind', kind);

void main() {
  test('defaults to Alibaba DoH and ECH, stores settings securely', () async {
    String? stored;
    final controller = AccountNetworkController(
      read: () async => stored,
      write: (value) async => stored = value,
    );
    final defaults = await controller.current;
    expect(defaults.dohProvider, AccountDohProvider.alibaba);
    expect(defaults.echEnabled, isTrue);
    expect(defaults.proxyUrl, isNull);
    final settings = defaults.copyWith(
      proxyEnabled: true,
      proxyKind: AccountProxyKind.socks5,
      proxyHost: '::1',
      proxyPort: 1080,
      proxyUsername: 'a@b',
      proxyPassword: 'p:@/#',
    );
    await controller.save(settings);
    final loaded = await AccountNetworkController(
      read: () async => stored,
    ).current;
    expect(loaded.toJson(), settings.toJson());
    expect(loaded.proxyUrl, 'socks5h://[::1]:1080');
    expect(loaded.proxyUrl, isNot(contains('p:@')));
  });

  test(
    'storage failure retains previous proxy and corrupt state fails closed',
    () async {
      final broken = AccountNetworkController(read: () async => '{bad');
      await expectLater(
        broken.current,
        throwsA(failure(XboardFailure.configuration)),
      );
      const initial = AccountNetworkSettings(proxyEnabled: true);
      final controller = AccountNetworkController(
        read: () async => jsonEncode(initial.toJson()),
        write: (_) async => throw StateError('storage'),
      );
      await controller.current;
      await expectLater(
        controller.save(initial.copyWith(proxyEnabled: false)),
        throwsStateError,
      );
      expect((await controller.current).proxyEnabled, isTrue);
      expect(initial.copyWith(proxyHost: 'bad/host').isValid, isFalse);
      expect(initial.copyWith(proxyPort: 65536).isValid, isFalse);
      expect(initial.copyWith(proxyUsername: '字' * 86).isValid, isFalse);
      expect(initial.copyWith(proxyHost: 'proxy.example.com').isValid, isTrue);
    },
  );

  test(
    'transport uses latest saved settings, never falls back after TLS failure',
    () async {
      final controller = AccountNetworkController(
        read: () async => null,
        write: (_) async {},
      );
      final seen = <native.AccountNetworkOptions>[];
      final transport = AccountNetworkTransport(
        controller,
        run:
            ({
              required options,
              required method,
              required url,
              required headers,
              required body,
            }) async {
              seen.add(options);
              throw Exception('certificate');
            },
      );
      final uri = Uri.https('www.haoze.cyou');
      await expectLater(
        transport.send('GET', uri, {}, null),
        throwsA(failure(XboardFailure.certificate)),
      );
      await controller.save(
        const AccountNetworkSettings(
          proxyEnabled: true,
          proxyKind: AccountProxyKind.socks5,
          dohProvider: AccountDohProvider.tencent,
          echEnabled: false,
        ),
      );
      await expectLater(
        transport.send('GET', uri, {}, null),
        throwsA(failure(XboardFailure.certificate)),
      );
      expect(seen.length, 2);
      expect(seen.first.dohProvider, 'alibaba');
      expect(seen.last.proxyUrl, 'socks5h://127.0.0.1:7890');
      expect(seen.last.echEnabled, isFalse);
      expect(seen.last.dohProvider, 'tencent');
    },
  );

  test(
    'blocks insecure requests, redirects, oversized JSON and late completions',
    () async {
      final controller = AccountNetworkController(read: () async => null);
      final pending = Completer<native.AccountHttpResponse>();
      int calls = 0;
      final transport = AccountNetworkTransport(
        controller,
        run:
            ({
              required options,
              required method,
              required url,
              required headers,
              required body,
            }) async {
              calls++;
              return pending.future;
            },
      );
      await expectLater(
        transport.send('GET', Uri.parse('http://www.haoze.cyou'), {}, null),
        throwsA(failure(XboardFailure.configuration)),
      );
      expect(calls, 0);
      final request = transport.send(
        'GET',
        Uri.https('www.haoze.cyou'),
        {},
        null,
      );
      await Future<void>.delayed(Duration.zero);
      transport.close();
      pending.complete(
        native.AccountHttpResponse(
          status: 200,
          body: Uint8List.fromList(utf8.encode('{}')),
          echUsed: false,
        ),
      );
      await expectLater(request, throwsA(failure(XboardFailure.socket)));
      for (final status in [302, 200]) {
        final transport = AccountNetworkTransport(
          controller,
          run:
              ({
                required options,
                required method,
                required url,
                required headers,
                required body,
              }) async => native.AccountHttpResponse(
                status: status,
                body: Uint8List(1024 * 1024 + 1),
                echUsed: false,
              ),
        );
        await expectLater(
          transport.send('GET', Uri.https('www.haoze.cyou'), {}, null),
          throwsA(
            failure(
              status == 302 ? XboardFailure.redirect : XboardFailure.protocol,
            ),
          ),
        );
        if (status == 200) {
          expect(
            await transport.download(Uri.https('www.haoze.cyou')),
            hasLength(1024 * 1024 + 1),
          );
        }
        transport.close();
      }
    },
  );
}
