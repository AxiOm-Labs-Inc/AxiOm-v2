import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/wbstream_tunnel/model/wbstream_settings.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Display name of the WBStream core session (shown in the core's
/// foreground notification). No profile entity is created — the tunnel is a
/// separate service from the main VPN, not a subscription.
const wbstreamProfileName = 'AxiOm Telemost';

/// WireGuard-over-tunnel (wg-tm): the WG session rides through the relay's
/// local SOCKS5 (UDP ASSOCIATE), so an SFU hiccup becomes plain packet loss
/// for WG and inner TCP connections survive the reconnect. Endpoint is the
/// wg-tm interface's tunnel-local address, reachable through the WB tunnel.
///
/// The WG identity is derived from the room id (22.08.2026). Before that every
/// install shipped the same key and the same 10.55.0.2, which meant one single
/// WireGuard peer for everybody: two phones online at once overwrote each
/// other's endpoint on the server and both connections died. Rooms are one per
/// user now, so the tunnel identity has to be one per user too.
///
/// Both sides derive it from the same public room id, exactly like the tunnel
/// obfuscation key does — no extra channel is needed to hand a config out.
/// This adds no authentication: whoever knows the room id can derive the key,
/// but knowing the room id already lets you into the room.
const _wgServerHost = '10.55.0.1';
const _wgServerPort = 51821;
const _wgServerPublicKey = 'Tiw/6D/XH08fKKN03lDcZBAvfwVVJpJb8ODz4nk/ck4=';

/// Labels keep the two derivations independent; bump the version if the
/// scheme ever changes — the server derives with the very same strings.
const _wgKeyLabel = 'axiom-wbs-wg/v1|';
const _wgIpLabel = 'axiom-wbs-ip/v1|';

/// X25519 private key for [roomId]: sha256 of the labelled room id, clamped
/// the way curve25519 requires, base64-encoded (what sing-box expects).
String wbstreamWgPrivateKey(String roomId) {
  final h = sha256.convert(utf8.encode(_wgKeyLabel + roomId.trim())).bytes;
  final k = Uint8List.fromList(h);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  return base64.encode(k);
}

/// Tunnel address for [roomId], somewhere in 10.55.1.1–10.55.254.254.
/// 10.55.0.0/24 is deliberately skipped: the legacy shared peer still lives
/// at 10.55.0.2 and old installs keep using it.
String wbstreamWgAddress(String roomId) {
  final h = sha256.convert(utf8.encode(_wgIpLabel + roomId.trim())).bytes;
  return '10.55.${1 + h[0] % 254}.${1 + h[1] % 254}/32';
}

final wbstreamConfigServiceProvider = Provider<WbstreamConfigService>(
  (ref) => WbstreamConfigService(ref),
);

/// Builds the sing-box config used in WB Stream tunnel mode: a WireGuard
/// outbound chained (`detour`) through a SOCKS5 outbound pointed at the
/// relay's local endpoint. Written to a standalone file — the tunnel
/// bypasses the profile store entirely.
class WbstreamConfigService with InfraLogger {
  WbstreamConfigService(this._ref);

  final Ref _ref;

  /// Writes the config fragment for [socks] to
  /// `<workingDir>/configs/wbstream.json` and returns the file, or null when
  /// the write failed.
  Future<File?> writeConfig(WbstreamSocks socks, String roomId) async {
    // A sing-box config fragment — the core's Parse step (same one that
    // converts subscription links) turns it into a full config. wireguard
    // goes first so it becomes the main outbound; the socks outbound is
    // marked §hide§ so the generated selector contains only wbstream-wg
    // (verified via HiddifyCli build in the Telemost mode).
    loggy.info('wbstream: wg identity for room $roomId -> '
        '${wbstreamWgAddress(roomId)}');
    final content = jsonEncode({
      'outbounds': [
        {
          'type': 'wireguard',
          'tag': 'wbstream-wg',
          'server': _wgServerHost,
          'server_port': _wgServerPort,
          'local_address': [wbstreamWgAddress(roomId)],
          'private_key': wbstreamWgPrivateKey(roomId),
          'peer_public_key': _wgServerPublicKey,
          // NOTE: no persistent-keepalive field — the core's wireguard
          // outbound does not support it (Parse fails with "unknown field",
          // verified via HiddifyCli).
          'detour': 'wbstream-relay §hide§',
        },
        {
          'type': 'socks',
          'tag': 'wbstream-relay §hide§',
          'server': socks.host,
          'server_port': socks.port,
          'version': '5',
          'username': socks.user,
          'password': socks.pass,
        },
      ],
    });

    try {
      final file = _ref.read(profilePathResolverProvider).file('wbstream');
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return file;
    } catch (e) {
      loggy.warning('wbstream: failed to write config: $e');
      return null;
    }
  }
}
