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
  test(
    'defaults to primary with Alibaba DoH and ECH off, stores settings securely',
    () async {
      String? stored;
      final controller = AccountNetworkController(
        read: () async => stored,
        write: (value) async => stored = value,
      );
      final defaults = await controller.current;
      expect(defaults.dohProvider, AccountDohProvider.alibaba);
      expect(defaults.route, AccountRoute.primary);
      expect(defaults.dohEnabled, isTrue);
      expect(defaults.echEnabled, isFalse);
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
    },
  );

  test(
    'each route retains its switches and probes use route defaults',
    () async {
      var settings = const AccountNetworkSettings();
      settings = settings.copyWith(dohEnabled: false, echEnabled: true);
      settings = settings.copyWith(route: AccountRoute.secondary);
      expect(settings.dohEnabled, isTrue);
      expect(settings.echEnabled, isTrue);
      settings = settings.copyWith(dohEnabled: false, echEnabled: false);
      settings = settings.copyWith(route: AccountRoute.primary);
      expect(settings.dohEnabled, isFalse);
      expect(settings.echEnabled, isTrue);
      final persisted = AccountNetworkSettings.fromJson(settings.toJson());
      expect(persisted.toJson(), settings.toJson());
      expect(
        persisted.copyWith(route: AccountRoute.secondary).echEnabled,
        isFalse,
      );
      final custom = settings.copyWith(
        dohProvider: AccountDohProvider.google,
        proxyEnabled: true,
        proxyPassword: 'secret',
      );
      for (final route in AccountRoute.values) {
        final probe = custom.defaultsFor(route);
        expect(probe.dohEnabled, isTrue);
        expect(probe.echEnabled, route == AccountRoute.secondary);
        expect(probe.dohProvider, AccountDohProvider.alibaba);
        expect(probe.proxyUrl, custom.proxyUrl);
        expect(probe.proxyPassword, 'secret');
      }
      final old = {...const AccountNetworkSettings().toJson()}
        ..remove('version')
        ..remove('route')
        ..remove('primary')
        ..remove('secondary')
        ..['echEnabled'] = true;
      expect(AccountNetworkSettings.fromJson(old).primaryEchEnabled, isTrue);
      expect(AccountNetworkSettings.fromJson(old).secondaryEchEnabled, isTrue);
      expect(
        () => AccountNetworkSettings.fromJson({
          ...settings.toJson(),
          'version': 99,
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'route changes reach the selected host, preserving paths and external hosts',
    () async {
      final settings = AccountNetworkController(
        read: () async => null,
        write: (_) async {},
      );
      final urls = <Uri>[];
      final configs = <native.AccountNetworkOptions>[];
      int dnsReads = 0;
      final transport = AccountNetworkTransport(
        settings,
        systemDns: () async {
          dnsReads++;
          return ['192.0.2.53'];
        },
        run:
            ({
              required options,
              required method,
              required url,
              required headers,
              required body,
            }) async {
              urls.add(Uri.parse(url));
              configs.add(options);
              return native.AccountHttpResponse(
                status: 200,
                body: Uint8List.fromList(utf8.encode('{}')),
                echUsed: false,
              );
            },
      );
      final target = Uri.parse('https://www.haoze.cyou/api/v1/user/info?a=1');
      await transport.send('GET', target, {}, null);
      await settings.save(
        const AccountNetworkSettings(
          route: AccountRoute.secondary,
          secondaryDohEnabled: false,
          secondaryEchEnabled: true,
        ),
      );
      await transport.send('GET', target, {}, null);
      await transport.send(
        'GET',
        Uri.https('sso.zhouhaoze.com', '/native/v1/config'),
        {},
        null,
      );
      expect(urls[0].host, 'www.haoze.cyou');
      expect(urls[1].host, 'alt.haoze.cyou');
      expect(urls[1].path, target.path);
      expect(urls[1].query, 'a=1');
      expect(urls[2].host, 'sso.zhouhaoze.com');
      expect(configs.last.dohEnabled, isFalse);
      expect(configs.last.echEnabled, isTrue);
      expect(configs.last.systemDnsServers, ['192.0.2.53']);
      expect(dnsReads, 2);
      await settings.save(
        (await settings.current).copyWith(proxyEnabled: true),
      );
      await transport.send('GET', target, {}, null);
      expect(dnsReads, 2);
      expect(configs.last.systemDnsServers, isEmpty);
      transport.close();
    },
  );

  test(
    'closing while reading system DNS cannot start a later native request',
    () async {
      final config = const AccountNetworkSettings().copyWith(
        dohEnabled: false,
        echEnabled: true,
      );
      final controller = AccountNetworkController(
        read: () async => jsonEncode(config.toJson()),
      );
      final dns = Completer<List<String>>();
      int calls = 0;
      final transport = AccountNetworkTransport(
        controller,
        systemDns: () => dns.future,
        run:
            ({
              required options,
              required method,
              required url,
              required headers,
              required body,
            }) async {
              calls++;
              throw StateError('must not start');
            },
      );
      final pending = transport.send(
        'GET',
        Uri.https('www.haoze.cyou'),
        {},
        null,
      );
      await Future<void>.delayed(Duration.zero);
      transport.close();
      dns.complete(['192.0.2.53']);
      await expectLater(pending, throwsA(failure(XboardFailure.socket)));
      expect(calls, 0);
    },
  );

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
          primaryEchEnabled: false,
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
