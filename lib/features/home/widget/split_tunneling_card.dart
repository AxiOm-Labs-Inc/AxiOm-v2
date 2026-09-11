import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:axiom/core/localization/translations.dart';
import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:axiom/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SplitTunnelingCard extends ConsumerWidget {
  const SplitTunnelingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!PlatformUtils.isAndroid) return const SizedBox.shrink();

    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final mode = ref.watch(Preferences.perAppProxyMode);
    final includeApps = ref.watch(Preferences.includeApps);
    final excludeApps = ref.watch(Preferences.excludeApps);

    final isEnabled = mode.enabled;

    final appsCount = switch (mode) {
      PerAppProxyMode.include => includeApps.length,
      PerAppProxyMode.exclude => excludeApps.length,
      PerAppProxyMode.off => 0,
    };

    final presented = mode.present(t);
    final subtitle = isEnabled && appsCount > 0
        ? '$appsCount apps · ${presented.message}'
        : presented.message;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            if (!isEnabled) {
              await ref.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.exclude);
            }
            if (context.mounted) context.pushNamed('perAppProxy');
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isEnabled
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.apps_rounded,
                    size: 22,
                    color: isEnabled
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.pages.settings.routing.perAppProxy.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: isEnabled,
                  onChanged: (value) async {
                    final newMode = value ? PerAppProxyMode.exclude : PerAppProxyMode.off;
                    await ref.read(Preferences.perAppProxyMode.notifier).update(newMode);
                    if (value && context.mounted) {
                      context.pushNamed('perAppProxy');
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
