import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/custom_issue.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/widgets/card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haoze_xboard/account.dart';
import 'package:haoze_xboard/browser_auth.dart';
import 'package:haoze_xboard/haoze_xboard.dart';
import 'package:haoze_xboard/native_auth.dart';
import 'native_google.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account.dart';

String? _issue(BuildContext context, XboardAccountIssue? issue) {
  final l10n = context.appLocalizations;
  return switch (issue) {
    null => null,
    XboardAccountIssue.network => l10n.haozePanelUnavailable,
    XboardAccountIssue.credentials => l10n.haozeCredentialsError,
    XboardAccountIssue.expiredSession => l10n.haozeSessionExpired,
    XboardAccountIssue.storage => l10n.haozeStorageError,
    XboardAccountIssue.profile => l10n.haozeProfileError,
  };
}

Future<void> _openWebsite(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class HaozeAccountGate extends ConsumerWidget {
  const HaozeAccountGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(haozeAccountProvider);
    if (!account.initialized) {
      return const Material(
        child: Center(child: CommonCircleLoading(size: 24)),
      );
    }
    return account.authenticated ? child : const _AuthenticationPage();
  }
}

class _AuthenticationPage extends ConsumerStatefulWidget {
  const _AuthenticationPage();

  @override
  ConsumerState<_AuthenticationPage> createState() =>
      _AuthenticationPageState();
}

class _AuthenticationPageState extends ConsumerState<_AuthenticationPage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _confirm = TextEditingController();
  late final XboardNativeLogin _native;
  late final NativeGoogleSignIn _google;
  NativeAuthResult? _result;
  XboardAccountIssue? _error;
  bool _googleNonceError = false;
  bool _submitting = false;
  bool _started = false;
  bool _emailMode = false;
  bool _codeSent = false;
  bool _googleWaiting = false;

  @override
  void initState() {
    super.initState();
    _native = ref.read(haozeNativeLoginProvider);
    _google = ref.read(haozeNativeGoogleProvider);
  }

  @override
  void dispose() {
    _native.reset();
    unawaited(_google.close());
    _account.dispose();
    _password.dispose();
    _code.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _ensureSession() async {
    if (_started && _native.active) return;
    final redirect = await _google.prepare();
    await _native.start(
      _google.isAndroid ? 'android' : 'windows',
      redirect: redirect,
    );
    _started = true;
  }

  Future<void> _run(Future<NativeAuthResult?> Function() action) async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
      _googleNonceError = false;
    });
    try {
      await _ensureSession();
      if (!mounted) return;
      final result = await action();
      if (!mounted) return;
      if (result?.account case final account?) {
        _password.clear();
        _code.clear();
        _confirm.clear();
        _started = false;
        await ref
            .read(haozeAccountProvider.notifier)
            .controller
            .loginWithCredential(() async => account);
      } else if (result != null) {
        setState(() {
          _result = result;
          _password.clear();
          _confirm.clear();
          _code.clear();
        });
      }
    } on NativeGoogleNonceException {
      if (mounted) setState(() => _googleNonceError = true);
    } on XboardLoginCancelled {
      _started = false;
      _native.reset();
    } on XboardException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.kind == XboardFailure.unauthorized
              ? XboardAccountIssue.credentials
              : XboardAccountIssue.network,
        );
      }
      if (error.statusCode == 401 && _result == null) {
        _native.reset();
        _started = false;
        _codeSent = false;
      }
    } catch (_) {
      if (mounted) setState(() => _error = XboardAccountIssue.network);
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
          _googleWaiting = false;
        });
      }
    }
  }

  Future<void> _submit() => _run(() async {
    final step = _result?.step;
    if (step == 'password-change' &&
        (_password.text.isEmpty || _password.text != _confirm.text)) {
      throw const XboardException(XboardFailure.unauthorized);
    }
    return _native.authenticate(
      switch (step) {
        'mfa' => 'mfa',
        'password-change' => 'password-change',
        _ => _emailMode && step != 'link' ? 'email/verify' : 'password',
      },
      {
        'account': _account.text.trim(),
        'password': _password.text,
        'code': _code.text.trim(),
      },
    );
  });

  Future<void> _sendCode() => _run(() async {
    await _native.sendEmailCode(_account.text.trim());
    if (mounted) setState(() => _codeSent = true);
    return null;
  });

  Future<void> _googleLogin() => _run(() async {
    if (mounted) setState(() => _googleWaiting = true);
    try {
      final result = await _google.signIn(
        _native,
        returnMessage: context.appLocalizations.haozeGoogleReturn,
        returnButtonLabel: context.appLocalizations.haozeGoogleReturnToApp,
      );
      if (mounted && _google.isWindows) {
        try {
          await windowPort?.show();
        } on Exception {
          // Foreground failure must not discard a verified login.
        }
      }
      return result;
    } catch (_) {
      _native.reset();
      _started = false;
      rethrow;
    }
  });

  void _reset() {
    _native.reset();
    unawaited(_google.close());
    setState(() {
      _started = false;
      _result = null;
      _error = null;
      _googleNonceError = false;
      _codeSent = false;
      _password.clear();
      _confirm.clear();
      _code.clear();
    });
  }

  void _cancelGoogle() {
    _native.reset();
    _started = false;
    _google.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(haozeAccountProvider);
    final initialized = ref.watch(initProvider);
    final l10n = context.appLocalizations;
    final busy = _submitting || state.busy || !initialized;
    final step = _result?.step;
    return CommonScaffold(
      title: appName,
      body: Builder(
        builder: (context) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            context.contentTopPadding + 24,
            24,
            24 + context.bottomInset,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 20,
                  children: [
                    Text(
                      l10n.haozeUnifiedLogin,
                      style: AppTextStyle.title1.of(context),
                    ),
                    Text(switch (step) {
                      'mfa' => l10n.haozeNativeMfa,
                      'password-change' => l10n.haozeNativeChangePassword,
                      'link' => l10n.haozeNativeLinkGoogle,
                      _ => l10n.haozeUnifiedLoginDescription,
                    }),
                    ErrorBanner(
                      message: _googleNonceError
                          ? l10n.haozeGoogleNonceError
                          : _issue(context, _error ?? state.issue),
                    ),
                    if (step == null)
                      TextFormField(
                        key: const ValueKey('haoze-native-account'),
                        controller: _account,
                        enabled: !busy,
                        autofillHints: const [AutofillHints.username],
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(labelText: l10n.account),
                      ),
                    if (step == 'link') Text(_result?.email ?? ''),
                    if (step == 'mfa' || (_emailMode && step == null))
                      TextFormField(
                        key: const ValueKey('haoze-native-code'),
                        controller: _code,
                        enabled: !busy,
                        autocorrect: false,
                        autofillHints: step == 'mfa'
                            ? null
                            : const [AutofillHints.oneTimeCode],
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: step == 'mfa'
                              ? l10n.haozeNativeMfa
                              : l10n.haozeEmailCode,
                        ),
                        onFieldSubmitted: (_) {
                          if (!busy) unawaited(_submit());
                        },
                      )
                    else
                      SecretTextFormField(
                        key: const ValueKey('haoze-native-password'),
                        controller: _password,
                        decoration: InputDecoration(labelText: l10n.password),
                        textInputAction: step == 'password-change'
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (!busy) unawaited(_submit());
                        },
                      ),
                    if (step == 'password-change')
                      SecretTextFormField(
                        controller: _confirm,
                        decoration: InputDecoration(
                          labelText: l10n.haozeConfirmPassword,
                        ),
                      ),
                    if (_emailMode && step == null)
                      OutlinedButton(
                        key: const ValueKey('haoze-native-send-code'),
                        onPressed: busy ? null : _sendCode,
                        child: Text(l10n.haozeSendCode),
                      ),
                    if (_codeSent && step == null) Text(l10n.haozeCodeSent),
                    FilledButton(
                      key: const ValueKey('haoze-submit'),
                      onPressed: busy ? null : _submit,
                      child: _submitting
                          ? const CommonCircleLoading(size: 20)
                          : Text(l10n.haozeLogin),
                    ),
                    if (_googleWaiting) ...[
                      Text(l10n.haozeNativeGoogleWaiting),
                      TextButton(
                        key: const ValueKey('haoze-login-cancel'),
                        onPressed: _cancelGoogle,
                        child: Text(l10n.cancel),
                      ),
                    ],
                    if (step == null) ...[
                      TextButton(
                        key: const ValueKey('haoze-native-mode'),
                        onPressed: busy
                            ? null
                            : () {
                                _reset();
                                setState(() => _emailMode = !_emailMode);
                              },
                        child: Text(
                          _emailMode
                              ? l10n.haozeNativeUsePassword
                              : l10n.haozeNativeUseEmail,
                        ),
                      ),
                      OutlinedButton(
                        key: const ValueKey('haoze-native-google'),
                        onPressed: busy ? null : _googleLogin,
                        child: Text(l10n.haozeNativeGoogle),
                      ),
                    ] else
                      TextButton(
                        onPressed: busy ? null : _reset,
                        child: Text(l10n.cancel),
                      ),
                    Text(
                      l10n.haozeNativePrivacy,
                      style: AppTextStyle.footnote.of(context),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _openWebsite(haozeAccountUrl),
                      child: Text(l10n.haozeRegister),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HaozeAccountView extends ConsumerWidget {
  const HaozeAccountView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(haozeAccountProvider);
    final controller = ref.read(haozeAccountProvider.notifier).controller;
    final l10n = context.appLocalizations;
    return CommonScaffold(
      title: l10n.haozeAccount,
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            24,
            context.contentTopPadding + 16,
            24,
            24 + context.bottomInset,
          ),
          children: [
            ErrorBanner(message: _issue(context, state.issue)),
            Text(state.email ?? '', style: AppTextStyle.title2.of(context)),
            const SizedBox(height: 16),
            const HaozeUsageCard(),
            const SizedBox(height: 16),
            Text(state.profileReady ? l10n.haozeReady : l10n.haozeNotReady),
            if (state.updatedAt case final date?)
              Text('${l10n.haozeLastRefresh}: ${date.toLocal().showFull}'),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  onPressed: state.busy ? null : () => controller.refresh(),
                  child: Text(l10n.haozeRefresh),
                ),
                OutlinedButton(
                  onPressed: state.busy
                      ? null
                      : () => controller.refresh(syncProfile: true),
                  child: Text(l10n.haozeSync),
                ),
                OutlinedButton(
                  key: const ValueKey('haoze-account-security'),
                  onPressed: () =>
                      _openWebsite('$haozeAccountUrl/auth/login?next=security'),
                  child: Text(l10n.haozeAccountSecurity),
                ),
                TextButton(
                  onPressed: state.busy ? null : controller.logout,
                  child: Text(l10n.haozeLogout),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class HaozeUsageCard extends ConsumerWidget {
  const HaozeUsageCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(haozeAccountProvider);
    final subscription = account.subscription;
    final l10n = context.appLocalizations;
    final expiry = subscription?.expiresAt;
    final date = expiry != null && expiry > 0
        ? DateTime.fromMillisecondsSinceEpoch(expiry * 1000)
        : null;
    final status = subscription == null
        ? l10n.haozeNoUsage
        : subscription.total == 0
        ? l10n.haozeNoPlan
        : date != null && date.isBefore(DateTime.now())
        ? l10n.haozeExpired
        : subscription.remaining == 0
        ? l10n.haozeExhausted
        : null;
    return CommonCard(
      inert: true,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              Text(l10n.haozeUsage, style: AppTextStyle.headline.of(context)),
              if (status != null) Text(status),
              if (subscription != null) ...[
                Text(
                  '${l10n.haozeRemaining}: ${_bytes(subscription.remaining)}',
                ),
                Text('${l10n.haozeTotal}: ${_bytes(subscription.total)}'),
                Text(
                  '${l10n.haozeExpiry}: ${date?.toLocal().show ?? l10n.haozeUnlimitedTime}',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HaozeDashboardCard extends ConsumerWidget {
  const HaozeDashboardCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(haozeAccountProvider);
    final l10n = context.appLocalizations;
    final subscription = account.subscription;
    return DashboardCard(
      semanticLabel: l10n.haozeUsage,
      onTap: () =>
          ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.account),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 8,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.profiles,
            title: l10n.haozeUsage,
            chevron: true,
          ),
          Text(
            subscription == null
                ? l10n.haozeNoUsage
                : '${l10n.haozeRemaining}: ${_bytes(subscription.remaining)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            account.profileReady ? l10n.haozeReady : l10n.haozeNotReady,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

String _bytes(int count) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = count.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
}
