// Пассивная сторона протокола синхронизации с CLI (без Flutter и Riverpod — её гоняют тесты,
// в том числе вместе с настоящим sbx.py):
// - app-location.json в каталоге настроек CLI при запуске;
// - app-state.json: при изменениях и пульсом раз в 2 с, удаляется при выходе;
// - control.json: каждая команда один раз (в том числе после перезапуска — по control-ack.json),
//   ответ — только по факту (отключено / выбор сохранён и применён), не дольше 12 с;
// - start.lock: резерв запуска движка приложения.
// Сам движок приложения и настройки — за адаптером AppEngineAdapter.

import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/selection_resolution.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:uuid/uuid.dart';

enum AppEngineStatus { disconnected, connecting, connected, disconnecting, failed }

/// Движок и настройки приложения глазами синхронизации.
abstract class AppEngineAdapter {
  AppEngineStatus get status;

  /// Текущий сервер ядра приложения, если оно подключено.
  String? get rawTag;

  /// Выбор из настроек как есть.
  ServerSelection get storedSelection;

  /// Известный список серверов (живой из ядра или сохранённый) — для канонических троек.
  List<ServerOption> get knownOptions;

  /// Сохранить выбор обычным путём приложения (настройки + карточка выбора). Авто — только страна.
  Future<void> persistSelection(ServerSelection selection);

  /// Применить выбор в подключённом ядре приложения (авто — выбрать самый быстрый). Ошибка или null.
  Future<String?> applyToEngine(ServerSelection selection);

  /// Остановить движок приложения и дождаться Disconnected. Ошибка или null.
  Future<String?> stopEngine();
}

/// Резерв запуска движка приложения (start.lock).
class StartReservation {
  StartReservation._(this.id, {this.real = true});

  /// Резерв без файла: синхронизация выключена.
  factory StartReservation.none() => StartReservation._('', real: false);

  final String id;
  final bool real;
  bool _cancelled = false;
  final _released = Completer<void>();

  /// CLI попросил отключить VPN, пока приложение ещё запускалось: подключение надо бросить.
  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;

  Future<void> get released => _released.future;
}

class CliSyncService {
  CliSyncService({
    required this.files,
    required this.adapter,
    this.locationFile,
    this.location,
    int Function()? clock,
    int? ownPid,
    this.handlerTimeout = const Duration(seconds: 12),
    void Function(String message)? log,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
       _pid = ownPid ?? pid,
       _log = log ?? ((_) {});

  final CliSyncFiles files;
  final AppEngineAdapter adapter;

  /// `<каталог настроек CLI>/app-location.json` и его содержимое (без ts — его ставит сервис).
  final File? locationFile;
  final AppLocation? location;

  /// Предел обработки одной команды: CLI ждёт ответ 15 с.
  final Duration handlerTimeout;

  final int Function() _clock;
  final int _pid;
  final void Function(String message) _log;

  late final StartLock startLock = StartLock(files.startLockFile);

  bool _stopped = false;
  bool _writing = false;
  bool _executing = false;
  AppSyncState? _lastWritten;
  int _lastWriteMs = 0;
  StartReservation? _reservation;

  int get now => _clock();

  bool get executing => _executing;

  /// Свой резерв запуска (движок приложения запускается).
  StartReservation? get reservation => _reservation;

  Future<void> start() async {
    await files.dir.create(recursive: true);
    await writeLocation();
    await files.initDedupFromAck();
    await writeState(force: true);
  }

  Future<void> writeLocation() async {
    final file = locationFile;
    final loc = location;
    if (file == null || loc == null) return;
    final stamped = AppLocation(
      supportDir: loc.supportDir,
      syncDir: loc.syncDir,
      prefsFile: loc.prefsFile,
      prefsPrefix: loc.prefsPrefix,
      exe: loc.exe,
      pid: loc.pid,
      tsMs: now,
    );
    if (!await writeJsonAtomic(file, stamped.toJson())) _log('cannot write ${file.path}');
  }

  /// Опрос команд и пульс; вызывается раз в 1 с.
  Future<void> tick() async {
    if (_stopped) return;
    if (!_executing) {
      final command = await files.pollControl(now);
      if (command != null) unawaited(execute(command));
    }
    await writeState();
  }

  AppSyncState snapshot() {
    final status = adapter.status;
    final connected = status == AppEngineStatus.connected;
    final rawTag = connected ? adapter.rawTag : null;
    return AppSyncState(
      pid: _pid,
      heartbeatMs: now,
      connected: connected,
      connecting: status == AppEngineStatus.connecting || _reservation != null,
      selection: canonicalSelection(adapter.storedSelection, adapter.knownOptions),
      rawTag: rawTag == null || rawTag.isEmpty ? null : rawTag,
    );
  }

  /// app-state.json при изменении или раз в 2 с (опрос раз в 1 с, запас полсекунды).
  Future<void> writeState({bool force = false}) async {
    if (_stopped) return;
    if (_writing) {
      if (!force) return;
      // Принудительная запись не теряется: ждём начатую (она короткая).
      for (var i = 0; _writing && i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (_writing || _stopped) return;
    }
    _writing = true;
    try {
      final state = snapshot();
      final last = _lastWritten;
      final due = now - _lastWriteMs >= appStateHeartbeat.inMilliseconds - 500;
      if (!force && !due && last != null && last.sameContent(state)) return;
      if (await files.writeAppState(state)) {
        _lastWritten = state;
        _lastWriteMs = state.heartbeatMs;
      }
    } finally {
      _writing = false;
    }
  }

  /// Чистый выход: снять свой резерв, дождаться начатой записи и удалить app-state.json.
  Future<void> shutdown() async {
    _stopped = true;
    final r = _reservation;
    if (r != null && r.real) await startLock.release(r.id);
    for (var i = 0; _writing && i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await files.deleteAppState();
  }

  /// Чужой (CLI) свежий start.lock: VPN включается через CLI.
  Future<StartLockInfo?> foreignStartLock() async {
    final info = await startLock.read();
    if (info == null || !info.isFresh(now)) return null;
    if (_reservation != null && info.id == _reservation!.id) return null;
    return info;
  }

  /// Взять start.lock до любой подготовки к запуску. null — замок держит другая сторона.
  Future<StartReservation?> reserveStart() async {
    if (_reservation != null) return null; // уже запускаемся
    final id = const Uuid().v4();
    if (!await startLock.tryAcquire('app', id, now)) return null;
    final reservation = StartReservation._(id);
    _reservation = reservation;
    await writeState(force: true);
    return reservation;
  }

  /// Снять резерв: сначала app-state (connected уже виден), потом сам замок — без «дыры».
  Future<void> releaseStart(StartReservation reservation) async {
    if (!reservation.real) return;
    if (_reservation == reservation) _reservation = null;
    await writeState(force: true);
    await startLock.release(reservation.id);
    if (!reservation._released.isCompleted) reservation._released.complete();
  }

  /// Выполнить команду и ответить. Не дольше [handlerTimeout].
  Future<void> execute(ControlCommand command) async {
    _executing = true;
    String? error;
    try {
      _log('control ${command.cmd.name} ${command.selection ?? ""} (${command.id})');
      error = await _handle(command).timeout(
        handlerTimeout,
        onTimeout: () => 'приложение не выполнило «${command.cmd.name}» за ${handlerTimeout.inSeconds} с',
      );
    } catch (e) {
      error = '$e';
    } finally {
      // Сначала новое состояние, потом ответ: получив ответ, CLI уже видит, что VPN выключен/сервер сменён.
      await writeState(force: true);
      final ack = ControlAck(id: command.id, ok: error == null, error: error, tsMs: now);
      if (!await files.writeAck(ack)) _log('cannot write ack ${command.id}');
      _executing = false;
    }
  }

  Future<String?> _handle(ControlCommand command) => switch (command.cmd) {
    ControlCmd.disconnect => _disconnect(),
    ControlCmd.select => _select(command.selection!),
  };

  Future<String?> _disconnect() async {
    final pending = _reservation;
    if (pending != null) {
      // Приложение как раз запускается: отменить запуск и дождаться, пока он отпустит замок.
      pending.cancel();
      await pending.released;
    }
    final status = adapter.status;
    if (status == AppEngineStatus.disconnected || status == AppEngineStatus.failed) return null;
    return adapter.stopEngine();
  }

  Future<String?> _select(ServerSelection requested) async {
    final options = adapter.knownOptions;
    final selection = canonicalSelection(requested, options);
    final invalid = validateSelection(selection, options);
    if (invalid != null) return invalid;
    await adapter.persistSelection(selection);
    if (adapter.status != AppEngineStatus.connected) return null;
    return adapter.applyToEngine(selection);
  }
}
