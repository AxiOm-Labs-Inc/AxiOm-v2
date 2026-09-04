import 'package:flutter/material.dart';
import 'package:hiddify/core/model/app_colors.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/account/widget/purchase_options_sheet.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Session-only dismissal of the expiry banner: hidden until the app restarts
/// (intentionally NOT persisted — the banner comes back on the next launch).
final expiryBannerDismissedProvider = StateProvider<bool>((ref) => false);

/// Warning banner on the home page shown when the nearest subscription is
/// about to expire (≤ 3 days) or has already expired. Considers both the
/// Telegram-account subscriptions and any remote profile in the profile list
/// (via its `subscription-userinfo` expiry).
///
/// Tapping offers all three ways to pay — in the app, on the site, in the
/// sales bot — instead of picking one: the routes are not interchangeable
/// (promo codes live on the site, purchase history in the bot), and the old
/// split by expiry state was invisible to the user.
///
/// The close button hides it for the current session only.
class HomeExpiryBanner extends HookConsumerWidget {
  const HomeExpiryBanner({super.key});

  /// Same urgency threshold as the account page (_ExpireRow).
  static const urgentDays = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(expiryBannerDismissedProvider)) return const SizedBox.shrink();

    // Candidates from the Telegram account (active with time left) and from
    // any remote profile (subscription-userinfo expiry), so subscriptions
    // added without the Telegram account are covered too.
    int? nearestActiveDays;
    var anyDated = false;

    final accountState = ref.watch(accountNotifierProvider);
    if (accountState is AccountStateConnected) {
      for (final s in accountState.subscriptions) {
        if (s.daysLeft == null) continue;
        anyDated = true;
        if (s.status == 'active' && s.daysLeft! >= 0) {
          if (nearestActiveDays == null || s.daysLeft! < nearestActiveDays) {
            nearestActiveDays = s.daysLeft;
          }
        }
      }
    }

    final profiles = ref.watch(profilesNotifierProvider).valueOrNull;
    if (profiles != null) {
      for (final p in profiles) {
        if (p is! RemoteProfileEntity) continue;
        final info = p.subInfo;
        if (info == null) continue;
        // Parser maps "no expiry" to a huge sentinel — skip those.
        if (info.expire.millisecondsSinceEpoch >= ProfileParser.infiniteTimeThreshold * 1000) continue;
        anyDated = true;
        final days = info.expire.difference(DateTime.now()).inDays;
        if (days >= 0 && (nearestActiveDays == null || days < nearestActiveDays)) {
          nearestActiveDays = days;
        }
      }
    }

    final theme = Theme.of(context);
    final String title;
    final String subtitle;
    final Color color;
    final IconData icon;

    if (nearestActiveDays != null && nearestActiveDays <= urgentDays) {
      title = 'Подписка заканчивается';
      subtitle = '${_daysLabel(nearestActiveDays)} — продлите заранее';
      color = const Color(AppColors.warning);
      icon = Icons.schedule_rounded;
    } else if (nearestActiveDays == null && anyDated) {
      // Every dated subscription/profile is expired.
      title = 'Подписка истекла';
      subtitle = 'Продлите, чтобы продолжить пользоваться VPN';
      color = const Color(AppColors.danger);
      icon = Icons.error_outline_rounded;
    } else {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => showPurchaseOptions(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: theme.textTheme.labelLarge),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Скрыть до перезапуска',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  icon: Icon(Icons.close_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  onPressed: () =>
                      ref.read(expiryBannerDismissedProvider.notifier).state = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _daysLabel(int days) => switch (days) {
        0 => 'Последний день',
        1 => 'Остался 1 день',
        _ => 'Осталось $days дн.',
      };
}
