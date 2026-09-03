import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hiddify/features/telemost_tunnel/model/telemost_names.dart';
import 'package:hiddify/features/telemost_tunnel/model/telemost_settings.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A status line from the native relay controller.
class TelemostStatusEvent {
  const TelemostStatusEvent(this.status, {this.message});

  /// starting | connecting | connected | lost | error | captcha | stopped
  final String status;
  final String? message;
}

/// Dart wrapper over MethodChannel `com.hiddify.app/telemost` and the
/// matching EventChannel (see TelemostMethodHandler.kt).
class TelemostRelayService with InfraLogger {
  static const _channel = MethodChannel('com.hiddify.app/telemost');
  static const _statusChannel = EventChannel('com.hiddify.app/telemost.status');

  /// Starts the relay process. Returns the local SOCKS5 endpoint generated
  /// natively; tunnel progress arrives over [watchStatus]. The conference
  /// display name is picked at random from a fixed pool on every start.
  Future<TelemostSocks> start(TelemostSettings settings) async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {
      'joinLink': settings.joinLink,
      'displayName': randomTelemostDisplayName(),
      'vp8Fps': settings.vp8Fps,
      'vp8Batch': settings.vp8Batch,
      'dualTrack': settings.dualTrack,
      'reliable': settings.reliable,
    });
    if (res == null) throw Exception('telemost start: empty response');
    return TelemostSocks.fromMap(res);
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      loggy.warning('telemost stop failed (ignoring): $e');
    }
  }

  Stream<TelemostStatusEvent> watchStatus() {
    return _statusChannel.receiveBroadcastStream().map((event) {
      final map = event as Map<dynamic, dynamic>;
      return TelemostStatusEvent(
        map['status'] as String? ?? 'error',
        message: map['message'] as String?,
      );
    });
  }
}

final telemostRelayServiceProvider = Provider<TelemostRelayService>(
  (ref) => TelemostRelayService(),
);
