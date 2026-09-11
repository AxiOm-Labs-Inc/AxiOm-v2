import 'dart:async';

import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/features/account/model/account_models.dart';
import 'package:axiom/features/wbstream_tunnel/notifier/wbstream_tunnel_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Feature flags from the latest successful GET /api/app/me.
/// Updated by [AccountNotifier]; defaults to all-false before the first fetch.
final accountFeaturesProvider = StateProvider<AccountFeatures>((ref) => const AccountFeatures());

/// Whether the «AxiOm Telemost» tab is usable. The fresh server flag wins;
/// otherwise fall back to the cached value from the last successful /me call
/// so the tab isn't locked during session restore or without network.
final telemostEntitledProvider = Provider<bool>((ref) {
  if (ref.watch(accountFeaturesProvider).telemost) return true;
  return ref.watch(Preferences.telemostEntitled);
});

/// Whenever the bypass gate closes (logout, entitlement revoked) the tunnels
/// must go down with it — a locked tab must never keep a live tunnel running
/// in the background.
final telemostGateGuardProvider = Provider<void>((ref) {
  ref.listen(telemostEntitledProvider, (previous, next) {
    if (previous == true && next == false) {
      unawaited(ref.read(wbstreamTunnelNotifierProvider.notifier).deactivate());
    }
  });
});
