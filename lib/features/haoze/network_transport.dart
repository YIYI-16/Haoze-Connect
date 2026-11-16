import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/plugins/app.dart';
import 'dart:typed_data';

import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart' as native;

import 'network_settings.dart';

typedef AccountHttpRunner =
    Future<native.AccountHttpResponse> Function({
      required native.AccountNetworkOptions options,
      required String method,
      required String url,
      required Map<String, String> headers,
      required Uint8List body,
    });

typedef AccountDohProbe =
    Future<int> Function({required native.AccountNetworkOptions options});

native.AccountNetworkOptions nativeNetworkOptions(
  AccountNetworkSettings value, {
  List<String> systemDnsServers = const [],
}) => native.AccountNetworkOptions(
  dohProvider: value.dohProvider.name,
  dohEnabled: value.dohEnabled,
  systemDnsServers: systemDnsServers,
  echEnabled: value.echEnabled,
  proxyUrl: value.proxyUrl,
  proxyUsername: value.proxyUsername,
  proxyPassword: value.proxyPassword,
);

class AccountNetworkTransport implements XboardTransport {
  AccountNetworkTransport(
    this.settings, {
    AccountHttpRunner? run,
    Future<List<String>> Function()? systemDns,
  }) : _run = run ?? native.accountHttpRequest,
       _systemDns = systemDns ?? _androidSystemDns;

  static Future<List<String>> _androidSystemDns() async =>
      Platform.isAndroid ? await app!.getSystemDnsServers() : const [];

  final AccountNetworkController settings;
  final AccountHttpRunner _run;
  final Future<List<String>> Function() _systemDns;
  bool _closed = false;

  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    final response = await _request(method, uri, headers, body);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      if (response.status >= 200 && response.status < 300) {
        throw const XboardException(XboardFailure.protocol);
      }
    }
    return XboardResponse(response.status, decoded);
  }

  Future<Uint8List> download(Uri uri) async {
    final response = await _request(
      'GET',
      uri,
      {
        'Accept': 'application/yaml, text/yaml, text/plain',
        'User-Agent': 'HaozeConnect',
      },
      null,
      binary: true,
    );
    if (response.status < 200 || response.status >= 300) {
      throw XboardException(XboardFailure.http, statusCode: response.status);
    }
    return response.body;
  }

  Future<native.AccountHttpResponse> _request(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body, {
    bool binary = false,
  }) async {
    if (_closed) throw const XboardException(XboardFailure.socket);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const XboardException(XboardFailure.configuration);
    }
    final value = await settings.current;
    if (_closed) throw const XboardException(XboardFailure.socket);
    final native.AccountHttpResponse response;
    try {
      final servers =
          !value.dohEnabled && value.echEnabled && !value.proxyEnabled
          ? await _systemDns()
          : const <String>[];
      if (_closed) throw const XboardException(XboardFailure.socket);
      response = await _run(
        options: nativeNetworkOptions(value, systemDnsServers: servers),
        method: method,
        url:
            AccountRoute.values.any((route) => route.host == uri.host) &&
                uri.port == 443
            ? uri.replace(host: value.route.host).toString()
            : uri.toString(),
        headers: {
          ...headers,
          if (body != null) 'Content-Type': 'application/json',
        },
        body: Uint8List.fromList(
          body == null ? const [] : utf8.encode(jsonEncode(body)),
        ),
      );
    } catch (error) {
      final text = error.toString();
      final kind = XboardFailure.values
          .where((kind) => RegExp('\\b${kind.name}\\b').hasMatch(text))
          .firstOrNull;
      throw XboardException(kind ?? XboardFailure.tls);
    }
    if (_closed) throw const XboardException(XboardFailure.socket);
    if (response.status >= 300 && response.status < 400) {
      throw XboardException(
        XboardFailure.redirect,
        statusCode: response.status,
      );
    }
    if (response.body.length > (binary ? 8 : 1) * 1024 * 1024) {
      throw const XboardException(XboardFailure.protocol);
    }
    return response;
  }

  @override
  void close() => _closed = true;
}

final accountDohProbeProvider = Provider<AccountDohProbe>(
  (ref) => native.accountDohLatency,
);

typedef AccountRouteProbe =
    Future<int> Function({required AccountNetworkSettings settings});

Future<int> _measureAccountRoute({
  required AccountNetworkSettings settings,
}) async {
  final controller = AccountNetworkController(
    read: () async => jsonEncode(settings.toJson()),
  );
  final transport = AccountNetworkTransport(controller);
  final watch = Stopwatch()..start();
  try {
    final response = await transport.send(
      'GET',
      settings.route.origin.replace(path: '/api/v1/guest/comm/config'),
      {'Accept': 'application/json'},
      null,
    );
    if (response.statusCode != 200 || response.body is! Map<String, dynamic>) {
      throw const XboardException(XboardFailure.protocol);
    }
    return watch.elapsedMilliseconds;
  } finally {
    transport.close();
  }
}

final accountRouteProbeProvider = Provider<AccountRouteProbe>(
  (ref) => _measureAccountRoute,
);
