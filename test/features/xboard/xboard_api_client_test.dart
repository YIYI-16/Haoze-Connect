import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_transport_failure.dart';
import 'package:logging/logging.dart';

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

  test('verified certificate failures are safe and never retried', () async {
    for (final failure in [
      (DioExceptionType.unknown, const HandshakeException('CERTIFICATE_VERIFY_FAILED: Bearer secret')),
      (DioExceptionType.badCertificate, null),
      (DioExceptionType.unknown, const CertificateException('Bearer secret')),
      (
        DioExceptionType.unknown,
        const HandshakeException('Handshake error', OSError('CERTIFICATE_VERIFY_FAILED: Bearer secret')),
      ),
    ]) {
      var requests = 0;
      final api = XboardApiClient(
        config: config,
        userAgent: 'test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((options) {
            requests++;
            throw DioException(requestOptions: options, type: failure.$1, error: failure.$2);
          }),
      );
      addTearDown(api.close);
      await expectLater(
        api.fetchSubscription('Bearer secret'),
        throwsA(
          isA<XboardException>()
              .having((error) => error.kind, 'kind', XboardFailureKind.network)
              .having((error) => error.transportFailure, 'category', XboardTransportFailure.certificateRejected)
              .having((error) => error.message, 'trust guidance', contains('证书信任'))
              .having((error) => error.message, 'safe message', isNot(contains('secret'))),
        ),
      );
      expect(requests, 1);
    }
  });

  test('GET recovers once after a handshake or socket interruption and preserves authorization', () async {
    for (final cause in [
      const HandshakeException('Connection terminated during handshake'),
      const SocketException('Connection reset by peer', osError: OSError('reset', 104)),
      const SocketException('Windows connection reset', osError: OSError('reset', 10054)),
      const HttpException('Connection closed before full header was received'),
    ]) {
      final requests = <RequestOptions>[];
      final api = XboardApiClient(
        config: config,
        userAgent: 'test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((options) async {
            requests.add(options);
            if (requests.length == 1) throw DioException(requestOptions: options, error: cause);
            return _json(200, {
              'data': {'transfer_enable': 500, 'u': 10, 'd': 20},
            });
          }),
      );
      addTearDown(api.close);

      final result = await api.fetchSubscription('Bearer secret');
      expect(result.subscription.remaining, 470);
      expect(requests, hasLength(2));
      expect(requests.map((request) => request.method), everyElement('GET'));
      expect(requests.map((request) => request.headers['Authorization']), everyElement('Bearer secret'));
      expect(requests.map((request) => request.uri).toSet(), hasLength(1));
    }
  });

  test('a repeated transient GET failure stops after two attempts', () async {
    var requests = 0;
    final api = XboardApiClient(
      config: config,
      userAgent: 'test',
      dio: Dio()
        ..httpClientAdapter = _FakeAdapter((options) {
          requests++;
          throw DioException(
            requestOptions: options,
            error: const HandshakeException('Connection terminated during handshake https://secret.invalid'),
          );
        }),
    );
    addTearDown(api.close);

    await expectLater(
      api.fetchPublicConfig(),
      throwsA(
        isA<XboardException>()
            .having((error) => error.transportFailure, 'category', XboardTransportFailure.tlsInterrupted)
            .having((error) => error.message, 'connection guidance', contains('握手时中断'))
            .having((error) => error.message, 'privacy', isNot(contains('secret'))),
      ),
    );
    expect(requests, 2);
  });

  test('all mutating endpoints avoid replay even after handshake termination', () async {
    var requests = 0;
    final api = XboardApiClient(
      config: config,
      userAgent: 'test',
      dio: Dio()
        ..httpClientAdapter = _FakeAdapter((options) {
          requests++;
          throw DioException(
            requestOptions: options,
            error: const HandshakeException('Connection terminated during handshake'),
          );
        }),
    );
    addTearDown(api.close);

    await expectLater(api.login(email: 'a@example.com', password: 'secret'), throwsA(isA<XboardException>()));
    expect(requests, 1);
    await expectLater(api.register(email: 'a@example.com', password: 'secret'), throwsA(isA<XboardException>()));
    expect(requests, 2);
    await expectLater(api.sendEmailCode('a@example.com'), throwsA(isA<XboardException>()));
    expect(requests, 3);
  });

  test('TLS protocol errors, DNS failures, timeouts and HTTP responses are not retried', () async {
    for (final failure in [
      (DioExceptionType.unknown, const HandshakeException('WRONG_VERSION_NUMBER: secret')),
      (DioExceptionType.unknown, const TlsException('Read failed: secret')),
      (DioExceptionType.connectionError, const SocketException('Failed host lookup: secret')),
      (DioExceptionType.receiveTimeout, null),
      (DioExceptionType.cancel, null),
      (DioExceptionType.badResponse, null),
    ]) {
      var requests = 0;
      final api = XboardApiClient(
        config: config,
        userAgent: 'test',
        dio: Dio()
          ..httpClientAdapter = _FakeAdapter((options) {
            requests++;
            throw DioException(requestOptions: options, type: failure.$1, error: failure.$2);
          }),
      );
      addTearDown(api.close);
      await expectLater(
        api.fetchPublicConfig(),
        throwsA(
          isA<XboardException>()
              .having((error) => error.message, 'privacy', isNot(contains('secret')))
              .having((error) => error.message, 'no false certificate claim', isNot(contains('证书'))),
        ),
      );
      expect(requests, 1);
    }
  });

  test('transport diagnostics exclude credentials, URLs and raw error text', () {
    final diagnostic = XboardTransportDiagnostic(
      DioException(
        requestOptions: RequestOptions(
          path: 'https://secret.invalid/token',
          headers: {'Authorization': 'Bearer secret'},
          data: {'password': 'secret'},
        ),
        error: const HandshakeException('Connection terminated during handshake secret', OSError('secret', 104)),
        message: 'secret',
      ),
      attempt: 2,
    );

    expect(diagnostic.failure, XboardTransportFailure.tlsInterrupted);
    expect(diagnostic.causeType, 'HandshakeException');
    expect(diagnostic.osErrorCode, 104);
    expect(diagnostic.toString(), contains('attempt=2'));
    expect(diagnostic.toString(), isNot(contains('secret')));
    expect(diagnostic.toString(), isNot(contains('Bearer')));
  });

  test('transport failures reach the app logger without sensitive error payloads', () async {
    final records = <LogRecord>[];
    final subscription = Logger.root.onRecord
        .where((record) => record.loggerName == 'infra.XboardApiClient')
        .listen(records.add);
    addTearDown(subscription.cancel);
    final adapter = _FakeAdapter((options) {
      throw DioException(
        requestOptions: options,
        error: const HandshakeException('Connection terminated during handshake raw-secret'),
        message: 'raw-secret',
      );
    });
    final client = XboardApiClient(config: config, userAgent: 'test', dio: Dio()..httpClientAdapter = adapter);
    addTearDown(client.close);

    await expectLater(client.fetchSubscription('Bearer account-secret'), throwsA(isA<XboardException>()));

    expect(records, hasLength(2));
    for (final record in records) {
      expect(record.message, contains('category=tlsInterrupted'));
      expect(record.message, isNot(contains('secret')));
      expect(record.message, isNot(contains('panel.example.com')));
      expect(record.message, isNot(contains('Authorization')));
      expect(record.error, isNull);
      expect(record.stackTrace, isNull);
    }
  });

  test('native IO adapter retries a real peer-terminated TLS handshake only once', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    final listener = server.listen((socket) {
      connections++;
      socket.destroy();
    });
    addTearDown(listener.cancel);
    addTearDown(server.close);
    final api = XboardApiClient(
      config: XboardClientConfig.parse(baseUrl: 'https://127.0.0.1:${server.port}', appName: 'Test Connect'),
      userAgent: 'test',
    );
    addTearDown(api.close);

    await expectLater(
      api.fetchPublicConfig(),
      throwsA(
        isA<XboardException>()
            .having((error) => error.kind, 'kind', XboardFailureKind.network)
            .having((error) => error.transportFailure, 'category', XboardTransportFailure.tlsInterrupted),
      ),
    );
    expect(connections, 2);
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
