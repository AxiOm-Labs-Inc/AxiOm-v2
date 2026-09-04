import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/app_colors.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/account/model/account_models.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/account/widget/account_subscription_tile.dart';
import 'package:hiddify/features/account/widget/purchase_options_sheet.dart';
import 'package:hiddify/features/account/widget/purchase_sheet.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Personal Account / ЛК block on the Profiles tab (not a separate screen).
///
/// Shows tariff / days / traffic for connected subscriptions, plus actions:
/// renew (purchase options), link Telegram, support. Guests see connect + buy.
class AccountSection extends HookConsumerWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(translationsProvider).requireValue.pages.profiles.account;
    final state = ref.watch(accountNotifierProvider);
    final storedPending = ref.watch(pendingPaymentProvider);
    final pending = (storedPending != null && !storedPending.isExpired) ? storedPending : null;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pending != null) ...[
          _PendingPaymentChip(
            title: a.pendingTitle,
            hint: a.pendingHint,
            onTap: () => showPurchaseSheet(context),
          ),
          const SizedBox(height: 12),
        ],
        switch (state) {
          AccountStateRestoring() => _RestoringView(theme: theme),
          AccountStateConnected(:final session, :final subscriptions) =>
            _ConnectedView(session: session, subscriptions: subscriptions, theme: theme),
          _ => _DisconnectedView(theme: theme),
        },
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: () {
            if (pending != null) {
              showPurchaseSheet(context);
            } else {
              showPurchaseOptions(context);
            }
          },
          icon: Icon(
            pending != null ? Icons.pending_actions_rounded : Icons.shopping_cart_outlined,
            size: 20,
          ),
          label: Text(pending != null ? a.continuePayment : a.renewOrBuy),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => UriUtils.tryLaunch(Uri.parse(Constants.telegramSupportBotUrl)),
          icon: const Icon(Icons.support_agent_rounded, size: 20),
          label: Text(a.support),
        ),
      ],
    );
  }
}

class _PendingPaymentChip extends StatelessWidget {
  const _PendingPaymentChip({required this.title, required this.hint, required this.onTap});

  final String title;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.pending_actions_rounded, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.labelLarge),
                    Text(
                      hint,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
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
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(a.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              a.guestHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    ref.read(bottomSheetsNotifierProvider.notifier).showConnectAccount(),
                icon: const Icon(Icons.telegram, size: 20),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(AppColors.telegram),
                  foregroundColor: Colors.white,
                ),
                label: Text(a.connectTelegram),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Restoring ───────────────────────────────────────────────────────────────

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
