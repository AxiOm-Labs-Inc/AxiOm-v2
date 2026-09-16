import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:axiom/core/app_info/app_info_provider.dart';
import 'package:axiom/core/directories/directories_provider.dart';
import 'package:axiom/core/localization/translations.dart';
import 'package:axiom/core/logger/logger.dart';
import 'package:axiom/core/logger/logger_controller.dart';
import 'package:axiom/core/model/environment.dart';
import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/core/preferences/preferences_migration.dart';
import 'package:axiom/core/preferences/preferences_provider.dart';
import 'package:axiom/features/account/notifier/account_features_provider.dart';
import 'package:axiom/features/app/widget/app.dart';
import 'package:axiom/features/app_update/notifier/app_update_notifier.dart';
import 'package:axiom/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:axiom/features/log/data/log_data_providers.dart';
import 'package:axiom/features/profile/data/profile_data_providers.dart';
import 'package:axiom/features/profile/notifier/active_profile_notifier.dart';
import 'package:axiom/features/proxy/overview/server_list_cache_watcher.dart';
import 'package:axiom/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:axiom/features/window/notifier/window_notifier.dart';
import 'package:axiom/axiomcore/axiom_core_service_provider.dart';
import 'package:axiom/riverpod_observer.dart';
import 'package:axiom/utils/utils.dart';
import 'package:axiom/features/stats/app_stats_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

Future<void> lazyBootstrap(WidgetsBinding widgetsBinding, Environment env) async {
  if (!kIsWeb) {
    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  }
  LoggerController.preInit();
  // Падения идут и в журнал, и в анонимную статистику (features/stats) —
  // до старта сервиса статистики запись в неё просто пропускается.
  FlutterError.onError = (details) {
    Logger.logFlutterError(details);
    if (!details.silent) AppStatsCrashSink.record(details.exception);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stackTrace) {
    AppStatsCrashSink.record(error);
    return Logger.logPlatformDispatcherError(error, stackTrace);
  };

  final stopWatch = Stopwatch()..start();

  final container = ProviderContainer(overrides: [environmentProvider.overrideWithValue(env)]);

  await _init("directories", () => container.read(appDirectoriesProvider.future));
  LoggerController.init(container.read(logPathResolverProvider).appFile().path);

  final appInfo = await _init("app info", () => container.read(appInfoProvider.future));
  await _init("preferences", () => container.read(sharedPreferencesProvider.future));

  await _init("preferences migration", () async {
    try {
      await PreferencesMigration(sharedPreferences: container.read(sharedPreferencesProvider).requireValue).migrate();
    } catch (e, stackTrace) {
      Logger.bootstrap.error("preferences migration failed", e, stackTrace);
      if (env == Environment.dev) rethrow;
      Logger.bootstrap.info("clearing preferences");
      await container.read(sharedPreferencesProvider).requireValue.clear();
    }
  });

  final debug = container.read(debugModeNotifierProvider) || kDebugMode;

  if (PlatformUtils.isDesktop) {
    await _init("window controller", () => container.read(windowNotifierProvider.future));

    final silentStart = container.read(Preferences.silentStart);
    Logger.bootstrap.debug("silent start [${silentStart ? "Enabled" : "Disabled"}]");
    if (!silentStart) {
      await container.read(windowNotifierProvider.notifier).show(focus: false);
    } else {
      Logger.bootstrap.debug("silent start, remain hidden accessible via tray");
    }
    await _init("auto start service", () => container.read(autoStartNotifierProvider.future));
  }
  await _init("logs repository", () => container.read(logRepositoryProvider.future));
  await _init("logger controller", () => LoggerController.postInit(debug));

  Logger.bootstrap.info(appInfo.format());

  await _init("profile repository", () => container.read(profileRepositoryProvider.future));

  await _init("translations", () => container.read(translationsProvider.future));
  await _safeInit("app stats", () async => container.read(appStatsProvider));

  await _safeInit("active profile", () => container.read(activeProfileProvider.future), timeout: 1000);
  // Start syncing the offline server list with the active profile right away.
  container.read(serverListCacheWatcherProvider);
  // Shut the tunnel down whenever the Telemost gate closes.
  container.read(telemostGateGuardProvider);
  await _init("core", () => container.read(axiomCoreServiceProvider).init());

  if (!kIsWeb) {
    // await _safeInit(
    //   "deep link service",
    //   () => container.read(deepLinkNotifierProvider.future),
    //   timeout: 1000,
    // );

    if (PlatformUtils.isDesktop) {
      await _safeInit("system tray", () => container.read(systemTrayNotifierProvider.future), timeout: 1000);
    }

    if (PlatformUtils.isAndroid) {
      await _safeInit("android display mode", () async {
        await FlutterDisplayMode.setHighRefreshRate();
      });
    }
  }

  Logger.bootstrap.info("bootstrap took [${stopWatch.elapsedMilliseconds}ms]");
  stopWatch.stop();

  // Auto-check for updates on startup — fire-and-forget, does not block launch
  unawaited(container.read(appUpdateNotifierProvider.notifier).check());

  runApp(
    ProviderScope(
      parent: container,
      observers: [RiverpodObserver()],
      child: const App(),
    ),
  );

  if (!kIsWeb) {
    FlutterNativeSplash.remove();
  }
  // SentryFlutter.s(DateTime.now().toUtc());
}

Future<T> _init<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  final stopWatch = Stopwatch()..start();
  Logger.bootstrap.info("initializing [$name]");
  Future<T> func() => timeout != null ? initializer().timeout(Duration(milliseconds: timeout)) : initializer();
  try {
    final result = await func();
    Logger.bootstrap.debug("[$name] initialized in ${stopWatch.elapsedMilliseconds}ms");
    return result;
  } catch (e, stackTrace) {
    Logger.bootstrap.error("[$name] error initializing", e, stackTrace);
    rethrow;
  } finally {
    stopWatch.stop();
  }
}

Future<T?> _safeInit<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  try {
    return await _init(name, initializer, timeout: timeout);
  } catch (e) {
    return null;
  }
}
