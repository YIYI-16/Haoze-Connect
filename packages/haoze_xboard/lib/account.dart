import 'dart:async';

import 'haoze_xboard.dart';

abstract interface class XboardAccountStore {
  Future<XboardSavedAccount?> read();
  Future<void> write(XboardSavedAccount account);
  Future<void> clear();
}

class XboardSavedAccount {
  const XboardSavedAccount({
    required this.origin,
    required this.email,
    required this.session,
    this.profileId,
    this.subscriptionHost,
  });

  final String origin;
  final String email;
  final XboardSession session;
  final int? profileId;
  final String? subscriptionHost;

  XboardSavedAccount withProfile(int? id, {String? subscriptionHost}) =>
      XboardSavedAccount(
        origin: origin,
        email: email,
        session: session,
        profileId: id,
        subscriptionHost: id == null
            ? null
            : subscriptionHost ?? this.subscriptionHost,
      );

  @override
  String toString() => 'XboardSavedAccount(<private>)';
}

abstract interface class XboardManagedProfile {
  Future<bool> exists(int id);
  Future<int> prepare(Uri uri, int? previousId);
  Future<void> activate(int id);
  Future<void> disconnect();
  Future<void> remove(int id);
}

enum XboardAccountIssue {
  network,
  credentials,
  expiredSession,
  storage,
  profile,
}

class XboardAccountState {
  const XboardAccountState({
    this.initialized = false,
    this.busy = false,
    this.email,
    this.subscription,
    this.profileReady = false,
    this.updatedAt,
    this.issue,
    this.config,
    this.configFailed = false,
  });

  final bool initialized;
  final bool busy;
  final String? email;
  final XboardSubscription? subscription;
  final bool profileReady;
  final DateTime? updatedAt;
  final XboardAccountIssue? issue;
  final Map<String, dynamic>? config;
  final bool configFailed;

  bool get authenticated => email != null;

  XboardAccountState copy({
    bool? initialized,
    bool? busy,
    Object? email = _keep,
    Object? subscription = _keep,
    bool? profileReady,
    Object? updatedAt = _keep,
    Object? issue = _keep,
    Map<String, dynamic>? config,
    bool? configFailed,
  }) => XboardAccountState(
    initialized: initialized ?? this.initialized,
    busy: busy ?? this.busy,
    email: identical(email, _keep) ? this.email : email as String?,
    subscription: identical(subscription, _keep)
        ? this.subscription
        : subscription as XboardSubscription?,
    profileReady: profileReady ?? this.profileReady,
    updatedAt: identical(updatedAt, _keep)
        ? this.updatedAt
        : updatedAt as DateTime?,
    issue: identical(issue, _keep) ? this.issue : issue as XboardAccountIssue?,
    config: config ?? this.config,
    configFailed: configFailed ?? this.configFailed,
  );
}

const _keep = Object();

class XboardAccountController {
  XboardAccountController({
    required this.client,
    required this.store,
    required this.profiles,
    required this.origin,
    required this.coreVersion,
    this.onChanged,
  });

  final XboardClient client;
  final XboardAccountStore store;
  final XboardManagedProfile profiles;
  final Uri origin;
  final String coreVersion;
  void Function(XboardAccountState)? onChanged;
  XboardAccountState _state = const XboardAccountState();
  XboardAccountState get state => _state;
  XboardSavedAccount? _account;
  Future<void> _tail = Future.value();
  Future<void>? _refreshing;
  bool _closed = false;
  bool _revoked = false;
  bool _profileRecoveryRequired = false;

  bool ownsProfile(int id) => !_revoked && _account?.profileId == id;

  Set<String> get directHosts => {origin.host, ?_account?.subscriptionHost};

  bool canResumeProfile(int? id) =>
      !_revoked &&
      _account != null &&
      id != null &&
      _account!.profileId == id &&
      state.profileReady;

  void _emit(XboardAccountState value) {
    _state = value;
    if (!_closed) onChanged?.call(value);
  }

  Future<void> _serial(Future<void> Function() action) {
    if (_closed) return Future.value();
    final next = _tail.then((_) async {
      if (_closed) return;
      _emit(state.copy(busy: true, issue: null));
      try {
        await action();
      } finally {
        _emit(state.copy(busy: false));
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> restore() => _serial(() async {
    try {
      final saved = await store.read();
      if (saved != null && saved.origin != origin.origin) {
        await profiles.disconnect();
        if (saved.profileId case final id?) await profiles.remove(id);
        await store.clear();
      } else if (saved != null) {
        final ready =
            saved.profileId != null && await profiles.exists(saved.profileId!);
        _account = saved;
        _emit(state.copy(email: saved.email, profileReady: ready));
      }
    } catch (_) {
      _emit(state.copy(issue: XboardAccountIssue.storage));
    } finally {
      _emit(state.copy(initialized: true));
    }
  });

  Future<void> loadConfig() => _serial(() async {
    try {
      _emit(
        state.copy(config: await client.publicConfig(), configFailed: false),
      );
    } catch (_) {
      _emit(state.copy(configFailed: true));
    }
  });

  Future<void> login(String email, String password) =>
      _authenticate(email, () => client.login(email, password));

  Future<void> register(
    String email,
    String password, {
    String? emailCode,
    String? inviteCode,
  }) => _authenticate(email, () async {
    final config = state.config;
    if (config == null || !_registrationAllowed(config)) {
      throw const XboardException(XboardFailure.configuration);
    }
    return client.register(
      email,
      password,
      emailCode: emailCode,
      inviteCode: inviteCode,
    );
  });

  Future<void> sendEmailCode(String email) => _serial(() async {
    final config = state.config;
    if (config == null || !_registrationAllowed(config)) {
      _emit(state.copy(issue: XboardAccountIssue.credentials));
      return;
    }
    try {
      await client.sendEmailCode(email);
    } catch (_) {
      _emit(state.copy(issue: XboardAccountIssue.network));
    }
  });

  Future<void> _authenticate(
    String email,
    Future<XboardSession> Function() authenticate,
  ) => _serial(() async {
    if (_account != null) return;
    XboardSession session;
    try {
      session = await authenticate();
    } on XboardException catch (error) {
      _emit(
        state.copy(
          issue:
              error.kind == XboardFailure.unauthorized ||
                  error.statusCode == 422 ||
                  error.kind == XboardFailure.configuration
              ? XboardAccountIssue.credentials
              : XboardAccountIssue.network,
        ),
      );
      return;
    }
    final account = XboardSavedAccount(
      origin: origin.origin,
      email: email.trim(),
      session: session,
    );
    try {
      await store.write(account);
    } catch (_) {
      _emit(state.copy(issue: XboardAccountIssue.storage));
      return;
    }
    _account = account;
    _emit(
      state.copy(
        email: account.email,
        subscription: null,
        updatedAt: null,
        profileReady: false,
      ),
    );
    await _refresh(syncProfile: true);
  });

  Future<void> refresh({bool syncProfile = false}) {
    if (_refreshing case final pending?) return pending;
    final future = _serial(() => _refresh(syncProfile: syncProfile));
    _refreshing = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_refreshing, future)) _refreshing = null;
        },
        onError: (Object _) {
          if (identical(_refreshing, future)) _refreshing = null;
        },
      ),
    );
    return future;
  }

  void holdProfileRecovery() {
    _profileRecoveryRequired = true;
    _emit(state.copy(profileReady: false, issue: XboardAccountIssue.profile));
  }

  Future<void> reconcileProfile() => _serial(() async {
    final id = _account?.profileId;
    if (!_revoked &&
        !_profileRecoveryRequired &&
        state.profileReady &&
        id != null) {
      await profiles.activate(id);
    }
  });

  Future<void> _refresh({required bool syncProfile}) async {
    if (_revoked) {
      _emit(state.copy(issue: XboardAccountIssue.storage, profileReady: false));
      return;
    }
    final account = _account;
    if (account == null) return;
    XboardSubscription subscription;
    Map<String, dynamic> user;
    try {
      user = await client.userInfo(account.session);
      subscription = await client.subscription(account.session);
    } on XboardException catch (error) {
      if (error.kind == XboardFailure.unauthorized) {
        await _logout(expired: true);
      } else {
        _emit(state.copy(issue: XboardAccountIssue.network));
      }
      return;
    }
    if (_revoked) return;
    _emit(state.copy(subscription: subscription, updatedAt: DateTime.now()));
    final expiry = subscription.expiresAt;
    final unavailable =
        enabled(user['banned']) ||
        subscription.total == 0 ||
        subscription.remaining == 0 ||
        (expiry != null &&
            expiry > 0 &&
            expiry <= DateTime.now().millisecondsSinceEpoch ~/ 1000);
    if (unavailable) {
      try {
        await _removeProfile();
      } catch (_) {
        _emit(
          state.copy(issue: XboardAccountIssue.profile, profileReady: false),
        );
      }
      return;
    }
    if (_profileRecoveryRequired && !syncProfile) {
      _emit(state.copy(issue: XboardAccountIssue.profile));
      return;
    }
    if (!syncProfile && state.profileReady) return;
    int? prepared;
    try {
      final uri = subscription.metaSubscriptionUri(coreVersion: coreVersion);
      if (uri == null) throw const XboardException(XboardFailure.protocol);
      prepared = await profiles.prepare(uri, account.profileId);
      final updated = account.withProfile(prepared, subscriptionHost: uri.host);
      await store.write(updated);
      _account = updated;
      if (_revoked) return;
      await profiles.activate(prepared);
      _profileRecoveryRequired = false;
      _emit(state.copy(profileReady: true));
    } catch (_) {
      if (prepared != null && prepared != _account?.profileId) {
        try {
          await profiles.remove(prepared);
        } catch (_) {
          /* Cleanup failure remains a profile error. */
        }
      }
      _emit(state.copy(issue: XboardAccountIssue.profile));
    }
  }

  Future<void> _removeProfile() async {
    final account = _account;
    await profiles.disconnect();
    _emit(state.copy(profileReady: false));
    if (account?.profileId case final id?) await profiles.remove(id);
    if (account != null) {
      final updated = account.withProfile(null);
      await store.write(updated);
      _account = updated;
    }
  }

  Future<void> logout() {
    _revoked = true;
    _emit(state.copy(profileReady: false));
    return _serial(() => _logout(expired: false));
  }

  Future<XboardAppVersion?> appVersion(String platform) async {
    final account = _account;
    if (account == null || _revoked) return null;
    try {
      final versions = await client.appVersions(account.session);
      return identical(account, _account) && !_revoked
          ? versions[platform]
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _logout({required bool expired}) async {
    _revoked = true;
    _emit(state.copy(profileReady: false));
    try {
      await _removeProfile();
      await store.clear();
    } catch (_) {
      _emit(state.copy(issue: XboardAccountIssue.storage));
      return;
    }
    _account = null;
    _revoked = false;
    _profileRecoveryRequired = false;
    _emit(
      state.copy(
        email: null,
        subscription: null,
        profileReady: false,
        updatedAt: null,
        issue: expired ? XboardAccountIssue.expiredSession : null,
      ),
    );
  }

  void close() {
    _closed = true;
    onChanged = null;
    client.close();
  }
}

bool enabled(Object? value) => value == true || value == 1 || value == '1';

bool _registrationAllowed(Map<String, dynamic> config) =>
    !enabled(config['stop_register']) &&
    !enabled(config['is_captcha']) &&
    !enabled(config['is_recaptcha']);
