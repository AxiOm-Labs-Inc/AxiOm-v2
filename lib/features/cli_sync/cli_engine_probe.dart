// Проверка движка CLI: работает ⇔ его clash API (порт и секрет — из state.json CLI)
// отвечает 200 на GET /version за 1 с. Текущий сервер — GET /proxies/proxy → now.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class CliApiSettings {
  const CliApiSettings({required this.port, required this.secret});

  final int port;
  final String secret;

  @override
  bool operator ==(Object other) => other is CliApiSettings && other.port == port && other.secret == secret;

  @override
  int get hashCode => Object.hash(port, secret);
}

/// Порт и секрет API из state.json CLI. null — файл не по формату SBX (например, состояние
/// старого Go-CLI без `settings`) или API не настроен.
CliApiSettings? parseCliApiSettings(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (json is! Map) return null;
  final settings = json['settings'];
  if (settings is! Map) return null;
  final rawPort = settings['api_port'];
  final port = rawPort is int ? rawPort : (rawPort is String ? int.tryParse(rawPort) : null);
  final secret = settings['api_secret'];
  if (port == null || port <= 0 || port > 65535) return null;
  return CliApiSettings(port: port, secret: secret is String ? secret : '');
}

class CliEngineState {
  const CliEngineState({required this.running, this.now, this.busy = false, this.starting = false});

  /// Движок CLI отвечает.
  final bool running;

  /// Текущий сервер (`now` селектора `proxy`), если известен.
  final String? now;

  /// Приложение сейчас выполняет команду CLI (axiom disconnect / use).
  final bool busy;

  /// CLI держит свежий start.lock: VPN включается через CLI.
  final bool starting;

  /// VPN включён (или включается) через CLI.
  bool get on => running || starting;

  static const stopped = CliEngineState(running: false);

  CliEngineState copyWith({bool? running, String? now, bool? busy, bool? starting}) => CliEngineState(
    running: running ?? this.running,
    now: now ?? this.now,
    busy: busy ?? this.busy,
    starting: starting ?? this.starting,
  );

  @override
  bool operator ==(Object other) =>
      other is CliEngineState &&
      other.running == running &&
      other.now == now &&
      other.busy == busy &&
      other.starting == starting;

  @override
  int get hashCode => Object.hash(running, now, busy, starting);

  @override
  String toString() => 'CliEngineState(running: $running, now: $now, busy: $busy, starting: $starting)';
}

Future<CliEngineState> probeCliEngine(
  CliApiSettings api, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = timeout;
  try {
    final version = await _get(client, api, '/version', timeout);
    if (version == null) return CliEngineState.stopped;
    String? now;
    final proxy = await _get(client, api, '/proxies/proxy', timeout);
    if (proxy != null) {
      try {
        final json = jsonDecode(proxy);
        if (json is Map && json['now'] is String) now = json['now'] as String;
      } catch (_) {}
    }
    return CliEngineState(running: true, now: now);
  } catch (_) {
    return CliEngineState.stopped;
  } finally {
    client.close(force: true);
  }
}

/// Тело ответа 200 или null.
Future<String?> _get(HttpClient client, CliApiSettings api, String path, Duration timeout) async {
  try {
    return await () async {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:${api.port}$path'));
      if (api.secret.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${api.secret}');
      final response = await request.close();
      final body = await response.transform(const Utf8Decoder(allowMalformed: true)).join();
      return response.statusCode == 200 ? body : null;
    }().timeout(timeout);
  } catch (_) {
    return null;
  }
}
