import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/common/managed_routing.dart';
import 'package:fl_clash/common/yaml_writer.dart';
import 'package:yaml/yaml.dart';
import 'routing_resources.dart';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haoze_xboard/account.dart';
import 'package:haoze_xboard/haoze_xboard.dart';

const haozePanelUrl = String.fromEnvironment(
  'XBOARD_BASE_URL',
  defaultValue: 'https://www.haoze.cyou',
);
const haozeCoreVersion = String.fromEnvironment(
  'XBOARD_CORE_VERSION',
  defaultValue: 'v1.19.33',
);

final haozeAccountProvider = NotifierProvider<HaozeAccount, XboardAccountState>(
  HaozeAccount.new,
);

class HaozeAccount extends Notifier<XboardAccountState> {
  late XboardAccountController controller;

  @override
  XboardAccountState build() {
    final origin = Uri.parse(haozePanelUrl);
    final downloads = StrictIoXboardTransport();
    controller = XboardAccountController(
      client: XboardClient(panelOrigin: origin),
      store: SecureAccountStore(),
      profiles: HaozeManagedProfile(ref, downloads),
      origin: origin,
      coreVersion: haozeCoreVersion,
      onChanged: (value) {
        if (ref.mounted) state = value;
      },
    );
    ref.onDispose(() {
      controller.close();
      downloads.close();
    });
    return const XboardAccountState();
  }
}

class SecureAccountStore implements XboardAccountStore {
  SecureAccountStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: false),
          );

  static const _key = 'haoze.xboard.account.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<XboardSavedAccount?> read() async {
    final value = await _storage.read(key: _key);
    if (value == null || value == 'revoked') return null;
    final data = jsonDecode(value) as Map<String, dynamic>;
    return XboardSavedAccount(
      origin: data['origin'] as String,
      email: data['email'] as String,
      session: XboardSession(
        authorization: data['authorization'] as String,
        subscriptionToken: data['subscriptionToken'] as String,
      ),
      profileId: data['profileId'] as int?,
      subscriptionHost: data['subscriptionHost'] as String?,
    );
  }

  @override
  Future<void> write(XboardSavedAccount account) => _storage.write(
    key: _key,
    value: jsonEncode({
      'origin': account.origin,
      'email': account.email,
      'authorization': account.session.authorization,
      'subscriptionToken': account.session.subscriptionToken,
      'profileId': account.profileId,
      'subscriptionHost': account.subscriptionHost,
    }),
  );

  @override
  Future<void> clear() async {
    try {
      await _storage.write(key: _key, value: 'revoked');
    } catch (_) {
      await _storage.delete(key: _key);
      return;
    }
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // The durable tombstone prevents restoring a credential after deletion fails.
    }
  }
}

class HaozeManagedProfile implements XboardManagedProfile {
  HaozeManagedProfile(this.ref, this.downloads);
  final Ref ref;
  final StrictIoXboardTransport downloads;
  final _changed = <int>{};

  @override
  Future<bool> exists(int id) async =>
      ref.read(profilesProvider).getProfile(id) != null &&
      await File(await appPath.getProfilePath('$id')).exists();

  @override
  Future<int> prepare(Uri uri, int? previousId) async {
    final previous = ref.read(profilesProvider).getProfile(previousId);
    final profile = (previous ?? Profile.normal(label: appName)).copyWith(
      type: ProfileType.file,
      url: '',
      autoUpdate: false,
    );
    final downloaded = await downloads.download(uri);
    final policy = await HaozeRoutingResources().ensure({
      Uri.parse(haozePanelUrl).host,
      uri.host,
    });
    final bytes = await compute(_protectSubscription, (
      bytes: downloaded,
      policy: policy,
    ));
    final path = await appPath.getProfilePath('${profile.id}');
    final file = File(path);
    final original = await file.exists() ? await file.readAsBytes() : null;
    if (original != null && listEquals(original, bytes)) {
      return profile.id;
    }
    final staged = File('$path.haoze-${snowflake.id}.tmp');
    try {
      await staged.writeAsBytes(bytes, flush: true);
      final message = await ref
          .read(coreHandlerProvider)
          .validateProfile(staged.path, '');
      if (message.isNotEmpty) {
        throw const XboardException(XboardFailure.protocol);
      }
      if (previous != null &&
          ref.read(profilesProvider).getProfile(profile.id) == null) {
        throw StateError('Managed profile was removed during synchronization');
      }
      await staged.rename(path);
      try {
        await ref
            .read(profilesProvider.notifier)
            .putManaged(
              (ref.read(profilesProvider).getProfile(profile.id) ?? profile)
                  .copyWith(
                    type: ProfileType.file,
                    url: '',
                    autoUpdate: false,
                    lastUpdateDate: DateTime.now(),
                  ),
            );
      } catch (_) {
        if (original != null) {
          await staged.writeAsBytes(original, flush: true);
          await staged.rename(path);
        } else if (await file.exists()) {
          await file.delete();
        }
        rethrow;
      }
      _changed.add(profile.id);
      return profile.id;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  @override
  Future<void> activate(int id) async {
    final changed = _changed.remove(id);
    if (ref.read(currentProfileIdProvider) != id) {
      ref.read(currentProfileIdProvider.notifier).value = id;
    } else if (changed) {
      ref
          .read(setupActionProvider.notifier)
          .applyProfileDebounce(silence: true);
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      if (system.isAndroid) {
        final revoked = ref
            .read(sharedStateProvider)
            .copyWith(accountReady: false, setupParams: null, vpnOptions: null);
        await preferences.saveShareState(revoked);
        final message = await service?.syncState(revoked);
        if (message != null && message.isNotEmpty) {
          throw StateError('Native account revocation failed');
        }
      }
    } finally {
      await ref.read(setupActionProvider.notifier).setRunning(false);
      ref.read(currentProfileIdProvider.notifier).value = null;
    }
  }

  @override
  Future<void> remove(int id) async {
    _changed.remove(id);
    await ref.read(profilesActionProvider.notifier).deleteProfile(id);
  }
}

Uint8List _protectSubscription(
  ({Uint8List bytes, ManagedRoutingPolicy policy}) data,
) {
  final config = jsonDecode(jsonEncode(loadYaml(utf8.decode(data.bytes))));
  if (config is! Map<String, dynamic> ||
      (!(config['proxies'] is List && (config['proxies'] as List).isNotEmpty) &&
          !(config['proxy-providers'] is Map &&
              (config['proxy-providers'] as Map).isNotEmpty))) {
    throw const FormatException('Subscription contains no proxies');
  }
  final protected = applyManagedRouting(config, data.policy);
  return Uint8List.fromList(utf8.encode(writeYaml(protected)));
}
