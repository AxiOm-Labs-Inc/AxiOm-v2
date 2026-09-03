import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';

/// Yandex answered 401 — the stored session is dead, the user must log in
/// again.
class YandexSessionExpired implements Exception {
  const YandexSessionExpired();

  @override
  String toString() => 'YandexSessionExpired';
}

/// Creates Telemost conferences on behalf of the logged-in Yandex user.
///
/// Request shape verified against the telemost web client:
///   POST https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences?next_gen_media_platform_allowed=true
///   headers: Cookie (full session), Origin/Referer telemost.yandex.ru,
///            Client-Instance-Id (fresh uuid), desktop Chrome UA
///   body: {}  →  201 `{"uri": "https://telemost.yandex.ru/j/<id>", ...}`
class YandexTelemostApi with InfraLogger {
  YandexTelemostApi({required this.httpClient});

  final DioHttpClient httpClient;

  static const _conferencesUrl =
      'https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences'
      '?next_gen_media_platform_allowed=true';

  static const _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';

  /// Returns the conference join link. Throws [YandexSessionExpired] on 401.
  /// [cookieHeader] stays in memory only — never logged.
  Future<String> createConference(String cookieHeader) async {
    try {
      final res = await httpClient.post(
        _conferencesUrl,
        data: '{}',
        userAgent: _desktopUserAgent,
        extraHeaders: {
          'Cookie': cookieHeader,
          'Origin': 'https://telemost.yandex.ru',
          'Referer': 'https://telemost.yandex.ru/',
          'Client-Instance-Id': const Uuid().v4(),
          'Content-Type': 'application/json',
        },
      );
      final map = res.data is String
          ? jsonDecode(res.data as String) as Map<String, dynamic>
          : Map<String, dynamic>.from(res.data as Map);
      final uri = map['uri'] as String?;
      if (uri == null || uri.isEmpty) {
        throw Exception('telemost conferences: no uri in response');
      }
      return uri;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) throw const YandexSessionExpired();
      rethrow;
    }
  }
}

final yandexTelemostApiProvider = Provider<YandexTelemostApi>(
  (ref) => YandexTelemostApi(httpClient: ref.watch(httpClientProvider)),
);
