import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/features/telemost_tunnel/model/telemost_settings.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Fetches the current Telemost join link from a public Yandex.Disk file:
/// `cloud-api.yandex.net/.../download?public_key=<diskUrl>` returns a JSON
/// with a one-time `href`, and that href (after a 302 redirect) serves the
/// file whose whole body is the join link. No auth needed — the links are
/// public. Used for the A/B server-side links failover.
class DiskLinkProvider with InfraLogger {
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

  /// Returns the join link stored behind [diskUrl], or null on any
  /// network/format problem (the caller then tries the other slot).
  Future<String?> fetchJoinLink(String diskUrl) async {
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
        loggy.warning('disk link: no href in response for $diskUrl');
        return null;
      }
      final file = await _dio().get<String>(href, options: Options(responseType: ResponseType.plain));
      final link = file.data?.trim() ?? '';
      if (!TelemostSettings.isValidJoinLink(link)) {
        loggy.warning('disk link: invalid join link from $diskUrl: $link');
        return null;
      }
      return link;
    } catch (e) {
      loggy.warning('disk link: fetch failed for $diskUrl: $e');
      return null;
    }
  }
}

final diskLinkProvider = Provider<DiskLinkProvider>(
  (ref) => DiskLinkProvider(),
);
