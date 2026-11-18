import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late CliSyncFiles files;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cli_sync_files_');
    files = CliSyncFiles(Directory(p.join(tmp.path, 'cli-sync')));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  int now() => DateTime.now().millisecondsSinceEpoch;

  // Новый control.json: пауза, чтобы время изменения точно сменилось.
  Future<void> writeControl(Map<String, dynamic> json) async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(await writeJsonAtomic(files.controlFile, json), isTrue);
  }

  Map<String, dynamic> control(String id, {int? ts, String cmd = 'disconnect', Map<String, dynamic>? selection}) => {
    'v': 1,
    'id': id,
    'ts': ts ?? now(),
    'cmd': cmd,
    if (selection != null) 'selection': selection,
  };

  test('atomic write creates the dir, replaces content and leaves no temp files', () async {
    final target = File(p.join(tmp.path, 'deep', 'x.json'));
    expect(await writeJsonAtomic(target, {'a': 1}), isTrue);
    expect(await writeJsonAtomic(target, {'a': 2}), isTrue);
    expect(jsonDecode(await target.readAsString()), {'a': 2});
    final names = target.parent.listSync().map((e) => p.basename(e.path)).toList();
    expect(names, ['x.json']);
  });

  test('app-state is written by protocol and deleted on clean exit', () async {
    const state = AppSyncState(
      pid: 7,
      heartbeatMs: 123,
      connected: true,
      connecting: false,
      selection: ServerSelection(c: 'France', p: 'vless', t: 'ws'),
      rawTag: 'France (u) [ws]',
    );
    expect(await files.writeAppState(state), isTrue);
    expect(p.basename(files.appStateFile.path), 'app-state.json');
    final json = jsonDecode(await files.appStateFile.readAsString());
    expect(AppSyncState.fromJson(json)!.sameContent(state), isTrue);
    await files.deleteAppState();
    expect(await files.appStateFile.exists(), isFalse);
    await files.deleteAppState(); // повторно — без ошибок
  });

  test('no control file — nothing to do', () async {
    expect(await files.pollControl(now()), isNull);
  });

  test('a command is executed once, a new id again', () async {
    await writeControl(control('id-1'));
    final first = await files.pollControl(now());
    expect(first?.id, 'id-1');
    expect(await files.pollControl(now()), isNull, reason: 'unchanged file');

    await writeControl(control('id-1', ts: now() + 1));
    expect(await files.pollControl(now()), isNull, reason: 'same id rewritten');

    await writeControl(
      control('id-2', cmd: 'select', selection: {'c': '__auto__', 'p': '', 't': ''}),
    );
    final second = await files.pollControl(now());
    expect(second?.id, 'id-2');
    expect(second?.selection, ServerSelection.auto);
  });

  test('commands older than 30 s are ignored', () async {
    await writeControl(control('old', ts: now() - 31000));
    expect(await files.pollControl(now()), isNull);
    expect(files.tracker.hasSeen('old'), isTrue);
  });

  test('a half-written file is not remembered and is read again', () async {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await files.controlFile.parent.create(recursive: true);
    await files.controlFile.writeAsString('{"v":1,"id":"half"');
    expect(await files.pollControl(now()), isNull);
    expect(files.tracker.hasSeen('half'), isFalse);
    await writeControl(control('half'));
    expect((await files.pollControl(now()))?.id, 'half');
  });

  test('ack is written with the command id', () async {
    expect(await files.writeAck(ControlAck(id: 'id-9', ok: false, error: 'нет сервера', tsMs: now())), isTrue);
    expect(p.basename(files.ackFile.path), 'control-ack.json');
    final json = jsonDecode(await files.ackFile.readAsString()) as Map<String, dynamic>;
    expect(json['v'], 1);
    expect(json['id'], 'id-9');
    expect(json['ok'], isFalse);
    expect(json['error'], 'нет сервера');
    expect(json['ts'], isA<int>());
  });
}
