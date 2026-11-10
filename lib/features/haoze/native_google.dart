import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:haoze_xboard/browser_auth.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:haoze_xboard/native_auth.dart';
import 'package:url_launcher/url_launcher.dart';

class NativeGoogleSignIn {
  NativeGoogleSignIn({
    required this.isAndroid,
    required this.isWindows,
    Future<bool> Function(Uri)? open,
  }) : _open =
           open ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));
  final bool isAndroid;
  final bool isWindows;
  final Future<bool> Function(Uri) _open;
  HttpServer? _server;
  Completer<String>? _callback;
  String? _state;
  String _returnMessage = '';
  Timer? _timer;
  int _generation = 0;

  Future<Uri?> prepare() async {
    if (isAndroid) return null;
    if (!isWindows) throw const XboardException(XboardFailure.configuration);
    if (_server == null) {
      final generation = _generation;
      final server = _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      if (generation != _generation) {
        await server.close(force: true);
        _server = null;
        throw const XboardLoginCancelled();
      }
      server.listen(
        (request) async {
          final uri = request.uri;
          final callback = _callback;
          final valid =
              request.method == 'GET' &&
              uri.path == '/oauth/callback' &&
              uri.queryParametersAll.values.every(
                (values) => values.length == 1,
              ) &&
              _state != null &&
              uri.queryParameters['state'] == _state &&
              callback != null &&
              !callback.isCompleted;
          request.response.headers.set(
            HttpHeaders.cacheControlHeader,
            'no-store',
          );
          request.response.headers.set('Referrer-Policy', 'no-referrer');
          request.response.headers.contentType = ContentType.text;
          if (!valid) {
            request.response.statusCode = HttpStatus.badRequest;
          } else {
            request.response.write(_returnMessage);
          }
          try {
            await request.response.close();
          } on IOException {
            // A browser disconnect does not invalidate an authenticated callback.
          }
          if (valid && !callback.isCompleted) {
            final code = uri.queryParameters['code'];
            if (code == null ||
                code.isEmpty ||
                code.length > 4096 ||
                uri.queryParameters.containsKey('error')) {
              callback.completeError(const XboardLoginCancelled());
            } else {
              callback.complete(code);
            }
          }
        },
        onError: (Object _) {
          if (_callback case final callback? when !callback.isCompleted) {
            callback.completeError(const XboardException(XboardFailure.socket));
          }
        },
      );
    }
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server!.port,
      path: '/oauth/callback',
    );
  }

  Future<NativeAuthResult> signIn(
    XboardNativeLogin login, {
    required String returnMessage,
  }) async {
    final generation = _generation;
    final config = await login.config();
    if (generation != _generation) throw const XboardLoginCancelled();
    if (isAndroid) {
      try {
        final token = await const MethodChannel('haoze/native_google')
            .invokeMethod<String>('signIn', {
              'serverClientId': config['webClientId'],
              'nonce': login.nonce,
            });
        if (token == null) throw const XboardException(XboardFailure.protocol);
        if (generation != _generation) throw const XboardLoginCancelled();
        return await login.authenticate('google', {'id_token': token});
      } on PlatformException catch (error) {
        if (error.code == 'cancelled') throw const XboardLoginCancelled();
        throw const XboardException(XboardFailure.configuration);
      }
    }
    final redirect = await prepare();
    if (generation != _generation) throw const XboardLoginCancelled();
    final callback = _callback = Completer<String>();
    _returnMessage = returnMessage;
    final random = Random.secure();
    final state = _state = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    _timer = Timer(const Duration(minutes: 5), () {
      if (!callback.isCompleted) {
        callback.completeError(const XboardException(XboardFailure.timeout));
      }
    });
    unawaited(() async {
      try {
        final opened = await _open(
          Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
            'client_id': config['desktopClientId'] as String,
            'redirect_uri': redirect.toString(),
            'response_type': 'code',
            'scope': 'openid email profile',
            'state': state,
            'nonce': login.nonce!,
            'code_challenge': login.challenge!,
            'code_challenge_method': 'S256',
          }),
        );
        if (!opened && !callback.isCompleted) {
          callback.completeError(
            const XboardException(XboardFailure.configuration),
          );
        }
      } catch (_) {
        if (!callback.isCompleted) {
          callback.completeError(
            const XboardException(XboardFailure.configuration),
          );
        }
      }
    }());
    try {
      final code = await callback.future;
      return await login.authenticate('google', {'code': code});
    } finally {
      _callback = null;
      _state = null;
      _timer?.cancel();
      await _server?.close(force: true);
      _server = null;
    }
  }

  void cancel() {
    _generation++;
    if (_callback case final callback? when !callback.isCompleted) {
      callback.completeError(const XboardLoginCancelled());
    }
  }

  Future<void> close() async {
    cancel();
    _timer?.cancel();
    await _server?.close(force: true);
    _server = null;
  }
}
