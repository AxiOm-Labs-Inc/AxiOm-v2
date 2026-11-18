import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_process.dart';
import 'package:hiddify/features/cli_sync/legacy_cli_migration.dart';
import 'package:path/path.dart' as p;

void main() {
  final isWindows = Platform.isWindows;
  final binName = isWindows ? 'axiom.exe' : 'axiom';

  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('legacy_cli_'));
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> makeFile(String rel, String content) async {
    final file = File(p.join(tmp.path, rel));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file.path;
  }

  /// Подставной запуск `version`: ответ зависит от содержимого файла.
  /// LEGACY… — старый Go-CLI, SBX14… — SBX 1.4.0, SBX13… — SBX 1.3.0, остальное — ошибка запуска.
  Future<CliRunResult> fakeRun(String exe, List<String> args, {Duration timeout = const Duration(seconds: 30)}) async {
    expect(args, ['version']);
    expect(timeout, const Duration(seconds: 10));
    final content = await File(exe).readAsString();
    if (content.startsWith('LEGACY')) {
      return const CliRunResult(exitCode: 0, stdout: 'axiom-cli 0.0.3 (linux/amd64)\n', stderr: '');
    }
    if (content.startsWith('SBX14')) return const CliRunResult(exitCode: 0, stdout: 'axiom 1.4.0\n', stderr: '');
    if (content.startsWith('SBX13')) return const CliRunResult(exitCode: 0, stdout: 'axiom 1.3.0\n', stderr: '');
    return CliRunResult(exitCode: -1, stdout: '', stderr: 'cannot run $exe: axiom-cli');
  }

  group('candidates', () {
    test('Linux: PATH, then ~/axiom-cli', () {
      final list = legacyCliCandidates(
        isWindows: false,
        env: {'PATH': '/usr/local/bin:/home/u/bin::/usr/local/bin', 'HOME': '/home/u'},
      );
      expect(list, ['/usr/local/bin/axiom', '/home/u/bin/axiom', '/home/u/axiom-cli/axiom']);
    });

    test('Windows: PATH (case-insensitive, quotes), then the usual unpack folders', () {
      final list = legacyCliCandidates(
        isWindows: true,
        env: {
          'Path': r'C:\Windows;c:\windows;"C:\Tools";',
          'USERPROFILE': r'C:\Users\u',
          'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
        },
      );
      expect(list, [
        r'C:\Windows\axiom.exe',
        r'C:\Tools\axiom.exe',
        r'C:\AxiOm-cli\axiom.exe',
        r'C:\Users\u\axiom-cli\axiom.exe',
        r'C:\Users\u\AppData\Local\AxiOm-cli\axiom.exe',
      ]);
    });

    test('existing only, installer CLI skipped, duplicates merged', () async {
      final installer = await makeFile(p.join('app', 'cli', binName), 'SBX');
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final missing = p.join(tmp.path, 'nowhere', binName);
      final candidates = [installer, legacy, missing, legacy];
      if (!isWindows) {
        // /usr/bin/axiom → /usr/lib/axiom/cli/axiom: ссылка на CLI установщика тоже пропускается,
        // ссылка на старый CLI сводится к нему самому.
        final toInstaller = p.join(tmp.path, 'bin', 'axiom');
        final toLegacy = p.join(tmp.path, 'bin2', 'axiom');
        await Link(toInstaller).create(installer, recursive: true);
        await Link(toLegacy).create(legacy, recursive: true);
        candidates.addAll([toInstaller, toLegacy]);
      }
      final found = await existingLegacyCandidates(
        candidates,
        installerPaths: [installer],
        isWindows: isWindows,
      );
      expect(found, [await File(legacy).resolveSymbolicLinks()]);
    });

    if (isWindows) {
      test('Windows paths compare case-insensitively with the installer', () async {
        final installer = await makeFile(p.join('App', 'cli', 'axiom.exe'), 'SBX');
        final found = await existingLegacyCandidates(
          [installer.toLowerCase()],
          installerPaths: [installer.toUpperCase()],
          isWindows: true,
        );
        expect(found, isEmpty);
      });
    }
  });

  group('release asset', () {
    final release = {
      'tag_name': 'v1.3.0',
      'assets': [
        {'name': 'sbx.py', 'browser_download_url': 'https://x/sbx.py', 'digest': 'sha256:${'a' * 64}'},
        {'name': 'sbx-windows-amd64.exe', 'browser_download_url': 'https://x/sbx.exe', 'digest': null},
      ],
    };

    test('picks url and sha256 by name', () {
      expect(pickReleaseAsset(release, 'sbx.py'), (url: 'https://x/sbx.py', sha256: 'a' * 64));
      expect(pickReleaseAsset(release, 'sbx-windows-amd64.exe'), isNull, reason: 'no digest');
      expect(pickReleaseAsset(release, 'other'), isNull);
      expect(pickReleaseAsset('x', 'sbx.py'), isNull);
      expect(sbxAssetName(isWindows: true), 'sbx-windows-amd64.exe');
      expect(sbxAssetName(isWindows: false), 'sbx.py');
    });

    test('sha256 check', () {
      final bytes = utf8.encode('hello');
      expect(sha256Matches(bytes, sha256.convert(bytes).toString().toUpperCase()), isTrue);
      expect(sha256Matches(bytes, 'b' * 64), isFalse);
    });
  });

  group('replaceCliBinary', () {
    List<String> names(String dir) => Directory(dir).listSync().map((e) => p.basename(e.path)).toList()..sort();

    test('replaces the file and verifies the new CLI (Windows keeps a unique backup, Linux mode 755)', () async {
      final target = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final source = await makeFile('new-sbx', 'SBX14');
      await replaceCliBinary(target, source, isWindows: isWindows, run: fakeRun, clock: () => 1000);
      expect(await File(target).readAsString(), 'SBX14');
      if (isWindows) {
        expect(await File('$target.old-1000').readAsString(), 'LEGACY');
      } else {
        expect((await File(target).stat()).mode & 0x1FF, 0x1ED); // 0755
        expect(names(p.dirname(target)), ['axiom'], reason: 'backup and temp removed');
      }
    });

    test('an existing backup is never overwritten', () async {
      final target = await makeFile(p.join('axiom-cli', binName), 'LEGACY2');
      await makeFile(p.join('axiom-cli', '$binName.old-1000'), 'SOMEONE ELSE');
      final source = await makeFile('new-sbx', 'SBX14');
      await replaceCliBinary(target, source, isWindows: isWindows, run: fakeRun, clock: () => 1000);
      expect(await File('$target.old-1000').readAsString(), 'SOMEONE ELSE');
      if (isWindows) expect(await File('$target.old-1000-1').readAsString(), 'LEGACY2');
    });

    test('a failed copy leaves the old CLI in place', () async {
      final target = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final source = p.join(tmp.path, 'missing-source');
      await expectLater(replaceCliBinary(target, source, isWindows: isWindows, run: fakeRun), throwsA(anything));
      expect(await File(target).readAsString(), 'LEGACY');
      expect(names(p.dirname(target)), [binName]);
    });

    test('a replacement that is not SBX >= 1.4.0 is rolled back', () async {
      final target = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final source = await makeFile('old-sbx', 'SBX13');
      await expectLater(replaceCliBinary(target, source, isWindows: isWindows, run: fakeRun), throwsA(anything));
      expect(await File(target).readAsString(), 'LEGACY');
      expect(names(p.dirname(target)), [binName]);
    });
  });

  group('migrateLegacyCli', () {
    test('replaces only the old Go CLI, from the installer CLI', () async {
      final installer = await makeFile(p.join('app', 'cli', binName), 'SBX14-FROM-INSTALLER');
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final sbx = await makeFile(p.join('elsewhere', binName), 'SBX13');
      final broken = await makeFile(p.join('broken', binName), 'garbage');
      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: [installer],
        installerSources: [installer],
        tempDir: tmp,
        run: fakeRun,
        fetch: (_) => fail('must not download when the installer CLI is SBX >= 1.4.0'),
        candidates: [installer, legacy, sbx, broken],
      );
      expect(report.hasFailures, isFalse);
      expect(report.results, {
        await File(legacy).resolveSymbolicLinks(): LegacyOutcome.replaced,
        await File(sbx).resolveSymbolicLinks(): LegacyOutcome.notLegacy,
        await File(broken).resolveSymbolicLinks(): LegacyOutcome.notLegacy,
      });
      expect(report.replaced, [await File(legacy).resolveSymbolicLinks()]);
      expect(await File(legacy).readAsString(), 'SBX14-FROM-INSTALLER');
      expect(await File(sbx).readAsString(), 'SBX13');
      expect(await File(broken).readAsString(), 'garbage', reason: 'a failed launch is never "old CLI"');
    });

    test('nothing found — nothing done', () async {
      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: const [],
        installerSources: const [],
        tempDir: tmp,
        run: fakeRun,
        fetch: (_) => fail('no download'),
        candidates: [p.join(tmp.path, 'none', binName)],
      );
      expect(report.results, isEmpty);
      expect(report.hasFailures, isFalse);
    });

    Future<List<int>> Function(Uri) releaseFetcher(List<int> payload, {String? digest, String tag = 'v1.4.0'}) {
      final asset = sbxAssetName(isWindows: isWindows);
      return (url) async {
        if (url.toString() == sbxReleaseApi) {
          return utf8.encode(
            jsonEncode({
              'tag_name': tag,
              'assets': [
                {
                  'name': asset,
                  'browser_download_url': 'https://example.invalid/$asset',
                  'digest': 'sha256:${digest ?? sha256.convert(payload)}',
                },
              ],
            }),
          );
        }
        expect(url.toString(), 'https://example.invalid/$asset');
        return payload;
      };
    }

    test('installer CLI older than 1.4.0 → downloads SBX >= 1.4.0 and verifies sha256', () async {
      final installer = await makeFile(p.join('app', 'cli', binName), 'SBX13');
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: [installer],
        installerSources: [installer, p.join(tmp.path, 'no-installer', binName)],
        tempDir: Directory(p.join(tmp.path, 'dl')),
        run: fakeRun,
        fetch: releaseFetcher(utf8.encode('SBX14 DOWNLOADED')),
        candidates: [legacy],
      );
      expect(report.hasFailures, isFalse);
      expect(report.results.values, [LegacyOutcome.replaced]);
      expect(await File(legacy).readAsString(), 'SBX14 DOWNLOADED');
      expect(Directory(p.join(tmp.path, 'dl')).listSync(), isEmpty, reason: 'temp copies removed');
    });

    test('sha256 mismatch: nothing replaced, retry next start', () async {
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: const [],
        installerSources: const [],
        tempDir: tmp,
        run: fakeRun,
        fetch: releaseFetcher(utf8.encode('SBX14 EVIL'), digest: 'c' * 64),
        candidates: [legacy],
      );
      expect(report.hasFailures, isTrue);
      expect(report.results.values, [LegacyOutcome.failed]);
      expect(await File(legacy).readAsString(), 'LEGACY');
    });

    test('latest SBX release older than 1.4.0 is not used', () async {
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: const [],
        installerSources: const [],
        tempDir: tmp,
        run: fakeRun,
        fetch: releaseFetcher(utf8.encode('SBX13'), tag: 'v1.3.0'),
        candidates: [legacy],
      );
      expect(report.hasFailures, isTrue);
      expect(report.errors.values.single, contains('1.4.0'));
      expect(await File(legacy).readAsString(), 'LEGACY');
    });

    test('a failed replacement is reported (marker not saved, retried next start)', () async {
      final installer = await makeFile(p.join('app', 'cli', binName), 'SBX14');
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final legacyResolved = await File(legacy).resolveSymbolicLinks();
      // Источник проверен на копии, но на месте старого CLI новый файл «не запускается» — откат.
      Future<CliRunResult> run(String exe, List<String> args, {Duration timeout = const Duration(seconds: 30)}) async {
        if (exe == legacyResolved && (await File(exe).readAsString()).startsWith('SBX14')) {
          return const CliRunResult(exitCode: 1, stdout: '', stderr: 'boom');
        }
        return fakeRun(exe, args, timeout: timeout);
      }

      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: [installer],
        installerSources: [installer],
        tempDir: tmp,
        run: run,
        fetch: (_) => fail('no download'),
        candidates: [legacy],
      );
      expect(report.hasFailures, isTrue);
      expect(await File(legacy).readAsString(), 'LEGACY');
    });

    test('the source is verified on a temp copy before anything is replaced', () async {
      final installer = await makeFile(p.join('app', 'cli', binName), 'SBX14');
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final legacyResolved = await File(legacy).resolveSymbolicLinks();
      final versionRuns = <String>[];
      Future<CliRunResult> run(String exe, List<String> args, {Duration timeout = const Duration(seconds: 30)}) async {
        versionRuns.add(exe);
        return fakeRun(exe, args, timeout: timeout);
      }

      await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: [installer],
        installerSources: [installer],
        tempDir: Directory(p.join(tmp.path, 'work')),
        run: run,
        fetch: (_) => fail('no download'),
        candidates: [legacy],
      );
      // 1) старый CLI, 2) копия источника (не сам источник и не цель), 3) проверка после замены.
      expect(versionRuns.length, 3);
      expect(versionRuns[0], legacyResolved);
      expect(p.isWithin(p.join(tmp.path, 'work'), versionRuns[1]), isTrue);
      expect(p.basename(versionRuns[1]), binName);
      expect(versionRuns[2], legacyResolved);
      expect(Directory(p.join(tmp.path, 'work')).listSync(), isEmpty, reason: 'temp copies removed');
    });

    if (!isWindows) {
      test('Linux: real `version` runs of fake binaries (shell scripts)', () async {
        Future<String> script(String rel, String output) async {
          final path = await makeFile(rel, '#!/bin/sh\n[ "\$1" = version ] && echo "$output"\n');
          await Process.run('chmod', ['755', path]);
          return path;
        }

        final old = await script(p.join('home', 'axiom-cli', 'axiom'), 'axiom-cli 0.0.3 (linux/amd64)');
        final sbx = await script(p.join('bin', 'axiom'), 'axiom 1.3.0');
        final source = await script(p.join('usr', 'lib', 'axiom', 'cli', 'axiom'), 'axiom 1.4.0');
        final report = await migrateLegacyCli(
          isWindows: false,
          env: {'PATH': p.join(tmp.path, 'bin'), 'HOME': p.join(tmp.path, 'home')},
          installerPaths: [source],
          installerSources: [source],
          tempDir: tmp,
          fetch: (_) => fail('no download'),
        );
        expect(report.results, {old: LegacyOutcome.replaced, sbx: LegacyOutcome.notLegacy});
        final after = await Process.run(old, ['version']);
        expect(after.stdout, contains('axiom 1.4.0'));
      });
    }
  });
}
