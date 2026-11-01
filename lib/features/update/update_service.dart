import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;

const updateRepository = 'YIYI-16/Haoze-Connect';
const updateManifestName = 'UPDATE-MANIFEST.json';
const _maxInstallerBytes = 512 * 1024 * 1024;
final _version = RegExp(r'^\d{1,6}\.\d{1,6}\.\d{1,6}$');
final _digest = RegExp(r'^[0-9a-f]{64}$');

enum UpdatePlatform { android, windows }

enum UpdateFailure {
  network,
  metadata,
  integrity,
  cancelled,
  permission,
  install,
}

class UpdateException implements Exception {
  const UpdateException(this.failure);
  final UpdateFailure failure;
}

class UpdateCancellation {
  bool cancelled = false;
  final _callbacks = <void Function()>[];
  void check() {
    if (cancelled) throw const UpdateException(UpdateFailure.cancelled);
  }

  void onCancel(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    for (final callback in _callbacks) {
      callback();
    }
    _callbacks.clear();
  }
}

class UpdateResponse {
  const UpdateResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Stream<List<int>> body;
}

abstract interface class UpdateTransport {
  Future<UpdateResponse> open(Uri uri, UpdateCancellation cancellation);
}

class _StrictUpdateHttpOverrides extends HttpOverrides {}

bool updateUrlAllowed(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  return uri.host == 'api.github.com' ||
      uri.host == 'github.com' ||
      uri.host == 'release-assets.githubusercontent.com' ||
      uri.host == 'objects.githubusercontent.com' ||
      uri.host == 'github-releases.githubusercontent.com';
}

class IoUpdateTransport implements UpdateTransport {
  IoUpdateTransport({this.findProxy});
  final String Function(Uri)? findProxy;

  @override
  Future<UpdateResponse> open(Uri uri, UpdateCancellation cancellation) async {
    if (!updateUrlAllowed(uri)) {
      throw const UpdateException(UpdateFailure.metadata);
    }
    final client =
        _StrictUpdateHttpOverrides().createHttpClient(
            SecurityContext(withTrustedRoots: true),
          )
          ..connectionTimeout = const Duration(seconds: 25)
          ..autoUncompress = false
          ..userAgent = 'Haoze-Connect-Updater';
    if (findProxy != null) client.findProxy = findProxy;
    cancellation.onCancel(() => client.close(force: true));
    try {
      cancellation.check();
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      if (uri.host == 'api.github.com') {
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final headers = <String, String>{};
      response.headers.forEach(
        (key, values) => headers[key.toLowerCase()] = values.join(','),
      );
      Stream<List<int>> body() async* {
        try {
          yield* response.timeout(const Duration(seconds: 30));
        } finally {
          client.close(force: true);
        }
      }

      return UpdateResponse(response.statusCode, headers, body());
    } catch (_) {
      client.close(force: true);
      cancellation.check();
      throw const UpdateException(UpdateFailure.network);
    }
  }
}

class UpdateIdentity {
  const UpdateIdentity({
    required this.version,
    required this.versionCode,
    this.package,
    this.certificate,
  });
  final String version;
  final int versionCode;
  final String? package;
  final String? certificate;
}

class UpdateRelease {
  const UpdateRelease._({
    required this.version,
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.uri,
    required this.platform,
    this.versionCode,
    this.package,
    this.certificate,
  });
  final String version;
  final String name;
  final int bytes;
  final String sha256;
  final Uri uri;
  final UpdatePlatform platform;
  final int? versionCode;
  final String? package;
  final String? certificate;
}

int compareUpdateVersions(String left, String right) {
  if (!_version.hasMatch(left) || !_version.hasMatch(right)) {
    throw const UpdateException(UpdateFailure.metadata);
  }
  final a = left.split('.').map(int.parse).toList();
  final b = right.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    final comparison = a[i].compareTo(b[i]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

Uri updateAssetUri(String version, String name) => Uri.https(
  'github.com',
  '/$updateRepository/releases/download/v$version/$name',
);

class HaozeUpdateService {
  HaozeUpdateService({
    required this.transport,
    required this.platform,
    required this.identity,
    required this.directory,
  });
  final UpdateTransport transport;
  final UpdatePlatform platform;
  final UpdateIdentity identity;
  final Future<Directory> Function() directory;

  Future<UpdateResponse> _open(Uri uri, UpdateCancellation cancellation) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      cancellation.check();
      if (!updateUrlAllowed(uri)) {
        throw const UpdateException(UpdateFailure.metadata);
      }
      final response = await transport.open(uri, cancellation);
      if (![301, 302, 303, 307, 308].contains(response.status)) return response;
      final location = response.headers['location'];
      await response.body.drain<void>();
      if (location == null) throw const UpdateException(UpdateFailure.metadata);
      uri = uri.resolve(location);
    }
    throw const UpdateException(UpdateFailure.metadata);
  }

  Future<Map<String, dynamic>> _json(
    Uri uri,
    UpdateCancellation cancellation, {
    int limit = 256 * 1024,
  }) async {
    final response = await _open(uri, cancellation);
    if (response.status != 200) {
      await response.body.drain<void>();
      throw const UpdateException(UpdateFailure.network);
    }
    final chunks = <int>[];
    await for (final chunk in response.body) {
      cancellation.check();
      if (chunks.length + chunk.length > limit) {
        throw const UpdateException(UpdateFailure.metadata);
      }
      chunks.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(chunks));
    if (value is! Map<String, dynamic>) {
      throw const UpdateException(UpdateFailure.metadata);
    }
    return value;
  }

  Future<UpdateRelease?> check(UpdateCancellation cancellation) async {
    try {
      final Map<String, dynamic> release;
      try {
        release = await _json(
          Uri.https(
            'api.github.com',
            '/repos/$updateRepository/releases/latest',
          ),
          cancellation,
          limit: 2 * 1024 * 1024,
        );
      } on UpdateException catch (error) {
        if (error.failure != UpdateFailure.network) rethrow;
        final response = await transport.open(
          Uri.https('github.com', '/$updateRepository/releases/latest'),
          cancellation,
        );
        await response.body.drain<void>();
        final uri = Uri.https(
          'github.com',
          '/',
        ).resolve(response.headers['location'] ?? '');
        final segments = uri.pathSegments;
        if (![301, 302, 303, 307, 308].contains(response.status) ||
            uri.host != 'github.com' ||
            !updateUrlAllowed(uri) ||
            uri.query.isNotEmpty ||
            segments.length != 5 ||
            segments.take(4).join('/') != '$updateRepository/releases/tag' ||
            !segments.last.startsWith('v') ||
            !_version.hasMatch(segments.last.substring(1))) {
          throw const UpdateException(UpdateFailure.metadata);
        }
        final version = segments.last.substring(1);
        if (compareUpdateVersions(version, identity.version) <= 0) return null;
        final manifest = await _json(
          updateAssetUri(version, updateManifestName),
          cancellation,
        );
        return parseManifest(manifest, version);
      }
      if (release['draft'] != false || release['prerelease'] != false) {
        throw const UpdateException(UpdateFailure.metadata);
      }
      final tag = release['tag_name'];
      if (tag is! String ||
          !tag.startsWith('v') ||
          !_version.hasMatch(tag.substring(1))) {
        throw const UpdateException(UpdateFailure.metadata);
      }
      final version = tag.substring(1);
      if (compareUpdateVersions(version, identity.version) <= 0) return null;
      final assets = release['assets'];
      if (assets is! List) throw const UpdateException(UpdateFailure.metadata);
      final manifests = assets
          .whereType<Map>()
          .where(
            (a) => a['name'] == updateManifestName && a['state'] == 'uploaded',
          )
          .toList();
      if (manifests.length != 1 ||
          manifests.single['browser_download_url'] !=
              updateAssetUri(version, updateManifestName).toString()) {
        throw const UpdateException(UpdateFailure.metadata);
      }
      final manifest = await _json(
        updateAssetUri(version, updateManifestName),
        cancellation,
      );
      final candidate = parseManifest(manifest, version);
      final files = assets
          .whereType<Map>()
          .where((a) => a['name'] == candidate.name && a['state'] == 'uploaded')
          .toList();
      if (files.length != 1 ||
          files.single['browser_download_url'] != candidate.uri.toString() ||
          files.single['size'] != candidate.bytes ||
          files.single['digest'] != 'sha256:${candidate.sha256}') {
        throw const UpdateException(UpdateFailure.metadata);
      }
      return candidate;
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      cancellation.check();
      throw const UpdateException(UpdateFailure.network);
    } on SocketException {
      cancellation.check();
      throw const UpdateException(UpdateFailure.network);
    } on HttpException {
      cancellation.check();
      throw const UpdateException(UpdateFailure.network);
    } catch (_) {
      cancellation.check();
      throw const UpdateException(UpdateFailure.metadata);
    }
  }

  UpdateRelease parseManifest(Map<String, dynamic> manifest, String version) {
    if (!_version.hasMatch(version) ||
        manifest['schema'] != 1 ||
        manifest['version'] != version ||
        manifest['channel'] != 'stable') {
      throw const UpdateException(UpdateFailure.metadata);
    }
    final platforms = manifest['platforms'];
    if (platforms is! Map || platforms[platform.name] is! Map) {
      throw const UpdateException(UpdateFailure.metadata);
    }
    final asset = platforms[platform.name] as Map;
    final name = platform == UpdatePlatform.android
        ? 'HaozeConnect-Android-arm64-$version.apk'
        : 'HaozeConnect-Windows-Setup-x64-$version.exe';
    final bytes = asset['bytes'];
    final digest = asset['sha256'];
    if (asset['name'] != name ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > _maxInstallerBytes ||
        digest is! String ||
        !_digest.hasMatch(digest)) {
      throw const UpdateException(UpdateFailure.metadata);
    }
    if (platform == UpdatePlatform.android &&
        (asset['package'] != 'com.haoze.connect.mihomo' ||
            asset['package'] != identity.package ||
            asset['certificate_sha256'] != identity.certificate ||
            asset['version_code'] is! int ||
            (asset['version_code'] as int) <= identity.versionCode)) {
      throw const UpdateException(UpdateFailure.integrity);
    }
    return UpdateRelease._(
      version: version,
      name: name,
      bytes: bytes,
      sha256: digest,
      uri: updateAssetUri(version, name),
      platform: platform,
      versionCode: platform == UpdatePlatform.android
          ? asset['version_code'] as int
          : null,
      package: platform == UpdatePlatform.android
          ? asset['package'] as String
          : null,
      certificate: platform == UpdatePlatform.android
          ? asset['certificate_sha256'] as String
          : null,
    );
  }

  Future<File> download(
    UpdateRelease release,
    UpdateCancellation cancellation, {
    required void Function(double) progress,
    required void Function() verifying,
  }) async {
    final folder = await directory();
    await folder.create(recursive: true);
    final name =
        'update-${release.version}-${release.sha256.substring(0, 12)}.${release.platform == UpdatePlatform.android ? 'apk' : 'exe'}';
    final target = File(paths.join(folder.path, name));
    final partial = File(
      '${target.path}.${Random.secure().nextInt(1 << 32)}.part',
    );
    IOSink? sink;
    try {
      if (await partial.exists()) await partial.delete();
      final response = await _open(release.uri, cancellation);
      if (response.status != 200) {
        await response.body.drain<void>();
        throw const UpdateException(UpdateFailure.network);
      }
      sink = partial.openWrite();
      var bytes = 0;
      await for (final chunk in response.body) {
        cancellation.check();
        bytes += chunk.length;
        if (bytes > release.bytes) {
          throw const UpdateException(UpdateFailure.integrity);
        }
        sink.add(chunk);
        progress(bytes / release.bytes);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      cancellation.check();
      if (bytes != release.bytes) {
        throw const UpdateException(UpdateFailure.integrity);
      }
      verifying();
      await verifyUpdateFile(partial, release);
      cancellation.check();
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } catch (_) {
      if (sink != null) await sink.close();
      if (await partial.exists()) await partial.delete();
      cancellation.check();
      rethrow;
    }
  }
}

Future<void> verifyUpdateFile(File file, UpdateRelease release) async {
  final path = file.path;
  final size = release.bytes;
  final expected = release.sha256;
  final valid = await Isolate.run(() async {
    final input = File(path);
    if (!await input.exists() || await input.length() != size) return false;
    final hash = await sha256.bind(input.openRead()).first;
    return hash.toString() == expected;
  });
  if (!valid) throw const UpdateException(UpdateFailure.integrity);
}
