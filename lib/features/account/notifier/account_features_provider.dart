import 'dart:async';

import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/account/model/account_models.dart';
import 'package:hiddify/features/account/notifier/whitepass_notifier.dart';
import 'package:hiddify/features/wbstream_tunnel/notifier/wbstream_tunnel_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Feature flags from the latest successful GET /api/app/me.
/// Updated by [AccountNotifier]; defaults to all-false before the first fetch.
final accountFeaturesProvider = StateProvider<AccountFeatures>((ref) => const AccountFeatures());

/// Whether the WhitePass cheat-code window is currently open.
final whitePassUnlockedProvider = Provider<bool>((ref) {
  final until = ref.watch(whitePassNotifierProvider);
  return until > DateTime.now().millisecondsSinceEpoch;
});

/// Whether the «AxiOm Telemost» tab is usable. The fresh server flag wins;
/// then the WhitePass cheat-code window; otherwise fall back to the cached
/// value from the last successful /me call so the tab isn't locked during
/// session restore or without network.
final telemostEntitledProvider = Provider<bool>((ref) {
  if (ref.watch(accountFeaturesProvider).telemost) return true;
  if (ref.watch(whitePassUnlockedProvider)) return true;
  return ref.watch(Preferences.telemostEntitled);
});

/// Whenever the bypass gate closes (logout, entitlement revoked, WhitePass
/// expired) the tunnels must go down with it — a locked tab must never keep
/// a live tunnel running in the background.
final telemostGateGuardProvider = Provider<void>((ref) {
  ref.listen(telemostEntitledProvider, (previous, next) {
    if (previous == true && next == false) {
      unawaited(ref.read(wbstreamTunnelNotifierProvider.notifier).deactivate());
    }
  });
});
