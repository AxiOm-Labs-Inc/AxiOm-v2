// Выбранный сервер (страна/протокол/транспорт) в одном месте (Windows, Linux): его пишут карточка выбора
// сервера и команды CLI. Пока приложение работает, настройки пишет только оно (DESIGN-sync v2, п. 2).
// Хранится в прежних настройках server_selector_country/protocol/transport.

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const serverSelectorCountryKey = 'server_selector_country';
const serverSelectorProtocolKey = 'server_selector_protocol';
const serverSelectorTransportKey = 'server_selector_transport';

ServerSelection readServerSelection(SharedPreferences prefs) {
  String read(String key, String fallback) {
    final value = prefs.get(key);
    return value is String ? value : fallback;
  }

  final country = read(serverSelectorCountryKey, autoCountryKey);
  return ServerSelection(
    c: country.isEmpty ? autoCountryKey : country,
    p: read(serverSelectorProtocolKey, ''),
    t: read(serverSelectorTransportKey, ''),
  );
}

class ServerSelectionNotifier extends StateNotifier<ServerSelection> {
  ServerSelectionNotifier(this._prefs) : super(readServerSelection(_prefs));

  final SharedPreferences _prefs;

  /// Меняет только переданные поля; состояние обновляется сразу и одним шагом, настройки пишутся следом.
  Future<void> update({String? c, String? p, String? t}) => set(state.copyWith(c: c, p: p, t: t));

  Future<void> set(ServerSelection next) => setIfCurrent(next, () => true);

  /// Один шаг (v4, S): проверка [current], новое состояние и запись всех изменённых настроек — синхронно,
  /// без пауз между ними (SharedPreferences меняет свою копию сразу, на диск пишет потом). Поздняя или
  /// устаревшая команда ничего не меняет, частично записанного выбора не бывает.
  Future<void> setIfCurrent(ServerSelection next, bool Function() current) {
    if (!current()) return Future.value();
    final previous = state;
    if (next == previous) return Future.value();
    state = next;
    return Future.wait([
      if (next.c != previous.c) _prefs.setString(serverSelectorCountryKey, next.c),
      if (next.p != previous.p) _prefs.setString(serverSelectorProtocolKey, next.p),
      if (next.t != previous.t) _prefs.setString(serverSelectorTransportKey, next.t),
    ]);
  }
}

final serverSelectionProvider = StateNotifierProvider<ServerSelectionNotifier, ServerSelection>(
  (ref) => ServerSelectionNotifier(ref.watch(sharedPreferencesProvider).requireValue),
);
