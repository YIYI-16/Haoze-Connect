import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Profile and connection operations used by the session controller.
///
/// Kept behind an interface so session tests do not need Drift, the native
/// core or Riverpod. The real implementation uses the existing profile
/// repository and validates a subscription before activating it.
abstract interface class XboardProfileBridge {
  /// Validates [subscribeUrl], activates it and returns the managed profile id.
  ///
  /// When [previousProfileId] differs from the newly resolved profile, the old
  /// managed profile is removed after the new one is active (URL rotation).
  Future<String> apply({required String subscribeUrl, String? previousProfileId});

  Future<void> remove(String? profileId);

  /// Stops the tunnel and disables connection restoration on next launch.
  Future<void> stopVpn();
}

/// A real profile bridge reloads the running tunnel after the session has
/// committed the new profile owner. Test/non-native bridges may omit this.
abstract interface class XboardProfileReloader {
  Future<void> reload(String profileId);
}

class RiverpodXboardProfileBridge implements XboardProfileBridge, XboardProfileReloader {
  RiverpodXboardProfileBridge(this._ref);

  final Ref _ref;

  @override
  Future<String> apply({required String subscribeUrl, String? previousProfileId}) async {
    final repo = await _ref.read(profileRepositoryProvider.future);
    final upsert = await repo.upsertRemote(subscribeUrl).run();
    final upsertFailure = upsert.fold((failure) => failure, (_) => null);
    if (upsertFailure != null) {
      throw const XboardException('订阅配置获取或校验失败，请确认套餐、流量和到期时间', kind: XboardFailureKind.subscription);
    }

    final entry = await _ref.read(profileDataSourceProvider).getByUrl(subscribeUrl);
    if (entry == null) {
      throw const XboardException('未能保存订阅配置，请稍后重试', kind: XboardFailureKind.subscription);
    }
    final newProfileId = entry.id;

    final activation = await repo.setAsActive(newProfileId).run();
    final activationFailure = activation.fold((failure) => failure, (_) => null);
    if (activationFailure != null) {
      throw const XboardException('订阅配置已保存但无法启用，请稍后重试', kind: XboardFailureKind.subscription);
    }

    if (previousProfileId != null && previousProfileId != newProfileId) {
      // The new profile is already active, so the previous one is inactive.
      // Best effort: an orphan is preferable to losing the working account.
      await repo.deleteById(previousProfileId, false).run();
    }

    return newProfileId;
  }

  @override
  Future<void> remove(String? profileId) async {
    if (profileId == null || profileId.isEmpty) return;
    final repo = await _ref.read(profileRepositoryProvider.future);
    final previous = await repo.getById(profileId).run();
    final profile = previous.fold(
      (_) => throw const XboardException('无法读取托管订阅，请重试清理', kind: XboardFailureKind.subscription),
      (value) => value,
    );
    // A previous cleanup may already have removed the database row before a
    // file/storage operation failed. Retrying account cleanup is idempotent.
    if (profile == null) return;
    final result = await repo.deleteById(profileId, profile.active).run();
    result.fold(
      (failure) => throw const XboardException('清理托管订阅失败，请稍后重试', kind: XboardFailureKind.subscription),
      (_) {},
    );
  }

  @override
  Future<void> reload(String profileId) async {
    final repo = await _ref.read(profileRepositoryProvider.future);
    final result = await repo.getById(profileId).run();
    final profile = result.fold((_) => null, (value) => value);
    if (profile == null) {
      throw const XboardException('未找到托管订阅，请刷新后重试', kind: XboardFailureKind.subscription);
    }
    try {
      await _ref.read(connectionNotifierProvider.future);
      await _ref.read(connectionNotifierProvider.notifier).reconnect(profile, throwOnFailure: true);
    } catch (_) {
      throw const XboardException('更新后的订阅无法应用到当前连接，请重试', kind: XboardFailureKind.subscription);
    }
  }

  @override
  Future<void> stopVpn() async {
    try {
      await _ref.read(connectionNotifierProvider.notifier).stopForAccount();
    } catch (_) {
      throw const XboardException('无法确认代理已停止，请重试退出登录', kind: XboardFailureKind.subscription);
    }
    await _ref.read(Preferences.startedByUser.notifier).update(false);
  }
}
