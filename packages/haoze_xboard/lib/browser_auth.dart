import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'haoze_xboard.dart';

const haozeAuthScheme = 'haoze-connect';

class XboardBrowserAccount {
  const XboardBrowserAccount({required this.email, required this.session});
  final String email;
  final XboardSession session;

  @override
  String toString() => 'XboardBrowserAccount(<private>)';
}

class XboardLoginCancelled implements Exception {
  const XboardLoginCancelled();
}

class _Attempt {
  final result = Completer<String>();
  bool cancelled = false;
}

/// Browser authentication keeps passwords and WebAuthn on their HTTPS origins.
/// Only an ephemeral, PKCE-bound code crosses the custom-scheme boundary.
class XboardBrowserLogin {
  XboardBrowserLogin({
    required this.client,
    required this.origin,
    required this.links,
    required this.open,
    this.timeout = const Duration(minutes: 5),
  });

  final XboardClient client;
  final Uri origin;
  final Stream<Uri> links;
  final Future<bool> Function(Uri) open;
  final Duration timeout;
  _Attempt? _attempt;
  bool _closed = false;

  Future<XboardBrowserAccount> login() async {
    if (_closed ||
        _attempt != null ||
        origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        !['', '/'].contains(origin.path) ||
        origin.hasQuery ||
        origin.hasFragment) {
      throw const XboardException(XboardFailure.configuration);
    }
    final attempt = _attempt = _Attempt();
    final random = Random.secure();
    String secret() => base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    final state = secret();
    final verifier = secret();
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final subscription = links.listen(
      (uri) {
        if (attempt.result.isCompleted ||
            uri.scheme != haozeAuthScheme ||
            uri.host != 'auth' ||
            uri.path != '/callback' ||
            uri.hasPort ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            uri.queryParametersAll.values.any((values) => values.length != 1) ||
            uri.queryParameters['state'] != state) {
          return;
        }
        final code = uri.queryParameters['code'];
        if (code == null || !RegExp(r'^[A-Za-z0-9]{64}$').hasMatch(code)) {
          attempt.result.completeError(
            const XboardException(XboardFailure.unauthorized),
          );
        } else {
          attempt.result.complete(code);
        }
      },
      onError: (Object _) {
        if (!attempt.result.isCompleted) {
          attempt.result.completeError(
            const XboardException(XboardFailure.protocol),
          );
        }
      },
    );
    final timer = Timer(timeout, () {
      if (!attempt.result.isCompleted) {
        attempt.result.completeError(
          const XboardException(XboardFailure.timeout),
        );
      }
    });
    // Attach the callback waiter before launching, including synchronous callbacks.
    unawaited(() async {
      try {
        final opened = await open(
          origin.replace(
            path: '/api/v1/account-bridge/app/login',
            queryParameters: {
              'state': state,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
            },
          ),
        );
        if (!opened && !attempt.result.isCompleted) {
          attempt.result.completeError(
            const XboardException(XboardFailure.configuration),
          );
        }
      } catch (_) {
        if (!attempt.result.isCompleted) {
          attempt.result.completeError(
            const XboardException(XboardFailure.configuration),
          );
        }
      }
    }());
    try {
      final code = await attempt.result.future;
      if (attempt.cancelled) throw const XboardLoginCancelled();
      final account = await client.exchangeBrowserGrant(code, verifier);
      if (attempt.cancelled) throw const XboardLoginCancelled();
      return account;
    } finally {
      timer.cancel();
      await subscription.cancel();
      if (identical(_attempt, attempt)) _attempt = null;
    }
  }

  void cancel() {
    final attempt = _attempt;
    if (attempt == null) return;
    attempt.cancelled = true;
    if (!attempt.result.isCompleted) {
      attempt.result.completeError(const XboardLoginCancelled());
    }
  }

  void close() {
    _closed = true;
    cancel();
  }
}
