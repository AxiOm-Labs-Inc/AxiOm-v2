// Мост приложения AxiOm с CLI (только Windows и Linux): один VPN на двоих (DESIGN-sync v1 + v2).
//
// Пассивная часть (CliSyncService: app-location, app-state, команды CLI, start.lock) работает, если CLI
// есть на машине (его файл или каталог настроек). Активная часть — проверка движка CLI раз в 2 с и команды
// `axiom disconnect` / `axiom use --select` — только с CLI установщика (или заменённым старым) версии
// SBX ≥ 1.4.0. Android и прочие платформы не затрагиваются.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/cli_sync/cli_engine_probe.dart';
import 'package:hiddify/features/cli_sync/cli_locations.dart';
import 'package:hiddify/features/cli_sync/cli_process.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/cli_sync_service.dart';
import 'package:hiddify/features/cli_sync/cli_version.dart';
import 'package:hiddify/features/cli_sync/legacy_cli_migration.dart';
import 'package:hiddify/features/cli_sync/server_selection_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/server_list_cache.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Синхронизация с CLI возможна только на настольных Windows и Linux.
bool get cliSyncSupported => !kIsWeb && (Platform.isWindows || Platform.isLinux);

/// Пути старых CLI, заменённых на SBX: ими можно пользоваться, если CLI установщика нет.
const cliSyncMigratedPathsKey = 'cli_sync_migrated_paths';

class CliEngineNotifier extends StateNotifier<CliEngineState> {
  CliEngineNotifier() : super(CliEngineState.stopped);

  void publish(CliEngineState next) {
    if (next != state) state = next;
  }
}

/// Состояние VPN через CLI: работает ли его движок или включается (start.lock), идёт ли команда CLI.
final cliEngineProvider = StateNotifierProvider<CliEngineNotifier, CliEngineState>((ref) => CliEngineNotifier());

final cliBridgeProvider = Provider<CliBridge>((ref) {
  final bridge = CliBridge(ref);
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// Движок приложения и его настройки для CliSyncService.
class _AppEngineAdapter implements AppEngineAdapter {
  _AppEngineAdapter(this._ref);

  final Ref _ref;

  static AppEngineStatus statusOf(AsyncValue<ConnectionStatus> value) => switch (value) {
    AsyncData(value: Connected()) => AppEngineStatus.connected,
    AsyncData(value: Connecting()) => AppEngineStatus.connecting,
    AsyncData(value: Disconnecting()) => AppEngineStatus.disconnecting,
    AsyncData(value: Disconnected()) => AppEngineStatus.disconnected,
    AsyncError() => AppEngineStatus.failed,
    _ => AppEngineStatus.disconnected,
  };

  @override
  AppEngineStatus get status => statusOf(_ref.read(connectionNotifierProvider));

  @override
  String? get rawTag => _ref.read(activeProxyNotifierProvider).valueOrNull?.tag;

  @override
  ServerSelection get storedSelection => _ref.read(serverSelectionProvider);

  OutboundGroup? get _loadedGroup =>
      status == AppEngineStatus.connected ? _ref.read(proxiesOverviewNotifierProvider).valueOrNull : null;

  @override
  List<ServerOption> get knownOptions {
    final group = _loadedGroup;
    if (group != null) {
      final live = ServerOption.parse(group);
      if (live.isNotEmpty) return live;
    }
    return readCachedServerOptions(_ref.read(sharedPreferencesProvider).requireValue);
  }

  @override
  Future<void> persistSelection(ServerSelection selection) async {
    final notifier = _ref.read(serverSelectionProvider.notifier);
    if (selection.isAuto) {
      await notifier.update(c: autoCountryKey);
    } else {
      await notifier.set(selection);
    }
  }

  @override
  Future<String?> applyToEngine(ServerSelection selection) async {
    final repo = _ref.read(proxyRepositoryProvider);
    var group = _loadedGroup;
    if (group == null) {
      try {
        group = (await repo.watchProxies().first.timeout(const Duration(seconds: 4))).getOrElse((_) => null);
      } catch (_) {}
    }
    if (group == null) return 'список серверов ядра приложения недоступен';
    final groupTag = group.tag;
    var selectedTag = group.selected;
    var options = ServerOption.parse(group);
    final String rawTag;
    if (selection.isAuto) {
      var best = ServerOption.fastest(options);
      if (best == null) {
        // Задержек ещё нет: замерить и дождаться результата (карточка выбора может быть не на экране).
        final tested = await repo.urlTest(groupTag).run();
        if (tested.isLeft()) return 'замер серверов не удался';
        try {
          final measured = await repo
              .watchProxies()
              .map((e) => e.getOrElse((_) => null))
              .where((g) => g != null && ServerOption.fastest(ServerOption.parse(g)) != null)
              .first
              .timeout(const Duration(seconds: 6));
          final fresh = measured!;
          selectedTag = fresh.selected;
          options = ServerOption.parse(fresh);
          best = ServerOption.fastest(options);
        } catch (_) {}
      }
      if (best == null) return 'ни один сервер не ответил на замер — авто не выбрать';
      rawTag = best.rawTag;
    } else {
      final option = ServerOption.find(options, selection.c, selection.p, selection.t);
      if (option == null) return 'сервера «${selection.toSelectArg()}» нет в ядре приложения';
      rawTag = option.rawTag;
    }
    if (selectedTag == rawTag) return null;
    final selected = await repo.selectProxy(groupTag, rawTag).run();
    return selected.match<String?>((failure) => 'не удалось переключить сервер: $failure', (_) => null);
  }

  @override
  Future<String?> stopEngine() async {
    await _ref.read(Preferences.startedByUser.notifier).update(false);
    await _ref.read(connectionNotifierProvider.notifier).abortConnection();
    for (var i = 0; i < 100; i++) {
      final value = _ref.read(connectionNotifierProvider);
      if (value case AsyncError(:final error)) return 'ядро приложения не остановилось: $error';
      if (value case AsyncData(value: Disconnected())) return null;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return 'приложение не отключилось за 10 с';
  }
}

class CliBridge with AppLogger {
  CliBridge(this._ref);

  final Ref _ref;

  static const _rediscoverEvery = Duration(seconds: 10);
  static const _probeEvery = Duration(seconds: 2);

  bool _started = false;
  bool _disposed = false;
  Timer? _tickTimer;
  Timer? _probeTimer;

  String? _syncDir;
  String? _stateFile;
  String? _configDir;
  AppLocation? _location;
  CliSyncService? _service;

  /// CLI, которым приложение пользуется: SBX ≥ 1.4.0 (установщика или заменённый старый).
  String? _binary;
  final _versionCache = <String, (String, bool)>{};

  int _lastDiscoveryMs = 0;
  bool _ticking = false;
  Future<CliEngineState>? _probeInFlight;
  bool _lastRunning = false;
  bool _cliRunning = false;
  ServerSelection? _pendingSelection;

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  CliEngineNotifier get _engine => _ref.read(cliEngineProvider.notifier);

  /// Пассивная синхронизация включена (CLI есть на машине).
  bool get active => _service != null;

  Future<void>? _startFuture;

  /// Запуск (один раз, после инициализации ядра). Ошибки не выпускает наружу.
  Future<void> start() => _startFuture ??= _start();

  /// Подключение в первые секунды после старта не должно проскочить мимо start.lock и проверки CLI.
  Future<void> _awaitStarted() async {
    final started = _startFuture;
    if (started != null) await started.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  /// Записать app-state.json сейчас (например, перед командой CLI после остановки ядра приложения).
  Future<void> publishState() async => _service?.writeState(force: true);

  Future<void> _start() async {
    if (!cliSyncSupported || _started) return;
    _started = true;
    try {
      final dirs = await _ref.read(appDirectoriesProvider.future);
      final env = Platform.environment;
      final isWindows = Platform.isWindows;
      final syncDir = CliLocations.syncDir(dirs.baseDir.path, isWindows: isWindows);
      _syncDir = syncDir;
      _stateFile = CliLocations.stateFile(isWindows: isWindows, env: env);
      _configDir = CliLocations.configDir(isWindows: isWindows, env: env);
      // Файл плагина shared_preferences — всегда в каталоге поддержки, префикс portable. — у portable Windows.
      final support = await getApplicationSupportDirectory();
      _location = AppLocation(
        supportDir: dirs.baseDir.absolute.path,
        syncDir: Directory(syncDir).absolute.path,
        prefsFile: p.join(support.absolute.path, 'shared_preferences.json'),
        prefsPrefix: isWindows && Environment.isPortable ? 'portable.' : 'flutter.',
        exe: Platform.resolvedExecutable,
        pid: pid,
        tsMs: 0,
      );
      await _discover();
    } catch (e, st) {
      loggy.warning('cli-sync: start failed', e, st);
      return;
    }
    if (_disposed) return;
    _ref.listen(connectionNotifierProvider, (_, _) => unawaited(_service?.writeState(force: true)));
    _ref.listen(serverSelectionProvider, (_, _) => unawaited(_service?.writeState(force: true)));
    _tickTimer = Timer.periodic(controlPollInterval, (_) => unawaited(_tick()));
    _probeTimer = Timer.periodic(_probeEvery, (_) => unawaited(_probe()));
    unawaited(_tick());
    unawaited(_probe());
  }

  /// Чистый выход: снять свой start.lock, удалить app-state.json.
  Future<void> shutdown() async {
    _disposed = true;
    _stopTimers();
    await _service?.shutdown();
  }

  void dispose() {
    _disposed = true;
    _stopTimers();
  }

  void _stopTimers() {
    _tickTimer?.cancel();
    _probeTimer?.cancel();
    _tickTimer = null;
    _probeTimer = null;
  }

  List<String> get _runtimeCandidates {
    final prefs = _ref.read(sharedPreferencesProvider).valueOrNull;
    return CliLocations.runtimeCandidates(
      isWindows: Platform.isWindows,
      exeDir: File(Platform.resolvedExecutable).parent.path,
      env: Platform.environment,
      migrated: prefs?.getStringList(cliSyncMigratedPathsKey) ?? const [],
    );
  }

  /// SBX ≥ 1.4.0 по `version`; результат кэшируется по размеру и времени изменения файла.
  Future<bool> _isCompatible(String path, FileStat stat) async {
    final stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    final cached = _versionCache[path];
    if (cached != null && cached.$1 == stamp) return cached.$2;
    final result = await runCliProcess(path, const ['version'], timeout: const Duration(seconds: 10));
    final ok = isCompatibleSbxRun(result);
    if (!ok) loggy.info('cli-sync: $path is not SBX >= 1.4.0 (${result.message}); CLI features off');
    _versionCache[path] = (stamp, ok);
    return ok;
  }

  /// Найти CLI. Пассивная синхронизация — если есть хоть какой-то CLI или его каталог настроек;
  /// команды и проверка движка — только с SBX ≥ 1.4.0.
  Future<void> _discover() async {
    _lastDiscoveryMs = _nowMs;
    String? compatible;
    var anyCli = false;
    for (final path in _runtimeCandidates) {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) continue;
      anyCli = true;
      if (await _isCompatible(path, stat)) {
        compatible = path;
        break;
      }
    }
    final configDir = _configDir;
    final hasConfig = configDir != null && await Directory(configDir).exists();
    if (compatible != _binary) loggy.info('cli-sync: CLI ${compatible ?? "SBX >= 1.4.0 not found"}');
    _binary = compatible;
    final active = anyCli || hasConfig;
    final syncDir = _syncDir;
    if (active && _service == null && syncDir != null) {
      loggy.info('cli-sync: active, sync dir $syncDir');
      final locationPath = CliLocations.appLocationFile(isWindows: Platform.isWindows, env: Platform.environment);
      final service = CliSyncService(
        files: CliSyncFiles(Directory(syncDir)),
        adapter: _AppEngineAdapter(_ref),
        locationFile: locationPath == null ? null : File(locationPath),
        location: _location,
        log: (m) => loggy.info('cli-sync: $m'),
      );
      await service.start();
      _service = service;
    } else if (!active && _service != null) {
      loggy.info('cli-sync: CLI is gone, sync off');
      await _service!.shutdown();
      _service = null;
      _engine.publish(CliEngineState.stopped);
    }
  }

  Future<void> _tick() async {
    if (_ticking || _disposed) return;
    _ticking = true;
    try {
      if (_nowMs - _lastDiscoveryMs >= _rediscoverEvery.inMilliseconds) await _discover();
      await _service?.tick();
    } catch (e, st) {
      loggy.warning('cli-sync: tick failed', e, st);
    } finally {
      _ticking = false;
    }
  }

  Future<CliEngineState> _probe() => _probeInFlight ??= _probeOnce().whenComplete(() => _probeInFlight = null);

  Future<CliEngineState> _probeOnce() async {
    final current = _ref.read(cliEngineProvider);
    var next = CliEngineState.stopped;
    try {
      final service = _service;
      final stateFile = _stateFile;
      if (service != null && _binary != null && stateFile != null && await File(stateFile).exists()) {
        final api = parseCliApiSettings(await File(stateFile).readAsString());
        if (api != null) next = await probeCliEngine(api);
      }
      if (service != null) {
        final lock = await service.foreignStartLock();
        if (lock != null) next = next.copyWith(starting: true);
      }
    } catch (e) {
      loggy.debug('cli-sync: probe failed: $e');
    }
    if (_disposed) return next;
    if (next.running != _lastRunning) loggy.info('cli-sync: CLI engine ${next.running ? "running" : "stopped"}');
    _lastRunning = next.running;
    final published = next.copyWith(busy: current.busy);
    _engine.publish(published);
    return published;
  }

  /// VPN включён или включается через CLI (свежая проверка, до 1 с).
  Future<bool> isCliOn() async {
    await _awaitStarted();
    if (!active) return false;
    return (await _probe()).on;
  }

  /// Резерв запуска движка приложения: до подготовки (обновления подписки) и запуска ядра.
  /// [StartReservation.none] — синхронизация выключена; null — VPN уже включён (или включается) через CLI.
  Future<StartReservation?> reserveAppStart() async {
    await _awaitStarted();
    final service = _service;
    if (!cliSyncSupported || service == null) return StartReservation.none();
    final reservation = await service.reserveStart();
    if (reservation == null) return null;
    // Замок взят — теперь проверить, не работает ли уже движок CLI.
    if ((await _probe()).running) {
      await service.releaseStart(reservation);
      return null;
    }
    return reservation;
  }

  /// Снять резерв; если ядро приложения запустилось — сначала дождаться Connected (до 5 с),
  /// чтобы app-state ни на миг не показал «выключено».
  Future<void> releaseAppStart(StartReservation reservation, {required bool started}) async {
    final service = _service;
    if (!reservation.real || service == null) return;
    if (started) {
      for (var i = 0; i < 50 && service.adapter.status != AppEngineStatus.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    await service.releaseStart(reservation);
  }

  /// Выключить VPN через CLI: дождаться его запуска, если он идёт (до 30 с), затем `axiom disconnect`.
  /// Linux: если он не смог, а движок CLI всё ещё работает, — `pkexec systemctl stop axiom.service`
  /// (сам `axiom` под root не запускается), затем проверка заново.
  Future<void> stopCliEngine() async {
    final service = _service;
    if (service != null) {
      for (var i = 0; i < 60 && await service.foreignStartLock() != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    final result = await _runCli(['disconnect'], toastOnError: false);
    if (result == null || result.ok) return;
    if (Platform.isLinux && (await _probe()).running) {
      final command = CliLocations.pkexecStopCommand(exists: (path) => File(path).existsSync());
      if (command != null) {
        loggy.info('cli-sync: axiom disconnect failed (${result.message}), stopping the service via pkexec');
        final elevated = await _runCli(
          command.sublist(1),
          executable: command.first,
          timeout: const Duration(minutes: 2),
          toastOnError: false,
        );
        if (!(await _probe()).running) return;
        _toastError(elevated?.message ?? result.message);
        return;
      }
    }
    _toastError(result.message);
  }

  /// Выбор сервера пользователем, пока VPN включён через CLI: `axiom use --select "C|P|T"`.
  /// Выбор, сделанный во время другой команды CLI, не теряется: уходит последний — после неё.
  Future<void> useSelectionInCli(ServerSelection selection) async {
    _pendingSelection = selection;
    while (!_cliRunning && _pendingSelection != null) {
      final next = _pendingSelection!;
      _pendingSelection = null;
      await _runCli(['use', '--select', next.toSelectArg()]);
    }
  }

  void _toastError(String message) {
    final t = _ref.read(translationsProvider).requireValue;
    _ref.read(inAppNotificationControllerProvider).showErrorToast(t.cliSync.commandFailed(error: message));
  }

  /// Запуск CLI (без окна, stdin закрыт). Пока он работает, опрос команд CLI идёт дальше —
  /// CLI может прислать приложению команду и ждать ответа. null — CLI нет.
  Future<CliRunResult?> _runCli(
    List<String> args, {
    String? executable,
    List<String> prefix = const [],
    Duration timeout = const Duration(seconds: 30),
    bool toastOnError = true,
  }) async {
    final binary = _binary;
    if (binary == null) {
      _ref.read(inAppNotificationControllerProvider).showErrorToast(
        _ref.read(translationsProvider).requireValue.cliSync.notFound,
      );
      return null;
    }
    _cliRunning = true;
    _engine.publish(_ref.read(cliEngineProvider).copyWith(busy: true));
    try {
      final exe = executable ?? binary;
      final fullArgs = [...prefix, ...args];
      loggy.info('cli-sync: $exe ${fullArgs.join(" ")}');
      final result = await runCliProcess(exe, fullArgs, timeout: timeout);
      if (!result.ok) {
        loggy.warning('cli-sync: ${args.first} failed: $result');
        if (toastOnError) _toastError(result.message);
      }
      return result;
    } finally {
      _cliRunning = false;
      _engine.publish(_ref.read(cliEngineProvider).copyWith(busy: false));
      await _probe();
      final pending = _pendingSelection;
      if (pending != null) {
        _pendingSelection = null;
        unawaited(useSelectionInCli(pending));
      }
    }
  }
}

const legacyCliMigrationVersionKey = 'cli_sync_legacy_migration_version';

/// Раз на версию приложения заменить старый Go-CLI (cli-v0.0.x) на SBX ≥ 1.4.0. Метка версии
/// ставится, только если ни одна замена не сорвалась. Ошибки только в журнал.
Future<void> runLegacyCliMigrationOnce(ProviderContainer container) async {
  if (!cliSyncSupported) return;
  final log = Loggy<AppLogger>('LegacyCliMigration');
  try {
    final prefs = await container.read(sharedPreferencesProvider.future);
    final info = await container.read(appInfoProvider.future);
    final version = '${info.version}+${info.buildNumber}';
    if (prefs.getString(legacyCliMigrationVersionKey) == version) return;
    final isWindows = Platform.isWindows;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final env = Platform.environment;
    final report = await migrateLegacyCli(
      isWindows: isWindows,
      env: env,
      installerPaths: CliLocations.installerPaths(isWindows: isWindows, exeDir: exeDir, env: env),
      installerSources: CliLocations.installerSourceCandidates(isWindows: isWindows, exeDir: exeDir, env: env),
      tempDir: Directory.systemTemp,
    );
    log.info('cli-sync: legacy CLI check for $version: $report');
    if (report.replaced.isNotEmpty) {
      final known = prefs.getStringList(cliSyncMigratedPathsKey) ?? const [];
      await prefs.setStringList(cliSyncMigratedPathsKey, {...known, ...report.replaced}.toList());
    }
    if (report.hasFailures) {
      log.warning('cli-sync: some legacy CLI were not replaced, will retry on next start');
      return;
    }
    await prefs.setString(legacyCliMigrationVersionKey, version);
  } catch (e, st) {
    log.warning('cli-sync: legacy CLI migration failed', e, st);
  }
}
