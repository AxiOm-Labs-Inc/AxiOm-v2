// Запуск CLI: без оболочки (на Windows Dart сам ставит CREATE_NO_WINDOW — окна консоли нет),
// stdin сразу закрыт (вопросы CLI получат EOF, а не повиснут), по таймауту процесс убивается.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CliRunResult {
  const CliRunResult({required this.exitCode, required this.stdout, required this.stderr, this.timedOut = false});

  /// -1, если процесс не запустился или убит по таймауту.
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  bool get ok => exitCode == 0 && !timedOut;

  /// Короткое сообщение для пользователя: последняя непустая строка stderr, иначе stdout.
  String get message {
    for (final text in [stderr, stdout]) {
      final lines = stripAnsi(text).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (lines.isNotEmpty) return lines.last;
    }
    return timedOut ? 'timeout' : 'exit code $exitCode';
  }

  @override
  String toString() => 'CliRunResult(exit: $exitCode, timedOut: $timedOut, stdout: $stdout, stderr: $stderr)';
}

final _ansi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

String stripAnsi(String text) => text.replaceAll(_ansi, '').replaceAll('\r', '');

/// Запуск процесса — подменяется в тестах.
typedef CliProcessRunner = Future<CliRunResult> Function(String executable, List<String> args, {Duration timeout});

Future<CliRunResult> runCliProcess(
  String executable,
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final Process process;
  try {
    process = await Process.start(
      executable,
      args,
      environment: const {'NO_COLOR': '1', 'PYTHONIOENCODING': 'utf-8'},
    );
  } catch (e) {
    return CliRunResult(exitCode: -1, stdout: '', stderr: '$e');
  }
  unawaited(process.stdin.close().catchError((_) {}));
  final out = StringBuffer();
  final err = StringBuffer();
  const decoder = Utf8Decoder(allowMalformed: true);
  final outDone = process.stdout.transform(decoder).forEach(out.write).catchError((_) {});
  final errDone = process.stderr.transform(decoder).forEach(err.write).catchError((_) {});
  var timedOut = false;
  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  // Потомки убитого процесса могут держать каналы открытыми — не ждём их дольше секунды.
  await Future.wait([outDone, errDone]).timeout(const Duration(seconds: 1), onTimeout: () => []);
  return CliRunResult(exitCode: exitCode, stdout: out.toString(), stderr: err.toString(), timedOut: timedOut);
}
