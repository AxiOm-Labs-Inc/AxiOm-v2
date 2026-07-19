import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/app_colors.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/account/model/account_models.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/account/widget/account_subscription_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Personal Account section in the Profiles page.
///
/// Disconnected → card-button to connect.
/// Connected → account info + subscription list.
class AccountSection extends HookConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(accountNotifierProvider);
    final theme = Theme.of(context);

    return switch (state) {
      AccountStateRestoring() => _RestoringView(theme: theme),
      AccountStateConnected(:final session, :final subscriptions) =>
        _ConnectedView(session: session, subscriptions: subscriptions, theme: theme),
      _ => _DisconnectedView(theme: theme),
    };
  }
}

// ── Disconnected ────────────────────────────────────────────────────────────

class _DisconnectedView extends ConsumerWidget {
  const _DisconnectedView({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(translationsProvider).requireValue.pages.profiles.account;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showConnectAccount(),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Color(AppColors.telegram).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.telegram, color: Color(AppColors.telegram), size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.title,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      a.connectDesc,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(AppColors.telegram)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Restoring (session check in progress) ──────────────────────────────────

class _RestoringView extends StatelessWidget {
  const _RestoringView({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
  }
}

// ── Connected ───────────────────────────────────────────────────────────────

class _ConnectedView extends HookConsumerWidget {
  const _ConnectedView({
    required this.session,
    required this.subscriptions,
    required this.theme,
  });
  final AccountSession session;
  final List<AccountSubscription> subscriptions;
  final ThemeData theme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(translationsProvider).requireValue.pages.profiles.account;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Color(AppColors.telegram).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.telegram, color: Color(AppColors.telegram), size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.firstName.isNotEmpty ? session.firstName : a.accountFallback,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        a.title,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // Menu button
                PopupMenuButton<String>(
                  onSelected: (value) async {
                    switch (value) {
                      case 'refresh':
                        final messenger = ScaffoldMessenger.of(context);
                        final ok = await ref.read(accountNotifierProvider.notifier).refresh();
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(ok ? a.refreshed : a.networkError),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      case 'logout':
                        _confirmLogout(context, ref, a);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'refresh', child: Text(a.refresh)),
                    PopupMenuItem(value: 'logout', child: Text(a.logout)),
                  ],
                ),
              ],
            ),

            if (subscriptions.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              // Subscription list
              ...subscriptions.map(
                (sub) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AccountSubscriptionTile(subscription: sub),
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              Text(
                a.noSubscriptions,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _confirmLogout(BuildContext context, WidgetRef ref, TranslationsPagesProfilesAccountEn a) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(a.logoutConfirm),
        content: Text(a.logoutConfirmDesc),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(a.cancel)),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(accountNotifierProvider.notifier).logout();
            },
            child: Text(a.logout),
          ),
        ],
      ),
    );
  }
}
