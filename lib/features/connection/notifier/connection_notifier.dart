import 'dart:async';
import 'dart:io';

import 'package:axiom/core/haptic/haptic_service.dart';
import 'package:axiom/core/localization/translations.dart';
import 'package:axiom/core/notification/in_app_notification_controller.dart';
import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/core/router/dialog/dialog_notifier.dart';
import 'package:axiom/features/connection/data/connection_data_providers.dart';
import 'package:axiom/features/connection/data/connection_repository.dart';
import 'package:axiom/features/connection/model/connection_failure.dart';
import 'package:axiom/features/connection/model/connection_status.dart';
import 'package:axiom/features/connection/model/core_owner.dart';
import 'package:axiom/features/profile/data/profile_data_providers.dart';
import 'package:axiom/features/profile/model/profile_entity.dart';
import 'package:axiom/features/profile/notifier/active_profile_notifier.dart';
import 'package:axiom/features/wbstream_tunnel/model/wbstream_settings.dart';
import 'package:axiom/features/wbstream_tunnel/notifier/wbstream_tunnel_notifier.dart';
import 'package:axiom/axiomcore/init_signal.dart';
import 'package:axiom/utils/utils.dart';
import 'package:axiom/features/stats/app_stats_service.dart';
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
          final stats = ref.read(appStatsProvider);
          unawaited(stats.connectSucceeded(stats.activeProtocol));
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
      if (event case Disconnected(:final connectionFailure)) {
        final stats = ref.read(appStatsProvider);
        if (connectionFailure != null) stats.connectFailed(connectionFailure);
        // Пока ядро у туннельного режима, запрос провайдера ушёл бы через его
        // выход — провайдер человека оттуда не виден.
        if (ref.read(coreOwnerProvider) != CoreOwner.wbstream) stats.disconnected();
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
    // The core belongs to a tunnel mode — a profile change must not hijack
    // it. An explicit VPN connect goes through _connectThrottled, which
    // handles the exclusion itself.
    final owner = ref.read(coreOwnerProvider);
    if (owner == CoreOwner.wbstream) return;
    if (state case AsyncData(:final value) when value == const Connected()) {
      if (profile == null) {
        loggy.info("no active profile, disconnecting");
        return _disconnect();
      }
      loggy.info("active profile changed, reconnecting");
      await ref.read(Preferences.startedByUser.notifier).update(true);
      ref.read(coreOwnerProvider.notifier).state = CoreOwner.vpn;
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
    // Mutual exclusion: a running WBStream tunnel is silently torn down first
    // (its deactivate stops the tunnel-owned core too).
    if (ref.read(wbstreamTunnelNotifierProvider) is! WbstreamIdle) {
      loggy.info("wbstream tunnel active, deactivating before VPN connect");
      await ref.read(wbstreamTunnelNotifierProvider.notifier).deactivate();
    }

    final initialProfile = await ref.read(activeProfileProvider.future);
    if (initialProfile == null) {
      loggy.info("no active profile, not connecting");
      return;
    }
    ref.read(appStatsProvider).connectStarted();

    // Refresh subscription before connecting for remote profiles.
    if (initialProfile is RemoteProfileEntity) {
      final notif = ref.read(inAppNotificationControllerProvider);
      notif.showLoadingToast('Обновление подписки...');
      await ref
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
    }

    // Re-fetch — subscription may have been updated by the refresh above.
    final activeProfile = await ref.read(activeProfileProvider.future);
    if (activeProfile == null) return;

    ref.read(coreOwnerProvider.notifier).state = CoreOwner.vpn;
    await _connectionRepo.connect(activeProfile, ref.read(Preferences.disableMemoryLimit)).mapLeft((
      ConnectionFailure err,
    ) async {
      loggy.warning("error connecting", err);
      ref.read(appStatsProvider).connectFailed(err);
      //Go err is not normal object to see the go errors are string and need to be dumped
      await ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      loggy.warning(err);
      await ref.read(Preferences.startedByUser.notifier).update(false);
      state = AsyncError(err, StackTrace.current);
    }).run();
  }

  Future<void> _disconnect() async {
    await _connectionRepo.disconnect().mapLeft((err) {
      loggy.warning("error disconnecting", err);
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(err.present(ref.read(translationsProvider).requireValue));
      state = AsyncError(err, StackTrace.current);
    }).run();
    ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
  }
}

@Riverpod(keepAlive: true)
Future<bool> serviceRunning(Ref ref) async {
  // ref.watch(coreRestartSignalProvider);
  return await ref
      .watch(connectionNotifierProvider.selectAsync((data) => data.isConnected))
      .onError((error, stackTrace) => false);
}

/// What the home screen shows as «the VPN status»: while the core is owned
/// by a tunnel mode (Telemost or WBStream), the main VPN is reported as
/// disconnected — the services are independent and never share an indicator.
final vpnConnectionStatusProvider = Provider<AsyncValue<ConnectionStatus>>((ref) {
  final status = ref.watch(connectionNotifierProvider);
  final owner = ref.watch(coreOwnerProvider);
  if (owner == CoreOwner.wbstream) {
    return const AsyncData(Disconnected());
  }
  return status;
});

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
