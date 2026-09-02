import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/account/widget/purchase_sheet.dart';
import 'package:hiddify/utils/utils.dart';

/// Where to buy: the expiry banner offers all three routes instead of deciding
/// for the user.
///
/// The in-app sheet is the short path, but it is not always the right one: a
/// promo code and a payment method other than the default exist only on the
/// site, and the bot is where an existing customer already has their history
/// and support. Previously the banner picked one route by itself — the sales
/// bot before expiry, the in-app sheet after — and that split was invisible to
/// the user.
Future<void> showPurchaseOptions(BuildContext context) async {
  final choice = await showModalBottomSheet<_PurchaseRoute>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _PurchaseOptionsSheet(),
  );
  // Действуем на контексте вызвавшего (баннера), а не закрытого листа: его
  // Navigator к этому моменту уже снят вместе с элементом.
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _PurchaseRoute.inApp:
      await showPurchaseSheet(context);
    case _PurchaseRoute.site:
      await UriUtils.tryLaunch(Uri.parse(Constants.purchaseSiteUrl));
    case _PurchaseRoute.bot:
      await UriUtils.tryLaunch(Uri.parse(Constants.telegramBuyBotUrl));
  }
}

enum _PurchaseRoute { inApp, site, bot }

class _PurchaseOptionsSheet extends StatelessWidget {
  const _PurchaseOptionsSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Как оплатить', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Тарифы и цены везде одинаковые',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _OptionTile(
              icon: Icons.smartphone_rounded,
              title: 'В приложении',
              subtitle: 'Оплата картой или через СБП, не выходя из AxiOm',
              onTap: () => Navigator.of(context).pop(_PurchaseRoute.inApp),
            ),
            const SizedBox(height: 8),
            _OptionTile(
              icon: Icons.language_rounded,
              title: 'На сайте',
              subtitle: 'Промокоды и сравнение тарифов',
              onTap: () => Navigator.of(context).pop(_PurchaseRoute.site),
            ),
            const SizedBox(height: 8),
            _OptionTile(
              icon: Icons.send_rounded,
              title: 'В Telegram-боте',
              subtitle: 'История покупок и поддержка в одном месте',
              onTap: () => Navigator.of(context).pop(_PurchaseRoute.bot),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: theme.colorScheme.primary),
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
              Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
