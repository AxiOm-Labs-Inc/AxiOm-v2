import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';

const idA = '0b4e28ba-2fa1-4d2e-9f6b-0a1b2c3d4e5f';
const idB = '1c5f39cb-3ab2-4e3f-8a7c-1b2c3d4e5f60';

void main() {
  group('ServerSelection', () {
    test('encodes and decodes the app prefs triple', () {
      const s = ServerSelection(c: 'Netherlands', p: 'vless', t: 'ws');
      expect(s.toJson(), {'c': 'Netherlands', 'p': 'vless', 't': 'ws'});
      expect(ServerSelection.fromJson(s.toJson()), s);
      expect(s.toSelectArg(), 'Netherlands|vless|ws');
    });

    test('auto drops protocol and transport in --select', () {
      const s = ServerSelection(c: autoCountryKey, p: 'vless', t: 'tcp');
      expect(s.isAuto, isTrue);
      expect(s.toSelectArg(), '__auto__');
    });

    test('missing p/t default to empty, invalid input is rejected', () {
      expect(ServerSelection.fromJson({'c': 'France'}), const ServerSelection(c: 'France'));
      expect(ServerSelection.fromJson({'c': ''}), isNull);
      expect(ServerSelection.fromJson({'c': 1}), isNull);
      expect(ServerSelection.fromJson({'c': 'X', 'p': 2}), isNull);
      expect(ServerSelection.fromJson('x'), isNull);
      expect(ServerSelection.fromJson(null), isNull);
    });
  });

  group('AppSyncState', () {
    const state = AppSyncState(
      pid: 42,
      heartbeatMs: 1700000000000,
      connected: true,
      connecting: false,
      selection: ServerSelection(c: 'France', p: 'hysteria2', t: 'hy2'),
      rawTag: 'France (u) [hy2]',
    );

    test('JSON has exactly the protocol fields', () {
      final json = jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>;
      expect(json, {
        'v': 1,
        'pid': 42,
        'heartbeat': 1700000000000,
        'connected': true,
        'connecting': false,
        'selection': {'c': 'France', 'p': 'hysteria2', 't': 'hy2'},
        'rawTag': 'France (u) [hy2]',
      });
      final back = AppSyncState.fromJson(json)!;
      expect(back.sameContent(state), isTrue);
      expect(back.heartbeatMs, state.heartbeatMs);
    });

    test('rawTag null is written as null', () {
      const s = AppSyncState(
        pid: 1,
        heartbeatMs: 2,
        connected: false,
        connecting: true,
        selection: ServerSelection.auto,
        rawTag: null,
      );
      expect(s.toJson().containsKey('rawTag'), isTrue);
      expect(s.toJson()['rawTag'], isNull);
      expect(AppSyncState.fromJson(s.toJson())!.rawTag, isNull);
    });

    test('sameContent ignores the heartbeat only', () {
      expect(state.withHeartbeat(1).sameContent(state), isTrue);
      final other = AppSyncState(
        pid: 42,
        heartbeatMs: state.heartbeatMs,
        connected: false,
        connecting: false,
        selection: state.selection,
        rawTag: state.rawTag,
      );
      expect(other.sameContent(state), isFalse);
    });

    test('rejects another protocol version', () {
      final json = state.toJson()..['v'] = 2;
      expect(AppSyncState.fromJson(json), isNull);
    });
  });

  group('staleness', () {
    test('heartbeat older than 10 s is stale', () {
      const now = 1000000;
      expect(isHeartbeatStale(now, now), isFalse);
      expect(isHeartbeatStale(now - 9999, now), isFalse);
      expect(isHeartbeatStale(now - 10000, now), isFalse);
      expect(isHeartbeatStale(now - 10001, now), isTrue);
      expect(isHeartbeatStale(now + 60000, now), isTrue);
    });
  });

  group('uuid4', () {
    test('only uuid4 ids are accepted', () {
      expect(isUuid4('1b4e28ba-2fa1-4d2e-9f6b-0a1b2c3d4e5f'), isTrue);
      expect(isUuid4('1B4E28BA-2FA1-4D2E-9F6B-0A1B2C3D4E5F'), isTrue);
      expect(isUuid4('1b4e28ba-2fa1-1d2e-9f6b-0a1b2c3d4e5f'), isFalse, reason: 'version 1');
      expect(isUuid4('id-1'), isFalse);
      expect(isUuid4(''), isFalse);
    });
  });

  group('ControlCommand', () {
    String encode(Map<String, dynamic> m) => jsonEncode(m);

    test('parses disconnect and select', () {
      final d = ControlCommand.tryParse(encode({'v': 1, 'id': idA, 'ts': 5, 'cmd': 'disconnect'}))!;
      expect(d.cmd, ControlCmd.disconnect);
      expect(d.selection, isNull);
      final s = ControlCommand.tryParse(
        encode({
          'v': 1,
          'id': idB,
          'ts': 6,
          'cmd': 'select',
          'selection': {'c': 'Germany', 'p': 'vless', 't': 'tcp'},
        }),
      )!;
      expect(s.cmd, ControlCmd.select);
      expect(s.selection, const ServerSelection(c: 'Germany', p: 'vless', t: 'tcp'));
      expect(ControlCommand.tryParse(jsonEncode(s.toJson()))!.selection, s.selection);
    });

    test('rejects malformed commands', () {
      expect(ControlCommand.tryParse(''), isNull);
      expect(ControlCommand.tryParse('{"v":1,"id":"a","ts":5,'), isNull);
      expect(ControlCommand.tryParse(encode({'v': 2, 'id': idA, 'ts': 5, 'cmd': 'disconnect'})), isNull);
      expect(ControlCommand.tryParse(encode({'v': 1, 'id': '', 'ts': 5, 'cmd': 'disconnect'})), isNull);
      expect(ControlCommand.tryParse(encode({'v': 1, 'id': 'a', 'ts': 5, 'cmd': 'disconnect'})), isNull, reason: 'not uuid4');
      expect(ControlCommand.tryParse(encode({'v': 1, 'id': idA, 'ts': '5', 'cmd': 'disconnect'})), isNull);
      expect(ControlCommand.tryParse(encode({'v': 1, 'id': idA, 'ts': 5, 'cmd': 'connect'})), isNull);
      expect(ControlCommand.tryParse(encode({'v': 1, 'id': idA, 'ts': 5, 'cmd': 'select'})), isNull);
      expect(ControlCommand.tryParse('[1,2]'), isNull);
    });
  });

  group('ControlTracker', () {
    ControlCommand cmd(String id, int ts) => ControlCommand(id: id, tsMs: ts, cmd: ControlCmd.disconnect);

    test('executes each id once', () {
      final tracker = ControlTracker();
      const now = 100000;
      expect(tracker.evaluate(cmd('x', now), now), ControlDecision.execute);
      tracker.markSeen('x');
      expect(tracker.evaluate(cmd('x', now), now + 1), ControlDecision.duplicate);
      expect(tracker.evaluate(cmd('y', now), now + 1), ControlDecision.execute);
    });

    test('commands older than 30 s expire', () {
      final tracker = ControlTracker();
      const now = 1000000;
      expect(tracker.evaluate(cmd('a', now - 30000), now), ControlDecision.execute);
      expect(tracker.evaluate(cmd('b', now - 30001), now), ControlDecision.expired);
      expect(tracker.evaluate(cmd('c', now + 30001), now), ControlDecision.expired);
    });

    test('remembers a bounded number of ids', () {
      final tracker = ControlTracker(capacity: 3);
      for (final id in ['1', '2', '3', '4']) {
        tracker.markSeen(id);
      }
      expect(tracker.hasSeen('1'), isFalse);
      expect(tracker.hasSeen('4'), isTrue);
    });
  });

  test('ControlAck parse is strict', () {
    expect(ControlAck.tryParse(jsonEncode(const ControlAck(id: idA, ok: true, tsMs: 9).toJson()))!.id, idA);
    expect(ControlAck.tryParse('{"v":1,"id":"$idA","ok":"false","ts":9}'), isNull, reason: 'ok must be bool');
    expect(ControlAck.tryParse('{"v":1,"id":"x","ok":true,"ts":9}'), isNull);
    expect(ControlAck.tryParse('{"v":1,"id":"$idA","ok":true,"ts":9.5}'), isNull);
    expect(ControlAck.tryParse('{"v":2,"id":"$idA","ok":true,"ts":9}'), isNull);
  });

  test('app-location JSON', () {
    const loc = AppLocation(
      supportDir: '/s',
      syncDir: '/s/cli-sync',
      prefsFile: '/s/shared_preferences.json',
      prefsPrefix: 'flutter.',
      exe: '/opt/AxiOm/hiddify',
      pid: 3,
      tsMs: 4,
    );
    expect(loc.toJson(), {
      'v': 1,
      'support_dir': '/s',
      'sync_dir': '/s/cli-sync',
      'prefs_file': '/s/shared_preferences.json',
      'prefs_prefix': 'flutter.',
      'exe': '/opt/AxiOm/hiddify',
      'pid': 3,
      'ts': 4,
    });
  });

  test('ControlAck JSON', () {
    expect(const ControlAck(id: 'i', ok: true, tsMs: 9).toJson(), {'v': 1, 'id': 'i', 'ok': true, 'ts': 9});
    expect(const ControlAck(id: 'i', ok: false, error: 'boom', tsMs: 9).toJson(), {
      'v': 1,
      'id': 'i',
      'ok': false,
      'error': 'boom',
      'ts': 9,
    });
  });
}
