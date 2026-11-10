import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'browser_auth.dart';
import 'haoze_xboard.dart';

class NativeAuthResult {
  const NativeAuthResult({
    required this.step,
    this.token,
    this.email,
    this.account,
  });
  final String step;
  final String? token;
  final String? email;
  final XboardBrowserAccount? account;

  @override
  String toString() => 'NativeAuthResult($step, <private>)';
}

class XboardNativeLogin {
  XboardNativeLogin({
    required this.origin,
    required this.client,
    XboardTransport? transport,
  }) : _transport = transport ?? StrictIoXboardTransport() {
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        !['', '/'].contains(origin.path)) {
      throw const XboardException(XboardFailure.configuration);
    }
  }
  final Uri origin;
  final XboardClient client;
  final XboardTransport _transport;
  String? _flow;
  String? _verifier;
  String? _token;
  int _generation = 0;
  String? nonce;
  String? challenge;
  bool get active => _flow != null;

  Future<Map<String, dynamic>> _request(
    String path, [
    Map<String, Object?>? body,
  ]) async {
    final response = await _transport.send(
      body == null ? 'GET' : 'POST',
      origin.replace(path: '/native/v1/$path'),
      {'Accept': 'application/json', 'Content-Type': 'application/json'},
      body,
    );
    if (response.statusCode != 200) {
      throw XboardException(
        response.statusCode == 401 || response.statusCode == 403
            ? XboardFailure.unauthorized
            : XboardFailure.http,
        statusCode: response.statusCode,
      );
    }
    final data = response.body;
    if (data is! Map<String, dynamic>) {
      throw const XboardException(XboardFailure.protocol);
    }
    return data;
  }

  Future<Map<String, dynamic>> config() => _request('config');

  Future<void> start(String platform, {Uri? redirect}) async {
    reset();
    final generation = _generation;
    final random = Random.secure();
    final verifier = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final boundChallenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final data = await _request('start', {
      'platform': platform,
      'code_challenge': boundChallenge,
      if (redirect != null) 'redirect_uri': redirect.toString(),
    });
    if (generation != _generation) throw const XboardLoginCancelled();
    if (data['flow'] is! String || data['nonce'] is! String) {
      throw const XboardException(XboardFailure.protocol);
    }
    _flow = data['flow'] as String;
    nonce = data['nonce'] as String;
    _verifier = verifier;
    challenge = boundChallenge;
  }

  Future<NativeAuthResult> authenticate(
    String action,
    Map<String, Object?> values,
  ) async {
    if (_flow == null) throw const XboardException(XboardFailure.configuration);
    final generation = _generation;
    final data = await _request(action, {
      'flow': _flow,
      ...values,
      if (action == 'mfa' || action == 'password-change') 'token': _token,
      if (action == 'google' &&
          (values.containsKey('code') ||
              values.containsKey('server_auth_code')))
        'code_verifier': _verifier,
    });
    if (generation != _generation) throw const XboardLoginCancelled();
    final step = data['step'];
    if (step == 'complete') {
      final code = data['code'];
      if (code is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(code)) {
        throw const XboardException(XboardFailure.protocol);
      }
      try {
        final account = await client.exchangeNativeGrant(code, _verifier!);
        if (generation != _generation) throw const XboardLoginCancelled();
        return NativeAuthResult(step: 'complete', account: account);
      } finally {
        if (generation == _generation) reset();
      }
    }
    if (!['mfa', 'password-change', 'link'].contains(step)) {
      throw const XboardException(XboardFailure.protocol);
    }
    _token = data['token'] as String?;
    return NativeAuthResult(
      step: step as String,
      token: _token,
      email: data['email'] as String?,
    );
  }

  Future<void> sendEmailCode(String account) async {
    if (_flow == null) throw const XboardException(XboardFailure.configuration);
    await _request('email/send', {'flow': _flow, 'account': account});
  }

  void reset() {
    _generation++;
    _flow = null;
    _verifier = null;
    _token = null;
    nonce = null;
    challenge = null;
  }

  void close() {
    reset();
    _transport.close();
  }
}
