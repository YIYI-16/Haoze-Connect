import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:haoze_xboard/native_auth.dart';
import 'package:haoze_xboard/browser_auth.dart';

class _Transport implements XboardTransport {
  final calls = <({Uri uri, Map<String, Object?>? body})>[];
  String step = 'complete';
  bool exchangeFails = false;
  Completer<XboardResponse>? pending;
  Completer<XboardResponse>? exchangeGate;
  Completer<void>? exchangeStarted;
  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    calls.add((uri: uri, body: body));
    if (uri.path.endsWith('/start')) {
      return pending?.future ??
          Future.value(
            XboardResponse(200, {'flow': 'f' * 43, 'nonce': 'n' * 43}),
          );
    }
    if (uri.path.endsWith('/native/exchange')) {
      if (exchangeGate case final gate?) {
        exchangeStarted?.complete();
        return gate.future;
      }
      return XboardResponse(exchangeFails ? 503 : 200, {
        'data': {
          'email': 'user@example.com',
          'auth_data': 'Bearer session',
          'token': 'subscription',
        },
      });
    }
    if (uri.path.endsWith('/email/send')) {
      return const XboardResponse(200, {'sent': true});
    }
    return XboardResponse(200, {
      'step': step,
      'code': 'c' * 43,
      'token': step == 'mfa' ? 'proof' : null,
    });
  }

  @override
  void close() {}
}

void main() {
  late _Transport transport;
  late XboardNativeLogin login;
  setUp(() {
    transport = _Transport();
    final client = XboardClient(
      panelOrigin: Uri.https('panel.example'),
      transport: transport,
    );
    login = XboardNativeLogin(
      origin: Uri.https('sso.example'),
      client: client,
      transport: transport,
    );
    addTearDown(() {
      login.close();
      client.close();
    });
  });
  test(
    'passwords go only to AuthRouter; PKCE verifier goes only to the trusted exchange',
    () async {
      await login.start('android');
      expect(transport.calls.first.body!.containsKey('code_verifier'), false);
      final challenge = login.challenge;
      final result = await login.authenticate('password', {
        'account': 'user@example.com',
        'password': 'private',
      });
      expect(result.account!.email, 'user@example.com');
      expect(transport.calls[1].uri.host, 'sso.example');
      expect(transport.calls.last.uri.host, 'panel.example');
      expect(transport.calls.last.body!.containsKey('password'), false);
      expect(transport.calls.last.body!['code_verifier'], isNot(challenge));
      expect(result.toString(), isNot(contains('session')));
      expect(login.active, false);
    },
  );
  test(
    'MFA proof is retained in memory and attached only to the matching next step',
    () async {
      await login.start('android');
      transport.step = 'mfa';
      final result = await login.authenticate('password', {
        'account': 'user@example.com',
        'password': 'private',
      });
      expect(result.step, 'mfa');
      expect(result.toString(), isNot(contains('proof')));
      transport.step = 'complete';
      await login.authenticate('mfa', {'code': '123456'});
      expect(transport.calls[2].body!['token'], 'proof');
      expect(transport.calls[2].body!.containsKey('password'), false);
    },
  );
  test(
    'a failed exchange clears its consumed flow so a retry starts fresh',
    () async {
      await login.start('android');
      transport.exchangeFails = true;
      await expectLater(
        login.authenticate('password', {}),
        throwsA(isA<XboardException>()),
      );
      expect(login.active, false);
      transport.exchangeFails = false;
      await login.start('android');
      expect((await login.authenticate('password', {})).account, isNotNull);
    },
  );
  test(
    'cancelling during flow creation cannot restore an obsolete login',
    () async {
      transport.pending = Completer<XboardResponse>();
      final start = login.start('android');
      final rejected = expectLater(start, throwsA(isA<XboardLoginCancelled>()));
      login.reset();
      transport.pending!.complete(
        XboardResponse(200, {'flow': 'f' * 43, 'nonce': 'n' * 43}),
      );
      await rejected;
      expect(login.active, false);
    },
  );
  test(
    'rejects insecure and path-bearing issuers before sending credentials',
    () {
      for (final origin in [
        'http://sso.example',
        'https://user@sso.example',
        'https://sso.example/login',
      ]) {
        expect(
          () => XboardNativeLogin(
            origin: Uri.parse(origin),
            client: XboardClient(panelOrigin: Uri.https('panel.example')),
          ),
          throwsA(isA<XboardException>()),
        );
      }
    },
  );
  test(
    'cancel during exchange cannot accept credentials or reset a newer attempt',
    () async {
      await login.start('android');
      transport.exchangeGate = Completer<XboardResponse>();
      transport.exchangeStarted = Completer<void>();
      final result = login.authenticate('password', {});
      final rejected = expectLater(
        result,
        throwsA(isA<XboardLoginCancelled>()),
      );
      await transport.exchangeStarted!.future;
      login.reset();
      await login.start('android');
      final freshChallenge = login.challenge;
      transport.exchangeGate!.complete(
        const XboardResponse(200, {
          'data': {
            'email': 'user@example.com',
            'auth_data': 'Bearer obsolete',
            'token': 'obsolete-subscription',
          },
        }),
      );
      await rejected;
      expect(login.active, true);
      expect(login.challenge, freshChallenge);
      transport.exchangeGate = null;
      expect((await login.authenticate('password', {})).account, isNotNull);
    },
  );
}
