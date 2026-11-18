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
  String toSelectArg() => isAuto ? '$autoCountryKey||' : '$c|$p|$t';

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
    if (id is! String || id.isEmpty || ts is! int || cmdName is! String) return null;
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

  String? _lastControlStamp;

  Future<bool> writeAppState(AppSyncState state) => writeJsonAtomic(appStateFile, state.toJson());

  Future<void> deleteAppState() async {
    try {
      if (await appStateFile.exists()) await appStateFile.delete();
    } catch (_) {}
  }

  /// Новая команда для выполнения или null.
  ///
  /// Файл перечитывается только при смене времени изменения или размера. Нечитаемый или недописанный
  /// файл не запоминается — его прочтут снова на следующем опросе. Устаревшая команда
  /// помечается как увиденная и пропускается.
  Future<ControlCommand?> pollControl(int nowMs) async {
    final FileStat stat;
    try {
      stat = await controlFile.stat();
    } catch (_) {
      return null;
    }
    if (stat.type != FileSystemEntityType.file) return null;
    final stamp = '${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    if (_lastControlStamp == stamp) return null;
    final String text;
    try {
      text = await controlFile.readAsString();
    } catch (_) {
      return null;
    }
    final command = ControlCommand.tryParse(text);
    if (command == null) return null;
    _lastControlStamp = stamp;
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
