// Файловый протокол синхронизации приложения AxiOm с CLI (SBX в режиме axiom).
//
// Каталог `<данные приложения>/cli-sync/`:
// - app-state.json   — пишет только приложение: состояние VPN и выбор сервера, пульс раз в 2 с;
// - control.json     — пишет только CLI: команда приложению (disconnect | select);
// - control-ack.json — пишет только приложение: ответ на команду по её id.
// Все записи атомарные (временный файл + rename). Файл без зависимостей от Flutter — его проверяют юнит-тесты.

import 'dart:convert';
import 'dart:io';

const cliSyncDirName = 'cli-sync';
const appStateFileName = 'app-state.json';
const controlFileName = 'control.json';
const controlAckFileName = 'control-ack.json';
const startLockFileName = 'start.lock';
const startOwnerFileName = 'start.owner.json';
const vpnIntentFileName = 'vpn-intent.json';
const intentLockFileName = 'intent.lock';

/// Файл-указатель на запущенное приложение в каталоге настроек CLI.
const appLocationFileName = 'app-location.json';

const cliSyncProtocolVersion = 1;

/// Как часто приложение обновляет app-state.json, даже если ничего не изменилось.
const appStateHeartbeat = Duration(seconds: 2);

/// app-state.json старше этого считается брошенным (приложение не работает).
const appStateStaleAfter = Duration(seconds: 10);

/// Как часто приложение проверяет control.json.
const controlPollInterval = Duration(seconds: 1);

/// Команды старше этого не выполняются.
const controlMaxAge = Duration(seconds: 30);

/// Ключ страны «авто» — как в настройках приложения.
const autoCountryKey = '__auto__';

final _uuid4 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', caseSensitive: false);

/// id команд — только uuid4.
bool isUuid4(String value) => _uuid4.hasMatch(value);

/// Выбор сервера в кодировке настроек приложения:
/// `c` — страна ('__auto__' для авто), `p`/`t` — протокол и транспорт ('' если не заданы).
class ServerSelection {
  const ServerSelection({required this.c, this.p = '', this.t = ''});

  final String c;
  final String p;
  final String t;

  static const auto = ServerSelection(c: autoCountryKey);

  bool get isAuto => c == autoCountryKey;

  Map<String, dynamic> toJson() => {'c': c, 'p': p, 't': t};

  /// Разбор `{"c","p","t"}`; null, если страна не задана или поля не строки.
  static ServerSelection? fromJson(Object? json) {
    if (json is! Map) return null;
    final c = json['c'];
    final p = json['p'] ?? '';
    final t = json['t'] ?? '';
    if (c is! String || c.isEmpty || p is! String || t is! String) return null;
    return ServerSelection(c: c, p: p, t: t);
  }

  /// Аргумент `--select "C|P|T"` для CLI. У авто протокол и транспорт не передаются.
  String toSelectArg() => isAuto ? autoCountryKey : '$c|$p|$t';

  ServerSelection copyWith({String? c, String? p, String? t}) =>
      ServerSelection(c: c ?? this.c, p: p ?? this.p, t: t ?? this.t);

  @override
  bool operator ==(Object other) => other is ServerSelection && other.c == c && other.p == p && other.t == t;

  @override
  int get hashCode => Object.hash(c, p, t);

  @override
  String toString() => toSelectArg();
}

/// Содержимое app-state.json.
class AppSyncState {
  const AppSyncState({
    required this.pid,
    required this.heartbeatMs,
    required this.connected,
    required this.connecting,
    required this.selection,
    required this.rawTag,
  });

  final int pid;
  final int heartbeatMs;
  final bool connected;
  final bool connecting;
  final ServerSelection selection;
  final String? rawTag;

  Map<String, dynamic> toJson() => {
    'v': cliSyncProtocolVersion,
    'pid': pid,
    'heartbeat': heartbeatMs,
    'connected': connected,
    'connecting': connecting,
    'selection': selection.toJson(),
    'rawTag': rawTag,
  };

  static AppSyncState? fromJson(Object? json) {
    if (json is! Map || json['v'] != cliSyncProtocolVersion) return null;
    final pid = json['pid'];
    final heartbeat = json['heartbeat'];
    final connected = json['connected'];
    final connecting = json['connecting'];
    final selection = ServerSelection.fromJson(json['selection']);
    final rawTag = json['rawTag'];
    if (pid is! int || heartbeat is! int || connected is! bool || connecting is! bool || selection == null) {
      return null;
    }
    if (rawTag != null && rawTag is! String) return null;
    return AppSyncState(
      pid: pid,
      heartbeatMs: heartbeat,
      connected: connected,
      connecting: connecting,
      selection: selection,
      rawTag: rawTag as String?,
    );
  }

  /// Совпадает ли всё, кроме времени пульса.
  bool sameContent(AppSyncState other) =>
      pid == other.pid &&
      connected == other.connected &&
      connecting == other.connecting &&
      selection == other.selection &&
      rawTag == other.rawTag;

  AppSyncState withHeartbeat(int ms) => AppSyncState(
    pid: pid,
    heartbeatMs: ms,
    connected: connected,
    connecting: connecting,
    selection: selection,
    rawTag: rawTag,
  );
}

/// Пульс считается устаревшим, если он старше [appStateStaleAfter] (или подозрительно из будущего).
bool isHeartbeatStale(int heartbeatMs, int nowMs) =>
    nowMs - heartbeatMs > appStateStaleAfter.inMilliseconds ||
    heartbeatMs - nowMs > appStateStaleAfter.inMilliseconds;

enum ControlCmd { disconnect, select }

/// Команда из control.json.
class ControlCommand {
  const ControlCommand({required this.id, required this.tsMs, required this.cmd, this.selection});

  final String id;
  final int tsMs;
  final ControlCmd cmd;
  final ServerSelection? selection;

  /// Разбор текста control.json; null, если он не по протоколу (в т.ч. недописан).
  static ControlCommand? tryParse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (json is! Map || json['v'] != cliSyncProtocolVersion) return null;
    final id = json['id'];
    final ts = json['ts'];
    final cmdName = json['cmd'];
    if (id is! String || !isUuid4(id) || ts is! int || cmdName is! String) return null;
    ControlCmd? cmd;
    for (final c in ControlCmd.values) {
      if (c.name == cmdName) cmd = c;
    }
    if (cmd == null) return null;
    final selection = ServerSelection.fromJson(json['selection']);
    if (cmd == ControlCmd.select && selection == null) return null;
    return ControlCommand(id: id, tsMs: ts, cmd: cmd, selection: selection);
  }

  Map<String, dynamic> toJson() => {
    'v': cliSyncProtocolVersion,
    'id': id,
    'ts': tsMs,
    'cmd': cmd.name,
    if (selection != null) 'selection': selection!.toJson(),
  };
}

/// Ответ приложения в control-ack.json.
class ControlAck {
  const ControlAck({required this.id, required this.ok, required this.tsMs, this.error});

  final String id;
  final bool ok;
  final String? error;
  final int tsMs;

  /// Разбор control-ack.json (для дедупликации после перезапуска); null — не по протоколу.
  static ControlAck? tryParse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (json is! Map || json['v'] != cliSyncProtocolVersion) return null;
    final id = json['id'];
    final ok = json['ok'];
    final ts = json['ts'];
    final error = json['error'];
    if (id is! String || !isUuid4(id) || ok is! bool || ts is! int) return null;
    if (error != null && error is! String) return null;
    return ControlAck(id: id, ok: ok, tsMs: ts, error: error as String?);
  }

  Map<String, dynamic> toJson() => {
    'v': cliSyncProtocolVersion,
    'id': id,
    'ok': ok,
    if (error != null) 'error': error,
    'ts': tsMs,
  };
}

enum ControlDecision { execute, duplicate, expired }

/// Каждую команду — один раз; старые — не выполнять.
class ControlTracker {
  ControlTracker({this.capacity = 64});

  final int capacity;
  final _seen = <String>{};

  ControlDecision evaluate(ControlCommand command, int nowMs) {
    if (_seen.contains(command.id)) return ControlDecision.duplicate;
    final age = nowMs - command.tsMs;
    if (age > controlMaxAge.inMilliseconds || -age > controlMaxAge.inMilliseconds) {
      return ControlDecision.expired;
    }
    return ControlDecision.execute;
  }

  void markSeen(String id) {
    _seen.remove(id);
    _seen.add(id);
    while (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
  }

  bool hasSeen(String id) => _seen.contains(id);
}

/// Атомарная запись JSON: временный файл рядом + rename поверх.
///
/// На Windows rename падает, если читатель держит целевой файл открытым, — тогда
/// временный файл удаляется и возвращается false (запись повторят позже).
Future<bool> writeJsonAtomic(File target, Map<String, dynamic> json) async {
  final tmp = File('${target.path}.$pid.tmp');
  try {
    await target.parent.create(recursive: true);
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(target.path);
    return true;
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    return false;
  }
}

/// Файлы каталога синхронизации.
class CliSyncFiles {
  CliSyncFiles(this.dir, {ControlTracker? tracker}) : tracker = tracker ?? ControlTracker();

  final Directory dir;
  final ControlTracker tracker;

  File get appStateFile => File('${dir.path}${Platform.pathSeparator}$appStateFileName');
  File get controlFile => File('${dir.path}${Platform.pathSeparator}$controlFileName');
  File get ackFile => File('${dir.path}${Platform.pathSeparator}$controlAckFileName');

  File get startLockFile => File('${dir.path}${Platform.pathSeparator}$startLockFileName');
  File get startOwnerFile => File('${dir.path}${Platform.pathSeparator}$startOwnerFileName');
  File get intentFile => File('${dir.path}${Platform.pathSeparator}$vpnIntentFileName');
  File get intentLockFile => File('${dir.path}${Platform.pathSeparator}$intentLockFileName');

  Future<VpnIntent?> readIntent() async {
    try {
      return VpnIntent.tryParse(await intentFile.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Записать новое намерение (v5, T): под замком intent.lock прочитать текущий seq и записать seq + 1.
  /// null — замок не взять за [lockWait] или файл не записать.
  Future<VpnIntent?> appendIntent({
    required String want,
    required String id,
    required String by,
    required int tsMs,
    Duration lockWait = const Duration(seconds: 5),
  }) async {
    final lock = ByteLock.forFile(intentLockFile);
    final deadline = DateTime.now().add(lockWait);
    while (!await lock.tryLock()) {
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    try {
      final current = await readIntent();
      final intent = VpnIntent(want: want, id: id, seq: (current?.seq ?? 0) + 1, tsMs: tsMs, by: by);
      for (var i = 0; i < 10; i++) {
        if (await writeJsonAtomic(intentFile, intent.toJson())) return intent;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return null;
    } finally {
      await lock.unlock();
    }
  }

  Future<bool> writeAppState(AppSyncState state) => writeJsonAtomic(appStateFile, state.toJson());

  Future<void> deleteAppState() async {
    try {
      if (await appStateFile.exists()) await appStateFile.delete();
    } catch (_) {}
  }

  /// Дедупликация после перезапуска: команда, на которую уже есть ответ, считается выполненной.
  Future<void> initDedupFromAck() async {
    try {
      final ack = ControlAck.tryParse(await ackFile.readAsString());
      if (ack != null) tracker.markSeen(ack.id);
    } catch (_) {}
  }

  /// Новая команда для выполнения или null.
  ///
  /// Файл маленький — читается целиком на каждом опросе, повторы отсекаются по id. Нечитаемый или
  /// недописанный файл не запоминается — его прочтут снова. Устаревшая команда пропускается.
  Future<ControlCommand?> pollControl(int nowMs) async {
    final String text;
    try {
      if (!await controlFile.exists()) return null;
      text = await controlFile.readAsString();
    } catch (_) {
      return null;
    }
    final command = ControlCommand.tryParse(text);
    if (command == null) return null;
    switch (tracker.evaluate(command, nowMs)) {
      case ControlDecision.execute:
        tracker.markSeen(command.id);
        return command;
      case ControlDecision.expired:
        tracker.markSeen(command.id);
        return null;
      case ControlDecision.duplicate:
        return null;
    }
  }

  /// Пишет ответ; на Windows повторяет, пока CLI держит файл открытым.
  Future<bool> writeAck(ControlAck ack, {int attempts = 10}) async {
    for (var i = 0; i < attempts; i++) {
      if (await writeJsonAtomic(ackFile, ack.toJson())) return true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }
}


/// Замок на байт 0 постоянного файла (DESIGN-sync v3, A; v4, N): `start.lock`, `control.lock` не удаляются никогда.
///
/// Берётся блокировкой ОС без ожидания: Dart `RandomAccessFile.lock(FileLock.exclusive, 0, 1)` = POSIX
/// fcntl-замок (CLI — `fcntl.lockf`) / Windows LockFileEx (CLI — `msvcrt.locking` с позиции 0). Ядро снимает
/// замок, когда держатель умирает, — устаревания нет.
///
/// ⚠ fcntl-замки POSIX принадлежат процессу: закрытие любого дескриптора файла снимает все замки процесса на нём,
/// а повторный lock в том же процессе проходит. Поэтому: на файл — один объект на весь процесс ([ByteLock.forFile]),
/// у него один открытый дескриптор, и все действия (открыть, взять, проверить, отпустить) идут строго по очереди.
/// Проверка, пока замок держим мы, дескриптор не трогает.
class ByteLock {
  ByteLock._(this.file);

  /// Единственный менеджер замка для файла в этом процессе.
  factory ByteLock.forFile(File file) => _managers.putIfAbsent(file.absolute.path, () => ByteLock._(file));

  static final _managers = <String, ByteLock>{};

  final File file;
  RandomAccessFile? _raf;
  bool _held = false;
  Future<void> _tail = Future.value();

  bool get held => _held;

  /// Действия с замком — по одному, без перекрытий.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<RandomAccessFile> _open() async {
    final open = _raf;
    if (open != null) return open;
    await file.parent.create(recursive: true);
    return _raf = await file.open(mode: FileMode.append);
  }

  Future<bool> _lockNow() async {
    final raf = await _open();
    try {
      await raf.lock(FileLock.exclusive, 0, 1);
      _held = true;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _unlockNow() async {
    if (!_held) return;
    _held = false;
    try {
      await _raf?.unlock(0, 1);
    } catch (_) {}
  }

  /// Взять замок без ожидания. false — его держит другой процесс (или мы сами уже держим).
  Future<bool> tryLock() => _serial(() async => !_held && await _lockNow());

  Future<void> unlock() => _serial(_unlockNow);

  /// Держит ли замок другой процесс: взять и сразу отпустить. Держим мы — false, дескриптор не трогается.
  Future<bool> heldElsewhere() => _serial(() async {
    if (_held) return false;
    if (await _lockNow()) {
      await _unlockNow();
      return false;
    }
    return true;
  });

  Future<void> close() => _serial(() async {
    await _unlockNow();
    final raf = _raf;
    _raf = null;
    try {
      await raf?.close();
    } catch (_) {}
  });
}

/// `vpn-intent.json` — последнее намерение пользователя включить/выключить VPN (v4, M; v5, T).
/// `seq` строго растёт: пишется только под замком `intent.lock` (прочитать seq → записать seq + 1).
/// Сравнения — только по seq; ts — для людей.
class VpnIntent {
  const VpnIntent({required this.want, required this.id, required this.seq, required this.tsMs, required this.by});

  /// 'on' | 'off'.
  final String want;
  final String id;
  final int seq;
  final int tsMs;

  /// 'app' | 'cli'.
  final String by;

  bool get off => want == 'off';

  /// `--intent <id>:<seq>` для `axiom disconnect` (v5, U).
  String get flagValue => '$id:$seq';

  Map<String, dynamic> toJson() => {
    'v': cliSyncProtocolVersion,
    'want': want,
    'id': id,
    'seq': seq,
    'ts': tsMs,
    'by': by,
  };

  static VpnIntent? tryParse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (json is! Map || json['v'] != cliSyncProtocolVersion) return null;
    final want = json['want'];
    final id = json['id'];
    final seq = json['seq'];
    final ts = json['ts'];
    final by = json['by'];
    if ((want != 'on' && want != 'off') || id is! String || !isUuid4(id) || seq is! int || seq < 1 || ts is! int) {
      return null;
    }
    if (by != 'app' && by != 'cli') return null;
    return VpnIntent(want: want as String, id: id, seq: seq, tsMs: ts, by: by as String);
  }

  /// Отменяет ли это намерение запуск, начатый намерением [on]: «выключить» с бо́льшим seq.
  bool cancels(VpnIntent on) => off && seq > on.seq;
}

/// `start.owner.json` — кто взял start.lock (только для сообщений).
Map<String, dynamic> startOwnerJson({required String owner, required String id, required int tsMs}) =>
    {'owner': owner, 'id': id, 'ts': tsMs};

/// Содержимое app-location.json: где искать работающее приложение.
class AppLocation {
  const AppLocation({
    required this.supportDir,
    required this.syncDir,
    required this.prefsFile,
    required this.prefsPrefix,
    required this.exe,
    required this.pid,
    required this.tsMs,
  });

  final String supportDir;
  final String syncDir;
  final String prefsFile;
  final String prefsPrefix;
  final String exe;
  final int pid;
  final int tsMs;

  Map<String, dynamic> toJson() => {
    'v': cliSyncProtocolVersion,
    'support_dir': supportDir,
    'sync_dir': syncDir,
    'prefs_file': prefsFile,
    'prefs_prefix': prefsPrefix,
    'exe': exe,
    'pid': pid,
    'ts': tsMs,
  };
}
