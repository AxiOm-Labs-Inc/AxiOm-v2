import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_process.dart';

/// Команда оболочки той ОС, на которой идут тесты (без runInShell: исполняемый файл — сама оболочка).
(String, List<String>) shell(String posix, String windows) =>
    Platform.isWindows ? ('cmd.exe', ['/c', windows]) : ('/bin/sh', ['-c', posix]);

void main() {
  test('collects stdout, stderr and the exit code', () async {
    final (exe, args) = shell('echo hello; echo oops >&2; exit 3', 'echo hello& echo oops 1>&2& exit 3');
    final result = await runCliProcess(exe, args);
    expect(result.exitCode, 3);
    expect(result.ok, isFalse);
    expect(result.stdout.trim(), 'hello');
    expect(result.stderr.trim(), 'oops');
    expect(result.message, 'oops');
  });

  test('success', () async {
    final (exe, args) = shell('echo done', 'echo done');
    final result = await runCliProcess(exe, args);
    expect(result.ok, isTrue);
    expect(result.message, 'done');
  });

  test('stdin is closed: a prompt gets EOF instead of hanging', () async {
    final (exe, args) = shell('read x; echo "got:$x"', r'set /p x= & echo got:%x%');
    final result = await runCliProcess(exe, args, timeout: const Duration(seconds: 10));
    expect(result.timedOut, isFalse);
    expect(result.stdout, contains('got:'));
  });

  test('timeout kills the process', () async {
    final (exe, args) = shell('sleep 30', 'ping -n 30 127.0.0.1');
    final watch = Stopwatch()..start();
    final result = await runCliProcess(exe, args, timeout: const Duration(milliseconds: 500));
    expect(result.timedOut, isTrue);
    expect(result.ok, isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('missing executable is an error result, not an exception', () async {
    final result = await runCliProcess(Platform.isWindows ? r'C:\nope\axiom.exe' : '/nope/axiom', ['version']);
    expect(result.ok, isFalse);
    expect(result.exitCode, -1);
  });

  test('ANSI colors are stripped from the message', () {
    expect(stripAnsi('\x1B[31mошибка\x1B[0m\r'), 'ошибка');
    expect(const CliRunResult(exitCode: 1, stdout: 'a\n\nlast\n', stderr: '').message, 'last');
  });
}
