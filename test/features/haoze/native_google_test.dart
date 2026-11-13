import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/features/haoze/native_google.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoze_xboard/browser_auth.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:haoze_xboard/native_auth.dart';

class _NetworkOverrides extends HttpOverrides {}

class _Transport implements XboardTransport {
  final calls = <({Uri uri, Map<String, Object?>? body})>[];
  Completer<XboardResponse>? configGate;
  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    calls.add((uri: uri, body: body));
    if (uri.path.endsWith('/config')) {
      return configGate?.future ??
          Future.value(
            const XboardResponse(200, {
              'webClientId': 'web-client',
              'desktopClientId': 'desktop-client',
            }),
          );
    }
    if (uri.path.endsWith('/start')) {
      return XboardResponse(200, {'flow': 'f' * 43, 'nonce': 'n' * 43});
    }
    if (uri.path.endsWith('/native/exchange') ||
        uri.path.endsWith('/app/exchange')) {
      return const XboardResponse(200, {
        'data': {
          'email': 'user@example.com',
          'auth_data': 'Bearer session',
          'token': 'subscription',
        },
      });
    }
    return XboardResponse(200, {'step': 'complete', 'code': 'c' * 43});
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    'Windows listens only on loopback, rejects forged state, and exchanges codes through AuthRouter',
    () async {
      Uri? launched;
      final pages = <({int status, String body, String? type, String? csp})>[];
      final http = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _NetworkOverrides(),
      );
      addTearDown(() => http.close(force: true));
      Future<int> callback(Uri uri) async {
        final response = await (await http.getUrl(uri)).close();
        final body = await utf8.decoder.bind(response).join();
        pages.add((
          status: response.statusCode,
          body: body,
          type: response.headers.contentType?.mimeType,
          csp: response.headers.value('Content-Security-Policy'),
        ));
        return response.statusCode;
      }

      final google = NativeGoogleSignIn(
        isAndroid: false,
        isWindows: true,
        open: (uri) async {
          launched = uri;
          final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          expect(redirect.host, '127.0.0.1');
          expect(
            await callback(
              redirect.replace(
                queryParameters: {'state': 'forged', 'code': 'bad'},
              ),
            ),
            400,
          );
          expect(
            await callback(
              redirect.replace(
                query:
                    'state=${uri.queryParameters['state']!}&state=forged&code=bad',
              ),
            ),
            400,
          );
          expect(
            await callback(
              redirect.replace(
                queryParameters: {
                  'state': uri.queryParameters['state']!,
                  'code': 'google-code',
                },
              ),
            ),
            200,
          );
          return true;
        },
      );
      addTearDown(google.close);
      final redirect = await google.prepare();
      await login.start('windows', redirect: redirect);
      final challenge = login.challenge;
      final result = await google.signIn(
        login,
        returnMessage: 'Return to Haoze <script>unsafe</script>',
        returnButtonLabel: 'Return to Windows & app',
      );
      expect(pages.first.body, isNot(contains('haoze-connect:')));
      final page = pages.last;
      expect(page.type, 'text/html');
      expect(page.csp, contains("default-src 'none'"));
      expect(page.csp, contains("script-src 'nonce-"));
      expect(page.body, contains('href="haoze-connect://auth/return"'));
      expect(page.body, contains('Return to Windows &amp; app'));
      expect(page.body, contains('&lt;script&gt;unsafe'));
      expect(page.body, isNot(contains('<script>unsafe')));
      expect(page.body, contains('history.replaceState'));
      expect(page.body, isNot(contains('google-code')));
      expect(page.body, isNot(contains(launched!.queryParameters['state']!)));
      expect(result.account!.email, 'user@example.com');
      expect(launched!.host, 'accounts.google.com');
      expect(launched!.queryParameters['code_challenge'], challenge);
      expect(launched!.queryParameters['nonce'], 'n' * 43);
      expect(launched!.queryParameters.containsKey('client_secret'), false);
      final exchange = transport.calls.firstWhere(
        (call) => call.uri.path.endsWith('/native/v1/google'),
      );
      expect(exchange.body!['code'], 'google-code');
      expect(exchange.body!['code_verifier'], isNotNull);
      expect(exchange.body!.containsKey('client_secret'), false);
    },
  );

  test(
    'Windows OAuth error callbacks do not offer to launch the app',
    () async {
      final http = HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        _NetworkOverrides(),
      );
      addTearDown(() => http.close(force: true));
      final google = NativeGoogleSignIn(
        isAndroid: false,
        isWindows: true,
        open: (uri) async {
          final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
          final response = await (await http.getUrl(
            redirect.replace(
              queryParameters: {
                'state': uri.queryParameters['state']!,
                'error': 'access_denied',
              },
            ),
          )).close();
          expect(response.statusCode, 400);
          expect(
            await utf8.decoder.bind(response).join(),
            isNot(contains('haoze-connect:')),
          );
          return true;
        },
      );
      addTearDown(google.close);
      await login.start('windows', redirect: await google.prepare());
      await expectLater(
        google.signIn(login, returnMessage: 'Return'),
        throwsA(isA<XboardLoginCancelled>()),
      );
      expect(
        transport.calls.any((call) => call.uri.path.endsWith('/google')),
        false,
      );
    },
  );

  test(
    'Windows cancellation completes the pending request and allows a fresh callback listener',
    () async {
      final opened = Completer<void>();
      final google = NativeGoogleSignIn(
        isAndroid: false,
        isWindows: true,
        open: (_) async {
          opened.complete();
          return true;
        },
      );
      addTearDown(google.close);
      final redirect = await google.prepare();
      await login.start('windows', redirect: redirect);
      final result = google.signIn(login, returnMessage: 'Return');
      final rejected = expectLater(
        result,
        throwsA(isA<XboardLoginCancelled>()),
      );
      await opened.future;
      google.cancel();
      await rejected;
      expect(await google.prepare(), isNotNull);
    },
  );

  test(
    'closing while public configuration is loading cannot launch a browser later',
    () async {
      var launches = 0;
      final google = NativeGoogleSignIn(
        isAndroid: false,
        isWindows: true,
        open: (_) async {
          launches++;
          return true;
        },
      );
      transport.configGate = Completer<XboardResponse>();
      final result = google.signIn(login, returnMessage: 'Return');
      final rejected = expectLater(
        result,
        throwsA(isA<XboardLoginCancelled>()),
      );
      await google.close();
      transport.configGate!.complete(
        const XboardResponse(200, {'desktopClientId': 'desktop-client'}),
      );
      await rejected;
      expect(launches, 0);
    },
  );

  test(
    'Android passes server client ID and nonce to Credential Manager and sends the ID token only to AuthRouter',
    () async {
      const channel = MethodChannel('haoze/native_google');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'cancel') return null;
            expect(call.method, 'signIn');
            expect(call.arguments, {
              'serverClientId': 'web-client',
              'nonce': 'n' * 43,
            });
            return {'id_token': 'native-id-token'};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final google = NativeGoogleSignIn(isAndroid: true, isWindows: false);
      addTearDown(google.close);
      await login.start('android');
      final result = await google.signIn(login, returnMessage: 'Return');
      expect(result.account, isNotNull);
      final call = transport.calls.firstWhere(
        (call) => call.uri.path.endsWith('/google'),
      );
      expect(call.uri.host, 'sso.example');
      expect(call.body!['id_token'], 'native-id-token');
      expect(transport.calls.last.body!.containsKey('id_token'), false);
    },
  );
  test(
    'Android missing nonce is reported without submitting a Google credential to AuthRouter',
    () async {
      const channel = MethodChannel('haoze/native_google');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: 'nonce_invalid');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final google = NativeGoogleSignIn(isAndroid: true, isWindows: false);
      addTearDown(google.close);
      await login.start('android');
      await expectLater(
        google.signIn(login, returnMessage: 'Return'),
        throwsA(isA<NativeGoogleNonceException>()),
      );
      expect(
        transport.calls.any((call) => call.uri.path.endsWith('/google')),
        false,
      );
    },
  );
  test(
    'Android native server code is sent to AuthRouter with the flow verifier and never launches a browser',
    () async {
      const channel = MethodChannel('haoze/native_google');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'cancel') return null;
            return {'server_auth_code': 'native-server-code'};
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      var launches = 0;
      final google = NativeGoogleSignIn(
        isAndroid: true,
        isWindows: false,
        open: (_) async {
          launches++;
          return true;
        },
      );
      addTearDown(google.close);
      await login.start('android');
      final result = await google.signIn(login, returnMessage: 'Return');
      expect(result.account!.email, 'user@example.com');
      expect(launches, 0);
      final call = transport.calls.firstWhere(
        (call) => call.uri.path.endsWith('/google'),
      );
      expect(call.body!['server_auth_code'], 'native-server-code');
      expect(call.body!['code_verifier'], isA<String>());
      expect(call.body!.containsKey('id_token'), false);
    },
  );

  test(
    'cancelled Android native result cannot complete login or open a browser',
    () async {
      const channel = MethodChannel('haoze/native_google');
      final token = Completer<Map<String, String>>();
      var cancels = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'cancel') {
              cancels++;
              return null;
            }
            return token.future;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      var launches = 0;
      final google = NativeGoogleSignIn(
        isAndroid: true,
        isWindows: false,
        open: (_) async {
          launches++;
          return true;
        },
      );
      addTearDown(google.close);
      await login.start('android');
      final result = google.signIn(login, returnMessage: 'Return');
      final rejected = expectLater(
        result,
        throwsA(isA<XboardLoginCancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      google.cancel();
      token.complete({'server_auth_code': 'late-native-code'});
      await rejected;
      await Future<void>.delayed(Duration.zero);
      expect(cancels, 1);
      expect(launches, 0);
      expect(
        transport.calls.any((call) => call.uri.path.endsWith('/google')),
        false,
      );
    },
  );
}
