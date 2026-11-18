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

  /// CLI, который ставит установщик приложения, в порядке поиска.
  /// Windows: `<папка exe>\cli\axiom.exe`; Linux: deb (`/usr/bin/axiom`, `/usr/lib/axiom/cli/axiom`)
  /// и AppImage (`~/.local/share/axiom/cli/axiom`).
  static List<String> binaryCandidates({
    required bool isWindows,
    required String exeDir,
    required Map<String, String> env,
  }) {
    final ctx = _ctx(isWindows);
    if (isWindows) return [ctx.join(exeDir, 'cli', 'axiom.exe')];
    final home = _home(false, env);
    return [
      '/usr/bin/axiom',
      '/usr/lib/axiom/cli/axiom',
      if (home != null) ctx.join(home, '.local', 'share', 'axiom', 'cli', 'axiom'),
    ];
  }

  static String? findBinary({
    required bool isWindows,
    required String exeDir,
    required Map<String, String> env,
    required bool Function(String path) exists,
  }) {
    for (final path in binaryCandidates(isWindows: isWindows, exeDir: exeDir, env: env)) {
      if (exists(path)) return path;
    }
    return null;
  }

  /// Файл, из которого установщик берёт CLI для замены старого Go-CLI (настоящий файл, не ссылка).
  /// Windows: `<папка exe>\cli\axiom.exe`; Linux: `/usr/lib/axiom/cli/axiom` (deb) или копия AppImage.
  static List<String> installerSourceCandidates({
    required bool isWindows,
    required String exeDir,
    required Map<String, String> env,
  }) {
    final all = binaryCandidates(isWindows: isWindows, exeDir: exeDir, env: env);
    return isWindows ? all : all.where((path) => path != '/usr/bin/axiom').toList();
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

  /// `<данные приложения>/cli-sync` — тот же каталог, что находит SBX (установка или portable).
  static String syncDir(String appBaseDir, {required bool isWindows}) =>
      _ctx(isWindows).join(appBaseDir, 'cli-sync');
}
