import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoze_xboard/browser_auth.dart';
import 'package:haoze_xboard/haoze_xboard.dart';

class Transport implements XboardTransport {
  Map<String, Object?>? body;
  int calls = 0;
  int status = 200;
  Completer<void>? hold;
  @override
  Future<XboardResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, Object?>? body,
  ) async {
    calls++;
    this.body = body;
    expect(method, 'POST');
    expect(
      uri.toString(),
      'https://panel.example/api/v1/account-bridge/app/exchange',
    );
    expect(headers.containsKey('Authorization'), false);
    await hold?.future;
    return XboardResponse(status, {
      'data': {
        'email': 'verified@example.com',
        'auth_data': 'Bearer private',
        'token': 'private-subscription',
      },
    });
  }

  @override
  void close() {}
}

void main() {
  late StreamController<Uri> links;
  late Transport transport;
  late XboardBrowserLogin browser;
  late Completer<Uri> opened;
  setUp(() {
    links = StreamController<Uri>.broadcast(sync: true);
    transport = Transport();
    opened = Completer<Uri>();
    browser = XboardBrowserLogin(
      client: XboardClient(
        panelOrigin: Uri.https('panel.example'),
        transport: transport,
      ),
      origin: Uri.https('panel.example'),
      links: links.stream,
      open: (uri) async {
        opened.complete(uri);
        return true;
      },
      timeout: const Duration(milliseconds: 150),
    );
  });
  tearDown(() async {
    browser.close();
    await links.close();
  });
  Uri callback(Uri request, {String? state}) => Uri(
    scheme: 'haoze-connect',
    host: 'auth',
    path: '/callback',
    queryParameters: {
      'state': state ?? request.queryParameters['state']!,
      'code': 'a' * 64,
    },
  );
  test('exchanges one opaque grant using its own S256 verifier', () async {
    final result = browser.login();
    final request = await opened.future;
    expect(request.path, '/api/v1/account-bridge/app/login');
    expect(request.queryParameters['code_challenge_method'], 'S256');
    expect(
      request.queryParameters.keys,
      unorderedEquals(['state', 'code_challenge', 'code_challenge_method']),
    );
    links.add(callback(request));
    final account = await result;
    expect(account.email, 'verified@example.com');
    final verifier = transport.body!['code_verifier'] as String;
    expect(
      base64UrlEncode(
        sha256.convert(ascii.encode(verifier)).bytes,
      ).replaceAll('=', ''),
      request.queryParameters['code_challenge'],
    );
    expect(account.toString(), isNot(contains('Bearer')));
    expect(transport.calls, 1);
    links.add(callback(request));
    expect(transport.calls, 1);
    expect(links.hasListener, false);
  });
  test(
    'wrong state, origin, path and duplicated parameters cannot finish sign-in',
    () async {
      final result = browser.login();
      final request = await opened.future;
      links.add(callback(request, state: 'wrong'));
      links.add(callback(request).replace(host: 'other'));
      links.add(callback(request).replace(scheme: 'https'));
      links.add(callback(request).replace(path: '/other'));
      links.add(Uri.parse('${callback(request)}&state=duplicate'));
      expect(transport.calls, 0);
      links.add(callback(request));
      await result;
      expect(transport.calls, 1);
    },
  );
  test('cancel detaches listener; next attempt uses fresh state', () async {
    final result = browser.login();
    final request = await opened.future;
    final check = expectLater(result, throwsA(isA<XboardLoginCancelled>()));
    browser.cancel();
    await check;
    expect(links.hasListener, false);
    opened = Completer<Uri>();
    final retry = browser.login();
    final next = await opened.future;
    expect(
      next.queryParameters['state'],
      isNot(request.queryParameters['state']),
    );
    links.add(callback(request));
    expect(transport.calls, 0);
    links.add(callback(next));
    await retry;
  });
  test('cancel during exchange cannot deliver credentials', () async {
    transport.hold = Completer<void>();
    final result = browser.login();
    final request = await opened.future;
    links.add(callback(request));
    await Future<void>.delayed(Duration.zero);
    final check = expectLater(result, throwsA(isA<XboardLoginCancelled>()));
    browser.cancel();
    transport.hold!.complete();
    await check;
  });
  test('timeout releases listener', () async {
    await expectLater(
      browser.login(),
      throwsA(
        isA<XboardException>().having(
          (e) => e.kind,
          'kind',
          XboardFailure.timeout,
        ),
      ),
    );
    expect(links.hasListener, false);
    expect(transport.calls, 0);
  });
  test('reject concurrent attempts; close terminates pending login', () async {
    final result = browser.login();
    await opened.future;
    await expectLater(browser.login(), throwsA(isA<XboardException>()));
    final check = expectLater(result, throwsA(isA<XboardLoginCancelled>()));
    browser.close();
    await check;
    await expectLater(browser.login(), throwsA(isA<XboardException>()));
  });
  test('launch failure is sanitized and clears listener', () async {
    browser.close();
    browser = XboardBrowserLogin(
      client: XboardClient(
        panelOrigin: Uri.https('panel.example'),
        transport: transport,
      ),
      origin: Uri.https('panel.example'),
      links: links.stream,
      open: (_) async => throw StateError('sensitive launch url'),
    );
    await expectLater(
      browser.login(),
      throwsA(
        isA<XboardException>().having(
          (e) => e.toString(),
          'sanitized',
          isNot(contains('sensitive')),
        ),
      ),
    );
    expect(links.hasListener, false);
  });
  test('server rejection never becomes valid session', () async {
    transport.status = 401;
    final result = browser.login();
    final check = expectLater(
      result,
      throwsA(
        isA<XboardException>().having(
          (e) => e.kind,
          'kind',
          XboardFailure.unauthorized,
        ),
      ),
    );
    links.add(callback(await opened.future));
    await check;
  });
}
