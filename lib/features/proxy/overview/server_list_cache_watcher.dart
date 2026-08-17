import 'dart:async';

import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/server_list_cache.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Keeps the offline server-list cache in sync with the active profile.
///
/// Whenever the active profile changes (manual selection, auto-import) or its
/// content is refreshed (manual/background/connect-time subscription update —
/// all of them emit a new entity via [activeProfileProvider]), the selector
/// cache is rebuilt from the profile's stored config. Without this the
/// selector showed the previous session's servers until the next connect.
final serverListCacheWatcherProvider = Provider<void>((ref) {
  String? lastKey;
  ref.listen(
    activeProfileProvider,
    (previous, next) {
      final profile = next.valueOrNull;
      if (profile == null) return;
      final key = '${profile.id}:${profile.lastUpdate.millisecondsSinceEpoch}';
      if (key == lastKey) return;
      lastKey = key;
      unawaited(refreshServerListCacheFromProfile(ref, profile.id));
    },
    fireImmediately: true,
  );
});
