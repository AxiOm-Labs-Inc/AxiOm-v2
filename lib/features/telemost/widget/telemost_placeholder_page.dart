import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Placeholder for the Telemost tab until the bypass feature ships.
/// Shows a blurred mock conference UI with a «coming soon» overlay.
class TelemostPlaceholderPage extends ConsumerWidget {
  const TelemostPlaceholderPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: const _MockConferenceLayout(),
          ),
          ColoredBox(
            color: colorScheme.surface.withValues(alpha: 0.55),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.video_call_rounded, size: 72, color: colorScheme.primary.withValues(alpha: 0.85)),
                    const Gap(20),
                    Text(
                      t.pages.telemost.comingSoon,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const Gap(12),
                    Text(
                      t.pages.telemost.comingSoonHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(color: colorScheme.onSurface.withValues(alpha: 0.72)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MockConferenceLayout extends StatelessWidget {
  const _MockConferenceLayout();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Telemost', style: Theme.of(context).textTheme.titleLarge),
            const Gap(24),
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                physics: const NeverScrollableScrollPhysics(),
                children: List.generate(
                  4,
                  (i) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer.withValues(alpha: 0.35 + i * 0.08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Center(
                      child: Icon(Icons.person_rounded, size: 48, color: colorScheme.onPrimaryContainer.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
              ),
            ),
            const Gap(16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _MockControl(Icons.mic_rounded, colorScheme),
                _MockControl(Icons.videocam_rounded, colorScheme),
                _MockControl(Icons.screen_share_rounded, colorScheme),
                _MockControl(Icons.call_end_rounded, colorScheme, tint: colorScheme.errorContainer),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MockControl extends StatelessWidget {
  const _MockControl(this.icon, this.colorScheme, {this.tint});

  final IconData icon;
  final ColorScheme colorScheme;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 28,
      backgroundColor: tint ?? colorScheme.surfaceContainerHighest,
      child: Icon(icon, color: tint != null ? colorScheme.onErrorContainer : colorScheme.onSurfaceVariant),
    );
  }
}
