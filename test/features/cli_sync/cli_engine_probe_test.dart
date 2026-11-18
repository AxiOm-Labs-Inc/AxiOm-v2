import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_engine_probe.dart';

void main() {
  group('parseCliApiSettings', () {
    test('reads settings.api_port and api_secret', () {
      final api = parseCliApiSettings(
        jsonEncode({
          'settings': {'api_port': 9197, 'api_secret': 's3cret', 'mixed_port': 2081},
        }),
      );
      expect(api, const CliApiSettings(port: 9197, secret: 's3cret'));
      expect(parseCliApiSettings('{"settings":{"api_port":"9197"}}'), const CliApiSettings(port: 9197, secret: ''));
    });

    test('old Go CLI state and garbage mean no CLI engine', () {
      expect(parseCliApiSettings('{"subscription_url":"https://x/sub/abc"}'), isNull);
      expect(parseCliApiSettings('{"settings":{"api_port":0}}'), isNull);
      expect(parseCliApiSettings('{"settings":{}}'), isNull);
      expect(parseCliApiSettings('not json'), isNull);
    });
  });

  group('probeCliEngine', () {
    late HttpServer server;
    var hang = false;

    setUp(() async {
      hang = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (hang) return; // не отвечаем вовсе
        if (request.headers.value(HttpHeaders.authorizationHeader) != 'Bearer good') {
          request.response.statusCode = 401;
        } else if (request.uri.path == '/version') {
          request.response.write('{"version":"sing-box 1.13"}');
        } else if (request.uri.path == '/proxies/proxy') {
          request.response.write('{"type":"Selector","now":"Netherlands (u) [ws]"}');
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('running with the current server', () async {
      final state = await probeCliEngine(CliApiSettings(port: server.port, secret: 'good'));
      expect(state.running, isTrue);
      expect(state.now, 'Netherlands (u) [ws]');
    });

    test('wrong secret is not running', () async {
      final state = await probeCliEngine(CliApiSettings(port: server.port, secret: 'bad'));
      expect(state.running, isFalse);
    });

    test('closed port is not running', () async {
      final port = server.port;
      await server.close(force: true);
      final state = await probeCliEngine(CliApiSettings(port: port, secret: 'good'));
      expect(state.running, isFalse);
    });

    test('a hanging API answers "not running" within the timeout', () async {
      hang = true;
      final watch = Stopwatch()..start();
      final state = await probeCliEngine(
        CliApiSettings(port: server.port, secret: 'good'),
        timeout: const Duration(milliseconds: 300),
      );
      expect(state.running, isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });
  });
}
