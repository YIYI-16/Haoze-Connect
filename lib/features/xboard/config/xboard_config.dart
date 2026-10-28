import 'package:flutter/foundation.dart';

/// Compile-time configuration for the Xboard integration.
///
/// Override the panel at build time, for example:
///
/// ```sh
/// flutter build apk \
///   --dart-define=XBOARD_BASE_URL=https://panel.example.com \
///   --dart-define=XBOARD_APP_NAME="Example Connect"
/// ```
const String xboardDefaultBaseUrl = 'https://www.haoze.cyou';
const String xboardDefaultAppName = 'Haoze Connect';

/// The public panel URL. Only an HTTPS origin is accepted by [XboardClientConfig].
String get xboardBaseUrl => const String.fromEnvironment('XBOARD_BASE_URL', defaultValue: xboardDefaultBaseUrl);

/// The brand shown inside the Xboard login/account screens.
String get xboardAppName => const String.fromEnvironment('XBOARD_APP_NAME', defaultValue: xboardDefaultAppName);

class XboardConfigurationException implements Exception {
  const XboardConfigurationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A validated, immutable view of the panel configuration.
///
/// [origin] is persisted with the session so an auth token can never be sent to
/// a different panel after the build configuration changes.
@immutable
class XboardClientConfig {
  const XboardClientConfig._({
    required this.baseUrl,
    required this.origin,
    required this.apiBaseUrl,
    required this.appName,
  });

  factory XboardClientConfig.fromEnvironment({String? baseUrl, String? appName}) {
    return XboardClientConfig.parse(baseUrl: baseUrl ?? xboardBaseUrl, appName: appName ?? xboardAppName);
  }

  /// Normalizes a panel URL and appends the Xboard v1 API prefix.
  ///
  /// Rejects credentials in the URL, query strings, fragments, non-HTTPS
  /// schemes and anything that is not a plain host origin.
  factory XboardClientConfig.parse({required String baseUrl, required String appName}) {
    final trimmed = baseUrl.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      throw const XboardConfigurationException('Xboard 面板地址无效');
    }
    if (uri.scheme != 'https') {
      throw const XboardConfigurationException('Xboard 面板地址必须使用 HTTPS');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const XboardConfigurationException('Xboard 面板地址不能包含账号、查询参数或片段');
    }

    final basePath = uri.path.replaceFirst(RegExp(r'/+$'), '');
    final apiPath = basePath.endsWith('/api/v1') ? basePath : '$basePath/api/v1';
    final apiBase = Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: apiPath);
    final origin = Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null).origin;

    return XboardClientConfig._(
      baseUrl: trimmed,
      origin: origin,
      apiBaseUrl: apiBase.toString(),
      appName: appName.trim().isEmpty ? xboardDefaultAppName : appName.trim(),
    );
  }

  /// The URL exactly as supplied by the build, kept for diagnostics/docs.
  final String baseUrl;

  /// Scheme + host + port. This is the panel binding stored with a session.
  final String origin;

  /// Fully qualified `/api/v1` URL, without a trailing slash.
  final String apiBaseUrl;

  final String appName;

  Uri endpoint(String path, [Map<String, dynamic>? queryParameters]) {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(
      '$apiBaseUrl/$normalized',
    ).replace(queryParameters: queryParameters == null || queryParameters.isEmpty ? null : queryParameters);
  }
}
