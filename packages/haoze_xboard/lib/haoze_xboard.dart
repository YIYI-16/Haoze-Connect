import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum XboardFailure {
  configuration,
  dns,
  socket,
  tls,
  certificate,
  timeout,
  redirect,
  unauthorized,
  http,
  protocol,
}

class XboardException implements Exception {
  const XboardException(this.kind, {this.statusCode, this.osCode});
  final XboardFailure kind;
  final int? statusCode;
  final int? osCode;

  @override
  String toString() =>
      'XboardException(${kind.name}, status=$statusCode, osCode=$osCode)';
}

class XboardResponse {
  const XboardResponse(this.statusCode, this.body);
  final int statusCode;
  final Object? body;
}

abstract interface class XboardTransport {
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  );
  void close();
}

class _IsolatedHttpOverrides extends HttpOverrides {}

class StrictIoXboardTransport implements XboardTransport {
  StrictIoXboardTransport({this.timeout = const Duration(seconds: 20)})
    : _client = HttpOverrides.runWithHttpOverrides(
        () => HttpClient(context: SecurityContext(withTrustedRoots: true)),
        _IsolatedHttpOverrides(),
      ) {
    _client.connectionTimeout = timeout;
    _client.findProxy = (_) => 'DIRECT';
    _client.badCertificateCallback = null;
  }

  final Duration timeout;
  final HttpClient _client;

  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    _requireHttps(uri);
    // close() is awaited through the non-null alias; abort owns timed-out work.
    // ignore: close_sinks
    HttpClientRequest? pending;
    var finished = false;
    var consumed = false;
    try {
      return await (() async {
        final request = pending = await _client.openUrl(method, uri);
        if (finished) {
          request.abort();
          throw const XboardException(XboardFailure.timeout);
        }
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close();
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw XboardException(
            XboardFailure.redirect,
            statusCode: response.statusCode,
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const XboardException(XboardFailure.protocol);
          }
          bytes.addAll(chunk);
        }
        Object? data;
        try {
          data = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          if (response.statusCode >= 200 && response.statusCode < 300) {
            throw const XboardException(XboardFailure.protocol);
          }
        }
        consumed = true;
        return XboardResponse(response.statusCode, data);
      })().timeout(timeout);
    } on TimeoutException {
      throw const XboardException(XboardFailure.timeout);
    } on HandshakeException catch (error) {
      final rejected =
          error.osError?.message.contains('CERTIFICATE_VERIFY_FAILED') ?? false;
      throw XboardException(
        rejected ? XboardFailure.certificate : XboardFailure.tls,
        osCode: error.osError?.errorCode,
      );
    } on SocketException catch (error) {
      throw XboardException(
        XboardFailure.socket,
        osCode: error.osError?.errorCode,
      );
    } on HttpException {
      throw const XboardException(XboardFailure.http);
    } finally {
      finished = true;
      if (!consumed) pending?.abort();
    }
  }

  @override
  void close() => _client.close(force: true);
}

class XboardSession {
  XboardSession({
    required String authorization,
    required this.subscriptionToken,
  }) : authorization = authorization.trim() {
    if (!RegExp(r'^Bearer [^\s]+$').hasMatch(this.authorization) ||
        subscriptionToken.isEmpty ||
        RegExp(r'\s').hasMatch(subscriptionToken)) {
      throw const XboardException(XboardFailure.protocol);
    }
  }

  final String authorization;
  final String subscriptionToken;

  @override
  String toString() => 'XboardSession(<redacted>)';
}

class XboardSubscription {
  XboardSubscription.fromJson(Map<String, dynamic> data)
    : uploaded = _integer(data['u']),
      downloaded = _integer(data['d']),
      total = _integer(data['transfer_enable']),
      expiresAt = data['expired_at'] == null
          ? null
          : _integer(data['expired_at']),
      _url = _subscriptionUri(data['subscribe_url']);

  final int uploaded;
  final int downloaded;
  final int total;
  final int? expiresAt;
  final Uri? _url;

  int get remaining => (total - uploaded - downloaded).clamp(0, total);

  Uri? metaSubscriptionUri({required String coreVersion}) {
    if (!RegExp(
      r'^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$',
    ).hasMatch(coreVersion)) {
      throw const XboardException(XboardFailure.configuration);
    }
    final uri = _url;
    if (uri == null) return null;
    return uri.replace(
      queryParameters: {
        ...uri.queryParametersAll,
        'flag': ['meta/$coreVersion'],
      },
    );
  }

  @override
  String toString() => 'XboardSubscription(<private>)';
}

class XboardAppVersion {
  XboardAppVersion({required this.version, required this.downloadUri});
  final String version;
  final Uri? downloadUri;
}

class XboardClient {
  XboardClient({required Uri panelOrigin, XboardTransport? transport})
    : _origin = panelOrigin,
      _transport = transport ?? StrictIoXboardTransport() {
    _requireHttps(panelOrigin);
    if (!['', '/'].contains(panelOrigin.path) || panelOrigin.hasQuery) {
      throw const XboardException(XboardFailure.configuration);
    }
  }

  final Uri _origin;
  final XboardTransport _transport;

  Future<Map<String, dynamic>> publicConfig() =>
      _request('GET', 'guest/comm/config');

  Future<XboardSession> login(String email, String password) async => _session(
    await _request(
      'POST',
      'passport/auth/login',
      body: {'email': email.trim(), 'password': password},
    ),
  );

  Future<XboardSession> register(
    String email,
    String password, {
    String? emailCode,
    String? inviteCode,
    Map<String, String> captcha = const {},
  }) async => _session(
    await _request(
      'POST',
      'passport/auth/register',
      body: {
        'email': email.trim(),
        'password': password,
        'email_code': ?emailCode,
        'invite_code': ?inviteCode,
        ..._captcha(captcha),
      },
    ),
  );

  Future<void> sendEmailCode(
    String email, {
    Map<String, String> captcha = const {},
  }) async {
    await _request(
      'POST',
      'passport/comm/sendEmailVerify',
      body: {'email': email.trim(), ..._captcha(captcha)},
      allowScalar: true,
    );
  }

  Future<Map<String, dynamic>> userInfo(XboardSession session) =>
      _request('GET', 'user/info', session: session);

  Future<XboardSubscription> subscription(XboardSession session) async =>
      XboardSubscription.fromJson(
        await _request('GET', 'user/getSubscribe', session: session),
      );

  Future<Map<String, XboardAppVersion>> appVersions(
    XboardSession session,
  ) async {
    final data = await _request(
      'GET',
      'client/app/getVersion',
      subscriptionToken: session.subscriptionToken,
    );
    return {
      for (final platform in ['windows', 'android', 'macos'])
        platform: XboardAppVersion(
          version: data['${platform}_version'] is String
              ? data['${platform}_version'] as String
              : '',
          downloadUri: _subscriptionUri(data['${platform}_download_url']),
        ),
    };
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    XboardSession? session,
    String? subscriptionToken,
    Map<String, Object?>? body,
    bool allowScalar = false,
  }) async {
    final uri = _origin.replace(
      path: '/api/v1/$path',
      queryParameters: subscriptionToken == null
          ? null
          : {'token': subscriptionToken},
    );
    final response = await _transport.send(method, uri, {
      'Accept': 'application/json',
      'User-Agent': 'HaozeConnect-Prototype/0.1.0',
      if (session != null) 'Authorization': session.authorization,
    }, body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XboardException(
        [401, 403].contains(response.statusCode)
            ? XboardFailure.unauthorized
            : XboardFailure.http,
        statusCode: response.statusCode,
      );
    }
    final envelope = response.body;
    if (envelope is! Map<String, dynamic> || !envelope.containsKey('data')) {
      throw const XboardException(XboardFailure.protocol);
    }
    final data = envelope['data'];
    if (allowScalar && (data == true || data == null)) return {};
    if (data is! Map<String, dynamic>) {
      throw const XboardException(XboardFailure.protocol);
    }
    return data;
  }

  void close() => _transport.close();
}

XboardSession _session(Map<String, dynamic> data) {
  if (data['auth_data'] is! String || data['token'] is! String) {
    throw const XboardException(XboardFailure.protocol);
  }
  return XboardSession(
    authorization: data['auth_data'] as String,
    subscriptionToken: data['token'] as String,
  );
}

Map<String, String> _captcha(Map<String, String> values) {
  const allowed = {'turnstile_token', 'recaptcha_data', 'recaptcha_v3_token'};
  if (values.keys.any((key) => !allowed.contains(key))) {
    throw const XboardException(XboardFailure.configuration);
  }
  return values;
}

int _integer(Object? value) {
  final parsed = value is int
      ? value
      : value is String
      ? int.tryParse(value)
      : null;
  if (parsed == null || parsed < 0) {
    throw const XboardException(XboardFailure.protocol);
  }
  return parsed;
}

Uri? _subscriptionUri(Object? value) {
  if (value == null || value == '') return null;
  if (value is! String) throw const XboardException(XboardFailure.protocol);
  final uri = Uri.tryParse(value);
  if (uri == null) throw const XboardException(XboardFailure.protocol);
  _requireHttps(uri);
  return uri;
}

void _requireHttps(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const XboardException(XboardFailure.configuration);
  }
}
