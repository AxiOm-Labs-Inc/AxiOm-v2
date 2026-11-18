import 'dart:io';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/cli_sync/cli_bridge.dart';
import 'package:hiddify/features/cli_sync/cli_sync_service.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'connection_notifier.g.dart';

@Riverpod(keepAlive: true)
class ConnectionNotifier extends _$ConnectionNotifier with AppLogger {
  @override
  Stream<ConnectionStatus> build() async* {
    if (Platform.isIOS) {
      await _connectionRepo.setup().mapLeft((l) {
        loggy.error("error setting up connection repository", l);
      }).run();
    }

    listenSelf((previous, next) async {
      if (previous == next) return;
      if (previous case AsyncData(:final value) when !value.isConnected) {
        if (next case AsyncData(value: final Connected _)) {
          await ref.read(hapticServiceProvider.notifier).heavyImpact();

          if (Platform.isAndroid && !ref.read(Preferences.storeReviewedByUser)) {
            if (await InAppReview.instance.isAvailable()) {
              InAppReview.instance.requestReview();
              ref.read(Preferences.storeReviewedByUser.notifier).update(true);
            }
          }
        }
      }
    });

    ref.listen(activeProfileProvider.select((value) => value.asData?.value), (previous, next) async {
      if (previous == null) return;
      final shouldReconnect = next == null || previous.id != next.id;
      if (shouldReconnect) {
        await reconnect(next);
      }
    });
    ref.watch(coreRestartSignalProvider);

    yield* _connectionRepo.watchConnectionStatus().doOnData((event) {
      if (event case Disconnected(connectionFailure: final _?) when PlatformUtils.isDesktop) {
        ref.read(Preferences.startedByUser.notifier).update(false);
      }
      loggy.info("connection status: ${event.format()}");
    });
  }

  ConnectionRepository get _connectionRepo => ref.read(connectionRepositoryProvider);

  Future<void> mayConnect() async {
    if (state case AsyncData(:final value)) {
      if (value case Disconnected()) return _connect();
    }
  }

  Future<void> toggleConnection() async {
    final haptic = ref.read(hapticServiceProvider.notifier);
    // CLI-синхронизация (Windows/Linux): общий OFF кнопки и трея — VPN включён через CLI
    // (с ядром приложения или без) → выключить все движки.
    if (cliSyncSupported && await _stopAllIfCliOn()) return;
    if (state case AsyncError()) {
      await haptic.lightImpact();
      await _connect();
    } else if (state case AsyncData(:final value)) {
      switch (value) {
        case Disconnected():
          await haptic.lightImpact();
          await ref.read(Preferences.startedByUser.notifier).update(true);
          await _connect();
        case Connected():
          // default:
          await haptic.mediumImpact();
          await ref.read(Preferences.startedByUser.notifier).update(false);
          await _disconnect();
        default:
          loggy.warning("switching status, debounce");
      }
    }
  }

  Future<void> reconnect(ProfileEntity? profile) async {
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      await _connectionRepo.reconnect(profile, ref.read(Preferences.disableMemoryLimit)).mapLeft((err) async {
        loggy.warning("error reconnecting", err);
        state = AsyncError(err, StackTrace.current);
        await ref
            .read(dialogNotifierProvider.notifier)
            .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      }).run();
    }
  }

  Future<void> abortConnection() async {
    if (state case AsyncData(:final value)) {
      switch (value) {
        case Connected() || Connecting():
          loggy.debug("aborting connection");
          await _disconnect();
        default:
      }
    }
  }

  /// Если VPN включён (или включается) через CLI — выключить и ядро приложения, и движок CLI. true — сделано.
  Future<bool> _stopAllIfCliOn() async {
    final bridge = ref.read(cliBridgeProvider);
    if (!bridge.active || !await bridge.isCliOn()) return false;
    await ref.read(hapticServiceProvider.notifier).mediumImpact();
    await ref.read(Preferences.startedByUser.notifier).update(false);
    if (state case AsyncData(value: Connected() || Connecting())) {
      await _disconnect();
    }
    await bridge.stopCliEngine();
    return true;
  }

  final _singleStart = SingleCall();

  Future<void> _connect() async {
    _singleStart.run(
      () async {
        await _connectThrottled();
      },
      onIgnored: () {
        loggy.debug("connect called while another connect/disconnect is still running, ignoring");
      },
    );
  }

  Future<void> _connectThrottled() async {
    // CLI-синхронизация (Windows/Linux): start.lock до любой подготовки; VPN уже включён или включается
    // через CLI — второй движок не запускаем.
    final bridge = cliSyncSupported ? ref.read(cliBridgeProvider) : null;
    final reservation = bridge == null ? StartReservation.none() : await bridge.reserveAppStart();
    if (reservation == null) {
      loggy.info("VPN is on (or starting) via the CLI, not starting the app engine");
      await ref.read(Preferences.startedByUser.notifier).update(false);
      return;
    }
    var started = false;
    try {
      started = await _connectReserved(reservation);
    } finally {
      if (bridge != null) await bridge.releaseAppStart(reservation, started: started);
    }
  }

  /// Подключение под резервом запуска; true — ядро приложения запущено.
  Future<bool> _connectReserved(StartReservation reservation) async {
    final initialProfile = await ref.read(activeProfileProvider.future);
    if (initialProfile == null) {
      loggy.info("no active profile, not connecting");
      return false;
    }

    // Refresh subscription before connecting for remote profiles.
    if (initialProfile is RemoteProfileEntity) {
      final notif = ref.read(inAppNotificationControllerProvider);
      notif.showLoadingToast('Обновление подписки...');
      final refresh = ref
          .read(profileRepositoryProvider)
          .requireValue
          .upsertRemote(initialProfile.url)
          .mapLeft((l) {
            loggy.debug("subscription refresh failed [$l]");
            notif.showErrorToast('Ошибка обновления подписки');
          })
          .map((_) {
            loggy.debug("subscription refreshed successfully");
            notif.showSuccessToast('Подписка обновлена');
          })
          .run();
      if (reservation.real) {
        // start.lock чужой стороне виден свежим 60 с: обновление подписки ждём не дольше 40 с.
        await Future.any<Object?>([refresh, Future<Object?>.delayed(const Duration(seconds: 40))]);
      } else {
        await refresh;
      }
    }

    // Re-fetch — subscription may have been updated by the refresh above.
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) return false;
    if (reservation.cancelled) {
      loggy.info("start cancelled by the CLI (disconnect), not connecting");
      await ref.read(Preferences.startedByUser.notifier).update(false);
      return false;
    }

    final result = await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
      loggy.warning("error connecting", err);
      //Go err is not normal object to see the go errors are string and need to be dumped
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      loggy.warning(err);
      await ref.read(Preferences.startedByUser.notifier).update(false);
      state = AsyncError(err, StackTrace.current);
    }).run();
    return result.isRight();
  }

  Future<void> _disconnect() async {
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      state = AsyncError(err, StackTrace.current);
    }).run();
  }
}

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}

class SingleCall {
  bool _running = false;

  Future<T> run<T>(Future<T> Function() task, {required T onIgnored}) async {
    if (_running) return onIgnored;

    _running = true;
    try {
      return await task();
    } finally {
      _running = false;
    }
  }
}

