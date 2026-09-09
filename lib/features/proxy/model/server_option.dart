import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

/// Parsed Arco VPN server entry from selector group items.
class ServerOption {
  ServerOption({
    required this.country,
    required this.protocol,
    required this.transport,
    required this.rawTag,
    required this.delay,
  });

  final String country;

  /// 'vless' | 'hysteria2' | 'naive' | 'shadowtls'
  final String protocol;

  /// 'ws' | 'tcp' (for vless) | 'hy2' (hysteria2) | 'naive' | 'stls' (shadowtls)
  final String transport;
  final String rawTag;
  final int delay;

  /// Sentinel for the auto (fastest server + transport) selector mode.
  static const String autoCountryKey = '__auto__';

  static const String protocolVless = 'vless';
  static const String protocolHysteria2 = 'hysteria2';
  static const String protocolNaive = 'naive';

  /// ShadowTLS v3 + Shadowsocks. В подписке это цепочка из двух хостов, но
  /// пользователю она видна одной записью `<Страна> (<user>) [stls]` — звено
  /// цепочки в селектор не попадает.
  static const String protocolShadowTls = 'shadowtls';

  static bool isValidDelay(int delay) => delay > 0 && delay < 65000;

  // Server tags look like "<Country> (<username>) [<token>]" where the
  // parenthetical is the subscription account name (varies per user), so it
  // must not be hard-coded to a specific value. The token encodes both
  // protocol and transport: ws/tcp → vless, hy2/hysteria2 → hysteria2,
  // naive/http → naive, stls/shadowtls → shadowtls.
  static final RegExp _displayPattern = RegExp(
    r'^(.*?)\s*\([^)]*\)\s*\[([a-z0-9]+)\]\s*$',
    caseSensitive: false,
  );

  /// Maps a bracket token to (protocol, transport), or null if unknown.
  static (String, String)? _tokenToProtocolTransport(String token) {
    return switch (token.toLowerCase()) {
      'ws' => (protocolVless, 'ws'),
      'tcp' => (protocolVless, 'tcp'),
      'hy2' || 'hysteria2' || 'hysteria' || 'hy' => (protocolHysteria2, 'hy2'),
      'naive' || 'http' => (protocolNaive, 'naive'),
      'stls' || 'shadowtls' => (protocolShadowTls, 'stls'),
      _ => null,
    };
  }

  static ServerOption? tryParseDisplay(String tagDisplay, {required String rawTag, int delay = 0}) {
    final match = _displayPattern.firstMatch(tagDisplay.trim());
    if (match == null) return null;
    final country = match.group(1)!.trim();
    if (country.isEmpty) return null;
    final mapped = _tokenToProtocolTransport(match.group(2)!);
    if (mapped == null) return null;
    return ServerOption(
      country: country,
      protocol: mapped.$1,
      transport: mapped.$2,
      rawTag: rawTag,
      delay: delay,
    );
  }

  static List<ServerOption> parse(OutboundGroup group) {
    final options = <ServerOption>[];
    for (final item in group.items) {
      if (item.isGroup) continue;
      final parsed = tryParseDisplay(
        item.tagDisplay,
        rawTag: item.tag,
        delay: item.urlTestDelay,
      );
      if (parsed != null) options.add(parsed);
    }
    return options;
  }

  static Set<String> countries(List<ServerOption> options) {
    return options.map((o) => o.country).toSet();
  }

  static int _protocolRank(String protocol) => switch (protocol.toLowerCase()) {
    'vless' => 0,
    'hysteria2' => 1,
    'naive' => 2,
    'shadowtls' => 3,
    _ => 4,
  };

  static List<String> protocolsFor(List<ServerOption> options, String country) {
    return options
        .where((o) => o.country == country)
        .map((o) => o.protocol)
        .toSet()
        .toList()
      ..sort((a, b) => _protocolRank(a).compareTo(_protocolRank(b)));
  }

  static List<String> transportsFor(List<ServerOption> options, String country, String protocol) {
    return options
        .where((o) => o.country == country && o.protocol == protocol)
        .map((o) => o.transport)
        .toSet()
        .toList()
      ..sort();
  }

  static ServerOption? find(List<ServerOption> options, String country, String protocol, String transport) {
    for (final o in options) {
      if (o.country == country && o.protocol == protocol && o.transport == transport) return o;
    }
    return null;
  }

  static int? bestDelayForCountry(List<ServerOption> options, String country) {
    final delays = options
        .where((o) => o.country == country && isValidDelay(o.delay))
        .map((o) => o.delay);
    if (delays.isEmpty) return null;
    return delays.reduce((a, b) => a < b ? a : b);
  }

  static int? bestDelayForProtocol(List<ServerOption> options, String country, String protocol) {
    final delays = options
        .where((o) => o.country == country && o.protocol == protocol && isValidDelay(o.delay))
        .map((o) => o.delay);
    if (delays.isEmpty) return null;
    return delays.reduce((a, b) => a < b ? a : b);
  }

  /// Fastest server among all country + transport combinations (by url-test delay).
  static ServerOption? fastest(List<ServerOption> options) {
    ServerOption? best;
    for (final option in options) {
      if (!isValidDelay(option.delay)) continue;
      if (best == null || option.delay < best.delay) best = option;
    }
    return best;
  }

  static String protocolLabel(String protocol) => switch (protocol.toLowerCase()) {
    'vless' => 'VLESS',
    'hysteria2' => 'Hysteria2',
    'naive' => 'Naive',
    'shadowtls' => 'ShadowTLS',
    _ => protocol,
  };

  static String transportLabel(String transport) => switch (transport.toLowerCase()) {
    'ws' => 'WebSocket',
    'tcp' => 'Reality (TCP)',
    'hy2' => 'QUIC',
    'naive' => 'HTTP/2 TLS',
    'stls' => 'ShadowTLS (TCP)',
    _ => transport,
  };

  static String countryFlagEmoji(String country) {
    final iso = _countryNameToIso[country.trim().toLowerCase()];
    if (iso == null || iso.length != 2) return '🏳️';
    final upper = iso.toUpperCase();
    return String.fromCharCodes(upper.codeUnits.map((c) => c + 127397));
  }

  static const Map<String, String> _countryNameToIso = {
    'netherlands': 'NL',
    'france': 'FR',
    'russia': 'RU',
    'poland': 'PL',
    'germany': 'DE',
    'united states': 'US',
    'usa': 'US',
    'united kingdom': 'GB',
    'uk': 'GB',
    'finland': 'FI',
    'sweden': 'SE',
    'norway': 'NO',
    'turkey': 'TR',
    'japan': 'JP',
    'singapore': 'SG',
    'canada': 'CA',
    'italy': 'IT',
    'spain': 'ES',
    'switzerland': 'CH',
    'austria': 'AT',
    'belgium': 'BE',
    'czechia': 'CZ',
    'czech republic': 'CZ',
    'romania': 'RO',
    'ukraine': 'UA',
    'kazakhstan': 'KZ',
    'hong kong': 'HK',
    'taiwan': 'TW',
    'south korea': 'KR',
    'korea': 'KR',
    'india': 'IN',
    'brazil': 'BR',
    'australia': 'AU',
    'israel': 'IL',
    'uae': 'AE',
    'united arab emirates': 'AE',
    'ireland': 'IE',
    'denmark': 'DK',
    'portugal': 'PT',
    'hungary': 'HU',
    'bulgaria': 'BG',
    'serbia': 'RS',
    'latvia': 'LV',
    'lithuania': 'LT',
    'estonia': 'EE',
    'moldova': 'MD',
    'georgia': 'GE',
    'armenia': 'AM',
    'azerbaijan': 'AZ',
  };
}
