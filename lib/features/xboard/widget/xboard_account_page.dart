import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart' show XboardException;
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';
import 'package:hiddify/features/xboard/widget/xboard_ui_common.dart';
import 'package:hiddify/features/xboard/widget/xboard_usage_card.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The account of the user: who is logged in, what the plan is, and the way
/// out of it.
class XboardAccountPage extends HookConsumerWidget {
  const XboardAccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(xboardSessionProvider);

    final refreshing = useState(false);
    final loggingOut = useState(false);
    final localError = useState<String?>(null);

    Future<void> refresh() async {
      if (refreshing.value || session.busy) return;
      refreshing.value = true;
      localError.value = null;
      try {
        await ref.read(xboardSessionProvider.notifier).refresh();
      } on XboardException catch (error) {
        if (!context.mounted) return;
        localError.value = error.message;
        refreshing.value = false;
        return;
      } catch (_) {
        if (!context.mounted) return;
        localError.value = '刷新失败，请稍后重试';
        refreshing.value = false;
        return;
      }
      if (!context.mounted) return;
      refreshing.value = false;
    }

    Future<void> logout() async {
      if (loggingOut.value || session.busy) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('退出登录'),
          content: const Text('退出后需要重新登录才能同步订阅，确定要退出吗？'),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('退出')),
          ],
        ),
      );
      if (confirmed != true) return;
      if (!context.mounted) return;

      loggingOut.value = true;
      localError.value = null;
      try {
        await ref.read(xboardSessionProvider.notifier).logout();
      } on XboardException catch (error) {
        if (!context.mounted) return;
        localError.value = error.message;
        loggingOut.value = false;
        return;
      } catch (_) {
        if (!context.mounted) return;
        localError.value = '退出登录失败，请重试';
        loggingOut.value = false;
        return;
      }

      if (!context.mounted) return;
      loggingOut.value = false;
      context.go(xboardLoginRoute);
    }

    final errorMessage = localError.value ?? session.error;

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的账户'),
        // The account screen is a root route, so it has no back arrow of its
        // own: the button here is the way back to the connection screen.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: '返回首页',
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(xboardHomeRoute);
            }
          },
        ),
        actions: [
          if (session.isAuthenticated)
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: refreshing.value || session.busy ? null : refresh,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!session.isAuthenticated) ...[
                    const XboardBanner(
                      title: '还没有登录',
                      message: '登录后可以看到你的套餐、流量和到期时间。',
                      icon: Icons.person_outline_rounded,
                    ),
                    const SizedBox(height: 16),
                    XboardPrimaryButton(
                      label: '去登录',
                      icon: Icons.login_rounded,
                      onPressed: () => context.go(xboardLoginRoute),
                    ),
                  ] else ...[
                    _identity(context, session.email, session.subscription?.planName),
                    const SizedBox(height: 14),
                    if (errorMessage != null) ...[
                      XboardBanner(
                        message: errorMessage,
                        tone: XboardBannerTone.error,
                        icon: Icons.error_outline_rounded,
                      ),
                      const SizedBox(height: 14),
                    ],
                    XboardUsageCard(showDetails: true, onRefresh: refreshing.value ? null : refresh),
                    const SizedBox(height: 14),
                    _actions(context, refreshing.value, loggingOut.value, refresh, logout),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Who is logged in, and under which plan.
  Widget _identity(BuildContext context, String? email, String? planName) {
    final theme = Theme.of(context);
    final name = planName?.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
            child: Text(
              email == null || email.isEmpty ? '?' : email.substring(0, 1).toUpperCase(),
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  email ?? '未知账号',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  name == null || name.isEmpty ? '未订阅套餐' : '套餐：$name',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The buttons under the card: refresh, the nodes, and the way out.
  Widget _actions(BuildContext context, bool refreshing, bool loggingOut, VoidCallback refresh, VoidCallback logout) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: refreshing ? null : refresh,
                icon: refreshing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded, size: 20),
                label: const Text('刷新'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.go(xboardProxiesRoute),
                icon: const Icon(Icons.dns_outlined, size: 20),
                label: const Text('节点列表'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: loggingOut ? null : logout,
          icon: loggingOut
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.logout_rounded, size: 20),
          label: const Text('退出登录'),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error, minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }
}
