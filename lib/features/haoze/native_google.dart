import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:haoze_xboard/browser_auth.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:haoze_xboard/native_auth.dart';
import 'package:url_launcher/url_launcher.dart';

class NativeGoogleNonceException implements Exception {
  const NativeGoogleNonceException();
}

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
  String _returnButtonLabel = '';
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
          final code = uri.queryParameters['code'];
          final accepted =
              valid &&
              code != null &&
              code.isNotEmpty &&
              code.length <= 4096 &&
              !uri.queryParameters.containsKey('error');
          request.response.headers.set(
            HttpHeaders.cacheControlHeader,
            'no-store',
          );
          request.response.headers.set('Referrer-Policy', 'no-referrer');
          request.response.headers.contentType = accepted
              ? ContentType.html
              : ContentType.text;
          if (!accepted) {
            request.response.statusCode = HttpStatus.badRequest;
          } else {
            final nonce = base64UrlEncode(
              List<int>.generate(16, (_) => Random.secure().nextInt(256)),
            ).replaceAll('=', '');
            request.response.headers.set(
              'Content-Security-Policy',
              "default-src 'none'; script-src 'nonce-$nonce'; "
                  "style-src 'nonce-$nonce'; base-uri 'none'; "
                  "frame-ancestors 'none'; form-action 'none'",
            );
            request.response.write(
              _returnPage(_returnMessage, _returnButtonLabel, nonce),
            );
          }
          try {
            await request.response.close();
          } on IOException {
            // A browser disconnect does not invalidate an authenticated callback.
          }
          if (valid && !callback.isCompleted) {
            if (!accepted) {
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
    String? returnButtonLabel,
  }) async {
    final generation = _generation;
    final config = await login.config();
    if (generation != _generation) throw const XboardLoginCancelled();
    if (isAndroid) {
      try {
        final credential = await const MethodChannel('haoze/native_google')
            .invokeMapMethod<String, dynamic>('signIn', {
              'serverClientId': config['webClientId'],
              'nonce': login.nonce,
            });
        if (credential == null || credential.length != 1) {
          throw const XboardException(XboardFailure.protocol);
        }
        final entry = credential.entries.single;
        if (!['id_token', 'server_auth_code'].contains(entry.key) ||
            entry.value is! String ||
            (entry.value as String).isEmpty) {
          throw const XboardException(XboardFailure.protocol);
        }
        if (generation != _generation) throw const XboardLoginCancelled();
        return await login.authenticate('google', credential);
      } on PlatformException catch (error) {
        if (error.code == 'cancelled') throw const XboardLoginCancelled();
        if (error.code == 'nonce_invalid') {
          if (generation != _generation) throw const XboardLoginCancelled();
          throw const NativeGoogleNonceException();
        }
        throw const XboardException(XboardFailure.configuration);
      }
    }
    final redirect = await prepare();
    if (generation != _generation) throw const XboardLoginCancelled();
    final callback = _callback = Completer<String>();
    _returnMessage = returnMessage;
    _returnButtonLabel = returnButtonLabel ?? returnMessage;
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
    if (isAndroid) {
      unawaited(
        const MethodChannel(
          'haoze/native_google',
        ).invokeMethod<void>('cancel').catchError((Object _) {}),
      );
    }
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

String _returnPage(String message, String buttonLabel, String nonce) {
  const escape = HtmlEscape();
  final label = escape.convert(buttonLabel);
  return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>$label</title>
<style nonce="$nonce">
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f6fa;
font-family:system-ui,sans-serif;color:#182230;padding:1.5rem;box-sizing:border-box}
main{max-width:27.5rem;background:white;padding:2.25rem;border-radius:1.75rem;
box-shadow:0 0.75rem 2.5rem #18223014;text-align:center}
h1{font-size:1.5rem;margin:0 0 1rem}p{line-height:1.7;margin-bottom:1.75rem}
a{display:inline-block;background:#245f9a;color:white;text-decoration:none;
padding:0.875rem 1.5rem;border-radius:1rem;font-weight:600}
a:focus-visible{outline:0.1875rem solid #182230;outline-offset:0.25rem}
</style></head><body><main role="dialog" aria-labelledby="title">
<h1 id="title">$label</h1><p>${escape.convert(message)}</p>
<a href="haoze-connect://auth/return">$label</a></main>
<script nonce="$nonce">
history.replaceState(null, '', location.pathname);
setTimeout(() => { location.href = 'haoze-connect://auth/return'; }, 300);
</script></body></html>''';
}
