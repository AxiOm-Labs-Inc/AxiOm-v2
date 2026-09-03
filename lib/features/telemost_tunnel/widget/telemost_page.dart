import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_features_provider.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/model/core_owner.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/telemost_tunnel/model/telemost_settings.dart';
import 'package:hiddify/features/telemost_tunnel/notifier/telemost_tunnel_notifier.dart';
import 'package:hiddify/features/telemost_tunnel/widget/telemost_connect_button.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The «AxiOm Telemost» tab: tunnel connect/disconnect via on-demand
/// conference creation (built-in service accounts) with the server-side
/// links (Yandex.Disk, A/B failover) as fallback, plus the collapsed
/// manual mode (hand-pasted link).
class TelemostPage extends HookConsumerWidget with PresLogger {
  const TelemostPage({super.key});

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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final notifier = ref.read(telemostTunnelNotifierProvider.notifier);
    final tunnelState = ref.watch(telemostTunnelNotifierProvider);
    final connectionState = ref.watch(connectionNotifierProvider).valueOrNull;
    final coreActive = connectionState is Connected && ref.watch(coreOwnerProvider) == CoreOwner.telemost;
    final initial = notifier.settings;

    final busyTunnel = useState(false);

    // Current conference link (local mirror of settings; updated by actions).
    final linkText = useState(initial.joinLink);

    // Relay parameter fields.
    final fpsController = useTextEditingController(text: '${initial.vp8Fps}');
    final batchController = useTextEditingController(text: '${initial.vp8Batch}');
    final dualTrack = useState(initial.dualTrack);
    final reliable = useState(initial.reliable);

    void save(TelemostSettings Function(TelemostSettings) update) {
      notifier.saveSettings(update(notifier.settings));
    }

    void toastError(String message) {
      ref.read(inAppNotificationControllerProvider).showErrorToast(message);
    }

    /// Full connect path: the main VPN goes down silently (mutual
    /// exclusion), then on-demand conference creation → disk slots A/B →
    /// manual link (all inside activate), then the core starts directly on
    /// the Telemost config — no profile, no shared connection pipeline.
    Future<void> connectTunnel() async {
      busyTunnel.value = true;
      try {
        await ref.read(connectionNotifierProvider.notifier).abortConnection();
        if (!await notifier.ensureConnected()) {
          final err = ref.read(telemostTunnelNotifierProvider);
          toastError(err is TelemostError ? err.message : 'Туннель не поднялся');
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

    /// Stops the telemost-owned core, then the relay and the manager-side
    /// creator (all inside deactivate).
    Future<void> disconnectTunnel() async {
      busyTunnel.value = true;
      try {
        await notifier.deactivate();
      } finally {
        busyTunnel.value = false;
      }
    }

    final tunnelUp = tunnelState is TelemostConnected;
    final heroState =
        busyTunnel.value ||
            tunnelState is TelemostStarting ||
            tunnelState is TelemostConnecting ||
            tunnelState is TelemostLost
        ? TelemostHeroState.connecting
        : tunnelUp || coreActive
        ? TelemostHeroState.active
        : TelemostHeroState.idle;

    void onHeroTap() {
      if (busyTunnel.value) return;
      switch (heroState) {
        case TelemostHeroState.idle:
          connectTunnel();
        case TelemostHeroState.connecting || TelemostHeroState.active:
          disconnectTunnel();
      }
    }

    final statusDetail = switch (tunnelState) {
      TelemostConnected() when coreActive => 'Туннель активен',
      TelemostConnected() => 'Туннель активен, ядро подключается…',
      TelemostStarting(slot: final slot, failedSlot: final failed) =>
        slot == 'on-demand'
            ? 'Создаём звонок…'
            : failed != null && slot != null
            ? 'Сервер $failed не ответил, пробуем сервер $slot…'
            : slot != null
            ? 'Подключаемся (сервер $slot)…'
            : 'Подготовка туннеля…',
      TelemostConnecting(slot: final slot) =>
        slot == 'on-demand'
            ? 'Вход в созданную конференцию…'
            : slot != null
            ? 'Вход в конференцию (сервер $slot)…'
            : 'Вход в конференцию…',
      TelemostLost() => 'Связь прервалась, восстанавливаем…',
      TelemostError(:final message) => 'Ошибка: $message',
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
                child: TelemostConnectButton(state: heroState, onTap: onHeroTap),
              ),
              const Gap(20),
              Text(
                switch (heroState) {
                  TelemostHeroState.idle => 'Отключено',
                  TelemostHeroState.connecting => 'Подключение…',
                  TelemostHeroState.active => 'Подключено',
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
                        TelemostHeroState.idle => theme.colorScheme.onSurfaceVariant,
                        TelemostHeroState.connecting => const Color(0xFFE5B260),
                        TelemostHeroState.active => const Color(0xFF5DCAA5),
                      },
                    ),
                  ),
                  const Gap(6),
                  Flexible(
                    child: Text(
                      statusDetail,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tunnelState is TelemostError
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (heroState == TelemostHeroState.connecting) ...[
                const Gap(8),
                Text(
                  'Подключение в процессе — это может занять до двух минут',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
                          'Имя в звонке выбирается случайно при каждом подключении',
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

              // ── Ручной режим ─────────────────────────────────────────────
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Ручной режим'),
                subtitle: const Text('Своя ссылка на конференцию'),
                children: [
                  if (linkText.value.isNotEmpty)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            linkText.value,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Скопировать',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: linkText.value));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Ссылка скопирована'), duration: Duration(seconds: 2)),
                            );
                          },
                        ),
                      ],
                    ),
                  const Gap(8),
                  TextField(
                    controller: useTextEditingController(text: initial.joinLink),
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Ссылка на конференцию вручную',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      final link = value.trim();
                      if (link.isEmpty || TelemostSettings.isValidJoinLink(link)) {
                        linkText.value = link;
                        save((s) => s.copyWith(joinLink: link));
                      }
                    },
                  ),
                  const Gap(8),
                  Text(
                    'Используется, если автоматическое создание звонка недоступно.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const Gap(8),
                ],
              ),
              const Gap(8),
              Text(
                'Одна ссылка = одно устройство. Не подключайтесь к одной '
                'конференции с двух устройств одновременно.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Gap(16),
            ],
          ),
          if (!entitled) const Positioned.fill(child: _TelemostGateOverlay()),
        ],
      ),
    );
  }
}

/// Blur gate shown over the whole tab when the user's tariff doesn't include
/// AxiOm Telemost: blocks all interaction with the content underneath and
/// either points to the «Стандарт» tariff (account connected) or offers
/// to connect an account first.
class _TelemostGateOverlay extends ConsumerWidget {
  const _TelemostGateOverlay();

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
