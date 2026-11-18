// Замена старого Go-CLI AxiOm (cli-v0.0.x, папка, которую пользователь распаковал сам) на SBX.
//
// Раз на версию приложения: ищем `axiom`/`axiom.exe` в PATH и в типичных папках распаковки,
// пропускаем CLI самого установщика, подтверждаем старый CLI строго: `<bin> version` завершился с кодом 0
// и первая строка stdout — `axiom-cli X.Y.Z`. Подменяем файл на SBX ≥ 1.4.0: источник — CLI установщика
// (проверяется его `version`), иначе релиз SBX ≥ 1.4.0 с проверкой sha256 из GitHub API. После замены
// новый файл обязан ответить `axiom X.Y.Z` ≥ 1.4.0, иначе возвращается копия старого
// (`<имя>.old-<время>`). Остальные файлы старого CLI (axiom-core.*, libcronet.dll, VERSION) не трогаем.
// Без зависимостей от Flutter: платформа, окружение, запуск процессов и загрузка передаются явно.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hiddify/features/cli_sync/cli_process.dart';
import 'package:hiddify/features/cli_sync/cli_version.dart';
import 'package:path/path.dart' as p;

const sbxReleaseApi = 'https://api.github.com/repos/Xenon-Tetraoxide/SBX-VPN-Client/releases/latest';

String sbxAssetName({required bool isWindows}) => isWindows ? 'sbx-windows-amd64.exe' : 'sbx.py';

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

/// Подменить [target] файлом [source] и проверить, что это SBX ≥ 1.4.0 (`<target> version`).
///
/// Копия старого файла — `<target>.old-<время>` (имя не занято, чужие файлы не трогаются).
/// Windows: старый файл переименовывается в копию (так можно и с запущенным exe), новый копируется на место.
/// Linux: копия старого (`cp -p`), новый — рядом, chmod 755 и атомарный rename поверх.
/// Любая ошибка или неверная версия — старый файл возвращается на место, исключение наружу.
/// Linux: копия при успехе удаляется; Windows: остаётся (старый exe может ещё работать).
Future<void> replaceCliBinary(
  String target,
  String source, {
  required bool isWindows,
  CliProcessRunner run = runCliProcess,
  int Function()? clock,
}) async {
  final stamp = (clock ?? () => DateTime.now().millisecondsSinceEpoch)();
  var backup = File('$target.old-$stamp');
  for (var i = 1; await backup.exists(); i++) {
    backup = File('$target.old-$stamp-$i');
  }
  Future<void> verify() async {
    final result = await run(target, const ['version'], timeout: const Duration(seconds: 10));
    if (!isCompatibleSbxRun(result)) {
      throw StateError('новый CLI не SBX ≥ 1.4.0: ${result.message}');
    }
  }

  if (isWindows) {
    await File(target).rename(backup.path);
    try {
      await File(source).copy(target);
      await verify();
    } catch (_) {
      try {
        if (await File(target).exists()) await File(target).delete();
      } catch (_) {}
      await backup.rename(target);
      rethrow;
    }
    return;
  }
  final copy = await Process.run('cp', ['-p', target, backup.path]);
  if (copy.exitCode != 0) throw FileSystemException('cp -p: ${copy.stderr}', target);
  final tmp = File('$target.axiom-new.$pid');
  try {
    await File(source).copy(tmp.path);
    final chmod = await Process.run('chmod', ['755', tmp.path]);
    if (chmod.exitCode != 0) throw FileSystemException('chmod 755: ${chmod.stderr}', tmp.path);
    await tmp.rename(target);
    await verify();
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    await backup.rename(target);
    rethrow;
  }
  try {
    await backup.delete();
  } catch (_) {}
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

/// Последний SBX из релиза: проверенные по sha256 байты. Релиз старше 1.4.0 не годится.
Future<List<int>> downloadLatestSbx({required bool isWindows, BytesFetcher fetch = httpFetchBytes}) async {
  final name = sbxAssetName(isWindows: isWindows);
  final release = jsonDecode(utf8.decode(await fetch(Uri.parse(sbxReleaseApi))));
  final tag = release is Map && release['tag_name'] is String ? release['tag_name'] as String : '';
  if (!isSyncCompatible(parseReleaseTag(tag))) {
    throw StateError('последний релиз SBX ($tag) старше 1.4.0 — синхронизации с приложением в нём нет');
  }
  final asset = pickReleaseAsset(release, name);
  if (asset == null) throw StateError('в релизе SBX $tag нет $name с sha256');
  final bytes = await fetch(Uri.parse(asset.url));
  if (!sha256Matches(bytes, asset.sha256)) throw StateError('sha256 $name не совпал с релизом');
  return bytes;
}

enum LegacyOutcome { replaced, notLegacy, failed }

class LegacyCliReport {
  final results = <String, LegacyOutcome>{};
  final errors = <String, String>{};

  /// Хоть одна замена не удалась (или SBX не получить) — повторить при следующем запуске.
  bool get hasFailures => results.values.contains(LegacyOutcome.failed);

  /// Заменённые на SBX пути — ими можно пользоваться как CLI.
  List<String> get replaced => [
    for (final e in results.entries)
      if (e.value == LegacyOutcome.replaced) e.key,
  ];

  @override
  String toString() => 'LegacyCliReport(results: $results, errors: $errors)';
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
  int Function()? clock,
}) async {
  final report = LegacyCliReport();
  final found = await existingLegacyCandidates(
    candidates ?? legacyCliCandidates(isWindows: isWindows, env: env),
    installerPaths: installerPaths,
    isWindows: isWindows,
  );
  final legacy = <String>[];
  for (final path in found) {
    if (isLegacyCliRun(await run(path, const ['version'], timeout: const Duration(seconds: 10)))) {
      legacy.add(path);
    } else {
      report.results[path] = LegacyOutcome.notLegacy;
    }
  }
  if (legacy.isEmpty) return report;

  String? source;
  for (final path in installerSources) {
    if (!await File(path).exists()) continue;
    if (isCompatibleSbxRun(await run(path, const ['version'], timeout: const Duration(seconds: 10)))) {
      source = await resolvePath(path);
      break;
    }
  }
  File? downloaded;
  if (source == null) {
    try {
      final bytes = await downloadLatestSbx(isWindows: isWindows, fetch: fetch);
      await tempDir.create(recursive: true);
      downloaded = File(p.join(tempDir.path, 'axiom-sbx-$pid-${sbxAssetName(isWindows: isWindows)}'));
      await downloaded.writeAsBytes(bytes, flush: true);
      source = downloaded.path;
    } catch (e) {
      for (final path in legacy) {
        report.results[path] = LegacyOutcome.failed;
        report.errors[path] = 'SBX не получен: $e';
      }
      return report;
    }
  }
  try {
    for (final path in legacy) {
      try {
        await replaceCliBinary(path, source, isWindows: isWindows, run: run, clock: clock);
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
