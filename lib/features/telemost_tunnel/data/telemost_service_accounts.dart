import 'dart:convert';

/// One built-in service account used to create Telemost conferences
/// on-demand (no user Yandex login required).
class TelemostServiceAccount {
  const TelemostServiceAccount({
    required this.login,
    required this.sessionId,
    required this.yandexUid,
  });

  final String login;
  final String sessionId;
  final String yandexUid;

  /// Cookie header for the Telemost conferences API. Never logged.
  String get cookieHeader => 'Session_id=$sessionId; yandexuid=$yandexUid';
}

/// Built-in service accounts (4), lightly obfuscated as base64 of
/// `login\nsessionId\nyandexUid` — not security, just so the raw cookies
/// do not show up in a plain-text grep.
final List<TelemostServiceAccount> telemostServiceAccounts = [
  for (final blob in _accountBlobs) _decode(blob),
];

const _accountBlobs = [
  // ВЫРЕЗАНО перед пушем в приватный репозиторий: здесь лежали четыре живых
  // Yandex Session_id. Реальные значения — telemost-backup/SECRETS-LOCAL-ONLY.txt
  // и в локальном коммите 1aa27d9. Подставить обратно перед сборкой этой ветки.
];

TelemostServiceAccount _decode(String blob) {
  final parts = utf8.decode(base64Decode(blob)).split('\n');
  return TelemostServiceAccount(
    login: parts[0],
    sessionId: parts[1],
    yandexUid: parts[2],
  );
}
