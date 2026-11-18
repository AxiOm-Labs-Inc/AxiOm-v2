// Версии CLI: SBX в режиме AxiOm печатает `axiom 1.4.0`, старый Go-CLI — `axiom-cli 0.0.3 (linux/amd64)`.
// Синхронизация требует SBX ≥ 1.4.0 (DESIGN-sync v2, п. 9).

import 'package:hiddify/features/cli_sync/cli_process.dart';

typedef SemVer = (int, int, int);

const minSyncSbxVersion = (1, 4, 0);

final _sbxLine = RegExp(r'^axiom (\d+)\.(\d+)\.(\d+)(?:\s|$)');
final _legacyLine = RegExp(r'^axiom-cli \d+\.\d+\.\d+(?:\s|$)');
final _tag = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$');

String _firstLine(String stdout) =>
    stripAnsi(stdout).split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');

int compareSemVer(SemVer a, SemVer b) {
  if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
  if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
  return a.$3.compareTo(b.$3);
}

/// Версия SBX из первой строки вывода `axiom version`; null — не SBX.
SemVer? parseSbxVersion(String stdout) {
  final m = _sbxLine.firstMatch(_firstLine(stdout));
  if (m == null) return null;
  return (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// Версия из тега релиза (`v1.4.0`, `1.4.0`); null — не X.Y.Z.
SemVer? parseReleaseTag(String tag) {
  final m = _tag.firstMatch(tag.trim());
  if (m == null) return null;
  return (int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

bool isSyncCompatible(SemVer? version) => version != null && compareSemVer(version, minSyncSbxVersion) >= 0;

/// `axiom version` завершился успешно и это SBX ≥ 1.4.0.
bool isCompatibleSbxRun(CliRunResult result) => result.ok && isSyncCompatible(parseSbxVersion(result.stdout));

/// Старый Go-CLI: успешный запуск и первая строка stdout `axiom-cli X.Y.Z`.
bool isLegacyCliRun(CliRunResult result) => result.ok && _legacyLine.hasMatch(_firstLine(result.stdout));
