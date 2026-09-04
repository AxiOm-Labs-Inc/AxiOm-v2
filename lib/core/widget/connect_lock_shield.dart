import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Lock shield over a connect button (same idiom as the tariff gate overlay):
/// dims and blurs [child], swallows taps inside its bounds and shows [message]
/// in a pill on top. Used for the mutual UI lock between the main VPN and the
/// tunnel tab — only one of them can run at a time (the logical exclusion in
/// the connection notifier stays as a backstop).
class ConnectLockShield extends StatelessWidget {
  const ConnectLockShield({required this.locked, required this.message, required this.child, super.key});

  final bool locked;
  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!locked) return child;
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(opacity: 0.5, child: child),
        // AbsorbPointer swallows taps for the whole shield bounds, so the
        // button underneath never fires.
        Positioned.fill(
          child: AbsorbPointer(
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                child: Container(color: theme.colorScheme.surface.withValues(alpha: 0.25)),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
