import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/account/model/account_models.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Feature flags from the latest successful GET /api/app/me.
/// Updated by [AccountNotifier]; defaults to all-false before the first fetch.
final accountFeaturesProvider = StateProvider<AccountFeatures>((ref) => const AccountFeatures());

/// Whether the Telemost tab is unlocked in the UI. The fresh server flag wins;
/// otherwise fall back to the cached value from the last successful /me call
/// so the tab isn't locked during session restore or without network.
final telemostEntitledProvider = Provider<bool>((ref) {
  if (ref.watch(accountFeaturesProvider).telemost) return true;
  return ref.watch(Preferences.telemostEntitled);
});
