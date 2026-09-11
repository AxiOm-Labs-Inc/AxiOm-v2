import 'dart:async';
import 'dart:convert';

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
