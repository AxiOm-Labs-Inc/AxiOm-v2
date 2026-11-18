// Сквозная проверка с настоящим CLI: CliSyncService приложения (с подставным движком) и sbx.py
// в режиме AxiOm (запуск как axiom.py) общаются через настоящие файлы во временном HOME.
//
// Нужен путь к sbx.py в SBX_PY (стенд CI берёт его из ветки SBX, указанной в sbx-ref.txt). Без него
// тест пропускается, а при CLI_SYNC_REQUIRE_SBX=1 — падает. Python: SBX_PYTHON, иначе python3 / python.

@Timeout(Duration(minutes: 3))
library;

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

  Future<ProcessResult> axiom(List<String> args, {Map<String, String> extraEnv = const {}}) async {
    final result = await Process.run(
      python,
      ['-X', 'utf8', axiomPy, ...args],
      environment: {...env, ...extraEnv},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 60));
    // Вывод CLI — в журнал теста: при падении видно, что ответил sbx.py.
    // ignore: avoid_print
    print('axiom ${args.join(" ")} → ${result.exitCode}\nstdout: ${result.stdout}\nstderr: ${result.stderr}');
    return result;
  }

  // Windows: .cmd как «sing-box» CLI запустить не может (WinError 216) — настоящий exe-заглушка из Dart.
  String? windowsFakeSingBox;
  setUpAll(() async {
    if (!Platform.isWindows) return;
    final dir = await Directory.systemTemp.createTemp('fake_sing_box_');
    final source = File(p.join(dir.path, 'fake_sing_box.dart'));
    await source.writeAsString(
      "import 'dart:io';\n"
      'void main(List<String> args) {\n'
      "  if (args.isNotEmpty && args.first == 'version') stdout.writeln('sing-box version 1.13.0');\n"
      "  if (args.isNotEmpty && args.first == 'check' && Platform.environment['FAKE_SINGBOX_SLOW'] != null) {\n"
      '    sleep(const Duration(seconds: 3));\n'
      '  }\n'
      '  exit(0);\n'
      '}\n',
    );
    final exe = p.join(dir.path, 'sing-box.exe');
    final compiled = await Process.run('dart', ['compile', 'exe', source.path, '-o', exe], runInShell: true);
    expect(compiled.exitCode, 0, reason: 'dart compile exe: ${compiled.stdout}\n${compiled.stderr}');
    windowsFakeSingBox = exe;
  });

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
      // region other — CLI не скачивает наборы правил (сеть в тесте не нужна).
      jsonEncode({
        'flutter.server_selector_country': 'France',
        'flutter.server_selector_protocol': 'vless',
        'flutter.region': 'other',
      }),
    );
    axiomPy = p.join(tmp.path, 'bin', 'axiom.py');
    await Directory(p.dirname(axiomPy)).create(recursive: true);
    await File(sbxPy).copy(axiomPy);
    // Ядро sing-box CLI здесь не запускается: подставное `check`/`version` (иначе `add` проверяет конфиг
    // настоящим sing-box, а на Windows ещё и скачивает его с GitHub).
    final singBox = File(Platform.isWindows ? windowsFakeSingBox! : p.join(tmp.path, 'bin', 'sing-box'));
    if (!Platform.isWindows) {
      // FAKE_SINGBOX_SLOW: `sing-box check` идёт 3 с — подготовка CLI (Linux: apply, Windows: конфиг задачи
      // SYSTEM через копию этой заглушки) растягивается, и «выключить» из приложения успевает детерминированно.
      await singBox.writeAsString(
        '#!/bin/sh\n[ "\$1" = version ] && echo "sing-box version 1.13.0"\n'
        '[ "\$1" = check ] && [ -n "\$FAKE_SINGBOX_SLOW" ] && sleep 3\nexit 0\n',
      );
      await Process.run('chmod', ['755', singBox.path]);
    }
    env['SBX_SING_BOX'] = singBox.path;

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
  });

  // Сервер у CLI (тот же, что в списке приложения) — для тестов, где меню CLI не должно быть пустым.
  Future<void> addCliServer() async {
    final add = await axiom([
      'add',
      'vless://11111111-2222-4333-8444-555555555555@192.0.2.1:443?type=ws&security=tls&sni=example.com'
          '#France%20(u)%20%5Bws%5D',
    ]);
    expect(add.exitCode, 0, reason: 'axiom add');
  }

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

  test('select from the CLI with zero own CLI servers: the app persists and applies it, exit 0', () async {
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
    await addCliServer();
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

  group('start.lock between the app and the real CLI', () {
    test('app holds start.lock → `axiom up` does not start its engine', () async {
      engine.status = AppEngineStatus.disconnected;
      await service.writeState(force: true);
      final lock = ByteLock.forFile(service.files.startLockFile);
      expect(await lock.tryLock(), isTrue);
      try {
        final result = await axiom(['up']);
        expect(result.exitCode, 0);
        expect(result.stdout as String, isNot(contains('✓ VPN включён')), reason: 'no own engine start');
        expect(result.stdout as String, contains('AxiOm'));
      } finally {
        await lock.close();
      }
    });

    test("sbx's own lock blocks the app start; killing the holder releases it", () async {
      // Замок берёт сам sbx.py (его try_lock), в отдельном процессе.
      final holder = await Process.start(python, [
        '-X',
        'utf8',
        '-c',
        'import importlib.util, pathlib, sys\n'
            'spec = importlib.util.spec_from_file_location("sbx_mod", sys.argv[1])\n'
            'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n'
            'print("locked" if m.try_lock(pathlib.Path(sys.argv[2])) else "busy", flush=True)\n'
            'sys.stdin.read()\n',
        axiomPy,
        service.files.startLockFile.path,
      ], environment: env);
      final line = await holder.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      expect(line, 'locked');
      expect(await service.startHeldElsewhere(), isTrue);
      expect(await service.reserveStart(), isNull, reason: 'CLI is starting — the app does not start');
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;
      final reservation = await service.reserveStart();
      expect(reservation, isNotNull, reason: 'the kernel released the lock of the dead holder');
      await service.releaseStart(reservation!);
    });
  });

  group('user intent (vpn-intent.json) between the app and the real CLI', () {
    test('CLI OFF while the app is preparing its start → the app start is cancelled', () async {
      engine.status = AppEngineStatus.disconnected;
      await service.writeState(force: true);
      final on = (await service.writeIntent(on: true))!; // кнопка «включить»; приложение обновляет подписку
      expect(await service.startStillWanted(on), isTrue);
      // CLI пишет «выключить» первым делом; остановка своей (несуществующей) службы на CI — не предмет теста.
      await axiom(['down']);
      final latest = await service.files.readIntent();
      expect(latest?.by, 'cli');
      expect(latest?.want, 'off');
      expect(await service.startStillWanted(on), isFalse, reason: 'the app aborts its start');
    });

    test('app OFF while `axiom up` prepares → the CLI cancels its start', () async {
      engine.status = AppEngineStatus.disconnected;
      await service.writeState(force: true);
      await addCliServer();
      final before = await service.files.readIntent();
      final up = axiom(['up', '--force'], extraEnv: {'FAKE_SINGBOX_SLOW': '1'});
      // Как только CLI записал своё «включить» — пользователь приложения нажимает «выключить».
      VpnIntent? cliOn;
      for (var i = 0; i < 3000 && cliOn == null; i++) {
        final intent = await service.files.readIntent();
        if (intent != null && intent.by == 'cli' && intent.want == 'on' && intent.id != before?.id) cliOn = intent;
        if (cliOn == null) await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cliOn, isNotNull, reason: 'axiom up writes its ON intent');
      await service.writeIntent(on: false);
      final result = await up;
      expect(result.exitCode, 0);
      expect(result.stdout as String, contains('запуск отменён'));
      expect(result.stdout as String, isNot(contains('✓ VPN включён')));
    });
  });

  group('intent seq (v5) between the app and the real CLI', () {
    test('app ON and CLI OFF right after it: OFF wins by seq', () async {
      engine.status = AppEngineStatus.disconnected;
      await service.writeState(force: true);
      final on = (await service.writeIntent(on: true))!;
      await axiom(['down']); // намерение «выключить» CLI пишет первым делом; остановка своей службы — не предмет теста
      final latest = (await service.files.readIntent())!;
      expect(latest.by, 'cli');
      expect(latest.want, 'off');
      expect(latest.seq, on.seq + 1, reason: 'seq under intent.lock, not timestamps');
      expect(await service.startStillWanted(on), isFalse);
    });

    test('a delayed `disconnect --intent` older than a newer CLI ON does nothing', () async {
      engine.status = AppEngineStatus.connected;
      await service.writeState(force: true);
      final off = (await service.writeIntent(on: false))!; // приложение нажало «выключить»…
      final up = await axiom(['up']); // …а пользователь CLI успел включить (VPN уже включён в приложении)
      expect(up.exitCode, 0);
      final cliOn = (await service.files.readIntent())!;
      expect(cliOn.by, 'cli');
      expect(cliOn.want, 'on');
      expect(cliOn.seq, greaterThan(off.seq));
      final late = await axiom(['disconnect', '--intent', off.flagValue]); // запоздавший OFF приложения
      expect(late.exitCode, 0);
      expect(engine.stopCalls, 0, reason: 'the newer ON wins — nothing is stopped');
      expect(engine.status, AppEngineStatus.connected);
      expect((await service.files.readIntent())!.id, cliOn.id, reason: 'no new intent written');
    });
  });
}
