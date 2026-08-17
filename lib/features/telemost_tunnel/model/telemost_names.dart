import 'dart:math';

/// Pool of neutral display names for the Telemost conference. One is picked
/// at random on every connect so sessions don't share a stable identity.
const telemostDisplayNames = <String>[
  'Александр',
  'Дмитрий',
  'Максим',
  'Иван',
  'Артём',
  'Никита',
  'Михаил',
  'Даниил',
  'Егор',
  'Андрей',
  'Алексей',
  'Сергей',
  'Владимир',
  'Павел',
  'Роман',
  'Илья',
  'Кирилл',
  'Тимофей',
  'Марк',
  'Лев',
];

final _rng = Random();

String randomTelemostDisplayName() =>
    telemostDisplayNames[_rng.nextInt(telemostDisplayNames.length)];
