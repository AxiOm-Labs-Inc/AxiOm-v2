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

  /// Подставной запуск: «старый CLI» узнаётся по содержимому файла.
  Future<CliRunResult> fakeRun(String exe, List<String> args, {Duration timeout = const Duration(seconds: 30)}) async {
    expect(args, ['version']);
    expect(timeout, const Duration(seconds: 10));
    final content = await File(exe).readAsString();
    if (content.startsWith('LEGACY')) {
      return const CliRunResult(exitCode: 0, stdout: 'axiom-cli 0.0.3 (linux/amd64)\n', stderr: '');
    }
    return const CliRunResult(exitCode: 0, stdout: 'axiom 1.3.0\n', stderr: '');
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

  test('version output of the old Go CLI', () {
    expect(isLegacyCliVersionOutput('axiom-cli 0.0.3 (linux/amd64)'), isTrue);
    expect(isLegacyCliVersionOutput('\x1B[1mAxiOm-CLI\x1B[0m 0.0.2 (windows/amd64)'), isTrue);
    expect(isLegacyCliVersionOutput('axiom 1.3.0'), isFalse);
    expect(isLegacyCliVersionOutput(''), isFalse);
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
    test('replaces the file (Windows: keeps .old; Linux: mode 755, atomic)', () async {
      final target = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final source = await makeFile('new-sbx', 'NEW');
      await replaceCliBinary(target, source, isWindows: isWindows);
      expect(await File(target).readAsString(), 'NEW');
      if (isWindows) {
        expect(await File('$target.old').readAsString(), 'LEGACY');
      } else {
        expect((await File(target).stat()).mode & 0x1FF, 0x1ED); // 0755
        expect(Directory(p.dirname(target)).listSync().map((e) => p.basename(e.path)), ['axiom']);
      }
    });

    test('Windows: a stale .old from the last update is replaced', () async {
      if (!isWindows) return;
      final target = await makeFile(p.join('axiom-cli', binName), 'LEGACY2');
      await makeFile(p.join('axiom-cli', '$binName.old'), 'LEGACY1');
      final source = await makeFile('new-sbx', 'NEW');
      await replaceCliBinary(target, source, isWindows: true);
      expect(await File(target).readAsString(), 'NEW');
      expect(await File('$target.old').readAsString(), 'LEGACY2');
    });

    test('a failed copy leaves the old CLI in place', () async {
      final target = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final source = p.join(tmp.path, 'missing-source');
      await expectLater(replaceCliBinary(target, source, isWindows: isWindows), throwsA(anything));
      expect(await File(target).readAsString(), 'LEGACY');
      expect(Directory(p.dirname(target)).listSync().map((e) => p.basename(e.path)), [binName]);
    });
  });

  group('migrateLegacyCli', () {
    test('replaces only the old Go CLI, from the installer CLI', () async {
      final installer = await makeFile(p.join('app', 'cli', binName), 'NEW-FROM-INSTALLER');
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final sbx = await makeFile(p.join('elsewhere', binName), 'SBX');
      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: [installer],
        installerSources: [installer],
        tempDir: tmp,
        run: fakeRun,
        fetch: (_) => fail('must not download when the installer CLI exists'),
        candidates: [installer, legacy, sbx],
      );
      expect(report.transientFailure, isFalse);
      expect(report.results, {
        await File(legacy).resolveSymbolicLinks(): LegacyOutcome.replaced,
        await File(sbx).resolveSymbolicLinks(): LegacyOutcome.notLegacy,
      });
      expect(await File(legacy).readAsString(), 'NEW-FROM-INSTALLER');
      expect(await File(sbx).readAsString(), 'SBX');
      expect(await File(installer).readAsString(), 'NEW-FROM-INSTALLER');
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
      expect(report.transientFailure, isFalse);
    });

    Future<List<int>> Function(Uri) releaseFetcher(List<int> payload, {String? digest}) {
      final asset = sbxAssetName(isWindows: isWindows);
      return (url) async {
        if (url.toString() == sbxReleaseApi) {
          return utf8.encode(
            jsonEncode({
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

    test('without the installer CLI downloads SBX and verifies sha256', () async {
      final legacy = await makeFile(p.join('axiom-cli', binName), 'LEGACY');
      final report = await migrateLegacyCli(
        isWindows: isWindows,
        env: const {},
        installerPaths: const [],
        installerSources: [p.join(tmp.path, 'no-installer', binName)],
        tempDir: Directory(p.join(tmp.path, 'dl')),
        run: fakeRun,
        fetch: releaseFetcher(utf8.encode('DOWNLOADED')),
        candidates: [legacy],
      );
      expect(report.transientFailure, isFalse);
      expect(report.results.values, [LegacyOutcome.replaced]);
      expect(await File(legacy).readAsString(), 'DOWNLOADED');
      expect(Directory(p.join(tmp.path, 'dl')).listSync(), isEmpty, reason: 'temp download removed');
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
        fetch: releaseFetcher(utf8.encode('EVIL'), digest: 'c' * 64),
        candidates: [legacy],
      );
      expect(report.transientFailure, isTrue);
      expect(report.results.values, [LegacyOutcome.failed]);
      expect(await File(legacy).readAsString(), 'LEGACY');
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
        final source = await makeFile(p.join('usr', 'lib', 'axiom', 'cli', 'axiom'), '#!/bin/sh\necho "axiom 1.3.0"\n');
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
        expect(after.stdout, contains('axiom 1.3.0'));
      });
    }
  });
}
