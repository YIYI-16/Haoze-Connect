import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/custom_issue.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/views/dashboard/widgets/card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haoze_xboard/account.dart';
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
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _emailCode = TextEditingController();
  final _invite = TextEditingController();
  bool _register = false;
  bool _termsAccepted = false;
  bool _invalid = false;
  bool _codeSent = false;
  bool _submitting = false;
  int _cooldown = 0;
  Timer? _timer;

  XboardAccountController get _controller =>
      ref.read(haozeAccountProvider.notifier).controller;

  Future<void> _submit() async {
    if (_submitting) return;
    final state = ref.read(haozeAccountProvider);
    final config = state.config ?? {};
    final invalid =
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim()) ||
        _password.text.isEmpty ||
        (_register &&
            (_password.text.length < 8 ||
                _password.text != _confirmation.text ||
                (enabled(config['is_email_verify']) &&
                    _emailCode.text.trim().isEmpty) ||
                (enabled(config['is_invite_force']) &&
                    _invite.text.trim().isEmpty)));
    setState(() => _invalid = invalid);
    if (invalid || state.busy || !ref.read(initProvider)) return;
    _submitting = true;
    try {
      if (_register) {
        if ((config['tos_url'] is String &&
                (config['tos_url'] as String).isNotEmpty &&
                !_termsAccepted) ||
            config.isEmpty ||
            enabled(config['is_captcha']) ||
            enabled(config['is_recaptcha'])) {
          return;
        }
        await _controller.register(
          _email.text,
          _password.text,
          emailCode: _emailCode.text.trim(),
          inviteCode: _invite.text.trim(),
        );
      } else {
        await _controller.login(_email.text, _password.text);
      }
    } finally {
      _submitting = false;
    }
  }

  Future<void> _sendCode() async {
    if (_cooldown > 0 || ref.read(haozeAccountProvider).busy) return;
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      setState(() => _invalid = true);
      return;
    }
    await _controller.sendEmailCode(_email.text.trim());
    if (!mounted || ref.read(haozeAccountProvider).issue != null) return;
    setState(() {
      _cooldown = 60;
      _codeSent = true;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown == 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    _emailCode.dispose();
    _invite.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(haozeAccountProvider);
    final initialized = ref.watch(initProvider);
    final l10n = context.appLocalizations;
    final config = state.config;
    final captcha =
        enabled(config?['is_captcha']) || enabled(config?['is_recaptcha']);
    final terms = config?['tos_url'];
    final hasTerms = terms is String && terms.isNotEmpty;
    final canRegister =
        config != null &&
        !captcha &&
        !enabled(config['stop_register']) &&
        (!hasTerms || _termsAccepted);
    final ready = !state.busy && initialized && (!_register || canRegister);
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
                  spacing: 16,
                  children: [
                    Text(
                      _register ? l10n.haozeRegister : l10n.haozeLogin,
                      style: AppTextStyle.title1.of(context),
                    ),
                    ErrorBanner(
                      message: _invalid
                          ? l10n.haozeInvalidForm
                          : _issue(context, state.issue),
                    ),
                    if (_register && state.configFailed) ...[
                      ErrorBanner(message: l10n.haozeConfigError),
                      TextButton(
                        onPressed: state.busy ? null : _controller.loadConfig,
                        child: Text(l10n.retry),
                      ),
                    ],
                    if (_register && captcha) Text(l10n.haozeCaptchaWebsite),
                    TextFormField(
                      key: const ValueKey('haoze-email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(labelText: l10n.haozeEmail),
                    ),
                    SecretTextFormField(
                      key: const ValueKey('haoze-password'),
                      controller: _password,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (ready) unawaited(_submit());
                      },
                      decoration: InputDecoration(labelText: l10n.password),
                    ),
                    if (_register) ...[
                      SecretTextFormField(
                        key: const ValueKey('haoze-confirmation'),
                        controller: _confirmation,
                        decoration: InputDecoration(
                          labelText: l10n.haozeConfirmPassword,
                        ),
                      ),
                      if (enabled(config?['is_email_verify'])) ...[
                        TextFormField(
                          key: const ValueKey('haoze-email-code'),
                          controller: _emailCode,
                          autocorrect: false,
                          decoration: InputDecoration(
                            labelText: l10n.haozeEmailCode,
                          ),
                        ),
                        TextButton(
                          onPressed: state.busy || captcha || _cooldown > 0
                              ? null
                              : _sendCode,
                          child: Text(
                            _cooldown > 0
                                ? '${l10n.haozeSendCode} ($_cooldown)'
                                : l10n.haozeSendCode,
                          ),
                        ),
                        if (_codeSent) Text(l10n.haozeCodeSent),
                      ],
                      TextFormField(
                        key: const ValueKey('haoze-invite'),
                        controller: _invite,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l10n.haozeInviteCode,
                        ),
                      ),
                      if (hasTerms) ...[
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _termsAccepted,
                          onChanged: state.busy
                              ? null
                              : (value) => setState(
                                  () => _termsAccepted = value == true,
                                ),
                          title: Text(l10n.haozeAgreeTerms),
                        ),
                        TextButton(
                          onPressed: () => _openWebsite(terms),
                          child: Text(l10n.haozeTerms),
                        ),
                      ],
                    ],
                    FilledButton(
                      key: const ValueKey('haoze-submit'),
                      onPressed: ready ? _submit : null,
                      child: Text(
                        _register ? l10n.haozeRegister : l10n.haozeLogin,
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('haoze-auth-toggle'),
                      onPressed: state.busy
                          ? null
                          : () {
                              setState(() {
                                _register = !_register;
                                _invalid = false;
                              });
                              if (_register && config == null) {
                                unawaited(_controller.loadConfig());
                              }
                            },
                      child: Text(
                        _register ? l10n.haozeLogin : l10n.haozeRegister,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _openWebsite(haozePanelUrl),
                      child: Text(l10n.haozeWebsite),
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
      onTap: () =>
          ref.read(currentPageLabelProvider.notifier).toPage(PageLabel.account),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 8,
        children: [
          Text(l10n.haozeUsage, style: AppTextStyle.headline.of(context)),
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
