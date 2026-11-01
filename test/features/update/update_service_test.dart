import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/features/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

const pin = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final payload = utf8.encode('verified installer fixture');
final payloadDigest = sha256.convert(payload).toString();

Map<String, dynamic> manifest({
  UpdatePlatform platform = UpdatePlatform.windows,
}) => {
  'schema': 1,
  'channel': 'stable',
  'version': '6.0.4',
  'platforms': {
    platform.name: {
      'name': platform == UpdatePlatform.windows
          ? 'HaozeConnect-Windows-Setup-x64-6.0.4.exe'
          : 'HaozeConnect-Android-arm64-6.0.4.apk',
      'bytes': payload.length,
      'sha256': payloadDigest,
      if (platform == UpdatePlatform.android) ...{
        'package': 'com.haoze.connect.mihomo',
        'certificate_sha256': pin,
        'version_code': 64004,
      },
    },
  },
};

class FakeTransport implements UpdateTransport {
  final responses = <String, UpdateResponse Function()>{};
  final requests = <Uri>[];
  void json(Uri uri, Object data) =>
      responses[uri.toString()] = () =>
          UpdateResponse(200, {}, Stream.value(utf8.encode(jsonEncode(data))));
  @override
  Future<UpdateResponse> open(Uri uri, UpdateCancellation cancellation) async {
    cancellation.check();
    requests.add(uri);
    return responses[uri.toString()]?.call() ??
        (throw const UpdateException(UpdateFailure.network));
  }
}

class HostOverride extends HttpOverrides {
  bool used = false;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    used = true;
    throw StateError(
      'Application certificate overrides must not affect updates',
    );
  }
}

void main() {
  late Directory directory;
  late FakeTransport transport;
  late HaozeUpdateService service;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('haoze-update');
    transport = FakeTransport();
    service = HaozeUpdateService(
      transport: transport,
      platform: UpdatePlatform.windows,
      identity: const UpdateIdentity(version: '6.0.3', versionCode: 62003),
      directory: () async => directory,
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  Map<String, dynamic> release() => {
    'tag_name': 'v6.0.4',
    'draft': false,
    'prerelease': false,
    'assets': [
      {
        'name': updateManifestName,
        'state': 'uploaded',
        'browser_download_url': updateAssetUri(
          '6.0.4',
          updateManifestName,
        ).toString(),
      },
      {
        'name': 'HaozeConnect-Windows-Setup-x64-6.0.4.exe',
        'state': 'uploaded',
        'size': payload.length,
        'digest': 'sha256:$payloadDigest',
        'browser_download_url': updateAssetUri(
          '6.0.4',
          'HaozeConnect-Windows-Setup-x64-6.0.4.exe',
        ).toString(),
      },
    ],
  };
  void serve(Map<String, dynamic> data) {
    transport.json(
      Uri.https('api.github.com', '/repos/$updateRepository/releases/latest'),
      data,
    );
    transport.json(updateAssetUri('6.0.4', updateManifestName), manifest());
  }

  Matcher failure(UpdateFailure value) =>
      isA<UpdateException>().having((e) => e.failure, 'failure', value);
  UpdateRelease candidate() => service.parseManifest(manifest(), '6.0.4');

  test(
    'latest stable release and exact asset are bound to the public manifest',
    () async {
      serve(release());
      final update = await service.check(UpdateCancellation());
      expect(update!.sha256, payloadDigest);
      expect(update.bytes, payload.length);
      expect(
        update.uri.toString(),
        'https://github.com/YIYI-16/Haoze-Connect/releases/download/v6.0.4/HaozeConnect-Windows-Setup-x64-6.0.4.exe',
      );
    },
  );
  test('an older release is current without fetching a manifest', () async {
    final data = release()..['tag_name'] = 'v6.0.2';
    serve(data);
    expect(await service.check(UpdateCancellation()), isNull);
    expect(transport.requests.length, 1);
  });
  for (final field in ['draft', 'prerelease']) {
    test('$field releases cannot supply an installer', () async {
      final data = release()..[field] = true;
      serve(data);
      await expectLater(
        service.check(UpdateCancellation()),
        throwsA(failure(UpdateFailure.metadata)),
      );
    });
  }
  test('duplicate manifests and foreign download links are rejected', () async {
    final data = release();
    final assets = data['assets'] as List;
    assets.add(assets.first);
    serve(data);
    await expectLater(
      service.check(UpdateCancellation()),
      throwsA(failure(UpdateFailure.metadata)),
    );
    final foreign = release();
    (foreign['assets'] as List).first['browser_download_url'] =
        'https://github.com/other/repo/releases/download/v6.0.4/UPDATE-MANIFEST.json';
    serve(foreign);
    await expectLater(
      service.check(UpdateCancellation()),
      throwsA(failure(UpdateFailure.metadata)),
    );
  });
  test('missing metadata is an error, not an up-to-date result', () async {
    serve(release()..['assets'] = []);
    await expectLater(
      service.check(UpdateCancellation()),
      throwsA(failure(UpdateFailure.metadata)),
    );
  });
  test('a transport failure remains distinct from current version', () async {
    await expectLater(
      service.check(UpdateCancellation()),
      throwsA(failure(UpdateFailure.network)),
    );
  });
  test(
    'API rate limits may use only the exact Latest tag and its verified manifest',
    () async {
      transport
              .responses['https://github.com/$updateRepository/releases/latest'] =
          () => const UpdateResponse(302, {
            'location':
                'https://github.com/YIYI-16/Haoze-Connect/releases/tag/v6.0.4',
          }, Stream.empty());
      transport.json(updateAssetUri('6.0.4', updateManifestName), manifest());
      expect(
        (await service.check(UpdateCancellation()))!.sha256,
        payloadDigest,
      );
      transport
              .responses['https://github.com/$updateRepository/releases/latest'] =
          () => const UpdateResponse(302, {
            'location': 'https://github.com/other/repo/releases/tag/v6.0.4',
          }, Stream.empty());
      await expectLater(
        service.check(UpdateCancellation()),
        throwsA(failure(UpdateFailure.metadata)),
      );
    },
  );
  test('asset digest and byte size must match the verified manifest', () async {
    final data = release();
    (data['assets'] as List).last['digest'] = 'sha256:${'b' * 64}';
    serve(data);
    await expectLater(
      service.check(UpdateCancellation()),
      throwsA(failure(UpdateFailure.metadata)),
    );
  });
  test('malformed or mismatched manifest is rejected', () {
    for (final data in [
      manifest()..['channel'] = 'pre',
      manifest()..['version'] = '6.0.5',
      manifest()..['schema'] = 2,
    ]) {
      expect(
        () => service.parseManifest(data, '6.0.4'),
        throwsA(failure(UpdateFailure.metadata)),
      );
    }
    expect(
      () => service.parseManifest(manifest(), '../6.0.4'),
      throwsA(failure(UpdateFailure.metadata)),
    );
  });
  test(
    'Android requires the installed production package, certificate and a newer code',
    () {
      final android = HaozeUpdateService(
        transport: transport,
        platform: UpdatePlatform.android,
        identity: const UpdateIdentity(
          version: '6.0.3',
          versionCode: 64003,
          package: 'com.haoze.connect.mihomo',
          certificate: pin,
        ),
        directory: () async => directory,
      );
      final valid = manifest(platform: UpdatePlatform.android);
      expect(android.parseManifest(valid, '6.0.4').versionCode, 64004);
      for (final change in [
        {'package': 'other.app'},
        {'certificate_sha256': 'b' * 64},
        {'version_code': 64003},
      ]) {
        final data = manifest(platform: UpdatePlatform.android);
        (data['platforms'] as Map)['android'].addAll(change);
        expect(
          () => android.parseManifest(data, '6.0.4'),
          throwsA(failure(UpdateFailure.integrity)),
        );
      }
    },
  );
  test('only HTTPS GitHub distribution hosts are accepted', () {
    for (final url in [
      'http://github.com/file',
      'https://evil.test/file',
      'https://github.com.evil.test/file',
      'https://user@github.com/file',
      'https://github.com:444/file',
      'file:///tmp/update.apk',
    ]) {
      expect(updateUrlAllowed(Uri.parse(url)), false, reason: url);
    }
    expect(
      updateUrlAllowed(
        Uri.parse(
          'https://release-assets.githubusercontent.com/asset?token=signed',
        ),
      ),
      true,
    );
  });
  test(
    'application-wide certificate overrides cannot weaken updater TLS',
    () async {
      final overrides = HostOverride();
      final client = IoUpdateTransport(findProxy: (_) => 'PROXY 127.0.0.1:1');
      await HttpOverrides.runWithHttpOverrides(() async {
        await expectLater(
          client.open(Uri.https('api.github.com', '/'), UpdateCancellation()),
          throwsA(failure(UpdateFailure.network)),
        );
      }, overrides);
      expect(overrides.used, false);
    },
  );
  test('valid streaming download verifies then atomically finalizes', () async {
    final update = candidate();
    var checked = false;
    var progress = 0.0;
    transport.responses[update.uri.toString()] = () => UpdateResponse(
      200,
      {},
      Stream.fromIterable([payload.sublist(0, 4), payload.sublist(4)]),
    );
    final file = await service.download(
      update,
      UpdateCancellation(),
      progress: (v) => progress = v,
      verifying: () => checked = true,
    );
    expect(await file.readAsBytes(), payload);
    expect(progress, 1);
    expect(checked, true);
    expect(
      directory.listSync().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });
  test('checksum mismatch removes incomplete download', () async {
    final update = candidate();
    transport.responses[update.uri.toString()] = () =>
        UpdateResponse(200, {}, Stream.value(List.filled(payload.length, 0)));
    await expectLater(
      service.download(
        update,
        UpdateCancellation(),
        progress: (_) {},
        verifying: () {},
      ),
      throwsA(failure(UpdateFailure.integrity)),
    );
    expect(directory.listSync(), isEmpty);
  });
  test('oversized and truncated downloads are removed', () async {
    final update = candidate();
    for (final bytes in [
      payload.sublist(1),
      [...payload, 0],
    ]) {
      transport.responses[update.uri.toString()] = () =>
          UpdateResponse(200, {}, Stream.value(bytes));
      await expectLater(
        service.download(
          update,
          UpdateCancellation(),
          progress: (_) {},
          verifying: () {},
        ),
        throwsA(failure(UpdateFailure.integrity)),
      );
      expect(directory.listSync(), isEmpty);
    }
  });
  test('redirects may reach GitHub assets but cannot downgrade TLS', () async {
    final update = candidate();
    final cloud = Uri.parse(
      'https://release-assets.githubusercontent.com/asset?token=signed',
    );
    transport.responses[update.uri.toString()] = () => UpdateResponse(302, {
      'location': cloud.toString(),
    }, const Stream.empty());
    transport.responses[cloud.toString()] = () =>
        UpdateResponse(200, {}, Stream.value(payload));
    await service.download(
      update,
      UpdateCancellation(),
      progress: (_) {},
      verifying: () {},
    );
    transport.responses[update.uri.toString()] = () => const UpdateResponse(
      302,
      {'location': 'http://github.com/file'},
      Stream.empty(),
    );
    await expectLater(
      service.download(
        update,
        UpdateCancellation(),
        progress: (_) {},
        verifying: () {},
      ),
      throwsA(failure(UpdateFailure.metadata)),
    );
  });
  test('cancellation closes work and removes partial output', () async {
    final update = candidate();
    final token = UpdateCancellation();
    transport.responses[update.uri.toString()] = () => UpdateResponse(
      200,
      {},
      Stream.fromIterable([payload.sublist(0, 4), payload.sublist(4)]),
    );
    await expectLater(
      service.download(
        update,
        token,
        progress: (_) => token.cancel(),
        verifying: () {},
      ),
      throwsA(failure(UpdateFailure.cancelled)),
    );
    expect(directory.listSync(), isEmpty);
  });
}
