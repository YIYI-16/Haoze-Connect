import 'package:flutter/material.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';
import 'package:hiddify/features/xboard/widget/xboard_ui_common.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The traffic of the account: what is left of it, how much of it there was,
/// and what the panel says about the plan.
class XboardUsageCard extends HookConsumerWidget {
  const XboardUsageCard({super.key, this.showDetails = false, this.onRefresh});

  /// Whether the card also shows when the plan ends and when it was last read.
  final bool showDetails;

  /// An optional refresh, shown as a button in the corner of the card.
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(xboardSessionProvider);
    final subscription = session.subscription;
    final planName = subscription?.planName?.trim();

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  planName == null || planName.isEmpty ? '流量与套餐' : planName,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (onRefresh != null)
                IconButton(
                  tooltip: '刷新',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  onPressed: session.busy ? null : onRefresh,
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (subscription == null)
            _empty(context, session.busy)
          else ...[
            _statusChips(context, subscription, session.lastUpdated),
            const SizedBox(height: 12),
            _usage(context, subscription),
            if (showDetails) ...[const SizedBox(height: 6), _details(context, subscription, session.lastUpdated)],
          ],
        ],
      ),
    );
  }

  /// What the card says when the panel has no traffic to show yet.
  Widget _empty(BuildContext context, bool busy) {
    final theme = Theme.of(context);
    if (busy) {
      return Row(
        children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text('正在获取订阅信息…', style: theme.textTheme.bodyMedium),
        ],
      );
    }
    return Text(
      '暂无订阅信息，登录后可查看套餐与流量。',
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }

  /// The states of the traffic: no plan, expired, used up, or simply old.
  Widget _statusChips(BuildContext context, XboardSubscription subscription, DateTime? lastUpdated) {
    final chips = <Widget>[];

    if (!subscription.hasPlan) {
      chips.add(
        const XboardStatusChip(label: '无套餐', tone: XboardBannerTone.warning, icon: Icons.card_membership_outlined),
      );
    }
    if (subscription.isExpired) {
      chips.add(const XboardStatusChip(label: '已过期', tone: XboardBannerTone.error, icon: Icons.event_busy_outlined));
    }
    if (subscription.total > 0 && !subscription.hasTraffic) {
      chips.add(const XboardStatusChip(label: '流量已用尽', tone: XboardBannerTone.error, icon: Icons.speed_outlined));
    }
    if (isXboardUsageStale(lastUpdated)) {
      chips.add(const XboardStatusChip(label: '数据较旧', icon: Icons.history_rounded));
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(spacing: 8, runSpacing: 8, children: chips);
  }

  /// The bar of the traffic and the numbers around it.
  Widget _usage(BuildContext context, XboardSubscription subscription) {
    final theme = Theme.of(context);
    final total = subscription.total;
    final used = subscription.used;
    final remaining = subscription.remaining;
    final exhausted = total > 0 && remaining <= 0;

    final bar = total > 0
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: (used / total).clamp(0.0, 1.0),
                  minHeight: 8,
                  color: exhausted ? theme.colorScheme.error : theme.colorScheme.primary,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 10),
            ],
          )
        : const SizedBox(height: 4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar,
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('剩余流量', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(
                    total > 0 ? formatXboardBytes(remaining) : '不限流量',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: exhausted ? theme.colorScheme.error : theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              total > 0
                  ? '已用 ${formatXboardBytes(used)} / 共 ${formatXboardBytes(total)}'
                  : '已用 ${formatXboardBytes(used)}',
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }

  /// When the plan ends, when the traffic resets and when this was read.
  Widget _details(BuildContext context, XboardSubscription subscription, DateTime? lastUpdated) {
    final theme = Theme.of(context);
    final expiresAt = subscription.expiresAt;
    final daysLeft = xboardDaysLeft(expiresAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 20),
        XboardInfoRow(
          label: '到期时间',
          value: expiresAt == null
              ? '长期有效'
              : '${formatXboardDate(expiresAt)}（${daysLeft >= 0 ? '剩 $daysLeft 天' : '已过期'}）',
          valueColor: subscription.isExpired ? theme.colorScheme.error : null,
          icon: Icons.event_outlined,
        ),
        XboardInfoRow(
          label: '下次重置',
          value: formatXboardDateTime(subscription.nextResetAt) ?? '面板未提供',
          icon: Icons.restart_alt_rounded,
        ),
        XboardInfoRow(label: '最近更新', value: formatXboardDateTime(lastUpdated) ?? '尚未更新', icon: Icons.update_rounded),
      ],
    );
  }
}

/// Whether the traffic of the panel is old enough to doubt.
bool isXboardUsageStale(DateTime? lastUpdated) {
  if (lastUpdated == null) return false;
  return DateTime.now().difference(lastUpdated) > xboardUsageStaleAfter;
}
