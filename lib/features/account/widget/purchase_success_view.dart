import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Экран «Подписка активна» в листе покупки.
///
/// Вынесен из [PurchaseSheet], чтобы вёрстку можно было проверить тестом на
/// узком экране. Раньше «Скопировать», «Привязать» и «Готово» стояли в одном
/// ряду без переноса, и на телефоне «Готово» уезжало за правый край — ровно та
/// кнопка, которой лист закрывают. Теперь вспомогательные действия переносятся
/// на новую строку, а «Готово» стоит отдельно во всю ширину.
class PurchaseSuccessView extends StatelessWidget {
  const PurchaseSuccessView({
    super.key,
    required this.subUrl,
    required this.imported,
    required this.onDone,
    this.claimUrl,
    this.onOpenClaim,
  });

  final String subUrl;

  /// Подписка уже добавлена в профили и выбрана активной.
  final bool imported;

  /// Ссылка привязки покупки к Telegram-аккаунту — есть только у гостя.
  final String? claimUrl;
  final VoidCallback? onOpenClaim;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = imported
        ? 'Подписка добавлена в профили и выбрана активной — если VPN был '
            'включён, соединение переподключилось на неё. Если профиль не '
            'появился, скопируйте ссылку и добавьте вручную.'
        : 'Скопируйте ссылку и добавьте её в профили вручную.';
    final claim = claimUrl;
    final hasClaim = claim != null && claim.isNotEmpty;

    return SafeArea(
      // Прокрутка — для крупного шрифта в настройках системы и невысоких
      // экранов: без неё «Готово» обрезалось бы уже снизу.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.green, size: 26),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Подписка активна', style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(hint, style: theme.textTheme.bodySmall),
            if (hasClaim) ...[
              const SizedBox(height: 8),
              Text(
                'Чтобы привязать покупку к Telegram-аккаунту, откройте ссылку ниже.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            SelectableText(
              subUrl,
              maxLines: 2,
              style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: subUrl)),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Скопировать'),
                ),
                if (hasClaim)
                  OutlinedButton.icon(
                    onPressed: onOpenClaim,
                    icon: const Icon(Icons.link_rounded, size: 18),
                    label: const Text('Привязать'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onDone,
                child: const Text('Готово'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
