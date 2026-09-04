import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/features/wbstream_tunnel/data/telemost_slot_cipher.dart';
import 'package:hiddify/features/wbstream_tunnel/model/wbstream_settings.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Fetches the current WB Stream room link from a public Yandex.Disk file:
/// `cloud-api.yandex.net/.../download?public_key=<diskUrl>` returns a JSON
/// with a one-time `href`, and that href (after a 302 redirect) serves the
/// file written by the NL keeper. No auth needed — the links are public. Same
/// channel as the Telemost mode: Disk stays reachable under whitelist
/// restrictions. A/B slots give the channel itself redundancy (both point at
/// one room).
///
/// Содержимое файла — конверт `v1:` ([TelemostSlotCipher]) либо, у старых
/// голов, открытый `https://stream.wb.ru/room/<uuid>`. Принимаются оба: в
/// момент переключения головы обе формы ходят одновременно.
class WbstreamLinkProvider with InfraLogger {
  static const _timeout = Duration(seconds: 15);

  Dio _dio() => Dio(
        BaseOptions(
          connectTimeout: _timeout,
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          followRedirects: true,
          maxRedirects: 5,
        ),
      );

  /// Returns the room id stored behind [diskUrl], or null on any
  /// network/format problem (the caller then tries the other slot).
  Future<String?> fetchRoomId(String diskUrl) async {
    try {
      final apiUri = Uri.https(
        'cloud-api.yandex.net',
        '/v1/disk/public/resources/download',
        {'public_key': diskUrl},
      );
      final meta = await _dio().getUri<dynamic>(apiUri);
      final data = meta.data;
      final map = data is String
          ? jsonDecode(data) as Map<String, dynamic>
          : Map<String, dynamic>.from(data as Map);
      final href = map['href'] as String?;
      if (href == null || href.isEmpty) {
        loggy.warning('wbstream disk link: no href in response for $diskUrl');
        return null;
      }
      final file = await _dio().get<String>(href, options: Options(responseType: ResponseType.plain));
      final roomId = parseSlot(file.data ?? '');
      if (roomId == null) {
        loggy.warning('wbstream disk link: invalid room link from $diskUrl: ${file.data}');
        return null;
      }
      return roomId;
    } catch (e) {
      loggy.warning('wbstream disk link: fetch failed for $diskUrl: $e');
      return null;
    }
  }

  /// Разбирает содержимое файла слота: сначала как конверт `v1:`, затем как
  /// открытый адрес. Второе — не запасной путь «на всякий случай», а живая
  /// ветка: голова переключается на шифрование отдельно от выката сборок.
  static String? parseSlot(String body) {
    final opened = TelemostSlotCipher.open(body);
    if (opened != null) return extractRoomId(opened);
    if (body.trimLeft().startsWith(TelemostSlotCipher.prefix)) {
      // Конверт есть, а раскрыть нечем: либо сборка собрана без
      // --dart-define=TELEMOST_SLOT_KEY, либо ключ на голове уже сменился.
      // Разбирать это дальше как открытый текст бессмысленно.
      return null;
    }
    return extractRoomId(body);
  }

  /// Accepts a `stream.wb.ru/room/<uuid>` URL or a bare UUID; returns the
  /// normalized (lowercase) room id, or null when neither parses.
  static String? extractRoomId(String input) {
    final s = input.trim();
    if (WbstreamSettings.isValidRoomId(s)) return s.toLowerCase();
    final m = RegExp('stream\\.wb\\.ru/room/([0-9a-fA-F-]{36})').firstMatch(s);
    final id = m?.group(1);
    if (id != null && WbstreamSettings.isValidRoomId(id)) return id.toLowerCase();
    return null;
  }
}

final wbstreamLinkProviderProvider = Provider<WbstreamLinkProvider>(
  (ref) => WbstreamLinkProvider(),
);
