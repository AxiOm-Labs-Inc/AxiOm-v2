import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_locations.dart';

void main() {
  group('Windows', () {
    const env = {'APPDATA': r'C:\Users\u\AppData\Roaming', 'USERPROFILE': r'C:\Users\u'};
    const exeDir = r'C:\Program Files\AxiOm';

    test('installer CLI next to the app, then migrated standalone CLIs', () {
      expect(CliLocations.installerPaths(isWindows: true, exeDir: exeDir, env: env), [
        r'C:\Program Files\AxiOm\cli\axiom.exe',
      ]);
      expect(CliLocations.installerSourceCandidates(isWindows: true, exeDir: exeDir, env: env), [
        r'C:\Program Files\AxiOm\cli\axiom.exe',
      ]);
      expect(
        CliLocations.runtimeCandidates(
          isWindows: true,
          exeDir: exeDir,
          env: env,
          migrated: [r'C:\AxiOm-cli\axiom.exe', r'c:\program files\axiom\CLI\axiom.exe'],
        ),
        [r'C:\Program Files\AxiOm\cli\axiom.exe', r'C:\AxiOm-cli\axiom.exe'],
      );
    });

    test('CLI state, app locator and sync dir', () {
      expect(CliLocations.stateFile(isWindows: true, env: env), r'C:\Users\u\AppData\Roaming\AxiOm\cli\state.json');
      expect(
        CliLocations.appLocationFile(isWindows: true, env: env),
        r'C:\Users\u\AppData\Roaming\AxiOm\cli\app-location.json',
      );
      expect(
        CliLocations.stateFile(isWindows: true, env: {'USERPROFILE': r'C:\Users\u'}),
        r'C:\Users\u\AppData\Roaming\AxiOm\cli\state.json',
      );
      expect(CliLocations.stateFile(isWindows: true, env: {}), isNull);
      expect(
        CliLocations.syncDir(r'C:\Users\u\AppData\Roaming\AxiOm\AxiOm', isWindows: true),
        r'C:\Users\u\AppData\Roaming\AxiOm\AxiOm\cli-sync',
      );
    });
  });

  group('Linux', () {
    const env = {'HOME': '/home/u', 'XDG_CONFIG_HOME': '/elsewhere'};

    test('/usr/bin/axiom is skipped by migration but never used directly', () {
      expect(CliLocations.installerPaths(isWindows: false, exeDir: '/opt/x', env: env), [
        '/usr/bin/axiom',
        '/usr/lib/axiom/cli/axiom',
        '/home/u/.local/share/axiom/cli/axiom',
      ]);
      expect(CliLocations.runtimeCandidates(isWindows: false, exeDir: '/opt/x', env: env, migrated: ['/home/u/axiom-cli/axiom']), [
        '/usr/lib/axiom/cli/axiom',
        '/home/u/.local/share/axiom/cli/axiom',
        '/home/u/axiom-cli/axiom',
      ]);
    });

    test('state ignores XDG_CONFIG_HOME like SBX', () {
      expect(CliLocations.stateFile(isWindows: false, env: env), '/home/u/.config/axiom/cli/state.json');
      expect(CliLocations.appLocationFile(isWindows: false, env: env), '/home/u/.config/axiom/cli/app-location.json');
      expect(CliLocations.stateFile(isWindows: false, env: {}), isNull);
      expect(
        CliLocations.syncDir('/home/u/.local/share/app.hiddify.com', isWindows: false),
        '/home/u/.local/share/app.hiddify.com/cli-sync',
      );
    });
  });
}
