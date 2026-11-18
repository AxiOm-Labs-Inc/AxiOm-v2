import 'dart:io';

import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/cli_sync_service.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';

/// Подставной движок приложения для тестов синхронизации.
class FakeAppEngine implements AppEngineAdapter {
  FakeAppEngine({this.status = AppEngineStatus.disconnected, List<ServerOption>? options})
    : knownOptions = options ?? const [];

  /// Состояние, как его видит экран приложения.
  @override
  AppEngineStatus status;

  /// Фактическое состояние ядра; null — как [status] (без ошибки и без «отключено» — работает).
  bool? coreRunning;

  bool get _coreRunning => coreRunning ?? (status != AppEngineStatus.disconnected && status != AppEngineStatus.failed);

  @override
  String? rawTag;

  @override
  ServerSelection storedSelection = ServerSelection.auto;

  @override
  List<ServerOption> knownOptions;

  final persisted = <ServerSelection>[];
  final applied = <ServerSelection>[];
  int stopCalls = 0;
  String? stopError;
  String? applyError;
  Duration stopDelay = Duration.zero;
  Duration applyDelay = Duration.zero;

  @override
  Future<void> persistSelection(ServerSelection selection, StillCurrent current) async {
    if (!current()) return;
    persisted.add(selection);
    storedSelection = selection.isAuto ? storedSelection.copyWith(c: autoCountryKey) : selection;
  }

  @override
  Future<String?> applyToEngine(ServerSelection selection, StillCurrent current) async {
    await Future<void>.delayed(applyDelay);
    if (!current()) return 'команда устарела';
    applied.add(selection);
    return applyError;
  }

  @override
  Future<String?> stopEngine(StillCurrent current) async {
    if (!_coreRunning) return null;
    stopCalls++;
    await Future<void>.delayed(stopDelay);
    if (stopError != null) return stopError;
    status = AppEngineStatus.disconnected;
    coreRunning = false;
    return null;
  }
}

/// Держатель замка start.lock по протоколу (fcntl.lockf / msvcrt.locking на байт 0) в отдельном процессе.
/// `hold` — взять и держать до завершения процесса; `probe` — напечатать held / free.
const lockHolderPy = r'''
import os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | getattr(os, "O_BINARY", 0), 0o600)
def lock():
    if sys.platform == "win32":
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 0, os.SEEK_SET)
if sys.argv[2] == "probe":
    try:
        lock()
        print("free", flush=True)
    except OSError:
        print("held", flush=True)
else:
    lock()
    print("locked", flush=True)
    sys.stdin.read()
''';

String get testPython => Platform.environment['SBX_PYTHON'] ?? (Platform.isWindows ? 'python' : 'python3');
