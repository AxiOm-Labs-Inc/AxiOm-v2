import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences key for the offline server list — the last known servers
/// of the active profile, shown in the selector while the core is not running.
const cachedServerOptionsKey = 'server_selector_cached_options';

List<ServerOption> readCachedServerOptions(SharedPreferences prefs) {
  final raw = prefs.getString(cachedServerOptionsKey);
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map(
          (e) => ServerOption(
            country: (e as Map<String, dynamic>)['c'] as String,
            protocol: (e['p'] as String?) ?? ServerOption.protocolVless,
            transport: e['t'] as String,
            rawTag: '',
            delay: 0,
          ),
        )
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<void> writeCachedServerOptions(SharedPreferences prefs, List<ServerOption> options) {
  final data = options.map((o) => {'c': o.country, 'p': o.protocol, 't': o.transport}).toList();
  return prefs.setString(cachedServerOptionsKey, jsonEncode(data));
}

/// Parses server options out of a stored profile config without the core.
///
/// Handles both formats a profile file can hold: a sing-box JSON config
/// (outbounds with tags) and a plain/base64 link list (display name in the
/// URI fragment). Entries that don't match the "Country (user) [proto]" tag
/// pattern are skipped.
List<ServerOption> parseServerOptionsFromConfig(String content) {
  final options = <ServerOption>[];

  // 1) sing-box JSON config
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic> && decoded['outbounds'] is List) {
      for (final outbound in decoded['outbounds'] as List) {
        if (outbound is! Map) continue;
        final tag = outbound['tag'];
        if (tag is! String) continue;
        final parsed = ServerOption.tryParseDisplay(tag, rawTag: tag);
        if (parsed != null) options.add(parsed);
      }
      return _dedupe(options);
    }
  } catch (_) {
    // not JSON — fall through to the link list
  }

  // 2) link list, possibly base64-encoded
  final text = safeDecodeBase64(content);
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final uri = Uri.tryParse(line);
    if (uri == null || !uri.hasFragment) continue;
    final display = Uri.decodeComponent(uri.fragment.split(' -> ').first).trim();
    if (display.isEmpty) continue;
    final parsed = ServerOption.tryParseDisplay(display, rawTag: display);
    if (parsed != null) options.add(parsed);
  }
  return _dedupe(options);
}

List<ServerOption> _dedupe(List<ServerOption> options) {
  final seen = <String>{};
  return options.where((o) => seen.add('${o.country}|${o.protocol}|${o.transport}')).toList();
}

/// Rebuilds the offline server-list cache from the stored config of profile
/// [profileId]. Called when the active profile changes or its subscription
/// content is refreshed, so the selector never shows a stale server list.
Future<void> refreshServerListCacheFromProfile(Ref ref, String profileId) async {
  try {
    final file = ref.read(profilePathResolverProvider).file(profileId);
    if (!await file.exists()) return;
    final options = parseServerOptionsFromConfig(await file.readAsString());
    if (options.isEmpty) return;
    final prefs = ref.read(sharedPreferencesProvider);
    if (!prefs.hasValue) return;
    await writeCachedServerOptions(prefs.requireValue, options);
  } catch (e) {
    debugPrint('server_list_cache: failed to refresh cache for [$profileId]: $e');
  }
}
