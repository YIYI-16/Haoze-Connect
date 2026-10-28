import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hiddify/features/xboard/config/xboard_config.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart';
import 'package:hiddify/features/xboard/data/xboard_data_providers.dart';
import 'package:hiddify/features/xboard/data/xboard_profile_bridge.dart';
import 'package:hiddify/features/xboard/data/xboard_session_store.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _unset = Object();

@immutable
class XboardSessionState {
  const XboardSessionState({
    this.initialized = false,
    this.isAuthenticated = false,
    this.busy = false,
    this.subscriptionReady = false,
    this.email,
    this.error,
    this.subscription,
    this.publicConfig,
    this.lastUpdated,
  });

  final bool initialized;
  final bool isAuthenticated;
  final bool busy;
  final bool subscriptionReady;
  final String? email;
  final String? error;
  final XboardSubscription? subscription;
  final XboardPublicConfig? publicConfig;
  final DateTime? lastUpdated;

  XboardSessionState copyWith({
    bool? initialized,
    bool? isAuthenticated,
    bool? busy,
    bool? subscriptionReady,
    Object? email = _unset,
    Object? error = _unset,
    Object? subscription = _unset,
    Object? publicConfig = _unset,
    Object? lastUpdated = _unset,
  }) {
    return XboardSessionState(
      initialized: initialized ?? this.initialized,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      busy: busy ?? this.busy,
      subscriptionReady: subscriptionReady ?? this.subscriptionReady,
      email: identical(email, _unset) ? this.email : email as String?,
      error: identical(error, _unset) ? this.error : error as String?,
      subscription: identical(subscription, _unset) ? this.subscription : subscription as XboardSubscription?,
      publicConfig: identical(publicConfig, _unset) ? this.publicConfig : publicConfig as XboardPublicConfig?,
      lastUpdated: identical(lastUpdated, _unset) ? this.lastUpdated : lastUpdated as DateTime?,
    );
  }
}

class XboardSessionController extends StateNotifier<XboardSessionState> {
  XboardSessionController({
    required XboardApi api,
    required XboardSessionStore store,
    required XboardProfileBridge profiles,
    required this.config,
  }) : _api = api,
       _store = store,
       _profiles = profiles,
       super(const XboardSessionState());

  final XboardApi _api;
  final XboardSessionStore _store;
  final XboardProfileBridge _profiles;
  final XboardClientConfig config;

  XboardStoredSession? _session;
  int _generation = 0;
  Future<void>? _initializeFlight;
  Future<void>? _restoreFlight;
  bool _sessionRestored = false;
  String? _storageError;
  Future<void>? _refreshFlight;
  Future<void> _profileChain = Future.value();

  /// The managed profile associated with the persisted account, if any.
  String? get managedProfileId => _session?.profileId;

  /// Restores the secure session, public registration switches and subscription.
  ///
  /// Triggered once by [xboardSessionProvider]; widgets must only watch state.
  Future<void> initialize() => _initializeFlight ??= _initializeInternal();

  /// Reads and origin-checks the persisted session without contacting the
  /// panel. Bootstrap awaits this before restoring a tunnel so a stale or
  /// foreign-panel session can never start the old profile.
  Future<void> ensureSessionRestored() {
    if (_sessionRestored) return Future.value();
    return _restoreFlight ??= _restoreStoredSession();
  }

  Future<void> _restoreStoredSession() async {
    final generation = _generation;
    XboardStoredSession? stored;
    try {
      stored = await _store.read();
    } catch (_) {
      _storageError = '无法读取安全存储，请重新登录';
    }
    if (!_isCurrent(generation)) {
      _sessionRestored = true;
      return;
    }

    if (stored != null && stored.origin != config.origin) {
      stored = null;
      await _revokeStoredSession();
    } else if (stored != null) {
      _session = stored;
      state = state.copyWith(isAuthenticated: true, email: stored.email);
    }
    _sessionRestored = true;
  }

  Future<void> _initializeInternal() async {
    final generation = _generation;
    state = state.copyWith(busy: true, error: null);
    await ensureSessionRestored();
    if (!_isCurrent(generation)) return;
    final stored = _session;

    await _loadPublicConfigQuietly();
    if (!_isCurrent(generation)) return;

    if (stored != null) {
      try {
        await _syncSubscription(generation: generation);
      } on XboardException catch (error) {
        if (!_isCurrent(generation)) return;
        if (error.isUnauthorized) {
          await _invalidateSession();
        } else {
          state = state.copyWith(busy: false, error: error.message);
        }
      } catch (_) {
        if (_isCurrent(generation)) {
          state = state.copyWith(busy: false, error: '无法同步账户状态，请检查网络后重试');
        }
      }
    }

    if (!_isCurrent(generation)) return;
    state = state.copyWith(initialized: true, busy: false, error: state.error ?? _storageError);
  }

  Future<void> loadPublicConfig() async {
    final generation = _generation;
    state = state.copyWith(busy: true, error: null);
    try {
      final config = await _api.fetchPublicConfig();
      if (!_isCurrent(generation)) return;
      state = state.copyWith(busy: false, publicConfig: config);
    } on XboardException catch (error) {
      if (_isCurrent(generation)) state = state.copyWith(busy: false, error: error.message);
      rethrow;
    }
  }

  Future<void> _loadPublicConfigQuietly() async {
    try {
      final config = await _api.fetchPublicConfig();
      if (_isCurrent(_generation)) state = state.copyWith(publicConfig: config);
    } catch (_) {
      // Public switches are an enhancement. Login/refresh still work when this
      // endpoint is temporarily unavailable; the backend enforces its rules.
    }
  }

  Future<void> login(String email, String password) async {
    await _authenticate(
      () => _api.login(email: email.trim(), password: password),
      email: email.trim(),
    );
  }

  Future<void> register({
    required String email,
    required String password,
    String? emailCode,
    String? inviteCode,
  }) async {
    final trimmedEmail = email.trim();
    _validateEmail(trimmedEmail);
    if (password.length < 8) {
      throw const XboardException('密码至少需要 8 位', kind: XboardFailureKind.protocol);
    }

    final publicConfig = await _configForRegistration();
    if (publicConfig != null) {
      if (publicConfig.captchaEnabled) {
        throw const XboardException('该面板已开启人机验证，请前往面板网页完成注册后再登录', kind: XboardFailureKind.protocol);
      }
      if (publicConfig.emailVerify && (emailCode == null || emailCode.trim().isEmpty)) {
        throw const XboardException('该面板要求邮箱验证码，请先获取验证码', kind: XboardFailureKind.protocol);
      }
      if (publicConfig.inviteForce && (inviteCode == null || inviteCode.trim().isEmpty)) {
        throw const XboardException('该面板要求邀请码，请填写邀请码', kind: XboardFailureKind.protocol);
      }
    }

    await _authenticate(
      () => _api.register(email: trimmedEmail, password: password, emailCode: emailCode, inviteCode: inviteCode),
      email: trimmedEmail,
    );
  }

  Future<XboardPublicConfig?> _configForRegistration() async {
    final cached = state.publicConfig;
    if (cached != null) return cached;
    try {
      final config = await _api.fetchPublicConfig();
      state = state.copyWith(publicConfig: config);
      return config;
    } catch (_) {
      // Let the backend enforce its own registration rules if the public
      // config cannot be loaded.
      return null;
    }
  }

  Future<void> _authenticate(Future<XboardAuthResult> Function() request, {required String email}) async {
    if (state.busy) {
      throw const XboardException('正在处理另一个请求，请稍候', kind: XboardFailureKind.protocol);
    }
    final generation = ++_generation;
    final previous = _session;
    state = state.copyWith(busy: true, error: null);

    try {
      final auth = await request();
      if (!_isCurrent(generation)) return;

      final accountChanged = previous != null && previous.email.toLowerCase() != email.toLowerCase();
      if (accountChanged) {
        // Never publish a new account while the previous account's profile can
        // still reconnect. Cleanup must succeed before the new session exists.
        try {
          await _runProfile(() async {
            await _profiles.stopVpn();
            await _profiles.remove(previous.profileId);
          });
        } catch (_) {
          throw const XboardException('切换账号失败：无法清理原账号的订阅配置，请重试', kind: XboardFailureKind.subscription);
        }
        if (!_isCurrent(generation)) return;
      }

      final newSession = XboardStoredSession(
        origin: config.origin,
        authData: auth.authData,
        email: auth.email ?? email,
        profileId: accountChanged ? null : previous?.profileId,
      );
      try {
        await _store.write(newSession);
      } catch (_) {
        throw const XboardException('无法安全保存登录状态，请检查系统安全存储后重试');
      }
      if (!_isCurrent(generation)) return;
      _session = newSession;
      // Publish the new account without any usage from the previous one. If the
      // first sync fails on the network, the UI must not keep showing the old
      // plan, traffic or a "ready" connection state.
      state = state.copyWith(
        isAuthenticated: true,
        email: newSession.email,
        error: null,
        subscription: null,
        subscriptionReady: false,
        lastUpdated: null,
      );

      try {
        await _syncSubscription(generation: generation, previousProfileId: previous?.profileId);
      } on XboardException catch (error) {
        if (!_isCurrent(generation)) return;
        if (error.isUnauthorized) {
          await _invalidateSession();
          throw const XboardException('登录状态已失效，请重新登录', kind: XboardFailureKind.unauthorized);
        }
        // Login itself succeeded. Keep the session and surface sync trouble.
        state = state.copyWith(busy: false, error: error.message);
      } catch (_) {
        if (_isCurrent(generation)) {
          state = state.copyWith(busy: false, error: '登录成功，但订阅同步失败，请稍后刷新');
        }
      }

      if (_isCurrent(generation)) state = state.copyWith(busy: false);
    } on XboardException catch (error) {
      if (_isCurrent(generation)) {
        state = state.copyWith(busy: false, error: error.message);
      }
      rethrow;
    } catch (_) {
      if (_isCurrent(generation)) {
        state = state.copyWith(busy: false, error: '登录失败，请稍后重试');
      }
      throw const XboardException('登录失败，请稍后重试');
    }
  }

  Future<void> sendEmailCode(String email) async {
    final trimmed = email.trim();
    _validateEmail(trimmed);
    final config = await _configForRegistration();
    if (config?.captchaEnabled == true) {
      throw const XboardException('该面板已开启人机验证，请前往面板网页获取验证码或完成注册', kind: XboardFailureKind.protocol);
    }
    try {
      await _api.sendEmailCode(trimmed);
    } on XboardException catch (error) {
      state = state.copyWith(error: error.message);
      rethrow;
    }
  }

  /// Fetches the latest traffic and rotates the managed profile when needed.
  ///
  /// Concurrent calls share one request. A network failure preserves the
  /// session; only an authenticated 403 clears it.
  Future<void> refresh() {
    if (!state.isAuthenticated || _session == null) return Future.value();
    final inFlight = _refreshFlight;
    if (inFlight != null) return inFlight;

    late final Future<void> tracked;
    tracked = _refreshInternal().whenComplete(() {
      if (identical(_refreshFlight, tracked)) _refreshFlight = null;
    });
    _refreshFlight = tracked;
    return tracked;
  }

  Future<void> _refreshInternal() async {
    final generation = _generation;
    final session = _session;
    if (session == null) return;
    state = state.copyWith(busy: true, error: null);
    try {
      await _syncSubscription(generation: generation);
      if (_isCurrent(generation)) state = state.copyWith(busy: false);
    } on XboardException catch (error) {
      if (!_isCurrent(generation)) return;
      if (error.isUnauthorized) {
        await _invalidateSession();
      } else {
        state = state.copyWith(busy: false, error: error.message);
      }
      rethrow;
    } catch (_) {
      if (_isCurrent(generation)) {
        state = state.copyWith(busy: false, error: '同步账户失败，请稍后重试');
      }
      throw const XboardException('同步账户失败，请稍后重试');
    }
  }

  Future<void> _syncSubscription({required int generation, String? previousProfileId}) async {
    final session = _session;
    if (session == null) return;
    final payload = await _api.fetchSubscription(session.authData);
    if (!_isCurrent(generation)) return;

    final subscription = payload.subscription;
    final subscribeUrl = payload.subscribeUrl;
    final canConnect =
        subscription.hasPlan &&
        subscription.hasTraffic &&
        !subscription.isExpired &&
        subscribeUrl != null &&
        subscribeUrl.isNotEmpty;
    String? warning;
    var ready = false;

    if (canConnect) {
      try {
        final profileId = await _runProfile(
          () =>
              _profiles.apply(subscribeUrl: subscribeUrl, previousProfileId: previousProfileId ?? _session?.profileId),
        );
        if (!_isCurrent(generation)) {
          // Logout/login changed the owner while the native apply was running.
          // Remove this stale result unless it is still the profile of the
          // current session (a same-URL re-login may legitimately reuse it).
          if (profileId != _session?.profileId) {
            await _runProfile(() => _profiles.remove(profileId));
          }
          return;
        }
        await _persistProfileId(profileId);
        if (!_isCurrent(generation)) return;
        // Ownership and the current panel response must be visible before a
        // native reload is allowed. A failed reload clears readiness below.
        state = state.copyWith(initialized: true, subscription: subscription, subscriptionReady: true);
        if (_profiles case final XboardProfileReloader reloader) {
          await _runProfile(() => reloader.reload(profileId));
        }
        ready = true;
      } on XboardProfileReloadException catch (error) {
        if (error.diagnostic == XboardProfileReloadFailure.cancelled) {
          // The profile has been validated and committed. An intentional stop
          // cancels applying it to the tunnel, not the account's eligibility.
          ready = true;
        } else {
          warning = error.message;
        }
      } on XboardException catch (error) {
        warning = error.message;
      } catch (_) {
        warning = '订阅配置同步失败，请稍后重试';
      }
    } else {
      // Expired, exhausted, missing plan/URL: do not download a profile that
      // would keep a stale subscription connectable.
      if (subscription.hasPlan && (subscription.isExpired || !subscription.hasTraffic)) {
        warning = subscription.isExpired ? '套餐已过期，请续费后刷新' : '流量已用尽，请购买流量或等待重置';
      } else if (subscription.hasPlan && (subscribeUrl == null || subscribeUrl.isEmpty)) {
        warning = '面板未返回订阅地址，请稍后刷新';
      }

      final oldProfileId = _session?.profileId;
      if (oldProfileId != null) {
        try {
          await _runProfile(() async {
            await _profiles.stopVpn();
            await _profiles.remove(oldProfileId);
          });
          if (!_isCurrent(generation)) return;
          await _persistProfileId(null);
        } catch (error) {
          warning = error is XboardException ? error.message : '清理旧订阅失败，请稍后重试';
        }
      }
    }

    if (!_isCurrent(generation)) return;
    state = state.copyWith(
      subscription: subscription,
      email: payload.email ?? state.email,
      lastUpdated: DateTime.now(),
      subscriptionReady: ready,
      busy: false,
      error: warning,
    );
  }

  /// Serializes all profile/core mutations. A logout waits behind an in-flight
  /// apply, and a stale apply can remove its own result before logout cleans up.
  Future<T> _runProfile<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _profileChain = _profileChain.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _persistProfileId(String? profileId) async {
    final session = _session;
    if (session == null) return;
    final updated = profileId == null ? session.copyWith(clearProfileId: true) : session.copyWith(profileId: profileId);
    _session = updated;
    try {
      await _store.write(updated);
    } catch (_) {
      throw const XboardException('无法保存托管订阅标识，请检查安全存储', kind: XboardFailureKind.subscription);
    }
  }

  /// Called on app resume. Failures stay in [XboardSessionState.error].
  Future<void> syncOnResume() async {
    if (!state.initialized || !state.isAuthenticated) return;
    try {
      await refresh();
    } catch (_) {
      // Already reflected in state.error.
    }
  }

  Future<void> logout() async {
    final generation = ++_generation;
    final session = _session;
    state = state.copyWith(busy: true, subscriptionReady: false, error: null);

    try {
      await _runProfile(() async {
        await _profiles.stopVpn();
        await _profiles.remove(session?.profileId);
      });
    } catch (_) {
      if (!_isCurrent(generation)) return;
      const error = XboardException('退出登录失败：无法停止代理或清理订阅，请重试', kind: XboardFailureKind.subscription);
      state = state.copyWith(busy: false, error: error.message);
      throw error;
    }

    final revoked = await _revokeStoredSession();
    if (!_isCurrent(generation)) return;
    if (!revoked) {
      // Do not pretend to be logged out while the token can still be restored
      // on the next launch. Keep the session in memory so logout is retryable,
      // and throw so the account page stays put and shows the error instead of
      // navigating to /login (where the router would send the user back home).
      const error = XboardException('无法清除本地登录状态，请重试退出登录');
      state = state.copyWith(busy: false, error: error.message);
      throw error;
    }
    _session = null;
    state = state.copyWith(
      isAuthenticated: false,
      busy: false,
      subscriptionReady: false,
      email: null,
      subscription: null,
      lastUpdated: null,
      error: null,
    );
  }

  Future<void> _invalidateSession() async {
    final generation = ++_generation;
    final session = _session;

    state = state.copyWith(subscriptionReady: false, busy: true);
    try {
      await _runProfile(() async {
        await _profiles.stopVpn();
        await _profiles.remove(session?.profileId);
      });
    } catch (_) {
      if (_isCurrent(generation)) {
        // Keep the account page and its retry action available until native
        // cleanup succeeds. The rejected token can never start another tunnel.
        state = state.copyWith(
          initialized: true,
          busy: false,
          subscriptionReady: false,
          error: '登录状态已失效，但无法确认代理已停止或清理订阅；请重试退出登录',
        );
      }
      return;
    }
    final revoked = await _revokeStoredSession();
    _session = null;
    if (_isCurrent(generation)) {
      state = state.copyWith(
        // An invalid token finishes initialization even though the generation
        // changed: the router must leave its loading gate and show /login.
        initialized: true,
        isAuthenticated: false,
        busy: false,
        subscriptionReady: false,
        email: null,
        subscription: null,
        lastUpdated: null,
        error: revoked ? '登录状态已失效，请重新登录' : '登录状态已失效，且本地安全存储清理失败；请重启后重新登录',
      );
    }
  }

  /// Deletes the secure entry, falling back to a tombstone when deletion fails.
  /// A false result means the token could still be restored on next launch.
  Future<bool> _revokeStoredSession() async {
    try {
      await _store.clear();
      return true;
    } catch (_) {
      try {
        await _store.write(XboardStoredSession.revoked(origin: config.origin));
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  bool _isCurrent(int generation) => generation == _generation && mounted;

  void _validateEmail(String email) {
    final value = email.trim();
    if (value.isEmpty || !value.contains('@') || value.startsWith('@') || value.endsWith('@')) {
      throw const XboardException('请输入有效的邮箱地址', kind: XboardFailureKind.protocol);
    }
  }
}

/// Whether the account behind the session may start a tunnel.
///
/// A managed account owns the only profile in the app, so a start is only
/// allowed when the panel says there is a usable plan: a session that is not
/// initialized, not signed in, without a synchronized plan or without traffic
/// left must not connect through a leftover profile. Stopping is always
/// allowed, so a user can always get out of a running tunnel.
bool xboardAllowsConnection(XboardSessionState session) {
  if (!session.initialized) return false;
  if (!session.isAuthenticated) return false;
  if (!session.subscriptionReady) return false;
  return session.subscription?.canConnect ?? false;
}

/// Published for the router and account UI.
///
/// The provider starts initialization exactly once. Widgets must not call
/// [XboardSessionController.initialize] from build.
final xboardSessionProvider = StateNotifierProvider<XboardSessionController, XboardSessionState>((ref) {
  final controller = XboardSessionController(
    api: ref.watch(xboardApiProvider),
    store: ref.watch(xboardSessionStoreProvider),
    profiles: ref.watch(xboardProfileBridgeProvider),
    config: ref.watch(xboardClientConfigProvider),
  );
  unawaited(controller.initialize());
  return controller;
});

/// The single answer to "may the tunnel start right now?".
///
/// The connection notifier reads this instead of trusting the profile
/// database: a profile that survived a failed cleanup must not become a way
/// around the panel.
final xboardConnectionAllowedProvider = Provider<bool>((ref) {
  return xboardAllowsConnection(ref.watch(xboardSessionProvider));
});

/// The account's profile owner, observed separately from the start permission.
final xboardManagedProfileIdProvider = Provider<String?>((ref) {
  ref.watch(xboardSessionProvider);
  return ref.read(xboardSessionProvider.notifier).managedProfileId;
});
