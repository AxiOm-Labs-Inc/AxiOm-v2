import 'package:flutter/material.dart';
import 'package:hiddify/core/model/windows_admin.dart';

/// Плашка «приложение работает без прав администратора».
///
/// Показывается только на Windows и только когда пользователь отказал в UAC при
/// старте (`WindowsAdmin.restricted`). В этом состоянии режим службы VPN
/// недоступен — ядро работает системным прокси, а его слушает не весь софт:
/// браузеры со своими настройками прокси или DoH и приложения с собственным
/// сетевым стеком ходят мимо. Молчать об этом нельзя: снаружи это выглядит как
/// «VPN подключён, но сайт не открывается».
///
/// Плашку нельзя скрыть — она исчезает сама, когда приложение перезапущено с
/// правами.
class WindowsAdminBanner extends StatelessWidget {
  const WindowsAdminBanner({super.key});

  Future<void> _confirmRelaunch(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Перезапустить с правами администратора?'),
        content: const Text(
          'Приложение закроется и откроется снова. Windows запросит подтверждение.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Перезапустить'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await WindowsAdmin.relaunchAsAdmin();
  }

  @override
  Widget build(BuildContext context) {
    if (!WindowsAdmin.restricted) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final accent = theme.colorScheme.error;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _confirmRelaunch(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.shield_outlined, color: accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Режим VPN недоступен', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 2),
                      Text(
                        'Приложение запущено без прав администратора. Сейчас работает '
                        'системный прокси — его использует не весь софт, часть сайтов '
                        'может не открываться. Нажмите, чтобы перезапустить с правами.',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: accent, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
