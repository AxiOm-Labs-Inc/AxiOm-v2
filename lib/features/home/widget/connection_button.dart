import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/theme/theme_extensions.dart';
import 'package:hiddify/core/widget/animated_text.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/notifier/config_option/config_option_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// SharedPreferences key holding the epoch-ms when the VPN connection started.
/// Stored persistently so the elapsed timer survives the Android app process
/// being killed in the background while the VPN service keeps running.
const _connectionStartedAtKey = 'connection_started_at_ms';

// TODO: rewrite
class ConnectionButton extends HookConsumerWidget {
  const ConnectionButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final connectionStatus = ref.watch(connectionNotifierProvider);
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final delay = activeProxy.valueOrNull?.urlTestDelay ?? 0;

    final requiresReconnect = ref.watch(configOptionNotifierProvider).valueOrNull;
    final today = DateTime.now();
    // final animationController = useAnimationController(
    //   duration: const Duration(seconds: 1),
    // )..repeat(reverse: true); // Ensure the animation loops indefinitely

    //   // Listen to the animation's value
    //   final animationValue = useAnimation(Tween<double>(begin: 0.8, end: 1).animate(animationController));

    //   // useEffect(() {
    //   //   if (true) {
    //   // Start repeating animation
    //   //   } else {
    //   //     animationController.stop(); // Stop animation if connected, disconnected, or error
    //   //   }

    //   //   // Cleanup when widget is disposed
    //   //   return animationController.dispose;
    //   // }, [connectionStatus.value]);

    //   // ref.listen(
    //   //   connectionNotifierProvider,
    //   //   (_, next) {
    //   //     if (next case AsyncError(:final error)) {
    //   //       CustomAlertDialog.fromErr(t.presentError(error)).show(context);
    //   //     }
    //   //     if (next case AsyncData(value: Disconnected(:final connectionFailure?))) {
    //   //       CustomAlertDialog.fromErr(t.presentError(connectionFailure)).show(context);
    //   //     }
    //   //   },
    //   // );

    //   // return CircleDesignWidget(
    //   //   onTap: switch (connectionStatus) {
    //   //     // AsyncData(value: Disconnected()) || AsyncError() => () async {
    //   //     //     if (await showExperimentalNotice()) {
    //   //     //       return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    //   //     //     }
    //   //     //   },
    //   //     // AsyncData(value: Connected()) => () async {
    //   //     //     if (requiresReconnect == true && await showExperimentalNotice()) {
    //   //     //       return await ref.read(connectionNotifierProvider.notifier).reconnect(await ref.read(activeProfileProvider.future));
    //   //     //     }
    //   //     //     return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    //   //     //   },
    //   //     _ => () {},
    //   //   },
    //   //   // enabled: switch (connectionStatus) {
    //   //   //   AsyncData(value: Connected()) || AsyncData(value: Disconnected()) || AsyncError() => true,
    //   //   //   _ => false,
    //   //   // },
    //   //   // label: switch (connectionStatus) {
    //   //   //   AsyncData(value: Connected()) when requiresReconnect == true => t.connection.reconnect,
    //   //   //   AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => t.connection.connecting,
    //   //   //   AsyncData(value: final status) => status.present(t),
    //   //   //   _ => "",
    //   //   // },
    //   //   color: switch (connectionStatus) {
    //   //     AsyncData(value: Connected()) when requiresReconnect == true => Colors.teal,
    //   //     AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => Color.fromARGB(255, 157, 139, 1),
    //   //     AsyncData(value: Connected()) => Colors.green.shade900,
    //   //     AsyncData(value: _) => Colors.indigo.shade700, // Color(0xFF3446A5), //buttonTheme.idleColor!,
    //   //     _ => Colors.red,
    //   //   },

    //   //   animated: true ||
    //   //       switch (connectionStatus) {
    //   //         AsyncData(value: Connected()) when requiresReconnect == true => false,
    //   //         AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => false,
    //   //         AsyncData(value: Connected()) => true,
    //   //         AsyncData(value: _) => true,
    //   //         _ => false,
    //   //       },
    //   //   animationValue: animationValue,
    //   // );
    // }

    const buttonTheme = ConnectionButtonTheme.light;

    // isConnected drives the timer — NOT delay, so ping retests don't reset the clock
    final isConnected = connectionStatus.valueOrNull is Connected && requiresReconnect != true;
    final fullyConnected = isConnected && delay > 0 && delay < 65000;

    final elapsedSeconds = useState(0);
    final prefs = ref.watch(sharedPreferencesProvider).requireValue;

    // Persist the connection start time so the elapsed timer survives the app
    // process being killed in the background (Android) while the VPN keeps
    // running. Only clear on a *confirmed* Disconnected — never during the
    // loading/connecting transient at startup, which would wipe the real time.
    final isDisconnected = connectionStatus.valueOrNull is Disconnected;
    useEffect(() {
      if (isConnected) {
        if (prefs.getInt(_connectionStartedAtKey) == null) {
          prefs.setInt(_connectionStartedAtKey, DateTime.now().millisecondsSinceEpoch);
        }
      } else if (isDisconnected) {
        prefs.remove(_connectionStartedAtKey);
      }
      return null;
    }, [isConnected, isDisconnected]);

    useEffect(() {
      if (!isConnected) {
        elapsedSeconds.value = 0;
        return null;
      }
      void tick() {
        final ms = prefs.getInt(_connectionStartedAtKey);
        if (ms == null) {
          elapsedSeconds.value = 0;
          return;
        }
        final secs = (DateTime.now().millisecondsSinceEpoch - ms) ~/ 1000;
        elapsedSeconds.value = secs < 0 ? 0 : secs;
      }
      tick();
      final timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
      return timer.cancel;
    }, [isConnected]);

    var secureLabel =
        (ref.watch(ConfigOptions.enableWarp) && ref.watch(ConfigOptions.warpDetourMode) == WarpDetourMode.warpOverProxy)
        ? t.connection.secure
        : "";
    if (delay <= 0 || delay > 65000 || connectionStatus.value != const Connected()) {
      secureLabel = "";
    }

    // Extra widget below the main label based on connection state
    final Widget? extraWidget = switch (connectionStatus) {
      AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => const _HandshakeIndicator(),
      AsyncData(value: Connected()) when fullyConnected => _ElapsedTimer(seconds: elapsedSeconds.value),
      AsyncError() => _RetryPill(
          onRetry: () async {
            if (ref.read(activeProfileProvider).valueOrNull == null) {
              await ref.read(dialogNotifierProvider.notifier).showNoActiveProfile();
              ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile();
              return;
            }
            if (await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
              await ref.read(connectionNotifierProvider.notifier).toggleConnection();
            }
          },
        ),
      _ => null,
    };

    return _ConnectionButton(
      extraWidget: extraWidget,
      onTap: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => () async {
          final activeProfile = await ref.read(activeProfileProvider.future);
          return await ref.read(connectionNotifierProvider.notifier).reconnect(activeProfile);
        },
        AsyncData(value: Disconnected()) || AsyncError() => () async {
          if (ref.read(activeProfileProvider).valueOrNull == null) {
            await ref.read(dialogNotifierProvider.notifier).showNoActiveProfile();
            ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile();
          }
          if (await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
          }
        },
        AsyncData(value: Connected()) => () async {
          if (requiresReconnect == true &&
              await ref.read(dialogNotifierProvider.notifier).showExperimentalFeatureNotice()) {
            return await ref
                .read(connectionNotifierProvider.notifier)
                .reconnect(await ref.read(activeProfileProvider.future));
          }
          return await ref.read(connectionNotifierProvider.notifier).toggleConnection();
        },
        _ => () {},
      },
      enabled: switch (connectionStatus) {
        AsyncData(value: Connected()) || AsyncData(value: Disconnected()) || AsyncError() => true,
        _ => false,
      },
      label: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => t.connection.reconnect,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => t.connection.connecting,
        AsyncData(value: final status) => status.present(t),
        _ => "",
      },
      buttonColor: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Colors.teal,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => const Color.fromARGB(255, 185, 176, 103),
        AsyncData(value: Connected()) => buttonTheme.connectedColor!,
        AsyncData(value: _) => buttonTheme.idleColor!,
        _ => Colors.red,
      },
      image: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Assets.images.disconnectNorouz,
        AsyncData(value: Connected()) => Assets.images.connectNorouz,
        AsyncData(value: _) => Assets.images.disconnectNorouz,
        _ => Assets.images.disconnectNorouz,
      },
      isConnected: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => false,
        AsyncData(value: Connected()) => true,
        _ => false,
      },
      newButtonColor: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => Colors.teal,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => const Color.fromARGB(255, 185, 176, 103),
        AsyncData(value: Connected()) => buttonTheme.connectedColor!,
        AsyncData(value: _) => buttonTheme.idleColor!,
        _ => Colors.red,
      },
      animated: switch (connectionStatus) {
        AsyncData(value: Connected()) when requiresReconnect == true => false,
        AsyncData(value: Connected()) when delay <= 0 || delay >= 65000 => false,
        AsyncData(value: Connected()) => true,
        AsyncData(value: _) => true,
        _ => false,
      },
      useImage: today.day >= 19 && today.day <= 23 && today.month == 3,
      secureLabel: secureLabel,
    );
  }
}

class _ConnectionButton extends StatelessWidget {
  const _ConnectionButton({
    required this.onTap,
    required this.enabled,
    required this.label,
    required this.buttonColor,
    required this.image,
    required this.useImage,
    required this.newButtonColor,
    required this.animated,
    required this.secureLabel,
    required this.isConnected,
    this.extraWidget,
  });

  final VoidCallback onTap;
  final bool enabled;
  final String label;
  final Color buttonColor;
  final AssetGenImage image;
  final bool useImage;
  final String secureLabel;
  final Color newButtonColor;
  final bool animated;
  final bool isConnected;
  final Widget? extraWidget;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          button: true,
          enabled: enabled,
          label: label,
          child: GestureDetector(
            key: const ValueKey("home_connection_button"),
            onTap: onTap,
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    blurRadius: 24,
                    spreadRadius: 2,
                    color: buttonColor.withValues(alpha: .45),
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: isConnected
                        ? Assets.images.connectButtonConnected.svg(
                            key: const ValueKey("svg_connected"),
                            fit: BoxFit.contain,
                          )
                        : Assets.images.connectButton.svg(
                            key: const ValueKey("svg_disconnected"),
                            fit: BoxFit.contain,
                          ),
                  ),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontSize: 115,
                      fontWeight: FontWeight.w400,
                      color: isConnected
                          ? const Color(0xFF0F6E56)
                          : const Color(0xFF185FA5),
                      height: 1.0,
                    ),
                    child: const Text('Ω'),
                  ),
                ],
              ),
            ).animate(target: enabled ? 0 : 1).blurXY(end: 1),
          ).animate(target: enabled ? 0 : 1).scaleXY(end: .88, curve: Curves.easeIn),
        ),
        const Gap(16),
        ExcludeSemantics(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedText(label, style: Theme.of(context).textTheme.titleMedium),
              if (secureLabel.isNotEmpty) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(FontAwesomeIcons.shieldHalved, size: 16, color: Theme.of(context).colorScheme.secondary),
                    const Gap(4),
                    Text(
                      secureLabel,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ],
                ),
              ],
              if (extraWidget != null) ...[
                const Gap(6),
                extraWidget!,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// "● HANDSHAKE · TLS 1.3" shown while connecting / waiting for first ping
class _HandshakeIndicator extends StatelessWidget {
  const _HandshakeIndicator();

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFD9CD7B);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: const BoxDecoration(
            color: gold,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: gold, blurRadius: 4)],
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          'HANDSHAKE · TLS 1.3',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 2.0,
            fontWeight: FontWeight.w500,
            color: gold,
          ),
        ),
      ],
    );
  }
}

// Elapsed connection time: "00:42:15"
class _ElapsedTimer extends StatelessWidget {
  const _ElapsedTimer({required this.seconds});
  final int seconds;

  String _format() {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _format(),
      style: const TextStyle(
        fontSize: 13,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w400,
        color: Color(0xFF5DCAA5),
        fontFeatures: [],
      ),
    );
  }
}

// Retry pill button shown on error state
class _RetryPill extends StatelessWidget {
  const _RetryPill({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF6B6B);
    return GestureDetector(
      onTap: onRetry,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: red.withValues(alpha: .55)),
          color: red.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.refresh_rounded, size: 14, color: red),
            const SizedBox(width: 6),
            const Text(
              'Повторить',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: red),
            ),
          ],
        ),
      ),
    );
  }
}
