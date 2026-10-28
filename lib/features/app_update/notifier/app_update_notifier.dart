import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/locale_preferences.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:upgrader/upgrader.dart';

part 'app_update_notifier.g.dart';

@riverpod
Upgrader upgrader(Ref ref) {
  // Without a validated HTTPS appcast (Constants.updateUrl) there is no update
  // channel at all. UpgraderStoreController fields have a default store
  // (PlayStore/AppStore) that is only overridden by passing an explicit
  // `null` callback, so "disabled platform" must pass null, not a () => null
  // factory. With a channel the feed is the maintainer's own https appcast —
  // GitHub repository URLs and upstream Hiddify endpoints are rejected in
  // Constants.updateUrl.
  final feed = Constants.updateUrl;
  final UpgraderStore Function()? appcastStore =
      feed == null ? null : () => UpgraderAppcastStore(appcastURL: feed.toString());
  final allowCustom = ref.read(appInfoProvider).requireValue.release.allowCustomUpdateChecker;
  return Upgrader(
    storeController: UpgraderStoreController(
      onAndroid: allowCustom ? appcastStore : null,
      oniOS: appcastStore,
      onLinux: appcastStore,
      onWindows: appcastStore,
      onMacOS: appcastStore,
      onWeb: appcastStore,
    ),
    // durationUntilAlertAgain: const Duration(hours: 12),
    messages: UpgraderMessages(
      code: ref.watch(localePreferencesProvider).languageCode,
    ),
  );
}

@Riverpod(keepAlive: true)
class AppUpdateNotifier extends _$AppUpdateNotifier with AppLogger {
  @override
  AppUpdateState build() => const AppUpdateState.initial();

  PreferencesEntry<String?, dynamic> get _ignoreReleasePref => PreferencesEntry(
    preferences: ref.read(sharedPreferencesProvider).requireValue,
    key: 'ignored_release_version',
    defaultValue: null,
  );

  Future<AppUpdateState> check() async {
    loggy.debug("checking for update");
    state = const AppUpdateState.checking();
    // Manual update channel is intentionally not supported (no GitHub
    // releases channel). Only the automatic https-appcast feed defined via
    // XBOARD_UPDATE_URL drives updates (see `upgrader` above); the manual
    // action simply reports updates as disabled — no network request, and
    // never against upstream Hiddify endpoints.
    loggy.debug(
      "manual update check disabled: updates are driven by the appcast feed only",
    );
    return state = const AppUpdateState.disabled();
  }

  Future<void> ignoreRelease(RemoteVersionEntity version) async {
    loggy.debug("ignoring release [${version.version}]");
    await _ignoreReleasePref.write(version.version);
    state = AppUpdateStateIgnored(version);
  }
}
