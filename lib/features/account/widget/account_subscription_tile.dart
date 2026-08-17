import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/app_colors.dart';
import 'package:hiddify/features/account/model/account_models.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Tile for a single subscription in the Personal Account section.
///
/// Shows tariff name, status, traffic/days meters (reusing _DualMeterRow style),
/// and actions: copy link, add to profiles.
class AccountSubscriptionTile extends HookConsumerWidget {
  const AccountSubscriptionTile({super.key, required this.subscription});

  final AccountSubscription subscription;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final a = ref.watch(translationsProvider).requireValue.pages.profiles.account;
    final sub = subscription;

    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tariff name + status badge
            Row(
              children: [
                Expanded(
                  child: Text(
                    sub.tariff.isNotEmpty ? sub.tariff : a.defaultTariff,
                    style: theme.textTheme.labelLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                _StatusBadge(status: sub.status, theme: theme, activeLabel: a.activeStatus),
              ],
            ),
            const SizedBox(height: 10),

            // Traffic / days meters
            if (sub.dataLimit > 0) ...[
              _SimpleMeter(
                label: a.trafficLabel,
                value: sub.trafficLabel,
                progress: sub.trafficRatio,
                progressColor: _trafficColor(sub.trafficRatio),
                theme: theme,
              ),
              const SizedBox(height: 6),
            ],
            if (sub.expire != null && sub.expire!.isNotEmpty)
              _ExpireRow(expire: sub.expire!, daysLeft: sub.daysLeft, theme: theme, label: a.expiresLabel),

            const SizedBox(height: 12),
            // Action buttons
            Column(
              children: [
                _ActionChip(
                  icon: Icons.copy_rounded,
                  label: a.copyLink,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: sub.subUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(a.linkCopied), duration: const Duration(seconds: 2)),
                    );
                  },
                  theme: theme,
                ),
                // Active subscriptions are auto-imported on login/refresh; the
                // button stays as a manual re-add. Inactive ones can't be added.
                if (sub.status == 'active') ...[
                  const SizedBox(height: 8),
                  _ActionChip(
                    icon: Icons.add_rounded,
                    label: a.addToProfiles,
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await ref.read(addProfileNotifierProvider.notifier).addClipboard(sub.subUrl);
                      messenger.showSnackBar(
                        SnackBar(content: Text(a.addedToProfiles), duration: const Duration(seconds: 2)),
                      );
                    },
                    theme: theme,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Status badge ────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, required this.theme, required this.activeLabel});
  final String status;
  final ThemeData theme;
  final String activeLabel;

  @override
  Widget build(BuildContext context) {
    final isActive = status == 'active';
    final color = isActive ? AppColors.success : AppColors.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Color(color).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isActive ? Icons.check_circle : Icons.error_outline,
            size: 12,
            color: Color(color),
          ),
          const SizedBox(width: 4),
          Text(
            isActive ? activeLabel : status,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Color(color),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Simple meter (single bar — traffic or days) ─────────────────────────────

/// Returns a signal color based on traffic ratio:
/// <0.8 info (blue), 0.8–0.95 warning (amber), >0.95 danger (red).
Color _trafficColor(double ratio) {
  if (ratio > 0.95) return const Color(AppColors.danger);
  if (ratio >= 0.8) return const Color(AppColors.warning);
  return const Color(AppColors.info);
}

class _SimpleMeter extends StatelessWidget {
  const _SimpleMeter({
    required this.label,
    required this.value,
    required this.progress,
    required this.progressColor,
    required this.theme,
  });
  final String label;
  final String value;
  final double progress;
  final Color progressColor;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2,
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
            Text(
              value,
              style: theme.textTheme.labelSmall?.copyWith(fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            color: progressColor,
            backgroundColor: progressColor.withValues(alpha: 0.15),
          ),
        ),
      ],
    );
  }
}

// ── Expire date row ─────────────────────────────────────────────────────────

class _ExpireRow extends StatelessWidget {
  const _ExpireRow({required this.expire, required this.daysLeft, required this.theme, required this.label});
  final String expire;
  final int? daysLeft;
  final ThemeData theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    // Warn when 3 days or fewer remain (but not yet expired).
    final isUrgent = daysLeft != null && daysLeft! >= 0 && daysLeft! <= 3;
    final color = isUrgent ? const Color(AppColors.warning) : theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(Icons.calendar_today, size: 12, color: color),
        const SizedBox(width: 6),
        Text(
          '$label $expire',
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: isUrgent ? FontWeight.w600 : null,
          ),
        ),
      ],
    );
  }
}

// ── Action chip ─────────────────────────────────────────────────────────────

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.theme,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
