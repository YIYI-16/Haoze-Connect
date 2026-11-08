import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/custom_issue.dart';
import 'package:fl_clash/features/update/update_dialog.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/ui/icons/icons.dart';
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
  bool _submitting = false;

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final browser = ref.read(haozeBrowserLoginProvider);
    try {
      await ref
          .read(haozeAccountProvider.notifier)
          .controller
          .loginWithBrowser(browser.login);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(haozeAccountProvider);
    final initialized = ref.watch(initProvider);
    final l10n = context.appLocalizations;
    final busy = _submitting || state.busy;
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 20,
                children: [
                  Text(
                    l10n.haozeUnifiedLogin,
                    style: AppTextStyle.title1.of(context),
                  ),
                  Text(l10n.haozeUnifiedLoginDescription),
                  ErrorBanner(message: _issue(context, state.issue)),
                  if (_submitting) Text(l10n.haozeBrowserWaiting),
                  FilledButton(
                    key: const ValueKey('haoze-submit'),
                    onPressed: busy || !initialized ? null : _submit,
                    child: Text(l10n.haozeUnifiedLogin),
                  ),
                  if (_submitting)
                    TextButton(
                      key: const ValueKey('haoze-login-cancel'),
                      onPressed: () =>
                          ref.read(haozeBrowserLoginProvider).cancel(),
                      child: Text(l10n.cancel),
                    ),
                  Text(
                    l10n.haozeBrowserPrivacy,
                    style: AppTextStyle.footnote.of(context),
                  ),
                  Text(
                    l10n.haozeMigrationNotice,
                    style: AppTextStyle.footnote.of(context),
                  ),
                  OutlinedButton(
                    key: const ValueKey('haoze-register-website'),
                    onPressed: busy
                        ? null
                        : () => _openWebsite(haozeAccountUrl),
                    child: Text(l10n.haozeRegister),
                  ),
                  TextButton(
                    onPressed: () => _openWebsite(haozePanelUrl),
                    child: Text(l10n.haozeWebsite),
                  ),
                  TextButton(
                    key: const ValueKey('haoze-auth-update'),
                    onPressed: () => showHaozeUpdateDialog(context),
                    child: Text(l10n.checkUpdate),
                  ),
                ],
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
