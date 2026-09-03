import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/telemost_tunnel/notifier/telemost_tunnel_notifier.dart';
import 'package:hiddify/features/wbstream_tunnel/notifier/wbstream_tunnel_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// WhitePass cheat-code access state: unix-ms timestamp until which the
/// «AxiOm Telemost» tab is unlocked, 0 = locked.
final whitePassNotifierProvider = StateNotifierProvider<WhitePassNotifier, int>((ref) {
  return WhitePassNotifier(ref);
});

/// Time-limited (2 h) access to the Telemost whitelist-bypass via a cheat code
/// entered on the About page. The code itself is never stored — only its
/// SHA-256. On expiry the tunnel is shut down and the tab re-locks; if the
/// user has since connected a Telegram account with the Telemost entitlement,
/// the regular gate keeps the tab open.
class WhitePassNotifier extends StateNotifier<int> with AppLogger {
  WhitePassNotifier(this._ref) : super(0) {
    _restore();
  }

  final Ref _ref;
  Timer? _timer;

  static const unlockDuration = Duration(hours: 2);

  /// SHA-256 of the access code.
  static const _codeSha256 = 'c6dacb5a0008c872a6da6ca4734b5beee4f1dc716460e977faa45ec50e964bff';

  void _restore() {
    final until = _ref.read(Preferences.whitePassUnlockUntil);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until > now) {
      state = until;
      _schedule(Duration(milliseconds: until - now));
    } else if (until != 0) {
      unawaited(_ref.read(Preferences.whitePassUnlockUntil.notifier).update(0));
    }
  }

  /// Checks the entered code against the stored hash; on match unlocks the
  /// tab for [unlockDuration]. Returns true when the code is correct.
  Future<bool> tryUnlock(String code) async {
    final digest = sha256.convert(utf8.encode(code.trim())).toString();
    if (digest != _codeSha256) return false;
    final until = DateTime.now().add(unlockDuration).millisecondsSinceEpoch;
    state = until;
    unawaited(_ref.read(Preferences.whitePassUnlockUntil.notifier).update(until));
    _schedule(unlockDuration);
    loggy.info('whitepass: unlocked for ${unlockDuration.inHours}h');
    return true;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _onExpire);
  }

  void _onExpire() {
    loggy.info('whitepass: access expired');
    state = 0;
    unawaited(_ref.read(Preferences.whitePassUnlockUntil.notifier).update(0));
    // Shut the tunnels down if they were running on the cheat access;
    // whether the tabs stay open afterwards is decided by the regular
    // TG-based gate. WBStream shares the gate, so it goes down too.
    unawaited(_ref.read(telemostTunnelNotifierProvider.notifier).deactivate());
    unawaited(_ref.read(wbstreamTunnelNotifierProvider.notifier).deactivate());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
