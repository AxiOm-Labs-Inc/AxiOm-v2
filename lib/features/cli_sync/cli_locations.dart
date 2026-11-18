// Где лежат CLI AxiOm (SBX под именем axiom), его состояние и каталог синхронизации.
// Чистые функции: платформа, окружение и проверка файлов передаются явно — так их проверяют тесты на любой ОС.

import 'package:path/path.dart' as p;

class CliLocations {
  const CliLocations._();

  static p.Context _ctx(bool isWindows) => isWindows ? p.windows : p.posix;

  static String? _home(bool isWindows, Map<String, String> env) {
    final home = isWindows ? env['USERPROFILE'] : env['HOME'];
    return home == null || home.isEmpty ? null : home;
  }

  /// Все пути, по которым лежит CLI установщика (вместе со ссылкой `/usr/bin/axiom` из deb).
  /// Их замена старого CLI пропускает.
  static List<String> installerPaths({
    required bool isWindows,
    required String exeDir,
    required Map<String, String> env,
  }) => [if (!isWindows) '/usr/bin/axiom', ...installerSourceCandidates(isWindows: isWindows, exeDir: exeDir, env: env)];

  /// Сам файл CLI установщика (не ссылка), в порядке предпочтения.
  /// Windows: `<папка exe>\cli\axiom.exe`; Linux: `/usr/lib/axiom/cli/axiom` (deb) или копия AppImage
  /// `~/.local/share/axiom/cli/axiom`.
  static List<String> installerSourceCandidates({
    required bool isWindows,
    required String exeDir,
    required Map<String, String> env,
  }) {
    final ctx = _ctx(isWindows);
    if (isWindows) return [ctx.join(exeDir, 'cli', 'axiom.exe')];
    final home = _home(false, env);
    return [
      '/usr/lib/axiom/cli/axiom',
      if (home != null) ctx.join(home, '.local', 'share', 'axiom', 'cli', 'axiom'),
    ];
  }

  /// CLI для команд приложения: сначала установщика, затем бывшие старые CLI, заменённые на SBX
  /// ([migrated]). `/usr/bin/axiom` отдельно не берётся: в deb это ссылка на `/usr/lib/axiom/cli/axiom`,
  /// а чужой `/usr/bin/axiom` использовать нельзя.
  static List<String> runtimeCandidates({
    required bool isWindows,
    required String exeDir,
    required Map<String, String> env,
    List<String> migrated = const [],
  }) {
    final seen = <String>{};
    return [
      ...installerSourceCandidates(isWindows: isWindows, exeDir: exeDir, env: env),
      ...migrated,
    ].where((path) => seen.add(isWindows ? path.toLowerCase() : path)).toList();
  }

  /// Каталог настроек CLI в режиме AxiOm (как в SBX: `%APPDATA%\AxiOm\cli`, `~/.config/axiom/cli`;
  /// XDG_CONFIG_HOME SBX не учитывает).
  static String? configDir({required bool isWindows, required Map<String, String> env}) {
    final ctx = _ctx(isWindows);
    if (isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) return ctx.join(appData, 'AxiOm', 'cli');
      final home = _home(true, env);
      return home == null ? null : ctx.join(home, 'AppData', 'Roaming', 'AxiOm', 'cli');
    }
    final home = _home(false, env);
    return home == null ? null : ctx.join(home, '.config', 'axiom', 'cli');
  }

  static String? stateFile({required bool isWindows, required Map<String, String> env}) {
    final dir = configDir(isWindows: isWindows, env: env);
    return dir == null ? null : _ctx(isWindows).join(dir, 'state.json');
  }

  /// Служба движка CLI в режиме AxiOm (systemd, Linux).
  static const axiomServiceUnit = 'axiom.service';

  /// Linux: команда остановки движка CLI с правами root, когда обычный `axiom disconnect` не смог.
  /// Сам `axiom` под root не запускается (у root другой HOME и каталог настроек) — останавливается
  /// только служба. null — нет pkexec или systemctl.
  static List<String>? pkexecStopCommand({required bool Function(String path) exists}) {
    const pkexec = '/usr/bin/pkexec';
    if (!exists(pkexec)) return null;
    for (final systemctl in const ['/usr/bin/systemctl', '/bin/systemctl']) {
      if (exists(systemctl)) return [pkexec, systemctl, 'stop', axiomServiceUnit];
    }
    return null;
  }

  /// `<каталог настроек CLI>/app-location.json` — указатель на работающее приложение.
  static String? appLocationFile({required bool isWindows, required Map<String, String> env}) {
    final dir = configDir(isWindows: isWindows, env: env);
    return dir == null ? null : _ctx(isWindows).join(dir, 'app-location.json');
  }

  /// `<данные приложения>/cli-sync` — тот же каталог, что находит SBX (установка или portable).
  static String syncDir(String appBaseDir, {required bool isWindows}) =>
      _ctx(isWindows).join(appBaseDir, 'cli-sync');
}
