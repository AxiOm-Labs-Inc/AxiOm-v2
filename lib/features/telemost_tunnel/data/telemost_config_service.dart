import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/telemost_tunnel/model/telemost_settings.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Display name of the Telemost core session (shown in the core's
/// foreground notification). No profile entity is created — the tunnel is a
/// separate service from the main VPN, not a subscription.
const telemostProfileName = 'AxiOm Telemost';

/// WireGuard-over-tunnel spike (wg-tm). The WG session rides through the
/// relay's local SOCKS5 (UDP ASSOCIATE), so the 53s SFU slot-kill becomes
/// plain packet loss for WG and inner TCP connections survive the reconnect.
/// Endpoint is the wg-tm interface's tunnel-local address: the same wg-tm
/// config (keys/subnet/port) runs on every bypass node (NL/FR/PL), so the
/// exit node is whichever node spawned the creator — no app-side change
/// needed when the dispatcher routes elsewhere. On FR an OUTPUT DNAT maps
/// 51821→51822 (port busy with wgfr there).
/// Single shared peer for the spike — per-user keys come later. Both keys are
/// passed at build time (`--dart-define=TELEMOST_WG_SERVER_PUBKEY=...`,
/// `--dart-define=TELEMOST_WG_CLIENT_PRIVKEY=...`): a WireGuard private key in
/// the tree ends up extractable from every shipped APK.
const _wgServerHost = '10.55.0.1';
const _wgServerPort = 51821;
const _wgServerPublicKey = String.fromEnvironment('TELEMOST_WG_SERVER_PUBKEY');
const _wgClientPrivateKey = String.fromEnvironment('TELEMOST_WG_CLIENT_PRIVKEY');
const _wgClientAddress = '10.55.0.2/32';

final telemostConfigServiceProvider = Provider<TelemostConfigService>(
  (ref) => TelemostConfigService(ref),
);

/// Builds the sing-box config used in Telemost tunnel mode: a WireGuard
/// outbound chained (`detour`) through a SOCKS5 outbound pointed at the
/// relay's local endpoint. Written to a standalone file — the tunnel
/// bypasses the profile store entirely.
class TelemostConfigService with InfraLogger {
  TelemostConfigService(this._ref);

  final Ref _ref;

  /// Writes the config fragment for [socks] to
  /// `<workingDir>/configs/telemost.json` and returns the file, or null when
  /// the write failed.
  Future<File?> writeConfig(TelemostSocks socks) async {
    // A sing-box config fragment — the core's Parse step (same one that
    // converts subscription links) turns it into a full config. wireguard
    // goes first so it becomes the main outbound; the socks outbound is
    // marked §hide§ so the generated selector contains only telemost-wg
    // (verified via HiddifyCli build).
    final content = jsonEncode({
      'outbounds': [
        {
          'type': 'wireguard',
          'tag': 'telemost-wg',
          'server': _wgServerHost,
          'server_port': _wgServerPort,
          'local_address': [_wgClientAddress],
          'private_key': _wgClientPrivateKey,
          'peer_public_key': _wgServerPublicKey,
          // NOTE: no persistent-keepalive field — the core's wireguard
          // outbound does not support it (Parse fails with "unknown field",
          // verified via HiddifyCli).
          'detour': 'telemost-relay §hide§',
        },
        {
          'type': 'socks',
          'tag': 'telemost-relay §hide§',
          'server': socks.host,
          'server_port': socks.port,
          'version': '5',
          'username': socks.user,
          'password': socks.pass,
        },
      ],
    });

    try {
      final file = _ref.read(profilePathResolverProvider).file('telemost');
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return file;
    } catch (e) {
      loggy.warning('telemost: failed to write config: $e');
      return null;
    }
  }
}
