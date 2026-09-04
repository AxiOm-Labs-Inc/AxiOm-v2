import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Конверт слота Яндекс.Диска (TODO_TELEMOST_AUTH.md §6).
///
/// **Это не безопасность, а гигиена.** Ключ лежит в этой самой сборке и
/// достаётся из неё за вечер. Смысл ровно один: человек, открывший публичную
/// ссылку на Диске в браузере, видит мусор, а не адрес рабочей комнаты.
/// Отсекаются любопытные и автоматические обходчики; мотивированный атакующий
/// не задержан ни на минуту. Настоящая защита выхода — рукопожатие §2–§3.
///
///     слот       = "v1:" + base64url( nonce[16] | ciphertext | tag[16] )
///     keystream  = HMAC(K, nonce|0x01) | HMAC(K, nonce|0x02) | ...
///     ciphertext = plaintext XOR keystream
///     tag        = HMAC(K, nonce | ciphertext)[0:16]
///
/// HKDF-Expand в роли потока, а не самодельный шифр: в зависимостях есть только
/// `crypto` (хеши и HMAC, без AEAD), и этой же конструкцией считается всё
/// остальное в протоколе. Тег нужен не от подделки — подделать может любой
/// владелец сборки, — а чтобы побившийся файл дал честное «не мой формат», а не
/// мусорный roomId, с которым клиент пойдёт в несуществующую комнату.
///
/// Эталон и общий набор векторов: `vpn-bot/telemost_crypto.py`,
/// `vpn-bot/tools/telemost_vectors.json`.
class TelemostSlotCipher {
  static const prefix = 'v1:';
  static const _nonceLen = 16;
  static const _tagLen = 16;

  /// Ключи сборки. Два, а не один: публикация ключа где-нибудь на форуме иначе
  /// означала бы выбор между «оставить как есть» и «сломать все выпущенные
  /// сборки». `_PREV` даёт окно, в котором новый ключ уже работает, а старые
  /// файлы ещё читаются.
  static const _keyHex = String.fromEnvironment('TELEMOST_SLOT_KEY');
  static const _prevKeyHex = String.fromEnvironment('TELEMOST_SLOT_KEY_PREV');

  /// Раскрывает конверт любым из ключей сборки. null — «не мой формат»:
  /// не тот префикс, битая база, короткий конверт или несошедшийся тег.
  /// Вызывающий тогда читает файл как открытый текст.
  static String? open(String envelope) {
    for (final hex in [_keyHex, _prevKeyHex]) {
      final out = openWithKey(hex, envelope);
      if (out != null) return out;
    }
    return null;
  }

  /// Раскрытие конкретным ключом. Отдельно от [open], потому что ключи сборки
  /// приходят из `--dart-define` и в тестах их взять неоткуда — а сверяться с
  /// общими векторами надо.
  static String? openWithKey(String keyHex, String envelope) {
    final s = envelope.trim();
    if (!s.startsWith(prefix)) return null;
    final key = _parseKey(keyHex);
    if (key == null) return null;
    return _openWith(key, s.substring(prefix.length));
  }

  /// Есть ли у сборки хоть один ключ. Без него шифрованный слот прочитать
  /// нечем — это ошибка сборки (забыли `--dart-define`), а не сети.
  static bool get hasKey => _parseKey(_keyHex) != null;

  static String? _openWith(Uint8List key, String body) {
    // Padding у base64url необязателен — добираем сами.
    final padded = body.padRight(body.length + ((4 - body.length % 4) % 4), '=');
    Uint8List raw;
    try {
      raw = base64Url.decode(padded);
    } catch (_) {
      return null;
    }
    if (raw.length < _nonceLen + _tagLen) return null;
    final nonce = Uint8List.sublistView(raw, 0, _nonceLen);
    final ct = Uint8List.sublistView(raw, _nonceLen, raw.length - _tagLen);
    final tag = Uint8List.sublistView(raw, raw.length - _tagLen);

    final want = Hmac(sha256, key)
        .convert([...nonce, ...ct])
        .bytes
        .sublist(0, _tagLen);
    if (!_constantTimeEquals(want, tag)) return null;

    final ks = _keystream(key, nonce, ct.length);
    final plain = Uint8List(ct.length);
    for (var i = 0; i < ct.length; i++) {
      plain[i] = ct[i] ^ ks[i];
    }
    try {
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  static Uint8List _keystream(Uint8List key, Uint8List nonce, int length) {
    final out = Uint8List(length);
    var written = 0;
    var counter = 1;
    while (written < length) {
      final block = Hmac(sha256, key).convert([...nonce, counter & 0xff]).bytes;
      final take = (length - written) < block.length ? length - written : block.length;
      out.setRange(written, written + take, block);
      written += take;
      counter++;
    }
    return out;
  }

  static Uint8List? _parseKey(String hex) {
    if (hex.length != 64) return null;
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      final b = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (b == null) return null;
      out[i] = b;
    }
    return out;
  }

  /// Тег сравнивается за постоянное время не ради стойкости (её тут нет), а
  /// чтобы не тащить в код привычку сравнивать секреты как попало.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
