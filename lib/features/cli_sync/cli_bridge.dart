// Мост приложения AxiOm с CLI (только Windows и Linux): один VPN на двоих.
//
// - app-state.json: состояние VPN приложения и выбор сервера — при изменениях и пульсом раз в 2 с;
// - control.json: команды CLI (disconnect, select) — раз в 1 с, ответ в control-ack.json;
// - движок CLI: раз в 2 с GET /version его clash API → cliEngineProvider;
// - действия пользователя, пока работает движок CLI, уходят командами `axiom disconnect` / `axiom use --select`.
// Ничего не делает, если нет ни CLI установщика, ни состояния CLI. Протокол — cli_sync_protocol.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/cli_sync/cli_engine_probe.dart';
import 'package:hiddify/features/cli_sync/cli_locations.dart';
import 'package:hiddify/features/cli_sync/cli_process.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/legacy_cli_migration.dart';
import 'package:hiddify/features/cli_sync/server_selection_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/server_list_cache.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Синхронизация с CLI возможна только на настольных Windows и Linux.
bool get cliSyncSupported => !kIsWeb && (Platform.isWindows || Platform.isLinux);

class CliEngineNotifier extends StateNotifier<CliEngineState> {
  CliEngineNotifier() : super(CliEngineState.stopped);

  void publish(CliEngineState next) {
    if (next != state) state = next;
  }
}

/// Состояние движка CLI: работает ли он, его текущий сервер и идёт ли команда CLI из приложения.
final cliEngineProvider = StateNotifierProvider<CliEngineNotifier, CliEngineState>((ref) => CliEngineNotifier());

final cliBridgeProvider = Provider<CliBridge>((ref) {
  final bridge = CliBridge(ref);
  ref.onDispose(bridge.dispose);
  return bridge;
});

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
  CliSyncFiles? _files;
  String? _binary;
  String? _stateFile;

  AppSyncState? _lastWritten;
  int _lastWriteMs = 0;
  int _lastDiscoveryMs = 0;
  bool _ticking = false;
  bool _writing = false;
  bool _executing = false;
  Future<CliEngineState>? _probeInFlight;
  bool _lastRunning = false;
  File? _prefsFile;
  String? _prefsStamp;

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  CliEngineNotifier get _engine => _ref.read(cliEngineProvider.notifier);

  /// Запуск (один раз, после инициализации ядра). Ошибки не выпускает наружу.
  Future<void> start() async {
    if (!cliSyncSupported || _started) return;
    _started = true;
    try {
      final dirs = await _ref.read(appDirectoriesProvider.future);
      _syncDir = CliLocations.syncDir(dirs.baseDir.path, isWindows: Platform.isWindows);
      _stateFile = CliLocations.stateFile(isWindows: Platform.isWindows, env: Platform.environment);
      // Настройки приложения на диске (их же пишет CLI): файл плагина shared_preferences.
      final support = await getApplicationSupportDirectory();
      _prefsFile = File(p.join(support.path, 'shared_preferences.json'));
      _prefsStamp = await _stampOf(_prefsFile!);
      await _discover();
    } catch (e, st) {
      loggy.warning('cli-sync: start failed', e, st);
      return;
    }
    if (_disposed) return;
    _ref.listen(connectionNotifierProvider, (_, _) => unawaited(_writeState(force: true)));
    _ref.listen(serverSelectionProvider, (_, _) => unawaited(_writeState(force: true)));
    _tickTimer = Timer.periodic(controlPollInterval, (_) => unawaited(_tick()));
    _probeTimer = Timer.periodic(_probeEvery, (_) => unawaited(_probe()));
    unawaited(_tick());
    unawaited(_probe());
  }

  /// Чистый выход: убрать app-state.json, чтобы CLI сразу видел, что приложения нет.
  Future<void> shutdown() async {
    _disposed = true;
    _stopTimers();
    await _files?.deleteAppState();
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

  /// Найти CLI установщика и состояние CLI; без обоих синхронизация выключена.
  Future<void> _discover() async {
    _lastDiscoveryMs = _nowMs;
    String? binary;
    for (final path in CliLocations.binaryCandidates(
      isWindows: Platform.isWindows,
      exeDir: File(Platform.resolvedExecutable).parent.path,
      env: Platform.environment,
    )) {
      if (await File(path).exists()) {
        binary = path;
        break;
      }
    }
    final stateFile = _stateFile;
    final hasState = stateFile != null && await File(stateFile).exists();
    final active = binary != null || hasState;
    if (binary != _binary) loggy.info('cli-sync: CLI binary ${binary ?? "not found"}');
    _binary = binary;
    final syncDir = _syncDir;
    if (active && _files == null && syncDir != null) {
      loggy.info('cli-sync: active, sync dir $syncDir');
      _files = CliSyncFiles(Directory(syncDir));
      _lastWritten = null;
    } else if (!active && _files != null) {
      loggy.info('cli-sync: CLI is gone, sync off');
      await _files!.deleteAppState();
      _files = null;
      _engine.publish(CliEngineState.stopped);
    }
  }

  Future<void> _tick() async {
    if (_ticking || _disposed) return;
    _ticking = true;
    try {
      if (_nowMs - _lastDiscoveryMs >= _rediscoverEvery.inMilliseconds) await _discover();
      if (_files == null) return;
      if (!_executing) {
        final command = await _files!.pollControl(_nowMs);
        if (command != null) unawaited(_execute(command));
      }
      await _writeState();
      await _reloadPrefsIfChangedOnDisk();
    } catch (e, st) {
      loggy.warning('cli-sync: tick failed', e, st);
    } finally {
      _ticking = false;
    }
  }

  AppSyncState _snapshot() {
    final status = _ref.read(connectionNotifierProvider).valueOrNull;
    final connected = status is Connected;
    final rawTag = connected ? _ref.read(activeProxyNotifierProvider).valueOrNull?.tag : null;
    return AppSyncState(
      pid: pid,
      heartbeatMs: _nowMs,
      connected: connected,
      connecting: status is Connecting,
      selection: _ref.read(serverSelectionProvider),
      rawTag: rawTag == null || rawTag.isEmpty ? null : rawTag,
    );
  }

  /// Пишет app-state.json, если состояние изменилось или пора пульсу.
  Future<void> _writeState({bool force = false}) async {
    final files = _files;
    if (files == null || _writing || _disposed) return;
    _writing = true;
    try {
      final state = _snapshot();
      final last = _lastWritten;
      final due = _nowMs - _lastWriteMs >= appStateHeartbeat.inMilliseconds;
      if (!force && !due && last != null && last.sameContent(state)) return;
      if (await files.writeAppState(state)) {
        _lastWritten = state;
        _lastWriteMs = state.heartbeatMs;
      }
    } finally {
      _writing = false;
    }
  }

  Future<void> _execute(ControlCommand command) async {
    _executing = true;
    String? error;
    try {
      loggy.info('cli-sync: control ${command.cmd.name} ${command.selection ?? ""} (${command.id})');
      switch (command.cmd) {
        case ControlCmd.disconnect:
          error = await _disconnectAppEngine();
        case ControlCmd.select:
          error = await applySelection(command.selection!);
      }
    } catch (e, st) {
      loggy.warning('cli-sync: control ${command.id} failed', e, st);
      error = '$e';
    } finally {
      final ack = ControlAck(id: command.id, ok: error == null, error: error, tsMs: _nowMs);
      if (!await (_files?.writeAck(ack) ?? Future.value(false))) {
        loggy.warning('cli-sync: could not write ack for ${command.id}');
      }
      _executing = false;
      unawaited(_writeState(force: true));
    }
  }

  /// Команда CLI `disconnect`: обычное отключение приложения.
  Future<String?> _disconnectAppEngine() async {
    ConnectionStatus? status() => _ref.read(connectionNotifierProvider).valueOrNull;
    final current = status();
    if (current is! Connected && current is! Connecting) return null;
    await _ref.read(Preferences.startedByUser.notifier).update(false);
    await _ref.read(connectionNotifierProvider.notifier).abortConnection();
    for (var i = 0; i < 50; i++) {
      if (status() is! Connected && status() is! Connecting) return null;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return 'приложение не отключилось за 5 с';
  }

  /// Выбор сервера тем же путём, что в карточке выбора: настройки (карточка подхватывает их через
  /// serverSelectionProvider) + переключение в работающем ядре приложения. Возвращает текст ошибки или null.
  Future<String?> applySelection(ServerSelection selection) async {
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    final connected = _ref.read(connectionNotifierProvider).valueOrNull is Connected;
    final repo = _ref.read(proxyRepositoryProvider);
    OutboundGroup? group;
    if (connected) {
      try {
        final either = await repo.watchProxies().first.timeout(const Duration(seconds: 5));
        group = either.getOrElse((_) => null);
      } catch (e) {
        loggy.debug('cli-sync: no live server list: $e');
      }
    }
    final options = group != null ? ServerOption.parse(group) : readCachedServerOptions(prefs);
    ServerOption? target;
    if (!selection.isAuto && options.isNotEmpty) {
      target = ServerOption.find(options, selection.c, selection.p, selection.t);
      if (target == null) return 'сервер «${selection.toSelectArg()}» не найден в списке приложения';
    }
    final notifier = _ref.read(serverSelectionProvider.notifier);
    if (selection.isAuto) {
      await notifier.update(c: autoCountryKey);
    } else {
      await notifier.set(selection);
    }
    if (!connected) return null;
    if (group == null) return 'список серверов ядра приложения недоступен';
    final String? rawTag;
    if (selection.isAuto) {
      final best = ServerOption.fastest(options);
      if (best == null) {
        // Задержек ещё нет — замер; самый быстрый выберет карточка выбора сервера.
        final tested = await repo.urlTest(group.tag).run();
        return tested.match<String?>((failure) => 'замер серверов не удался: $failure', (_) => null);
      }
      rawTag = best.rawTag;
    } else {
      rawTag = target?.rawTag;
    }
    if (rawTag == null || group.selected == rawTag) return null;
    final selected = await repo.selectProxy(group.tag, rawTag).run();
    return selected.match<String?>((failure) => 'не удалось переключить сервер: $failure', (_) => null);
  }

  /// Свежая проверка движка CLI (до 1 с). false, если синхронизация выключена.
  Future<bool> isCliEngineRunningNow() async {
    if (!cliSyncSupported || !_started) return false;
    return (await _probe()).running;
  }

  Future<CliEngineState> _probe() {
    return _probeInFlight ??= _probeOnce().whenComplete(() => _probeInFlight = null);
  }

  Future<CliEngineState> _probeOnce() async {
    final current = _ref.read(cliEngineProvider);
    var next = CliEngineState.stopped;
    try {
      final stateFile = _stateFile;
      if (_files != null && stateFile != null && await File(stateFile).exists()) {
        final api = parseCliApiSettings(await File(stateFile).readAsString());
        if (api != null) next = await probeCliEngine(api);
      }
    } catch (e) {
      loggy.debug('cli-sync: probe failed: $e');
    }
    if (_disposed) return next;
    if (next.running != _lastRunning) loggy.info('cli-sync: CLI engine ${next.running ? "running" : "stopped"}');
    _lastRunning = next.running;
    _engine.publish(next.copyWith(busy: current.busy));
    return next;
  }

  static Future<String?> _stampOf(File file) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return null;
    }
  }

  /// CLI пишет выбор сервера прямо в настройки приложения на диске. Файл изменился (и не меняется
  /// уже 300 мс, и это целый JSON) — перечитать настройки и выбор сервера.
  Future<void> _reloadPrefsIfChangedOnDisk() async {
    final file = _prefsFile;
    if (file == null) return;
    final stamp = await _stampOf(file);
    if (stamp == null || stamp == _prefsStamp) return;
    try {
      final modified = (await file.stat()).modified;
      if (DateTime.now().difference(modified) < const Duration(milliseconds: 300)) return;
      if (jsonDecode(await file.readAsString()) is! Map) return;
      if (await _stampOf(file) != stamp) return;
      _prefsStamp = stamp;
      await _ref.read(sharedPreferencesProvider).requireValue.reload();
      _ref.read(serverSelectionProvider.notifier).reloadFromPrefs();
    } catch (e) {
      loggy.debug('cli-sync: prefs reload skipped: $e');
    }
  }

  /// Кнопка подключения, когда работает только движок CLI: `axiom disconnect`.
  Future<void> disconnectCliEngine() => _runCli(['disconnect']);

  /// Выбор сервера пользователем, пока работает движок CLI: `axiom use --select "C|P|T"`.
  Future<void> useSelectionInCli(ServerSelection selection) =>
      _runCli(['use', '--select', selection.toSelectArg()]);

  Future<void> _runCli(List<String> args) async {
    final t = _ref.read(translationsProvider).requireValue;
    final notifications = _ref.read(inAppNotificationControllerProvider);
    final binary = _binary;
    if (binary == null) {
      notifications.showErrorToast(t.cliSync.notFound);
      return;
    }
    if (_ref.read(cliEngineProvider).busy) return;
    _engine.publish(_ref.read(cliEngineProvider).copyWith(busy: true));
    try {
      loggy.info('cli-sync: axiom ${args.join(" ")}');
      final result = await runCliProcess(binary, args);
      if (!result.ok) {
        loggy.warning('cli-sync: axiom ${args.first} failed: $result');
        notifications.showErrorToast(t.cliSync.commandFailed(error: result.message));
      }
    } finally {
      _engine.publish(_ref.read(cliEngineProvider).copyWith(busy: false));
      await _probe();
    }
  }
}

const legacyCliMigrationVersionKey = 'cli_sync_legacy_migration_version';

/// Раз на версию приложения заменить старый Go-CLI (cli-v0.0.x) на SBX. Ошибки только в журнал.
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
      installerPaths: CliLocations.binaryCandidates(isWindows: isWindows, exeDir: exeDir, env: env),
      installerSources: CliLocations.installerSourceCandidates(isWindows: isWindows, exeDir: exeDir, env: env),
      tempDir: Directory.systemTemp,
    );
    log.info('cli-sync: legacy CLI check for $version: $report');
    if (report.transientFailure) {
      log.warning('cli-sync: legacy CLI not replaced (download failed), will retry on next start');
      return;
    }
    await prefs.setString(legacyCliMigrationVersionKey, version);
  } catch (e, st) {
    log.warning('cli-sync: legacy CLI migration failed', e, st);
  }
}
