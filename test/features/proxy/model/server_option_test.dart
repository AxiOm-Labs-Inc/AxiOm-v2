import 'package:flutter_test/flutter_test.dart';
import 'package:axiom/features/proxy/model/server_option.dart';
import 'package:axiom/axiomcore/generated/v2/hcore/hcore.pb.dart';

void main() {
  group('ServerOption.parse', () {
    test('parses Arco servers and skips balancers', () {
      final group = OutboundGroup(
        tag: 'select',
        selected: 'fr-tcp',
        items: [
          OutboundInfo(
            tag: 'nl-ws',
            tagDisplay: 'Netherlands (Arco) [ws]',
            urlTestDelay: 120,
          ),
          OutboundInfo(
            tag: 'fr-tcp',
            tagDisplay: 'France (Arco) [tcp]',
            urlTestDelay: 90,
          ),
          OutboundInfo(
            tag: 'pl-tcp',
            tagDisplay: 'Poland (Arco) [tcp]',
            urlTestDelay: 200,
          ),
          OutboundInfo(
            tag: 'lowest',
            tagDisplay: 'lowest',
            isGroup: true,
          ),
          OutboundInfo(
            tag: 'balance',
            tagDisplay: 'balance',
          ),
        ],
      );

      final options = ServerOption.parse(group);

      expect(options, hasLength(3));
      expect(
        options.map((o) => (o.country, o.protocol, o.transport, o.rawTag, o.delay)),
        containsAll([
          ('Netherlands', 'vless', 'ws', 'nl-ws', 120),
          ('France', 'vless', 'tcp', 'fr-tcp', 90),
          ('Poland', 'vless', 'tcp', 'pl-tcp', 200),
        ]),
      );

      final countries = ServerOption.countries(options).toList()..sort();
      expect(countries, ['France', 'Netherlands', 'Poland']);

      expect(ServerOption.protocolsFor(options, 'France'), ['vless']);
      expect(ServerOption.protocolsFor(options, 'Netherlands'), ['vless']);
      expect(ServerOption.transportsFor(options, 'France', 'vless'), ['tcp']);
      expect(ServerOption.transportsFor(options, 'Netherlands', 'vless'), ['ws']);

      final found = ServerOption.find(options, 'France', 'vless', 'tcp');
      expect(found?.rawTag, 'fr-tcp');
    });

    test('parses servers regardless of the username in parentheses', () {
      final group = OutboundGroup(
        tag: 'select',
        selected: 'nl-ws',
        items: [
          OutboundInfo(tag: 'nl-ws', tagDisplay: 'Netherlands (ivan123) [ws]', urlTestDelay: 110),
          OutboundInfo(tag: 'de-tcp', tagDisplay: 'United States (some.user_42) [tcp]', urlTestDelay: 80),
        ],
      );

      final options = ServerOption.parse(group);

      expect(options, hasLength(2));
      expect(
        options.map((o) => (o.country, o.protocol, o.transport, o.rawTag)),
        containsAll([
          ('Netherlands', 'vless', 'ws', 'nl-ws'),
          ('United States', 'vless', 'tcp', 'de-tcp'),
        ]),
      );
    });

    test('fastest picks lowest delay across country and transport', () {
      final options = [
        ServerOption(country: 'Netherlands', protocol: 'vless', transport: 'ws', rawTag: 'nl-ws', delay: 120),
        ServerOption(country: 'France', protocol: 'vless', transport: 'tcp', rawTag: 'fr-tcp', delay: 90),
        ServerOption(country: 'Poland', protocol: 'vless', transport: 'tcp', rawTag: 'pl-tcp', delay: 200),
      ];

      expect(ServerOption.fastest(options)?.rawTag, 'fr-tcp');
      expect(ServerOption.fastest([]), isNull);
      expect(
        ServerOption.fastest([
          ServerOption(country: 'France', protocol: 'vless', transport: 'tcp', rawTag: 'fr-tcp', delay: 0),
        ]),
        isNull,
      );
    });
  });
}
