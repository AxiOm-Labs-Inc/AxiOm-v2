import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/widget/connect_lock_shield.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_features_provider.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/model/core_owner.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/wbstream_tunnel/model/wbstream_settings.dart';
import 'package:hiddify/features/wbstream_tunnel/notifier/wbstream_tunnel_notifier.dart';
import 'package:hiddify/features/wbstream_tunnel/widget/wbstream_connect_button.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The «AxiOm Telemost» tab: tunnel connect/disconnect through the static
/// conference room held open server-side. No accounts, no
/// manual links — just the room id and the relay tuning knobs.
class WbstreamPage extends HookConsumerWidget with PresLogger {
  const WbstreamPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // The native relay exists only on Android — on desktop the tunnel can't
    // work at all, so show a placeholder instead of a broken control page.
    if (PlatformUtils.isDesktop) {
      return Scaffold(
        appBar: AppBar(title: const Text('AxiOm Telemost')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_android_rounded, size: 48, color: theme.colorScheme.onSurfaceVariant),
                const Gap(16),
                Text(
                  'AxiOm Telemost доступен в Android-приложении',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                const Gap(8),
                Text(
                  'Обход белых списков работает только на телефоне',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final notifier = ref.read(wbstreamTunnelNotifierProvider.notifier);
    final tunnelState = ref.watch(wbstreamTunnelNotifierProvider);
    final connectionState = ref.watch(connectionNotifierProvider).valueOrNull;
    final coreOwner = ref.watch(coreOwnerProvider);
    final coreActive = connectionState is Connected && coreOwner == CoreOwner.wbstream;
    // UI lock: the core is up but NOT owned by this tunnel (main VPN
    // connecting/connected, or a surviving core after an app restart) —
    // shield the connect button instead of silently tearing the VPN down.
    final vpnActive = coreOwner != CoreOwner.wbstream && connectionState != null && !connectionState.isDisconnected;
    final initial = notifier.settings;

    final busyTunnel = useState(false);

    // Relay parameter fields.
    final fpsController = useTextEditingController(text: '${initial.vp8Fps}');
    final batchController = useTextEditingController(text: '${initial.vp8Batch}');
    final dualTrack = useState(initial.dualTrack);
    final reliable = useState(initial.reliable);

    void save(WbstreamSettings Function(WbstreamSettings) update) {
      notifier.saveSettings(update(notifier.settings));
    }

    void toastError(String message) {
      ref.read(inAppNotificationControllerProvider).showErrorToast(message);
    }

    /// Full connect path: the main VPN goes down silently (mutual
    /// exclusion), then the relay joins the static WB Stream room (inside
    /// activate), then the core starts directly on the WBStream config —
    /// no profile, no shared connection pipeline.
    Future<void> connectTunnel() async {
      busyTunnel.value = true;
      try {
        await ref.read(connectionNotifierProvider.notifier).abortConnection();
        if (!await notifier.ensureConnected()) {
          final err = ref.read(wbstreamTunnelNotifierProvider);
          toastError(err is WbstreamError ? err.message : 'Туннель не поднялся');
          notifier.resetError();
          return;
        }
        if (!await notifier.startCore()) {
          toastError('Не удалось запустить ядро');
          return;
        }
      } finally {
        busyTunnel.value = false;
      }
    }

    /// Stops the wbstream-owned core, then the relay (all inside deactivate).
    Future<void> disconnectTunnel() async {
      busyTunnel.value = true;
      try {
        await notifier.deactivate();
      } finally {
        busyTunnel.value = false;
      }
    }

    final tunnelUp = tunnelState is WbstreamConnected;
    final heroState =
        busyTunnel.value ||
            tunnelState is WbstreamStarting ||
            tunnelState is WbstreamConnecting ||
            tunnelState is WbstreamLost
        ? WbstreamHeroState.connecting
        : tunnelUp || coreActive
        ? WbstreamHeroState.active
        : WbstreamHeroState.idle;

    void onHeroTap() {
      if (busyTunnel.value) return;
      switch (heroState) {
        case WbstreamHeroState.idle:
          connectTunnel();
        case WbstreamHeroState.connecting || WbstreamHeroState.active:
          disconnectTunnel();
      }
    }

    final statusDetail = switch (tunnelState) {
      WbstreamConnected() when coreActive => 'Туннель активен',
      WbstreamConnected() => 'Туннель активен, ядро подключается…',
      WbstreamStarting() => 'Подготовка туннеля…',
      WbstreamConnecting() => 'Вход в конференцию…',
      WbstreamLost() => 'Связь прервалась, восстанавливаем…',
      WbstreamError(:final message) => 'Ошибка: $message',
      _ => 'Готов к подключению',
    };

    final entitled = ref.watch(telemostEntitledProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('AxiOm Telemost')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // ── Управление туннелем ──────────────────────────────────────
              const Gap(16),
              Center(
                child: ConnectLockShield(
                  locked: vpnActive,
                  message: 'Активен VPN — сначала отключите его',
                  child: WbstreamConnectButton(state: heroState, onTap: onHeroTap),
                ),
              ),
              const Gap(20),
              Text(
                switch (heroState) {
                  WbstreamHeroState.idle => 'Отключено',
                  WbstreamHeroState.connecting => 'Подключение…',
                  WbstreamHeroState.active => 'Подключено',
                },
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const Gap(6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: switch (heroState) {
                        WbstreamHeroState.idle => theme.colorScheme.onSurfaceVariant,
                        WbstreamHeroState.connecting => const Color(0xFFE5B260),
                        WbstreamHeroState.active => const Color(0xFF5DCAA5),
                      },
                    ),
                  ),
                  const Gap(6),
                  Flexible(
                    child: Text(
                      statusDetail,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tunnelState is WbstreamError
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (heroState == WbstreamHeroState.connecting) ...[
                const Gap(8),
                Text(
                  'Подключение в процессе — это может занять до двух минут',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const Gap(16),
              const Divider(),

              // ── Настройки туннеля ────────────────────────────────────────
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Настройки туннеля'),
                children: [
                  Row(
                    children: [
                      Icon(Icons.shuffle_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                      const Gap(8),
                      Expanded(
                        child: Text(
                          'Имя в трансляции выбирается случайно при каждом подключении',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const Gap(12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: fpsController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'VP8 FPS', border: OutlineInputBorder()),
                          onChanged: (value) {
                            final fps = int.tryParse(value.trim());
                            if (fps != null && fps > 0) save((s) => s.copyWith(vp8Fps: fps));
                          },
                        ),
                      ),
                      const Gap(12),
                      Expanded(
                        child: TextField(
                          controller: batchController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'VP8 Batch', border: OutlineInputBorder()),
                          onChanged: (value) {
                            final batch = int.tryParse(value.trim());
                            if (batch != null && batch > 0) save((s) => s.copyWith(vp8Batch: batch));
                          },
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Dual track'),
                    value: dualTrack.value,
                    onChanged: (v) {
                      dualTrack.value = v;
                      save((s) => s.copyWith(dualTrack: v));
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Reliable mode'),
                    value: reliable.value,
                    onChanged: (v) {
                      reliable.value = v;
                      save((s) => s.copyWith(reliable: v));
                    },
                  ),
                  const Gap(8),
                ],
              ),
              const Gap(16),
            ],
          ),
          if (!entitled) const Positioned.fill(child: _WbstreamGateOverlay()),
        ],
      ),
    );
  }
}

/// Blur gate shown over the whole tab when the user's tariff doesn't include
/// the whitelist-bypass entitlement: blocks all interaction with the content
/// underneath and either points to the «Стандарт» tariff (account connected)
/// or offers to connect an account first. Shared with the Telemost tab — the
/// server-side entitlement covers both bypass modes.
class _WbstreamGateOverlay extends ConsumerWidget {
  const _WbstreamGateOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final connected = ref.watch(accountNotifierProvider) is AccountStateConnected;

    return Stack(
      children: [
        // Swallow taps so the blurred content isn't interactive.
        Positioned.fill(
          child: AbsorbPointer(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainer,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline_rounded, size: 40, color: theme.colorScheme.primary),
                    const Gap(12),
                    Text(
                      connected
                          ? 'AxiOm Telemost доступен в тарифе Стандарт'
                          : 'Подключите аккаунт, чтобы проверить доступ к AxiOm Telemost',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (!connected) ...[
                      const Gap(16),
                      FilledButton(
                        onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showConnectAccount(),
                        child: const Text('Подключить аккаунт'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
