// Сквозная проверка с настоящим CLI: CliSyncService приложения (с подставным движком) и sbx.py
// в режиме AxiOm (запуск как axiom.py) общаются через настоящие файлы во временном HOME.
//
// Нужен путь к sbx.py в SBX_PY (стенд CI берёт его из ветки SBX, указанной в sbx-ref.txt). Без него
// тест пропускается, а при CLI_SYNC_REQUIRE_SBX=1 — падает. Python: SBX_PYTHON, иначе python3 / python.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/cli_sync_service.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:path/path.dart' as p;

import 'fake_app_engine.dart';

void main() {
  final sbxPy = Platform.environment['SBX_PY'] ?? '';
  final required = Platform.environment['CLI_SYNC_REQUIRE_SBX'] == '1';
  if (sbxPy.isEmpty || !File(sbxPy).existsSync()) {
    test(
      'real sbx.py (AxiOm mode) talks to the app sync service',
      () => fail('SBX_PY не задан или файла нет: "$sbxPy"'),
      skip: required ? false : 'SBX_PY не задан — сквозной тест с sbx.py пропущен',
    );
    return;
  }
  final python = Platform.environment['SBX_PYTHON'] ?? (Platform.isWindows ? 'python' : 'python3');

  late Directory tmp;
  late String axiomPy;
  late Map<String, String> env;
  late String support;
  late FakeAppEngine engine;
  late CliSyncService service;
  Timer? ticker;

  Future<ProcessResult> axiom(List<String> args) async {
    final result = await Process.run(
      python,
      ['-X', 'utf8', axiomPy, ...args],
      environment: env,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 60));
    // Вывод CLI — в журнал теста: при падении видно, что ответил sbx.py.
    // ignore: avoid_print
    print('axiom ${args.join(" ")} → ${result.exitCode}\nstdout: ${result.stdout}\nstderr: ${result.stderr}');
    return result;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cli_sync_sbx_');
    final home = p.join(tmp.path, 'home');
    final String cliConf;
    env = {
      'HOME': home,
      'USERPROFILE': home,
      'SBX_HOME': '',
      'SBX_AXIOM_HOME': '',
      'NO_COLOR': '1',
      'PYTHONIOENCODING': 'utf-8',
    };
    if (Platform.isWindows) {
      final roaming = p.join(home, 'AppData', 'Roaming');
      env['APPDATA'] = roaming;
      env['LOCALAPPDATA'] = p.join(home, 'AppData', 'Local');
      support = p.join(roaming, 'AxiOm', 'AxiOm');
      cliConf = p.join(roaming, 'AxiOm', 'cli');
    } else {
      env['XDG_DATA_HOME'] = p.join(home, '.local', 'share');
      env['XDG_CONFIG_HOME'] = p.join(home, '.config');
      env['XDG_STATE_HOME'] = p.join(home, '.local', 'state');
      env['XDG_CACHE_HOME'] = p.join(home, '.cache');
      support = p.join(home, '.local', 'share', 'app.hiddify.com');
      cliConf = p.join(home, '.config', 'axiom', 'cli');
    }
    await Directory(support).create(recursive: true);
    await Directory(cliConf).create(recursive: true);
    // Каталог приложения находится и по старому правилу CLI (db.sqlite), и по app-location.json.
    await File(p.join(support, 'db.sqlite')).writeAsBytes(const []);
    await File(p.join(support, 'shared_preferences.json')).writeAsString(
      jsonEncode({'flutter.server_selector_country': 'France', 'flutter.server_selector_protocol': 'vless'}),
    );
    axiomPy = p.join(tmp.path, 'bin', 'axiom.py');
    await Directory(p.dirname(axiomPy)).create(recursive: true);
    await File(sbxPy).copy(axiomPy);

    engine = FakeAppEngine(
      status: AppEngineStatus.connected,
      options: [
        ServerOption(country: 'France', protocol: 'vless', transport: 'ws', rawTag: 'France (u) [ws]', delay: 120),
      ],
    )..rawTag = 'France (u) [ws]';
    final syncDir = p.join(support, 'cli-sync');
    service = CliSyncService(
      files: CliSyncFiles(Directory(syncDir)),
      adapter: engine,
      locationFile: File(p.join(cliConf, 'app-location.json')),
      location: AppLocation(
        supportDir: support,
        syncDir: syncDir,
        prefsFile: p.join(support, 'shared_preferences.json'),
        prefsPrefix: 'flutter.',
        exe: Platform.resolvedExecutable,
        pid: pid,
        tsMs: 0,
      ),
    );
    await service.start();
    ticker = Timer.periodic(const Duration(milliseconds: 200), (_) => unawaited(service.tick()));
    // Сервер у CLI (тот же, что в списке приложения): меню CLI не пустое, как у настоящего пользователя.
    final add = await axiom([
      'add',
      'vless://11111111-2222-4333-8444-555555555555@192.0.2.1:443?type=ws&security=tls&sni=example.com'
          '#France%20(u)%20%5Bws%5D',
    ]);
    expect(add.exitCode, 0, reason: 'axiom add');
  });

  tearDown(() async {
    ticker?.cancel();
    await service.shutdown();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });


  test('status --json sees the app engine through app-state.json', () async {
    final result = await axiom(['status', '--json']);
    expect(result.exitCode, 0);
    final lines = (result.stdout as String).trim().split('\n');
    final status = jsonDecode(lines.last) as Map<String, dynamic>;
    expect(status['vpn'], 'on');
    expect(status['engine'], 'app');
  });

  test('select from the CLI: the app persists it (single writer) and applies it to its engine', () async {
    final prefsFile = File(p.join(support, 'shared_preferences.json'));
    final prefsBefore = await prefsFile.readAsString();
    final result = await axiom(['use', '--select', '__auto__']);
    expect(result.exitCode, 0);
    expect(engine.persisted, [ServerSelection.auto]);
    expect(engine.applied, [ServerSelection.auto]);
    expect(await prefsFile.readAsString(), prefsBefore, reason: 'while the app runs only the app writes prefs');
    final state = jsonDecode(await service.files.appStateFile.readAsString()) as Map<String, dynamic>;
    expect(state['selection'], {'c': '__auto__', 'p': '', 't': ''});
  });

  test('a partial selection is resolved identically on both sides', () async {
    final result = await axiom(['use', '--select', 'France']);
    expect(result.exitCode, 0);
    const full = ServerSelection(c: 'France', p: 'vless', t: 'ws');
    expect(engine.persisted, [full]);
    expect(engine.applied, [full]);
    final state = jsonDecode(await service.files.appStateFile.readAsString()) as Map<String, dynamic>;
    expect(state['selection'], full.toJson());
  });

  test('disconnect from the CLI stops the app engine and waits for a truthful ack', () async {
    final result = await axiom(['disconnect']);
    expect(result.exitCode, 0);
    expect(engine.stopCalls, 1);
    expect(engine.status, AppEngineStatus.disconnected);
    final state = jsonDecode(await service.files.appStateFile.readAsString()) as Map<String, dynamic>;
    expect(state['connected'], isFalse);
  });
}
