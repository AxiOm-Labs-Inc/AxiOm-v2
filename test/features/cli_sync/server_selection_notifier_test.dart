import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/server_selection_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late ServerSelectionNotifier notifier;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'server_selector_country': 'France', 'server_selector_protocol': 'vless'});
    prefs = await SharedPreferences.getInstance();
    notifier = ServerSelectionNotifier(prefs);
  });

  test('reads the existing prefs', () {
    expect(notifier.state, const ServerSelection(c: 'France', p: 'vless'));
  });

  test('a stale command writes nothing', () async {
    await notifier.setIfCurrent(const ServerSelection(c: 'Germany', p: 'hysteria2', t: 'hy2'), () => false);
    expect(notifier.state, const ServerSelection(c: 'France', p: 'vless'));
    expect(prefs.getString('server_selector_country'), 'France');
  });

  test('a current command is applied in one synchronous step (no partial selection)', () {
    // Без await: и состояние, и все три настройки уже новые.
    final done = notifier.setIfCurrent(const ServerSelection(c: 'Germany', p: 'hysteria2', t: 'hy2'), () => true);
    expect(notifier.state, const ServerSelection(c: 'Germany', p: 'hysteria2', t: 'hy2'));
    expect(prefs.getString('server_selector_country'), 'Germany');
    expect(prefs.getString('server_selector_protocol'), 'hysteria2');
    expect(prefs.getString('server_selector_transport'), 'hy2');
    return done;
  });
}
