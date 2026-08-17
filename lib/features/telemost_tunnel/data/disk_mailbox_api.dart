import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Writes on-demand conference requests to the app's private folder on
/// Yandex.Disk (`app:/wlb/requests/<deviceId>.txt`). The server-side daemon
/// polls the folder and spawns a creator for each new link — this is the
/// channel that works under whitelist restrictions (Disk stays reachable).
///
/// The OAuth token is lightly obfuscated (base64) — not security, just so
/// it does not show up in a plain-text grep. Errors are thrown to the
/// caller, which decides how fatal they are.
class DiskMailboxApi with InfraLogger {
  static const _timeout = Duration(seconds: 10);
  static const _baseUrl = 'https://cloud-api.yandex.net/v1/disk/resources';
  static const _folderPath = 'app:/wlb/requests';

  static final String _token = utf8.decode(
    base64Decode('' /* ВЫРЕЗАНО: OAuth-токен Диска, см. SECRETS-LOCAL-ONLY.txt */),
  );

  Dio _dio() => Dio(
        BaseOptions(
          connectTimeout: _timeout,
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          headers: {'Authorization': 'OAuth $_token'},
        ),
      );

  /// Stores [link] as this device's pending conference request.
  Future<void> postRequest(String deviceId, String link) async {
    await _ensureFolder();
    final path = '$_folderPath/$deviceId.txt';
    final meta = await _dio().get<dynamic>(
      '$_baseUrl/upload',
      queryParameters: {'path': path, 'overwrite': 'true'},
    );
    final data = meta.data;
    final map = data is String
        ? jsonDecode(data) as Map<String, dynamic>
        : Map<String, dynamic>.from(data as Map);
    final href = map['href'] as String?;
    if (href == null || href.isEmpty) {
      throw Exception('disk mailbox: no upload href in response');
    }
    // The href is a one-time uploader URL — it must be called WITHOUT the
    // Authorization header, hence a bare Dio.
    await Dio(
      BaseOptions(
        connectTimeout: _timeout,
        sendTimeout: _timeout,
        receiveTimeout: _timeout,
      ),
    ).put<String>(href, data: link, options: Options(contentType: 'text/plain'));
    loggy.info('disk mailbox: request posted for $deviceId');
  }

  /// Creates `app:/wlb/requests` when missing. 409 = already exists, fine;
  /// any other failure is logged and ignored — the upload call below fails
  /// with its own error if the folder is really missing.
  Future<void> _ensureFolder() async {
    try {
      await _dio().put<dynamic>(_baseUrl, queryParameters: {'path': _folderPath});
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) return;
      loggy.warning('disk mailbox: folder create failed (continuing): ${e.message}');
    }
  }
}

final diskMailboxApiProvider = Provider<DiskMailboxApi>(
  (ref) => DiskMailboxApi(),
);
