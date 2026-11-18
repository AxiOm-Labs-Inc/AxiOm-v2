// Пассивная сторона протокола синхронизации с CLI (без Flutter и Riverpod — её гоняют тесты,
// в том числе вместе с настоящим sbx.py):
// - app-location.json в каталоге настроек CLI при запуске;
// - app-state.json: при изменениях и пульсом раз в 2 с, удаляется при выходе;
// - control.json: каждая команда один раз (в том числе после перезапуска — по control-ack.json),
//   ответ — только по факту (отключено / выбор сохранён и применён), не дольше 12 с;
// - start.lock: резерв запуска движка приложения — замок ОС на байт 0 (v3, A), ядро снимает его само;
// - у каждой команды своё поколение: после таймаута или новой команды её поздние шаги не выполняются (v3, J).
// Сам движок приложения и настройки — за адаптером AppEngineAdapter.

import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/selection_resolution.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:uuid/uuid.dart';

enum AppEngineStatus { disconnected, connecting, connected, disconnecting, failed }

/// Ещё ли актуальна команда: false — она истекла по таймауту или пришла новее.
typedef StillCurrent = bool Function();

/// Движок и настройки приложения глазами синхронизации.
abstract class AppEngineAdapter {
  AppEngineStatus get status;

  /// Текущий сервер ядра приложения, если оно подключено.
  String? get rawTag;

  /// Выбор из настроек как есть.
  ServerSelection get storedSelection;

  /// Известный список серверов (живой из ядра или сохранённый) — для канонических троек.
  List<ServerOption> get knownOptions;

  /// Меню для команды select: живое, иначе сохранённый список, иначе разбор профиля (v4, R). Пусто — не загружено.
  Future<List<ServerOption>> loadOptions();

  /// Сохранить выбор обычным путём приложения (настройки + карточка выбора). Авто — только страна.
  /// Один шаг под проверкой поколения (v4, S): если [current] уже false — ничего не пишет.
  Future<void> persistSelection(ServerSelection selection, StillCurrent current);

  /// Применить выбор в подключённом ядре приложения (авто — выбрать самый быстрый). Ошибка или null.
  /// Перед каждым действием с ядром проверяет [current].
  Future<String?> applyToEngine(ServerSelection selection, StillCurrent current);

  /// Остановить движок приложения по ФАКТИЧЕСКОМУ состоянию ядра (ошибка в состоянии приложения — не
  /// доказательство остановки) и дождаться остановки. Ошибка или null.
  Future<String?> stopEngine(StillCurrent current);
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

  late final ByteLock startLock = ByteLock.forFile(files.startLockFile);

  bool _stopped = false;
  bool _writing = false;
  bool _executing = false;
  AppSyncState? _lastWritten;
  int _lastWriteMs = 0;
  StartReservation? _reservation;
  int _generation = 0;
  int _activeGeneration = 0;
  ServerSelection _lastCanonical = ServerSelection.auto;

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
      selection: publishedSelection(),
      rawTag: rawTag == null || rawTag.isEmpty ? null : rawTag,
    );
  }

  /// Выбор для app-state: только каноническая тройка (v3, I). Не достраивается (меню ещё нет) или её нет
  /// в известном списке — последняя каноническая (сначала авто).
  ServerSelection publishedSelection() {
    final options = adapter.knownOptions;
    final canonical = canonicalSelection(adapter.storedSelection, options);
    // Не авто — только проверенная по известному меню тройка; без меню остаётся последняя проверенная.
    if (canonical.isAuto || (options.isNotEmpty && validateSelection(canonical, options) == null)) {
      _lastCanonical = canonical;
    }
    return _lastCanonical;
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
    _reservation = null;
    for (var i = 0; _writing && i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await files.deleteAppState();
    await startLock.close();
  }

  // ── намерение пользователя (v4, M) ──

  /// Записать намерение пользователя приложения включить/выключить VPN (v5, T: seq под intent.lock).
  /// null — не удалось (замок занят дольше 5 с или файл не записать).
  Future<VpnIntent?> writeIntent({required bool on}) async {
    final intent = await files.appendIntent(want: on ? 'on' : 'off', id: const Uuid().v4(), by: 'app', tsMs: now);
    if (intent == null) _log('cannot write ${files.intentFile.path}');
    return intent;
  }

  /// Запуск, начатый намерением [on], всё ещё нужен: после него никто не просил выключить.
  Future<bool> startStillWanted(VpnIntent on) async {
    final latest = await files.readIntent();
    return latest == null || !latest.cancels(on);
  }

  /// start.lock держит другой процесс (CLI запускает свой движок): VPN включается.
  Future<bool> startHeldElsewhere() async {
    try {
      return await startLock.heldElsewhere();
    } catch (_) {
      return false;
    }
  }

  /// Взять start.lock перед запуском ядра. null — его держит другая сторона (или мы уже запускаемся).
  Future<StartReservation?> reserveStart() async {
    if (_reservation != null) return null;
    try {
      if (!await startLock.tryLock()) return null;
    } catch (e) {
      _log('start.lock: $e');
      return null;
    }
    final reservation = StartReservation._(const Uuid().v4());
    _reservation = reservation;
    // Кто держит замок — только для сообщений CLI.
    await writeJsonAtomic(files.startOwnerFile, startOwnerJson(owner: 'app', id: reservation.id, tsMs: now));
    await writeState(force: true);
    return reservation;
  }

  /// Снять резерв: сначала app-state (connected уже виден), потом сам замок — без «дыры».
  Future<void> releaseStart(StartReservation reservation) async {
    if (!reservation.real) return;
    if (_reservation == reservation) _reservation = null;
    await writeState(force: true);
    await startLock.unlock();
    if (!reservation._released.isCompleted) reservation._released.complete();
  }

  /// Выполнить команду и ответить. Не дольше [handlerTimeout].
  Future<void> execute(ControlCommand command) async {
    _executing = true;
    final generation = ++_generation;
    _activeGeneration = generation;
    bool current() => _activeGeneration == generation && !_stopped;
    String? error;
    try {
      _log('control ${command.cmd.name} ${command.selection ?? ""} (${command.id})');
      error = await _handle(command, current).timeout(
        handlerTimeout,
        onTimeout: () {
          _activeGeneration = 0; // поздние шаги этой команды больше ничего не сделают
          return 'приложение не выполнило «${command.cmd.name}» за ${handlerTimeout.inSeconds} с';
        },
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

  Future<String?> _handle(ControlCommand command, StillCurrent current) => switch (command.cmd) {
    ControlCmd.disconnect => _disconnect(current),
    ControlCmd.select => _select(command.selection!, current),
  };

  Future<String?> _disconnect(StillCurrent current) async {
    final pending = _reservation;
    if (pending != null) {
      // Приложение как раз запускается: отменить запуск и дождаться, пока он отпустит замок.
      pending.cancel();
      await pending.released;
    }
    if (!current()) return 'команда устарела';
    // Состояние приложения (в т.ч. ошибка) — не доказательство: адаптер смотрит фактическое состояние ядра.
    return adapter.stopEngine(current);
  }

  Future<String?> _select(ServerSelection requested, StillCurrent current) async {
    final options = await adapter.loadOptions();
    // Меню не загружено и взять неоткуда — ничего не сохраняем (v4, R).
    if (options.isEmpty) return 'список серверов ещё не загружен';
    final selection = canonicalSelection(requested, options);
    final invalid = validateSelection(selection, options);
    if (invalid != null) return invalid;
    if (!current()) return 'команда устарела';
    await adapter.persistSelection(selection, current);
    if (adapter.status != AppEngineStatus.connected) return null;
    return adapter.applyToEngine(selection, current);
  }
}
