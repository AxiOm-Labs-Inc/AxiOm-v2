// Замена старого Go-CLI AxiOm (cli-v0.0.x, папка, которую пользователь распаковал сам) на SBX.
//
// Раз на версию приложения: ищем `axiom`/`axiom.exe` в PATH и в типичных папках распаковки,
// пропускаем CLI самого установщика, подтверждаем старый CLI по выводу `<bin> version`
// ("axiom-cli 0.0.3 (linux/amd64)"; SBX печатает "axiom 1.3.0") и подменяем файл на SBX:
// источник — CLI установщика, иначе последний релиз SBX с проверкой sha256 из GitHub API.
// Остальные файлы старого CLI (axiom-core.*, libcronet.dll, VERSION) не трогаем.
// Без зависимостей от Flutter: платформа, окружение, запуск процессов и загрузка передаются явно.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:hiddify/features/cli_sync/cli_process.dart';
import 'package:path/path.dart' as p;

const sbxReleaseApi = 'https://api.github.com/repos/Xenon-Tetraoxide/SBX-VPN-Client/releases/latest';

String sbxAssetName({required bool isWindows}) => isWindows ? 'sbx-windows-amd64.exe' : 'sbx.py';

/// Вывод `axiom version` старого Go-CLI.
bool isLegacyCliVersionOutput(String output) => stripAnsi(output).toLowerCase().contains('axiom-cli');

p.Context _ctx(bool isWindows) => isWindows ? p.windows : p.posix;

/// Все места, где может лежать старый CLI (без проверки существования), без повторов.
List<String> legacyCliCandidates({required bool isWindows, required Map<String, String> env}) {
  final ctx = _ctx(isWindows);
  final name = isWindows ? 'axiom.exe' : 'axiom';
  final result = <String>[];
  final pathVar = isWindows ? (env['PATH'] ?? env['Path'] ?? '') : (env['PATH'] ?? '');
  for (final raw in pathVar.split(isWindows ? ';' : ':')) {
    final dir = raw.trim().replaceAll('"', '');
    if (dir.isEmpty) continue;
    result.add(ctx.join(dir, name));
  }
  if (isWindows) {
    result.add(r'C:\AxiOm-cli\axiom.exe');
    final profile = env['USERPROFILE'];
    if (profile != null && profile.isNotEmpty) result.add(ctx.join(profile, 'axiom-cli', 'axiom.exe'));
    final local = env['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) result.add(ctx.join(local, 'AxiOm-cli', 'axiom.exe'));
  } else {
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) result.add(ctx.join(home, 'axiom-cli', 'axiom'));
  }
  return _dedupe(result.map(ctx.normalize), isWindows);
}

List<String> _dedupe(Iterable<String> paths, bool isWindows) {
  final seen = <String>{};
  return paths.where((path) => seen.add(isWindows ? path.toLowerCase() : path)).toList();
}

/// Путь без символических ссылок; если файла нет или ссылка битая — сам путь.
Future<String> resolvePath(String path) async {
  try {
    return await File(path).resolveSymbolicLinks();
  } catch (_) {
    return path;
  }
}

/// Существующие кандидаты (уже без ссылок), кроме CLI установщика, без повторов.
Future<List<String>> existingLegacyCandidates(
  List<String> candidates, {
  required List<String> installerPaths,
  required bool isWindows,
}) async {
  String key(String path) => isWindows ? _ctx(true).normalize(path).toLowerCase() : path;
  final skip = <String>{};
  for (final path in installerPaths) {
    skip.add(key(path));
    skip.add(key(await resolvePath(path)));
  }
  final result = <String>[];
  final seen = <String>{};
  for (final candidate in candidates) {
    if (!await File(candidate).exists()) continue;
    final resolved = await resolvePath(candidate);
    if (skip.contains(key(candidate)) || skip.contains(key(resolved))) continue;
    if (seen.add(key(resolved))) result.add(resolved);
  }
  return result;
}

/// Подменить [target] файлом [source].
///
/// Windows: старый файл переименовывается в `<target>.old` (так можно и с запущенным exe),
/// затем копируется новый; при ошибке старый возвращается на место.
/// Linux: копия рядом, chmod 755, атомарный rename поверх.
Future<void> replaceCliBinary(String target, String source, {required bool isWindows}) async {
  if (isWindows) {
    final old = File('$target.old');
    if (await old.exists()) {
      try {
        await old.delete();
      } catch (_) {
        // прежний .old ещё запущен — rename ниже тогда не пройдёт и сообщит об ошибке
      }
    }
    await File(target).rename(old.path);
    try {
      await File(source).copy(target);
    } catch (_) {
      try {
        if (await File(target).exists()) await File(target).delete();
      } catch (_) {}
      await old.rename(target);
      rethrow;
    }
    return;
  }
  final tmp = File('$target.axiom-new.$pid');
  try {
    await File(source).copy(tmp.path);
    final chmod = await Process.run('chmod', ['755', tmp.path]);
    if (chmod.exitCode != 0) throw FileSystemException('chmod 755: ${chmod.stderr}', tmp.path);
    await tmp.rename(target);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Ассет релиза из ответа GitHub API: (адрес загрузки, sha256 hex) или null,
/// если ассета нет или у него нет `digest` вида `sha256:…`.
({String url, String sha256})? pickReleaseAsset(Object? release, String name) {
  if (release is! Map || release['assets'] is! List) return null;
  for (final asset in release['assets'] as List) {
    if (asset is! Map || asset['name'] != name) continue;
    final url = asset['browser_download_url'];
    final digest = asset['digest'];
    if (url is! String || digest is! String || !digest.startsWith('sha256:')) return null;
    final hex = digest.substring('sha256:'.length).toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
    return (url: url, sha256: hex);
  }
  return null;
}

bool sha256Matches(List<int> bytes, String expectedHex) => sha256.convert(bytes).toString() == expectedHex.toLowerCase();

/// Загрузка байтов по адресу — подменяется в тестах.
typedef BytesFetcher = Future<List<int>> Function(Uri url);

Future<List<int>> httpFetchBytes(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  client.userAgent = 'AxiOm-app';
  try {
    final request = await client.getUrl(url);
    if (url.host == 'api.github.com') request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final builder = BytesBuilder(copy: false);
    await response.timeout(const Duration(seconds: 60)).forEach(builder.add);
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// Последний SBX из релиза: проверенные по sha256 байты.
Future<List<int>> downloadLatestSbx({required bool isWindows, BytesFetcher fetch = httpFetchBytes}) async {
  final name = sbxAssetName(isWindows: isWindows);
  final release = jsonDecode(utf8.decode(await fetch(Uri.parse(sbxReleaseApi))));
  final asset = pickReleaseAsset(release, name);
  if (asset == null) throw StateError('в последнем релизе SBX нет $name с sha256');
  final bytes = await fetch(Uri.parse(asset.url));
  if (!sha256Matches(bytes, asset.sha256)) throw StateError('sha256 $name не совпал с релизом');
  return bytes;
}

enum LegacyOutcome { replaced, notLegacy, failed }

class LegacyCliReport {
  final results = <String, LegacyOutcome>{};
  final errors = <String, String>{};

  /// Не удалось получить SBX (сеть) — проверку стоит повторить при следующем запуске.
  bool transientFailure = false;

  @override
  String toString() => 'LegacyCliReport(results: $results, errors: $errors, transient: $transientFailure)';
}

/// Найти старые CLI и заменить их SBX.
Future<LegacyCliReport> migrateLegacyCli({
  required bool isWindows,
  required Map<String, String> env,
  required List<String> installerPaths,
  required List<String> installerSources,
  required Directory tempDir,
  CliProcessRunner run = runCliProcess,
  BytesFetcher fetch = httpFetchBytes,
  List<String>? candidates,
}) async {
  final report = LegacyCliReport();
  final found = await existingLegacyCandidates(
    candidates ?? legacyCliCandidates(isWindows: isWindows, env: env),
    installerPaths: installerPaths,
    isWindows: isWindows,
  );
  final legacy = <String>[];
  for (final path in found) {
    final result = await run(path, const ['version'], timeout: const Duration(seconds: 10));
    if (isLegacyCliVersionOutput('${result.stdout}\n${result.stderr}')) {
      legacy.add(path);
    } else {
      report.results[path] = LegacyOutcome.notLegacy;
    }
  }
  if (legacy.isEmpty) return report;

  String? source;
  for (final path in installerSources) {
    if (await File(path).exists()) {
      source = await resolvePath(path);
      break;
    }
  }
  File? downloaded;
  if (source == null) {
    try {
      final bytes = await downloadLatestSbx(isWindows: isWindows, fetch: fetch);
      await tempDir.create(recursive: true);
      downloaded = File(_ctx(Platform.isWindows).join(tempDir.path, 'axiom-sbx-$pid-${sbxAssetName(isWindows: isWindows)}'));
      await downloaded.writeAsBytes(bytes, flush: true);
      source = downloaded.path;
    } catch (e) {
      report.transientFailure = true;
      for (final path in legacy) {
        report.results[path] = LegacyOutcome.failed;
        report.errors[path] = 'загрузка SBX: $e';
      }
      return report;
    }
  }
  try {
    for (final path in legacy) {
      try {
        await replaceCliBinary(path, source, isWindows: isWindows);
        report.results[path] = LegacyOutcome.replaced;
      } catch (e) {
        report.results[path] = LegacyOutcome.failed;
        report.errors[path] = '$e';
      }
    }
  } finally {
    try {
      if (downloaded != null && await downloaded.exists()) await downloaded.delete();
    } catch (_) {}
  }
  return report;
}
