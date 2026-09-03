import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hiddify/features/wbstream_tunnel/model/display_names.dart';
import 'package:hiddify/features/wbstream_tunnel/model/wbstream_settings.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A status line from the native relay controller.
class WbstreamStatusEvent {
  const WbstreamStatusEvent(this.status, {this.message});

  /// starting | connecting | connected | lost | error | stopped
  final String status;
  final String? message;
}

/// Dart wrapper over MethodChannel `com.hiddify.app/wbstream` and the
/// matching EventChannel (see WBStreamMethodHandler.kt).
class WbstreamRelayService with InfraLogger {
  static const _channel = MethodChannel('com.hiddify.app/wbstream');
  static const _statusChannel = EventChannel('com.hiddify.app/wbstream.status');

  /// Starts the relay process. Returns the local SOCKS5 endpoint generated
  /// natively; tunnel progress arrives over [watchStatus]. The conference
  /// display name is picked at random from a fixed pool on every start
  /// (same neutral-name pool as the Telemost mode).
  /// [tmSecret] — секрет Телемоста аккаунта (hex). Пусто = подключение без
  /// авторизации: пока держатели не переведены в strict, это рабочий путь.
  ///
  /// Режим клиента всегда soft: рукопожатие он проходит целиком и ключ
  /// переключает, но своих кадров не гейтит. Так одна и та же сборка работает
  /// и со старым держателем, и со strict — гейт всё равно стоит на держателе.
  Future<WbstreamSocks> start(WbstreamSettings settings, {String? tmSecret}) async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {
      'roomId': settings.roomId,
      'displayName': randomTelemostDisplayName(),
      'vp8Fps': settings.vp8Fps,
      'vp8Batch': settings.vp8Batch,
      'dualTrack': settings.dualTrack,
      'reliable': settings.reliable,
      if (tmSecret != null && tmSecret.isNotEmpty) ...{
        'tmSecret': tmSecret,
        'authMode': 'soft',
      },
    });
    if (res == null) throw Exception('wbstream start: empty response');
    return WbstreamSocks.fromMap(res);
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      loggy.warning('wbstream stop failed (ignoring): $e');
    }
  }

  Stream<WbstreamStatusEvent> watchStatus() {
    return _statusChannel.receiveBroadcastStream().map((event) {
      final map = event as Map<dynamic, dynamic>;
      return WbstreamStatusEvent(
        map['status'] as String? ?? 'error',
        message: map['message'] as String?,
      );
    });
  }
}

final wbstreamRelayServiceProvider = Provider<WbstreamRelayService>(
  (ref) => WbstreamRelayService(),
);
