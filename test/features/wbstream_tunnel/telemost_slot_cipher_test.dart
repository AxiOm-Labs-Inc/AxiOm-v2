import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/wbstream_tunnel/data/telemost_slot_cipher.dart';
import 'package:hiddify/features/wbstream_tunnel/data/wbstream_link_provider.dart';

/// testdata/telemost_vectors.json — копия vpn-bot/tools/telemost_vectors.json,
/// сгенерированного эталонной реализацией на Python. Обновлять обе копии
/// вместе: расхождение даст не ошибку сборки, а комнаты, которые клиент
/// перестал находить.
void main() {
  final vectors = jsonDecode(
    File('test/features/wbstream_tunnel/testdata/telemost_vectors.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final slots = (vectors['slot'] as List<dynamic>).cast<Map<String, dynamic>>();

  group('конверт слота', () {
    test('раскрывается на всех общих векторах', () {
      expect(slots, isNotEmpty);
      for (final v in slots) {
        expect(
          TelemostSlotCipher.openWithKey(v['key'] as String, v['envelope'] as String),
          v['plaintext'],
          reason: 'вектор ${v['plaintext']}',
        );
      }
    });

    test('чужой ключ не раскрывает', () {
      final v = slots[1];
      expect(
        TelemostSlotCipher.openWithKey('11' * 32, v['envelope'] as String),
        isNull,
      );
    });

    test('порченый конверт даёт null, а не мусор', () {
      final env = slots[1]['envelope'] as String;
      final key = slots[1]['key'] as String;
      // Тег не сойдётся: последний символ base64 меняем.
      final broken = env.substring(0, env.length - 1) +
          (env.endsWith('A') ? 'B' : 'A');
      expect(TelemostSlotCipher.openWithKey(key, broken), isNull);
      expect(TelemostSlotCipher.openWithKey(key, 'v1:не-база64'), isNull);
      expect(TelemostSlotCipher.openWithKey(key, 'v1:'), isNull);
    });

    test('открытый текст конвертом не считается', () {
      expect(
        TelemostSlotCipher.openWithKey(
          slots[1]['key'] as String,
          'https://stream.wb.ru/room/01a05932-4f0e-7c1a-9d33-8b6e2c5f0011',
        ),
        isNull,
      );
    });
  });

  group('разбор слота', () {
    test('открытый адрес читается как раньше', () {
      expect(
        WbstreamLinkProvider.parseSlot(
          'https://stream.wb.ru/room/01A05932-4F0E-7C1A-9D33-8B6E2C5F0011\n',
        ),
        '01a05932-4f0e-7c1a-9d33-8b6e2c5f0011',
      );
    });

    test('голый uuid читается как раньше', () {
      expect(
        WbstreamLinkProvider.parseSlot(' 01a05932-4f0e-7c1a-9d33-8b6e2c5f0011 '),
        '01a05932-4f0e-7c1a-9d33-8b6e2c5f0011',
      );
    });

    test('конверт без ключа сборки не разбирается как текст', () {
      // Сборка в тестах собрана без --dart-define, ключей нет. Важно, что это
      // даёт честный null: иначе клиент пошёл бы в комнату по мусору.
      expect(WbstreamLinkProvider.parseSlot(slots[1]['envelope'] as String), isNull);
    });

    test('мусор даёт null', () {
      expect(WbstreamLinkProvider.parseSlot('<html>404</html>'), isNull);
      expect(WbstreamLinkProvider.parseSlot(''), isNull);
    });
  });
}
