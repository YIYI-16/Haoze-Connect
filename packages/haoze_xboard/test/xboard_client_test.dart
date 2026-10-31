import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoze_xboard/haoze_xboard.dart';

class FakeTransport implements XboardTransport {
  XboardResponse next = const XboardResponse(200, {
    'data': <String, dynamic>{},
  });
  String? method;
  Uri? uri;
  Map<String, String>? headers;
  Map<String, Object?>? body;
  int calls = 0;

  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    calls++;
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    this.body = body;
    return next;
  }

  @override
  void close() {}
}

void main() {
  late FakeTransport transport;
  late XboardClient client;
  final session = XboardSession(
    authorization: 'Bearer fixture-login-secret',
    subscriptionToken: 'fixture-subscription-secret',
  );

  setUp(() {
    transport = FakeTransport();
    client = XboardClient(
      panelOrigin: Uri.parse('https://panel.example'),
      transport: transport,
    );
  });
  tearDown(() => client.close());

  test(
    'account transport does not inherit the enclosing app HTTP override',
    () {
      var inheritedOverrideCalls = 0;
      HttpOverrides.runZoned(
        () {
          final isolated = StrictIoXboardTransport();
          isolated.close();
        },
        createHttpClient: (_) {
          inheritedOverrideCalls++;
          throw StateError(
            'An app override must not own account TLS or proxy policy',
          );
        },
      );
      expect(inheritedOverrideCalls, 0);
    },
  );

  test('public config needs no login and uses the full v1 route', () async {
    await client.publicConfig();
    expect(
      transport.uri.toString(),
      'https://panel.example/api/v1/guest/comm/config',
    );
    expect(transport.headers!.containsKey('Authorization'), isFalse);
    expect(transport.uri!.hasQuery, isFalse);
  });

  test('login uses JSON POST and distinguishes the two token types', () async {
    transport.next = const XboardResponse(200, {
      'data': {
        'auth_data': 'Bearer fixture-login-secret',
        'token': 'fixture-subscription-secret',
      },
    });
    final result = await client.login(
      ' person@example.test ',
      'fixture-password',
    );
    expect(transport.method, 'POST');
    expect(transport.uri!.path, '/api/v1/passport/auth/login');
    expect(transport.body, {
      'email': 'person@example.test',
      'password': 'fixture-password',
    });
    expect(result.authorization, 'Bearer fixture-login-secret');
    expect(result.subscriptionToken, 'fixture-subscription-secret');
    expect(result.toString(), isNot(contains('fixture-')));
  });

  test(
    'registration carries the actual Xboard verification field names',
    () async {
      transport.next = const XboardResponse(200, {
        'data': {
          'auth_data': 'Bearer fixture-login-secret',
          'token': 'fixture-subscription-secret',
        },
      });
      await client.register(
        'person@example.test',
        'fixture-password',
        emailCode: '123456',
        inviteCode: 'invite',
        captcha: {'turnstile_token': 'fixture-captcha'},
      );
      expect(transport.uri!.path, '/api/v1/passport/auth/register');
      expect(transport.body!['email_code'], '123456');
      expect(transport.body!['invite_code'], 'invite');
      expect(transport.body!['turnstile_token'], 'fixture-captcha');
    },
  );

  test('captcha cannot overwrite an account credential', () async {
    await expectLater(
      client.register(
        'person@example.test',
        'fixture-password',
        captcha: {'password': 'overwrite'},
      ),
      throwsA(isA<XboardException>()),
    );
    expect(transport.calls, 0);
  });

  test('email code accepts the backend scalar success envelope', () async {
    transport.next = const XboardResponse(200, {'data': true});
    await client.sendEmailCode('person@example.test');
    expect(transport.uri!.path, '/api/v1/passport/comm/sendEmailVerify');
  });

  test('user info uses the exact Bearer header, not a query token', () async {
    await client.userInfo(session);
    expect(transport.uri!.path, '/api/v1/user/info');
    expect(transport.headers!['Authorization'], session.authorization);
    expect(transport.uri!.hasQuery, isFalse);
  });

  test(
    'subscription preserves the returned origin and path and replaces only the client flag',
    () async {
      transport.next = const XboardResponse(200, {
        'data': {
          'u': 100,
          'd': '200',
          'transfer_enable': 1000,
          'expired_at': null,
          'subscribe_url':
              'https://subscription.example/custom/fixture-subscription-secret?flag=hiddify&filter=one&filter=two',
        },
      });
      final sub = await client.subscription(session);
      expect(transport.uri!.path, '/api/v1/user/getSubscribe');
      expect(sub.remaining, 700);
      expect(sub.expiresAt, isNull);
      expect(
        sub.metaSubscriptionUri(coreVersion: 'v1.19.33')!.host,
        'subscription.example',
      );
      expect(
        sub.metaSubscriptionUri(coreVersion: 'v1.19.33')!.path,
        '/custom/fixture-subscription-secret',
      );
      expect(
        sub.metaSubscriptionUri(coreVersion: 'v1.19.33')!.queryParametersAll,
        {
          'flag': ['meta/v1.19.33'],
          'filter': ['one', 'two'],
        },
      );
      expect(sub.toString(), isNot(contains('fixture-subscription-secret')));
    },
  );

  test('exhausted quota is clamped to zero', () {
    final sub = XboardSubscription.fromJson({
      'u': 800,
      'd': 900,
      'transfer_enable': 1000,
      'expired_at': 123,
      'subscribe_url': null,
    });
    expect(sub.remaining, 0);
    expect(sub.metaSubscriptionUri(coreVersion: 'v1.19.33'), isNull);
  });

  test(
    'APP metadata uses subscription-token auth and sends no Bearer credential',
    () async {
      transport.next = const XboardResponse(200, {
        'data': {
          'windows_version': '6.0.0',
          'windows_download_url': 'https://downloads.example/setup.exe',
          'android_version': '6.0.0',
          'android_download_url': 'https://downloads.example/client.apk',
          'macos_version': '',
          'macos_download_url': '',
        },
      });
      final versions = await client.appVersions(session);
      expect(transport.uri!.path, '/api/v1/client/app/getVersion');
      expect(transport.uri!.queryParameters, {
        'token': session.subscriptionToken,
      });
      expect(transport.headers!.containsKey('Authorization'), isFalse);
      expect(versions['windows']!.version, '6.0.0');
      expect(versions['android']!.downloadUri!.path, '/client.apk');
      expect(versions['macos']!.downloadUri, isNull);
    },
  );

  for (final uri in [
    'http://panel.example',
    'https://user:secret@panel.example',
    'https://panel.example/api',
    'https://panel.example?token=secret',
    'https://panel.example#secret',
  ]) {
    test(
      'rejects ambiguous or insecure panel origin: ${Uri.parse(uri).scheme}',
      () {
        expect(
          () => XboardClient(panelOrigin: Uri.parse(uri), transport: transport),
          throwsA(isA<XboardException>()),
        );
        expect(transport.calls, 0);
      },
    );
  }

  for (final status in [401, 403, 429, 500]) {
    test('HTTP $status is typed and not replayed', () async {
      transport.next = XboardResponse(status, {
        'message': 'fixture-password fixture-subscription-secret',
      });
      await expectLater(
        client.login('person@example.test', 'fixture-password'),
        throwsA(
          isA<XboardException>()
              .having((e) => e.statusCode, 'status', status)
              .having(
                (e) => e.toString(),
                'safe text',
                isNot(contains('fixture-')),
              ),
        ),
      );
      expect(transport.calls, 1);
    });
  }

  test('rejects an unexpected response envelope', () async {
    transport.next = const XboardResponse(200, {'message': 'OK'});
    await expectLater(client.publicConfig(), throwsA(isA<XboardException>()));
  });

  test('rejects insecure subscription addresses', () {
    expect(
      () => XboardSubscription.fromJson({
        'u': 0,
        'd': 0,
        'transfer_enable': 10,
        'subscribe_url': 'http://subscription.example/secret',
      }),
      throwsA(isA<XboardException>()),
    );
  });

  test(
    'rejects an insecure update URL from otherwise valid metadata',
    () async {
      transport.next = const XboardResponse(200, {
        'data': {
          'windows_version': '6.0.0',
          'windows_download_url': 'http://downloads.example/setup.exe',
        },
      });
      await expectLater(
        client.appVersions(session),
        throwsA(isA<XboardException>()),
      );
      expect(transport.calls, 1);
    },
  );

  test('rejects malformed or header-injecting authentication data', () {
    for (final authorization in [
      'fixture-login-secret',
      'Bearer Bearer secret',
      'Bearer secret\r\nX-Header: secret',
    ]) {
      expect(
        () => XboardSession(
          authorization: authorization,
          subscriptionToken: 'fixture-subscription-secret',
        ),
        throwsA(isA<XboardException>()),
      );
    }
  });
}
