import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _cookiesKey = 'yandex_cookies';

/// One Yandex session cookie. Values are secrets — never logged.
class YandexCookie {
  const YandexCookie({required this.name, required this.value});

  final String name;
  final String value;

  Map<String, dynamic> toJson() => {'name': name, 'value': value};

  factory YandexCookie.fromJson(Map<String, dynamic> json) => YandexCookie(
        name: json['name'] as String,
        value: json['value'] as String,
      );
}

/// Persists the Yandex session cookies in secure storage (the ONLY place
/// they are kept; nothing is written to logs or toasts).
class YandexAuthStorage with InfraLogger {
  final _secureStorage = const FlutterSecureStorage();

  Future<void> saveCookies(List<YandexCookie> cookies) async {
    await _secureStorage.write(
      key: _cookiesKey,
      value: jsonEncode(cookies.map((c) => c.toJson()).toList()),
    );
  }

  Future<List<YandexCookie>?> readCookies() async {
    try {
      final raw = await _secureStorage.read(key: _cookiesKey);
      if (raw == null || raw.isEmpty) return null;
      final list = jsonDecode(raw) as List<dynamic>;
      final cookies = list
          .map((e) => YandexCookie.fromJson(e as Map<String, dynamic>))
          .toList();
      return cookies.isEmpty ? null : cookies;
    } catch (e) {
      loggy.warning('failed to read yandex cookies: $e');
      return null;
    }
  }

  /// `name=value; name2=value2` for the Cookie request header.
  Future<String?> cookieHeader() async {
    final cookies = await readCookies();
    if (cookies == null) return null;
    return cookies.map((c) => '${c.name}=${c.value}').join('; ');
  }

  /// Login from the yandex_login cookie, when present.
  Future<String?> readLogin() async {
    final cookies = await readCookies();
    if (cookies == null) return null;
    for (final cookie in cookies) {
      if (cookie.name == 'yandex_login' && cookie.value.isNotEmpty) return cookie.value;
    }
    return null;
  }

  Future<bool> hasSession() async {
    final cookies = await readCookies();
    return cookies != null && cookies.any((c) => c.name == 'Session_id');
  }

  Future<void> clear() => _secureStorage.delete(key: _cookiesKey);
}

final yandexAuthStorageProvider = Provider<YandexAuthStorage>(
  (ref) => YandexAuthStorage(),
);
