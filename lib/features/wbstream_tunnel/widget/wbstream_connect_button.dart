import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

/// Visual state of the hero button.
enum WbstreamHeroState { idle, connecting, active }

/// The «connected» accent of the app (same teal as branding/server cards).
const _connectedAccent = Color(0xFF5DCAA5);

/// Round connect button for the WBStream tab, ported from the
/// whitelist-bypass Android client («hero»: rotating sweep-gradient outer
/// ring, dashed mid ring, inner panel, pulse ripple, press overshoot) and
/// recolored to the app palette (theme primary while connecting, app teal
/// when active).
class WbstreamConnectButton extends HookWidget {
  const WbstreamConnectButton({
    required this.state,
    required this.onTap,
    super.key,
  });

  final WbstreamHeroState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final connecting = state == WbstreamHeroState.connecting;
    final active = state == WbstreamHeroState.active;
    final accent = active ? _connectedAccent : scheme.primary;

    // Outer ring rotation: 6s per turn while connecting, 18s when active,
    // hidden and stopped when idle.
    final rotation = useAnimationController(duration: const Duration(seconds: 6));
    useEffect(() {
      switch (state) {
        case WbstreamHeroState.connecting:
          rotation.duration = const Duration(seconds: 6);
          rotation.repeat();
        case WbstreamHeroState.active:
          rotation.duration = const Duration(seconds: 18);
          rotation.repeat();
        case WbstreamHeroState.idle:
          rotation.stop();
          rotation.reset();
      }
      return null;
    }, [state]);

    // Sonar pulse: only while connecting (scale 1→1.18, fade 1→0, 1600ms).
    final pulse = useAnimationController(duration: const Duration(milliseconds: 1600));
    useEffect(() {
      if (connecting) {
        pulse.repeat();
      } else {
        pulse.stop();
        pulse.reset();
      }
      return null;
    }, [connecting]);

    // Press feedback: 0.92 on touch-down (100ms), overshoot back (200ms).
    final pressed = useState(false);

    final label = switch (state) {
      WbstreamHeroState.idle => 'ПОДКЛЮЧИТЬ',
      WbstreamHeroState.connecting => 'ОТМЕНА',
      WbstreamHeroState.active => 'ОТКЛЮЧИТЬ',
    };
    final foreground = switch (state) {
      WbstreamHeroState.idle => scheme.onSurfaceVariant,
      WbstreamHeroState.connecting => scheme.primary,
      WbstreamHeroState.active => Colors.white,
    };

    return SizedBox(
      width: 248,
      height: 248,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer rotating sweep-gradient glow.
          if (state != WbstreamHeroState.idle)
            Positioned.fill(
              child: IgnorePointer(
                child: RotationTransition(
                  turns: rotation,
                  child: Opacity(
                    opacity: active ? 0.9 : 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(
                          colors: connecting
                              ? [accent.withValues(alpha: 0.12), accent.withValues(alpha: 0), accent.withValues(alpha: 0.12)]
                              : [
                                  accent.withValues(alpha: 0),
                                  accent.withValues(alpha: 0.35),
                                  accent.withValues(alpha: 0.35),
                                  accent.withValues(alpha: 0),
                                ],
                          stops: connecting ? const [0, 0.5, 1] : const [0, 0.3, 0.7, 1],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Dashed mid ring.
          IgnorePointer(
            child: CustomPaint(
              size: const Size(220, 220),
              painter: _DashedCirclePainter(
                color: state == WbstreamHeroState.idle ? scheme.outlineVariant : accent.withValues(alpha: 0.6),
              ),
            ),
          ),
          // Inner panel circle.
          IgnorePointer(
            child: Container(
              width: 192,
              height: 192,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surface,
                border: Border.all(color: scheme.outlineVariant),
              ),
            ),
          ),
          // Pulse ripple (connecting only).
          if (connecting)
            IgnorePointer(
              child: AnimatedBuilder(
                animation: pulse,
                builder: (context, child) {
                  final t = pulse.value;
                  return Transform.scale(
                    scale: 1 + 0.18 * t,
                    child: Opacity(
                      opacity: 1 - t,
                      child: Container(
                        width: 168,
                        height: 168,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          // The button itself.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => pressed.value = true,
            onTapCancel: () => pressed.value = false,
            onTapUp: (_) => pressed.value = false,
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: AnimatedScale(
              scale: pressed.value ? 0.92 : 1,
              duration: pressed.value ? const Duration(milliseconds: 100) : const Duration(milliseconds: 200),
              curve: pressed.value ? Curves.easeOut : Curves.elasticOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 168,
                height: 168,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: switch (state) {
                    WbstreamHeroState.idle => scheme.surface,
                    WbstreamHeroState.connecting => scheme.primary.withValues(alpha: 0.12),
                    WbstreamHeroState.active => _connectedAccent,
                  },
                  border: active
                      ? null
                      : Border.all(
                          color: connecting ? scheme.primary : scheme.outline,
                        ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.power_settings_new, size: 44, color: foreground),
                    const SizedBox(height: 12),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 2.2,
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      ),
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

class _DashedCirclePainter extends CustomPainter {
  _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 0.5;
    const dash = 4.0;
    const gap = 3.0;
    final circumference = 2 * math.pi * radius;
    final count = (circumference / (dash + gap)).floor();
    final step = (2 * math.pi) / count;
    final dashAngle = step * dash / (dash + gap);
    final rect = Rect.fromCircle(center: center, radius: radius);
    for (var i = 0; i < count; i++) {
      canvas.drawArc(rect, i * step, dashAngle, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedCirclePainter oldDelegate) => oldDelegate.color != color;
}
