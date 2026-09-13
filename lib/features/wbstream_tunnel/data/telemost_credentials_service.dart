import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:axiom/features/account/data/account_api.dart';
import 'package:axiom/features/account/model/account_state.dart';
import 'package:axiom/features/account/notifier/account_notifier.dart';
import 'package:axiom/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Секрет Телемоста этого аккаунта — то, чем приложение доказывает держателю
/// комнаты право на мост.
///
/// В комнату он не уходит никогда: рукопожатие внутри relay считает из него
/// одноразовый HMAC на пару (комната, nonce). Здесь только хранение и
/// обновление.
///
/// Хранится рядом с сессией — в защищённом хранилище платформы, а не в
/// SharedPreferences: срок жизни у него длинный, и обычный prefs-файл читается
/// с рутованного устройства как есть.
///
/// Берётся один раз и живёт на устройстве. Обновляется, когда:
///   * его ещё нет;
///   * сменился Telegram-аккаунт;
///   * держатель ответил `unknown_uid` — на сервере подняли поколение секрета.
class TelemostCredentialsService with InfraLogger {
  TelemostCredentialsService(this._ref);

  final Ref _ref;
  static const _storageKey = 'telemost_credentials';
  static const _storage = FlutterSecureStorage();

  /// Не даём двум подключениям подряд дёрнуть RU дважды.
  Future<Map<String, dynamic>?>? _inFlight;

  /// Секрет в hex, либо null — если аккаунт не привязан, не оплачен или RU
  /// недоступен и ничего не сохранено. Вызывающий в этом случае просто
  /// подключается без авторизации: до strict это рабочий путь.
  Future<String?> secret({bool forceRefresh = false}) async {
    final stored = await _read();
    final tgId = _currentTelegramId();
    // Смена аккаунта обесценивает сохранённое: uid считается от Telegram ID.
    final stale = stored != null && tgId != null && stored['telegram_id'] != tgId;
    if (stored != null && !forceRefresh && !stale) {
      return stored['tm_secret'] as String?;
    }
    final fresh = await _fetch();
    if (fresh != null) return fresh['tm_secret'] as String?;
    // Обновиться не вышло. Устаревшее по аккаунту не отдаём — оно заведомо
    // чужое; всё прочее оставляем: RU мог просто не ответить.
    if (stale) {
      await clear();
      return null;
    }
    return stored?['tm_secret'] as String?;
  }

  Future<void> clear() => _storage.delete(key: _storageKey);

  /// Код активации — тот же секрет, выданный вручную (скриптом на RU) и
  /// присланный человеку через то, что у него открывается: MAX, ВК, SMS.
  /// Нужен, когда RU с телефона недоступен вовсе — белые списки, а Telegram
  /// для входа в аккаунт не открывается ни на какой сети.
  ///
  /// Формат: `AXT1-` + base64url(tg_id[8] | gen[4] | tm_secret[32] | check[4]),
  /// check — первые 4 байта SHA-256 от `AXT1` и первых 44 байт. Проверка только
  /// от опечаток: право на мост решает держатель по самому секрету, а вкладка,
  /// открытая выдуманным кодом, ни к чему не подключится.
  ///
  /// Код ищется внутри вставленного текста, так что можно вставить сообщение
  /// целиком. true — код принят, секрет сохранён, вкладка открыта.
  Future<bool> importActivationCode(String input) async {
    final match = RegExp(r'AXT1-([A-Za-z0-9_-]{64})').firstMatch(input);
    if (match == null) return false;
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(match.group(1)!);
    } catch (_) {
      return false;
    }
    if (bytes.length != 48) return false;
    final check = sha256.convert([...utf8.encode('AXT1'), ...bytes.sublist(0, 44)]).bytes;
    for (var i = 0; i < 4; i++) {
      if (check[i] != bytes[44 + i]) return false;
    }
    final view = ByteData.sublistView(bytes);
    final payload = <String, dynamic>{
      'tm_secret': bytes.sublist(12, 44).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'gen': view.getUint32(8),
      'telegram_id': view.getUint64(0),
    };
    await _storage.write(key: _storageKey, value: jsonEncode(payload));
    await _ref.read(Preferences.telemostEntitled.notifier).update(true);
    loggy.info('telemost: секрет принят из кода активации (поколение ${payload['gen']})');
    return true;
  }

  int? _currentTelegramId() {
    final state = _ref.read(accountNotifierProvider);
    return state is AccountStateConnected ? state.session.telegramId : null;
  }

  Future<Map<String, dynamic>?> _read() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      loggy.warning('telemost: не удалось прочитать секрет: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _fetch() {
    final running = _inFlight;
    if (running != null) return running;
    final future = _fetchOnce();
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<Map<String, dynamic>?> _fetchOnce() async {
    final state = _ref.read(accountNotifierProvider);
    if (state is! AccountStateConnected) return null;
    final session = state.session;
    try {
      final res = await _ref
          .read(accountApiProvider)
          .getTelemostCredentials(session.sessionToken);
      if (res == null) return null; // нет права или подтвердить нечем
      final secret = res['tm_secret'] as String?;
      if (secret == null || secret.length != 64) {
        loggy.warning('telemost: сервер вернул секрет неожиданного вида');
        return null;
      }
      final payload = <String, dynamic>{
        'tm_secret': secret,
        'gen': res['gen'],
        'telegram_id': session.telegramId,
      };
      await _storage.write(key: _storageKey, value: jsonEncode(payload));
      loggy.info('telemost: секрет получен (поколение ${res['gen']})');
      return payload;
    } on AccountUnauthorizedException {
      // Сессия мертва — этим займётся account_notifier, здесь просто нечего
      // сохранять.
      return null;
    } catch (e) {
      loggy.warning('telemost: не удалось получить секрет: $e');
      return null;
    }
  }
}

final telemostCredentialsServiceProvider = Provider<TelemostCredentialsService>(
  (ref) => TelemostCredentialsService(ref),
);
