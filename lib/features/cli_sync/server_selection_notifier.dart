// Выбранный сервер (страна/протокол/транспорт) в одном месте: его пишут и карточка выбора сервера,
// и команды CLI. Хранится в прежних настройках server_selector_country/protocol/transport.

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

  /// Меняет только переданные поля; состояние обновляется сразу и одним шагом,
  /// настройки пишутся следом.
  Future<void> update({String? c, String? p, String? t}) => set(state.copyWith(c: c, p: p, t: t));

  Future<void> set(ServerSelection next) async {
    final previous = state;
    if (next == previous) return;
    state = next;
    if (next.c != previous.c) await _prefs.setString(serverSelectorCountryKey, next.c);
    if (next.p != previous.p) await _prefs.setString(serverSelectorProtocolKey, next.p);
    if (next.t != previous.t) await _prefs.setString(serverSelectorTransportKey, next.t);
  }

  /// Перечитать после того, как настройки на диске изменил CLI.
  void reloadFromPrefs() {
    final fresh = readServerSelection(_prefs);
    if (fresh != state) state = fresh;
  }
}

final serverSelectionProvider = StateNotifierProvider<ServerSelectionNotifier, ServerSelection>(
  (ref) => ServerSelectionNotifier(ref.watch(sharedPreferencesProvider).requireValue),
);
