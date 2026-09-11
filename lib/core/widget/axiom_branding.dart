import 'package:dartx/dartx.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:axiom/core/app_info/app_info_provider.dart';
import 'package:axiom/core/localization/translations.dart';
import 'package:axiom/features/connection/model/connection_status.dart';
import 'package:axiom/features/connection/notifier/connection_notifier.dart';
import 'package:axiom/gen/assets.gen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AxiOmLogoIcon extends HookConsumerWidget {
  const AxiOmLogoIcon({super.key, this.size = 32, this.connected});

  final double size;
  final bool? connected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isConnected =
        connected ??
        (() {
          final connectionStatus = ref.watch(connectionNotifierProvider);
          return connectionStatus is AsyncData && connectionStatus.value is Connected;
        })();

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: isConnected
                ? Assets.images.navbarIconConnected.svg(
                    key: const ValueKey('nav_connected'),
                    width: size,
                    height: size,
                  )
                : Assets.images.navbarIcon.svg(
                    key: const ValueKey('nav_disconnected'),
                    width: size,
                    height: size,
                  ),
          ),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 300),
            style: TextStyle(
              fontSize: size * 0.625,
              fontWeight: FontWeight.w400,
              color: isConnected ? const Color(0xFF5DCAA5) : const Color(0xFF5BA3FF),
              height: 1.0,
            ),
            child: const Text('Ω'),
          ),
        ],
      ),
    );
  }
}

class AxiOmAppBarTitle extends HookConsumerWidget {
  const AxiOmAppBarTitle({super.key, this.showVersion = true});

  final bool showVersion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AxiOmLogoIcon(),
        const Gap(8),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: t.common.appTitle),
              if (showVersion) ...[
                const TextSpan(text: ' '),
                const WidgetSpan(child: AppVersionLabel(), alignment: PlaceholderAlignment.middle),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class AxiOmSectionTitle extends HookConsumerWidget {
  const AxiOmSectionTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AxiOmLogoIcon(size: 28),
        const Gap(10),
        Text(title),
      ],
    );
  }
}

class AppVersionLabel extends HookConsumerWidget {
  const AppVersionLabel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    final version = ref.watch(appInfoProvider).requireValue.presentVersion;
    if (version.isBlank) return const SizedBox();

    return Semantics(
      label: t.common.version,
      button: false,
      child: Container(
        decoration: BoxDecoration(color: theme.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(4)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          version,
          textDirection: TextDirection.ltr,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
  }
}
