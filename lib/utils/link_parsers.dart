import 'dart:convert';

import 'package:hiddify/utils/validators.dart';

typedef ProfileLink = ({String url, String name});

// TODO: test and improve
abstract class LinkParser {
  static String generateSubShareLink(String url, [String? name]) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final modifiedUri = Uri(
      scheme: uri.scheme,
      host: uri.host,
      path: uri.path,
      query: uri.query,
      fragment: name ?? uri.fragment,
    );
    // return 'hiddify://import/$modifiedUri';
    return '$modifiedUri';
  }

  // protocols schemas
  /// Схемы, ссылки которых мы **умеем разбирать**, если их нам передали.
  /// Принимать чужой формат безвредно: пользователь сам открыл ссылку у нас.
  static const protocols = [
    'axiom',
    'hiddify',
    'v2ray',
    'v2rayn',
    'v2rayng',
    'clash',
    'clashmeta',
    'sing-box',
  ];

  /// Схемы, которые мы **регистрируем на себя в системе**. Только своя.
  ///
  /// Раньше на Windows при каждом запуске перерегистрировался весь список выше —
  /// то есть `hiddify://`, `clash://` и `sing-box://` уводились у чужих
  /// приложений, и ссылка, предназначенная Hiddify, открывала AxiOm. Своей же
  /// схемы `axiom` в списке не было вовсе: на Windows наши собственные ссылки не
  /// регистрировались, хотя в Android-манифесте `axiom` есть.
  ///
  /// Чужие регистрации не снимаем: настоящий Hiddify заберёт их обратно сам при
  /// следующем запуске — он делает такой же проход по своему списку.
  static const ownProtocols = ['axiom'];

  static ProfileLink? parse(String link) {
    return simple(link) ?? deep(link);
  }

  static ProfileLink? simple(String link) {
    if (!isUrl(link)) return null;
    final uri = Uri.parse(link.trim());
    return (url: uri.toString(), name: uri.queryParameters['name'] ?? '');
  }

  static ProfileLink? deep(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    final queryParams = uri.queryParameters;
    switch (uri.scheme) {
      case 'hiddify':
        if (queryParams.containsKey('url')) {
          return (url: queryParams['url']!, name: queryParams['name'] ?? '');
        } else {
          return (url: uri.path.substring(1) + (uri.hasQuery ? "?${uri.query}" : ""), name: uri.fragment);
        }
      case 'v2ray' || 'v2rayn' || 'v2rayng' || 'clash' || 'clashmeta' || 'sing-box':
        return queryParams.containsKey('url') ? (url: queryParams['url']!, name: queryParams['name'] ?? '') : null;
      default:
        return null;
    }
  }
}

String safeDecodeBase64(String str) {
  try {
    return utf8.decode(base64Decode(str));
  } catch (e) {
    return str;
  }
}
