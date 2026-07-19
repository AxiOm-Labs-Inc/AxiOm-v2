import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/app_colors.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A banner on the home page for the Personal Account.
///
/// - Restoring → hidden (avoids flashing the wrong card while the stored
///   session is being checked on startup).
/// - Disconnected/error → "connect your account" prompt.
/// - Connected → compact chip showing first-name + nearest subscription expiry,
///   tapping opens the profiles page.
class HomeAccountBanner extends HookConsumerWidget {
  const HomeAccountBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accountNotifierProvider);
    final theme = Theme.of(context);
    final a = ref.watch(translationsProvider).requireValue.pages.profiles.account;

    // Hidden only while restoring — otherwise show connect prompt / connected chip.
    if (state is AccountStateRestoring) return const SizedBox.shrink();

    if (state is AccountStateConnected) {
      final session = state.session;
      final firstSub = state.subscriptions.firstOrNull;
      final subtitle = (firstSub != null && firstSub.expire != null && firstSub.expire!.isNotEmpty)
          ? a.activeUntil(date: firstSub.expire!)
          : a.noActiveSub;
      return _BannerCard(
        onTap: () => context.goNamed('profiles'),
        title: session.firstName.isNotEmpty ? session.firstName : a.accountFallback,
        subtitle: subtitle,
        theme: theme,
      );
    }

    // Disconnected / connecting / error → invite to connect.
    return _BannerCard(
      onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showConnectAccount(),
      title: a.connectTitle,
      theme: theme,
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({
    required this.onTap,
    required this.title,
    required this.theme,
    this.subtitle,
  });
  final VoidCallback onTap;
  final String title;
  final String? subtitle;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(AppColors.telegram).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.telegram, color: Color(AppColors.telegram), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.labelLarge,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Color(AppColors.telegram), size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
