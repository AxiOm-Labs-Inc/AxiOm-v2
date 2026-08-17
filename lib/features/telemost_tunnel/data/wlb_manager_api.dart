import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Creator-manager rejected the request (ok:false) or is unreachable.
class WlbManagerException implements Exception {
  const WlbManagerException(this.message);

  final String message;

  @override
  String toString() => 'WlbManagerException: $message';
}

/// Client for the creator-manager on the NL node (spawns/stops the server
/// side of the Telemost tunnel for a given conference link).
///
/// The API key is a build-time secret — pass it as
/// `flutter build ... --dart-define=WLB_API_KEY=<key>` (same pattern as
/// DEVICE_API_KEY in device_count_provider). Without a key every call is
/// silently skipped.
class WlbManagerApi with InfraLogger {
  WlbManagerApi();

  static const baseUrl = String.fromEnvironment(
    'WLB_MANAGER_URL',
    defaultValue: 'https://nl.arcohouse.space/wlb',
  );
  static const _apiKey = String.fromEnvironment('WLB_API_KEY');

  /// False when no WLB_API_KEY was provided at build time.
  static bool get isConfigured => _apiKey.isNotEmpty;

  Dio _dio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          headers: {
            'X-Api-Key': _apiKey,
            'Content-Type': 'application/json',
          },
        ),
      );

  /// POST /api/creator/spawn — idempotent per link.
  Future<void> spawn(String link, String user) async {
    if (!isConfigured) return;
    final res = await _post('/api/creator/spawn', {'link': link, 'user': user});
    if (res['ok'] != true) {
      throw WlbManagerException(res['error'] as String? ?? 'spawn failed');
    }
    loggy.info('wlb manager: creator ${res['status']} for $link');
  }

  /// POST /api/creator/stop.
  Future<void> stop(String link) async {
    if (!isConfigured) return;
    final res = await _post('/api/creator/stop', {'link': link});
    if (res['ok'] != true) {
      throw WlbManagerException(res['error'] as String? ?? 'stop failed');
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    try {
      final res = await _dio().post<dynamic>('$baseUrl$path', data: jsonEncode(body));
      final data = res.data;
      if (data is String) return jsonDecode(data) as Map<String, dynamic>;
      if (data is Map) return Map<String, dynamic>.from(data);
      throw WlbManagerException('unexpected response type ${data.runtimeType}');
    } on DioException catch (e) {
      throw WlbManagerException(e.message ?? 'network error');
    }
  }
}

final wlbManagerApiProvider = Provider<WlbManagerApi>(
  (ref) => WlbManagerApi(),
);
