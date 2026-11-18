import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/cli_sync_service.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'fake_app_engine.dart';

ServerOption opt(String c, String pr, String t) =>
    ServerOption(country: c, protocol: pr, transport: t, rawTag: '$c ($pr) [$t]', delay: 0);

void main() {
  late Directory tmp;
  late FakeAppEngine engine;
  late CliSyncService service;
  late File locationFile;

  int now() => DateTime.now().millisecondsSinceEpoch;

  CliSyncService make({Duration handlerTimeout = const Duration(seconds: 12)}) => CliSyncService(
    files: CliSyncFiles(Directory(p.join(tmp.path, 'app', 'cli-sync'))),
    adapter: engine,
    locationFile: locationFile,
    location: AppLocation(
      supportDir: p.join(tmp.path, 'app'),
      syncDir: p.join(tmp.path, 'app', 'cli-sync'),
      prefsFile: p.join(tmp.path, 'app', 'shared_preferences.json'),
      prefsPrefix: 'flutter.',
      exe: '/opt/AxiOm/hiddify',
      pid: 77,
      tsMs: 0,
    ),
    ownPid: 77,
    handlerTimeout: handlerTimeout,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cli_sync_service_');
    locationFile = File(p.join(tmp.path, 'cli', 'app-location.json'));
    engine = FakeAppEngine(
      options: [opt('France', 'vless', 'ws'), opt('France', 'vless', 'tcp'), opt('Germany', 'hysteria2', 'hy2')],
    );
    service = make();
    await service.start();
  });

  tearDown(() async {
    await service.shutdown();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> appState() async =>
      jsonDecode(await service.files.appStateFile.readAsString()) as Map<String, dynamic>;

  Future<ControlAck> run(String cmd, {Map<String, dynamic>? selection}) async {
    final id = const Uuid().v4();
    await writeJsonAtomic(service.files.controlFile, {
      'v': 1,
      'id': id,
      'ts': now(),
      'cmd': cmd,
      if (selection != null) 'selection': selection,
    });
    await service.tick();
    for (var i = 0; i < 200; i++) {
      final ack = ControlAck.tryParse(await service.files.ackFile.readAsString().catchError((_) => ''));
      if (ack != null && ack.id == id) return ack;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('no ack for $cmd');
  }

  test('start writes the app locator and a canonical app-state', () async {
    final loc = jsonDecode(await locationFile.readAsString()) as Map<String, dynamic>;
    expect(loc['v'], 1);
    expect(loc['sync_dir'], p.join(tmp.path, 'app', 'cli-sync'));
    expect(loc['prefs_prefix'], 'flutter.');
    expect(loc['pid'], 77);
    expect(loc['ts'], isA<int>());
    expect((loc['ts'] as int) > 0, isTrue);
    engine.storedSelection = const ServerSelection(c: autoCountryKey, p: 'vless', t: 'ws');
    await service.writeState(force: true);
    expect((await appState())['selection'], {'c': '__auto__', 'p': '', 't': ''});
    engine.storedSelection = const ServerSelection(c: 'France');
    await service.writeState(force: true);
    expect((await appState())['selection'], {'c': 'France', 'p': 'vless', 't': 'tcp'});
  });

  test('select with no engine: persisted (canonical), not applied, ack ok', () async {
    final ack = await run('select', selection: {'c': 'France', 'p': '', 't': ''});
    expect(ack.ok, isTrue);
    expect(engine.persisted, [const ServerSelection(c: 'France', p: 'vless', t: 'tcp')]);
    expect(engine.applied, isEmpty);
  });

  test('select while connected is applied; apply failure is a failed ack', () async {
    engine.status = AppEngineStatus.connected;
    expect((await run('select', selection: {'c': 'Germany', 'p': 'hysteria2', 't': 'hy2'})).ok, isTrue);
    expect(engine.applied.single, const ServerSelection(c: 'Germany', p: 'hysteria2', t: 'hy2'));
    engine.applyError = 'core said no';
    final ack = await run('select', selection: {'c': '__auto__', 'p': 'x', 't': 'y'});
    expect(ack.ok, isFalse);
    expect(ack.error, 'core said no');
    expect(engine.applied.last, ServerSelection.auto);
  });

  test('unknown server is rejected and not persisted', () async {
    final ack = await run('select', selection: {'c': 'Spain', 'p': 'vless', 't': 'ws'});
    expect(ack.ok, isFalse);
    expect(engine.persisted, isEmpty);
  });

  test('disconnect acks ok only after the engine stopped', () async {
    engine.status = AppEngineStatus.connected;
    expect((await run('disconnect')).ok, isTrue);
    expect(engine.stopCalls, 1);
    expect((await appState())['connected'], isFalse);

    engine.status = AppEngineStatus.connected;
    engine.coreRunning = null; // ядро снова работает (по состоянию экрана)
    engine.stopError = 'core error';
    final failed = await run('disconnect');
    expect(failed.ok, isFalse);
    expect(failed.error, 'core error');
  });

  test('disconnect with the core stopped is ok without touching the engine', () async {
    expect((await run('disconnect')).ok, isTrue);
    expect(engine.stopCalls, 0);
  });

  test('a slow handler is answered with an error within the timeout', () async {
    await service.shutdown();
    service = make(handlerTimeout: const Duration(milliseconds: 300));
    await service.start();
    engine.status = AppEngineStatus.connected;
    engine.stopDelay = const Duration(seconds: 3);
    final ack = await run('disconnect');
    expect(ack.ok, isFalse);
    expect(ack.error, contains('disconnect'));
  });

  group('start.lock (OS lock on byte 0, contention with another process)', () {
    late File holderScript;

    setUp(() async {
      holderScript = File(p.join(tmp.path, 'lock_holder.py'));
      await holderScript.writeAsString(lockHolderPy);
    });

    Future<Process> hold() async {
      final process = await Process.start(testPython, [holderScript.path, service.files.startLockFile.path, 'hold']);
      final line = await process.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      expect(line, 'locked');
      return process;
    }

    Future<String> probe() async {
      final result = await Process.run(testPython, [holderScript.path, service.files.startLockFile.path, 'probe']);
      return (result.stdout as String).trim();
    }

    test('reservation holds the lock for other processes and publishes connecting', () async {
      final r = await service.reserveStart();
      expect(r, isNotNull);
      expect(await probe(), 'held');
      final owner = jsonDecode(await service.files.startOwnerFile.readAsString()) as Map<String, dynamic>;
      expect(owner['owner'], 'app');
      expect(owner['id'], r!.id);
      expect((await appState())['connecting'], isTrue);
      expect(await service.reserveStart(), isNull, reason: 'already starting');
      expect(await service.startHeldElsewhere(), isFalse, reason: 'own lock is not "elsewhere"');
      engine.status = AppEngineStatus.connected;
      await service.releaseStart(r);
      expect(await probe(), 'free');
      expect(await service.files.startLockFile.exists(), isTrue, reason: 'the lock file is never deleted');
      final state = await appState();
      expect(state['connected'], isTrue);
      expect(state['connecting'], isFalse);
    });

    test('a lock held by another process blocks the app; the holder dying releases it', () async {
      final holder = await hold();
      expect(await service.startHeldElsewhere(), isTrue);
      expect(await service.reserveStart(), isNull);
      holder.kill(ProcessSignal.sigkill); // «падение» держателя
      await holder.exitCode;
      expect(await service.startHeldElsewhere(), isFalse);
      final r = await service.reserveStart();
      expect(r, isNotNull);
      await service.releaseStart(r!);
    });

    test('disconnect during the app start cancels it and waits for the release', () async {
      final r = (await service.reserveStart())!;
      final ackFuture = run('disconnect');
      for (var i = 0; i < 100 && !r.cancelled; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(r.cancelled, isTrue);
      expect(await service.files.ackFile.exists(), isFalse, reason: 'no ack before the start gave up');
      await service.releaseStart(r);
      expect((await ackFuture).ok, isTrue);
      expect(engine.stopCalls, 0);
    });
  });

  test('disconnect: an error shown by the app is not proof — the real core state decides', () async {
    engine.status = AppEngineStatus.failed;
    engine.coreRunning = true;
    expect((await run('disconnect')).ok, isTrue);
    expect(engine.stopCalls, 1);
    engine.status = AppEngineStatus.failed;
    engine.coreRunning = true;
    engine.stopError = 'core still running';
    final ack = await run('disconnect');
    expect(ack.ok, isFalse);
    expect(ack.error, 'core still running');
  });

  test('a timed-out select never takes effect later (newer command wins)', () async {
    await service.shutdown();
    service = make(handlerTimeout: const Duration(milliseconds: 300));
    await service.start();
    engine.status = AppEngineStatus.connected;
    engine.applyDelay = const Duration(seconds: 1);
    final late = await run('select', selection: {'c': 'Germany', 'p': 'hysteria2', 't': 'hy2'});
    expect(late.ok, isFalse);
    engine.applyDelay = Duration.zero;
    expect((await run('select', selection: {'c': 'France', 'p': 'vless', 't': 'ws'})).ok, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(engine.applied, [const ServerSelection(c: 'France', p: 'vless', t: 'ws')]);
  });

  test('app-state publishes only canonical triples (last known one when unresolvable)', () async {
    engine.storedSelection = const ServerSelection(c: 'France', p: 'vless', t: 'ws');
    await service.writeState(force: true);
    expect((await appState())['selection'], {'c': 'France', 'p': 'vless', 't': 'ws'});
    engine.knownOptions = const [];
    engine.storedSelection = const ServerSelection(c: 'Spain');
    await service.writeState(force: true);
    expect((await appState())['selection'], {'c': 'France', 'p': 'vless', 't': 'ws'});
  });

  test('shutdown removes app-state and the own lock', () async {
    await service.reserveStart();
    await service.shutdown();
    expect(await service.files.appStateFile.exists(), isFalse);
    final holder = File(p.join(tmp.path, 'lock_holder.py'));
    await holder.writeAsString(lockHolderPy);
    final probe = await Process.run(testPython, [holder.path, service.files.startLockFile.path, 'probe']);
    expect((probe.stdout as String).trim(), 'free');
  });
}
