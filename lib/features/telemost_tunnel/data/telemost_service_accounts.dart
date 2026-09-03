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

/// Service accounts are passed at build time as a comma-separated list:
/// `--dart-define=TELEMOST_ACCOUNTS=<blob>,<blob>,...`, where each blob is
/// base64 of `login\nsessionId\nyandexUid`. These are live Yandex
/// cookies, so they must never sit in the tree: a build without the define
/// gets an empty list and on-demand conference creation is unavailable.
final List<TelemostServiceAccount> telemostServiceAccounts = [
  for (final blob in _accountBlobs.split(','))
    if (blob.trim().isNotEmpty) _decode(blob.trim()),
];

const _accountBlobs = String.fromEnvironment('TELEMOST_ACCOUNTS');

TelemostServiceAccount _decode(String blob) {
  final parts = utf8.decode(base64Decode(blob)).split('\n');
  return TelemostServiceAccount(
    login: parts[0],
    sessionId: parts[1],
    yandexUid: parts[2],
  );
}
