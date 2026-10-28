import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';

/// Classification kept separate from the user-facing [XboardException.message]
/// so callers can distinguish an invalid session from a network outage.
enum XboardFailureKind { network, unauthorized, server, protocol, configuration, subscription }

class XboardException implements Exception {
  const XboardException(this.message, {this.kind = XboardFailureKind.server});

  final String message;
  final XboardFailureKind kind;

  bool get isUnauthorized => kind == XboardFailureKind.unauthorized;

  @override
  String toString() => message;
}

class XboardAuthResult {
  const XboardAuthResult({required this.authData, this.email, this.isAdmin = false});

  /// The panel's `auth_data` value, already prefixed with `Bearer`.
  final String authData;
  final String? email;
  final bool isAdmin;
}

/// Internal subscription payload. [subscribeUrl] must stay in the data layer
/// and is never part of the public [XboardSubscription] model.
class XboardSubscriptionPayload {
  const XboardSubscriptionPayload({required this.subscription, required this.subscribeUrl, this.email});

  final XboardSubscription subscription;
  final String? subscribeUrl;
  final String? email;
}

abstract interface class XboardApi {
  Future<XboardPublicConfig> fetchPublicConfig();

  Future<XboardAuthResult> login({required String email, required String password});

  Future<XboardAuthResult> register({
    required String email,
    required String password,
    String? emailCode,
    String? inviteCode,
  });

  Future<void> sendEmailCode(String email);

  Future<XboardSubscriptionPayload> fetchSubscription(String authData);

  void close();
}

/// Minimal Dio client dedicated to the Xboard API.
///
/// It intentionally does not reuse the app's Sentry-enabled HTTP client: panel
/// credentials and subscription URLs must never pass through request logging.
class XboardApiClient implements XboardApi {
  XboardApiClient({required this.config, required String userAgent, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: '${config.apiBaseUrl}/',
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 25),
              contentType: Headers.jsonContentType,
              // 4xx is parsed as an API response so its message can be shown;
              // 5xx and transport errors are converted to typed failures below.
              validateStatus: (status) => status != null && status >= 200 && status < 500,
              headers: {'Accept': Headers.jsonContentType, 'User-Agent': userAgent},
            ),
          ) {
    _dio.options.baseUrl = config.apiBaseUrl;
    _dio.options.validateStatus = (status) => status != null && status >= 200 && status < 500;
    _dio.options.headers
      ..removeWhere((key, _) => key.toLowerCase() == 'authorization')
      ..['Accept'] = Headers.jsonContentType
      ..['User-Agent'] = userAgent;
  }

  static final RegExp _bearerPrefix = RegExp(r'^Bearer\s+', caseSensitive: false);

  final XboardClientConfig config;
  final Dio _dio;

  @override
  Future<XboardPublicConfig> fetchPublicConfig() async {
    final data = await _request('GET', 'guest/comm/config');
    return XboardPublicConfig.fromJson(_asMap(data));
  }

  @override
  Future<XboardAuthResult> login({required String email, required String password}) async {
    final data = await _request('POST', 'passport/auth/login', body: {'email': email.trim(), 'password': password});
    return _parseAuth(_asMap(data), fallbackEmail: email.trim());
  }

  @override
  Future<XboardAuthResult> register({
    required String email,
    required String password,
    String? emailCode,
    String? inviteCode,
  }) async {
    final body = <String, dynamic>{
      'email': email.trim(),
      'password': password,
      if (emailCode != null && emailCode.trim().isNotEmpty) 'email_code': emailCode.trim(),
      if (inviteCode != null && inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
    };
    final data = await _request('POST', 'passport/auth/register', body: body);
    return _parseAuth(_asMap(data), fallbackEmail: email.trim());
  }

  @override
  Future<void> sendEmailCode(String email) async {
    // Successful sendEmailVerify responses carry `data: true`, not an object.
    await _request('POST', 'passport/comm/sendEmailVerify', body: {'email': email.trim()});
  }

  @override
  Future<XboardSubscriptionPayload> fetchSubscription(String authData) async {
    final data = _asMap(await _request('GET', 'user/getSubscribe', authData: authData, authenticated: true));
    final subscribeUrl = _nonEmptyString(data['subscribe_url']);
    return XboardSubscriptionPayload(
      subscription: XboardSubscription.fromJson(data),
      subscribeUrl: subscribeUrl,
      email: _nonEmptyString(data['email']),
    );
  }

  XboardAuthResult _parseAuth(Map<String, dynamic> data, {required String fallbackEmail}) {
    final authData = _nonEmptyString(data['auth_data']);
    if (authData == null) {
      throw const XboardException('面板返回的登录信息不完整', kind: XboardFailureKind.protocol);
    }
    return XboardAuthResult(
      authData: normalizeAuthData(authData),
      email: _nonEmptyString(data['email']) ?? fallbackEmail,
      isAdmin: _asBool(data['is_admin']),
    );
  }

  /// Xboard already returns `Bearer <token>`. Never prepend a second prefix.
  @visibleForTesting
  static String normalizeAuthData(String authData) {
    final trimmed = authData.trim();
    if (_bearerPrefix.hasMatch(trimmed)) return trimmed;
    return 'Bearer $trimmed';
  }

  Future<Object?> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? authData,
    bool authenticated = false,
  }) async {
    try {
      // Use an absolute URL: Dio concatenates baseUrl and path as plain strings,
      // so a base without a trailing slash plus a path without a leading slash
      // would produce `/api/v1passport/...`.
      final response = await _dio.request<dynamic>(
        config.endpoint(path).toString(),
        data: body,
        options: Options(method: method, headers: authData == null ? null : {'Authorization': authData}),
      );
      final status = response.statusCode ?? 0;
      final payload = response.data;
      final data = payload is Map ? payload.cast<String, dynamic>() : <String, dynamic>{};

      if (status >= 400) {
        if (authenticated && (status == 401 || status == 403)) {
          throw const XboardException('登录状态已失效，请重新登录', kind: XboardFailureKind.unauthorized);
        }
        throw XboardException(_nonEmptyString(data['message']) ?? _fallbackMessage(status));
      }
      if (status < 200 || status >= 300) {
        throw XboardException(_fallbackMessage(status));
      }

      return data['data'];
    } on XboardException {
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.badResponse) {
        final status = error.response?.statusCode ?? 0;
        if (authenticated && (status == 401 || status == 403)) {
          throw const XboardException('登录状态已失效，请重新登录', kind: XboardFailureKind.unauthorized);
        }
        // Never surface a 5xx body: proxies and panels can return HTML or stack
        // traces. Only the status-derived safe message is shown.
        throw XboardException(_fallbackMessage(status));
      }
      throw XboardException(_networkMessage(error), kind: XboardFailureKind.network);
    } on TimeoutException {
      throw const XboardException('网络请求超时，请稍后重试', kind: XboardFailureKind.network);
    } catch (_) {
      throw const XboardException('无法连接面板，请检查网络后重试', kind: XboardFailureKind.network);
    }
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map) return value.cast<String, dynamic>();
    if (value == null) return const <String, dynamic>{};
    throw const XboardException('面板返回的数据格式不正确', kind: XboardFailureKind.protocol);
  }

  String _networkMessage(DioException error) {
    if (error.type == DioExceptionType.badCertificate || error.error is TlsException) {
      // TLS failures otherwise arrive as Dio's `unknown` type. Keep certificate
      // verification enabled and give a useful message without the raw error,
      // which can contain a request URL or credentials.
      return 'HTTPS 安全连接失败，请检查系统时间和证书信任后重试';
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => '网络请求超时，请稍后重试',
      DioExceptionType.connectionError => '无法连接面板，请检查网络后重试',
      DioExceptionType.cancel => '请求已取消',
      _ => '面板请求失败，请稍后重试',
    };
  }

  String _fallbackMessage(int status) {
    return switch (status) {
      400 => '请求参数有误',
      401 => '登录状态已失效，请重新登录',
      403 => '没有访问权限',
      404 => '面板接口不存在',
      429 => '请求过于频繁，请稍后重试',
      >= 500 => '面板暂时不可用，请稍后重试',
      _ => '面板请求失败（$status）',
    };
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value == '1' || value.toLowerCase() == 'true';
    return false;
  }

  @override
  void close() => _dio.close(force: true);
}
