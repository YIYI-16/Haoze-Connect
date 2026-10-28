import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';

void main() {
  late XboardClientConfig config;

  setUp(() {
    config = XboardClientConfig.parse(baseUrl: 'https://panel.example.com', appName: 'Test Connect');
  });

  test('uses the full /api/v1 path and preserves the panel Bearer token', () async {
    final requests = <RequestOptions>[];
    final adapter = _FakeAdapter((options) async {
      requests.add(options);
      if (options.uri.path.endsWith('/passport/auth/login')) {
        return _json(200, {
          'status': 'success',
          'data': {'auth_data': 'Bearer token-123', 'token': 'ignored'},
        });
      }
      if (options.uri.path.endsWith('/user/getSubscribe')) {
        return _json(200, {
          'status': 'success',
          'data': {
            'u': 100,
            'd': 50,
            'transfer_enable': 1000,
            'expired_at': null,
            'next_reset_at': 1900000000,
            'plan_id': 7,
            'plan': {'name': 'Monthly'},
            'subscribe_url': 'https://sub.example.net/api/v1/client/subscribe?token=abc',
          },
        });
      }
      throw StateError('unexpected path ${options.uri}');
    });

    final api = XboardApiClient(
      config: config,
      userAgent: 'HiddifyNext/5.0.0 (android) like ClashMeta',
      dio: Dio()..httpClientAdapter = adapter,
    );

    final auth = await api.login(email: 'a@example.com', password: 'password1');
    expect(auth.authData, 'Bearer token-123');

    final payload = await api.fetchSubscription(auth.authData);
    expect(payload.subscription.upload, 100);
    expect(payload.subscription.download, 50);
    expect(payload.subscription.total, 1000);
    expect(payload.subscription.remaining, 850);
    expect(payload.subscription.planName, 'Monthly');
    expect(payload.subscription.hasPlan, isTrue);
    expect(payload.subscription.hasTraffic, isTrue);
    expect(payload.subscription.isExpired, isFalse);
    expect(payload.subscription.nextResetAt, isNotNull);
    expect(payload.subscribeUrl, 'https://sub.example.net/api/v1/client/subscribe?token=abc');

    expect(requests.map((request) => request.uri.toString()), [
      'https://panel.example.com/api/v1/passport/auth/login',
      'https://panel.example.com/api/v1/user/getSubscribe',
    ]);
    expect(requests.first.headers['User-Agent'], contains('HiddifyNext/5.0.0'));
    expect(requests.last.headers['Authorization'], 'Bearer token-123');
    // The subscription URL is kept verbatim and is not fetched by this client.
    expect(requests.length, 2);
  });

  test('normalizes a bare auth_data without duplicating Bearer', () {
    expect(XboardApiClient.normalizeAuthData('Bearer abc'), 'Bearer abc');
    expect(XboardApiClient.normalizeAuthData('bearer abc'), 'bearer abc');
    expect(XboardApiClient.normalizeAuthData('abc'), 'Bearer abc');
  });

  test('accepts true data from sendEmailVerify and parses public config', () async {
    final adapter = _FakeAdapter((options) async {
      if (options.uri.path.endsWith('/guest/comm/config')) {
        return _json(200, {
          'status': 'success',
          'data': {
            'is_email_verify': 1,
            'is_invite_force': 0,
            'is_captcha': 0,
            'tos_url': 'https://panel.example.com/tos',
          },
        });
      }
      if (options.uri.path.endsWith('/passport/comm/sendEmailVerify')) {
        return _json(200, {'status': 'success', 'data': true});
      }
      throw StateError('unexpected path ${options.uri}');
    });

    final api = XboardApiClient(config: config, userAgent: 'test', dio: Dio()..httpClientAdapter = adapter);

    final publicConfig = await api.fetchPublicConfig();
    expect(publicConfig.emailVerify, isTrue);
    expect(publicConfig.inviteForce, isFalse);
    expect(publicConfig.captchaEnabled, isFalse);
    expect(publicConfig.tosUrl, 'https://panel.example.com/tos');

    await api.sendEmailCode('a@example.com');
  });

  test('authenticated 401 and 403 both invalidate the session', () async {
    for (final status in [401, 403]) {
      final api = XboardApiClient(
        config: config,
        userAgent: 'test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((_) async => _json(status, {'status': 'fail', 'message': 'expired'})),
      );

      await expectLater(
        api.fetchSubscription('Bearer token'),
        throwsA(
          isA<XboardException>()
              .having((error) => error.kind, 'kind', XboardFailureKind.unauthorized)
              .having((error) => error.message, 'message', contains('重新登录')),
        ),
      );
    }
  });

  test('network errors and 5xx responses remain distinct and safe', () async {
    final networkApi = XboardApiClient(
      config: config,
      userAgent: 'test',
      dio: Dio()
        ..httpClientAdapter = _FakeAdapter(
          (options) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: 'socket failed for Bearer secret',
          ),
        ),
    );

    await expectLater(
      networkApi.fetchSubscription('Bearer secret'),
      throwsA(
        isA<XboardException>()
            .having((error) => error.kind, 'kind', XboardFailureKind.network)
            .having((error) => error.message, 'message', isNot(contains('secret'))),
      ),
    );

    final serverApi = XboardApiClient(
      config: config,
      userAgent: 'test',
      dio: Dio()
        ..httpClientAdapter = _FakeAdapter(
          (_) async => _json(503, {'status': 'fail', 'message': 'stack trace with secret'}),
        ),
    );

    await expectLater(
      serverApi.fetchSubscription('Bearer secret'),
      throwsA(
        isA<XboardException>()
            .having((error) => error.kind, 'kind', XboardFailureKind.server)
            .having((error) => error.message, 'message', isNot(contains('secret')))
            .having((error) => error.kind, 'not unauthorized', isNot(XboardFailureKind.unauthorized)),
      ),
    );
  });

  test('TLS errors explain trust checks without exposing request details or invalidating the account', () async {
    for (final type in [DioExceptionType.unknown, DioExceptionType.badCertificate]) {
      final api = XboardApiClient(
        config: config,
        userAgent: 'test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter(
            (options) => throw DioException(
              requestOptions: options,
              type: type,
              error: const HandshakeException('certificate failed for Bearer secret'),
            ),
          ),
      );
      addTearDown(api.close);
      await expectLater(
        api.fetchSubscription('Bearer secret'),
        throwsA(
          isA<XboardException>()
              .having((error) => error.kind, 'kind', XboardFailureKind.network)
              .having((error) => error.message, 'trust guidance', contains('证书信任'))
              .having((error) => error.message, 'safe message', isNot(contains('secret'))),
        ),
      );
    }
  });

  test('rejects non-https panel URLs', () {
    expect(
      () => XboardClientConfig.parse(baseUrl: 'http://panel.example.com', appName: 'x'),
      throwsA(isA<XboardConfigurationException>()),
    );
    expect(
      () => XboardClientConfig.parse(baseUrl: 'https://user:pass@panel.example.com', appName: 'x'),
      throwsA(isA<XboardConfigurationException>()),
    );
  });
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Map<String, dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}
