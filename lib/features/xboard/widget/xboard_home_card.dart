import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart' show XboardException;
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';
import 'package:hiddify/features/xboard/widget/xboard_ui_common.dart';
import 'package:hiddify/features/xboard/widget/xboard_usage_card.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// What the home screen shows about the account: the traffic of the plan when
/// there is one, and the way in when there is not.
class XboardHomeCard extends HookConsumerWidget {
  const XboardHomeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(xboardSessionProvider);
    final localError = useState<String?>(null);

    Future<void> refresh() async {
      if (session.busy) return;
      localError.value = null;
      try {
        await ref.read(xboardSessionProvider.notifier).refresh();
      } on XboardException catch (error) {
        if (!context.mounted) return;
        localError.value = error.message;
      } catch (_) {
        if (!context.mounted) return;
        localError.value = '刷新失败，请稍后重试';
      }
    }

    if (!session.isAuthenticated) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_sync_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '登录 $xboardAppName',
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '登录后自动同步你的订阅与流量，无需手动添加节点。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(onPressed: () => context.go(xboardLoginRoute), child: const Text('登录')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(onPressed: () => context.go(xboardRegisterRoute), child: const Text('注册')),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final errorMessage = localError.value ?? session.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errorMessage != null) ...[
          XboardBanner(
            message: errorMessage,
            tone: XboardBannerTone.error,
            icon: Icons.error_outline_rounded,
            action: TextButton(onPressed: session.busy ? null : refresh, child: const Text('重试')),
          ),
          const SizedBox(height: 10),
        ],
        XboardUsageCard(onRefresh: session.busy ? null : refresh),
      ],
    );
  }
}
