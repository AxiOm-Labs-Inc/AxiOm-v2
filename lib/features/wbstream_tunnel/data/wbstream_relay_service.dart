import 'dart:async';

import 'package:flutter/services.dart';
import 'package:axiom/features/wbstream_tunnel/model/wbstream_settings.dart';
import 'package:axiom/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A status line from the native relay controller.
class WbstreamStatusEvent {
  const WbstreamStatusEvent(this.status, {this.message});

  /// starting | connecting | connected | lost | error | stopped | config
  ///
  /// `config` несёт в [message] готовый фрагмент конфига sing-box: нативная
  /// часть находит комнату сама и отдаёт конфиг строкой, приложение пишет его
  /// в файл не заглядывая внутрь.
  final String status;
  final String? message;
}

/// Dart-обёртка над MethodChannel `app.axiom/tunnel` и парным
/// EventChannel (см. TunnelMethodHandler.kt). Комнату и сборку
/// конфига делает нативный relay; приложение шлёт только секрет и параметры
/// видео и получает статусы (включая готовый конфиг).
class WbstreamRelayService with InfraLogger {
  static const _channel = MethodChannel('app.axiom/tunnel');
  static const _statusChannel = EventChannel('app.axiom/tunnel.status');

  /// Запускает relay. [tmSecret] — секрет Телемоста аккаунта (hex); пусто =
  /// подключение без авторизации, пока держатели не в strict. Возвращает
  /// локальный SOCKS5-эндпойнт; дальнейший прогресс — через [watchStatus],
  /// в т.ч. событие `config` с фрагментом для ядра.
  Future<WbstreamSocks> start(WbstreamSettings settings, {String? tmSecret}) async {
    final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('start', {
      'vp8Fps': settings.vp8Fps,
      'vp8Batch': settings.vp8Batch,
      'dualTrack': settings.dualTrack,
      'reliable': settings.reliable,
      if (tmSecret != null && tmSecret.isNotEmpty) ...{
        'tmSecret': tmSecret,
        'authMode': 'soft',
      },
    });
    if (res == null) throw Exception('tunnel start: empty response');
    return WbstreamSocks.fromMap(res);
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      loggy.warning('tunnel stop failed (ignoring): $e');
    }
  }

  /// Предупреждает нативную часть, что следующая остановка ядра — наш
  /// перезапуск: иначе вместе с ядром она гасит и relay.
  Future<void> keepOnCoreStop() async {
    try {
      await _channel.invokeMethod('keepOnCoreStop');
    } catch (e) {
      loggy.warning('tunnel keepOnCoreStop failed: $e');
    }
  }

  /// Relay, оставшийся от прежнего экрана: он живёт в процессе дольше
  /// Flutter-движка. null — relay не запущен (или спросить не удалось).
  Future<WbstreamNativeState?> runningState() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('state');
      if (res == null || res['running'] != true || res['host'] == null) return null;
      return WbstreamNativeState(
        status: res['status'] as String? ?? '',
        config: res['config'] as String?,
        socks: WbstreamSocks.fromMap(res),
      );
    } catch (e) {
      loggy.warning('tunnel state failed: $e');
      return null;
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

class WbstreamNativeState {
  const WbstreamNativeState({required this.status, required this.config, required this.socks});

  /// Последний статус relay: starting | connecting | connected | lost | error.
  final String status;
  final String? config;
  final WbstreamSocks socks;
}

final wbstreamRelayServiceProvider = Provider<WbstreamRelayService>(
  (ref) => WbstreamRelayService(),
);
