import 'package:flutter_test/flutter_test.dart';
import 'package:axiom/features/account/model/account_models.dart';
import 'package:axiom/features/connection/model/connection_failure.dart';
import 'package:axiom/features/stats/stats_error_type.dart';

void main() {
  group('subscriptionUrlStem', () {
    test('keeps everything up to the key', () {
      expect(
        subscriptionUrlStem('https://panel.example.com/sub/arco981_0b6e/5f2c9a'),
        'https://panel.example.com/sub/arco981_0b6e/',
      );
    });

    test('old and new link after a reset share the stem', () {
      final oldStem = subscriptionUrlStem('https://panel.example.com:8443/sub/u1/aaaa');
      final newStem = subscriptionUrlStem('https://panel.example.com:8443/sub/u1/bbbb');
      expect(oldStem, isNotNull);
      expect(oldStem, newStem);
    });

    test('different users do not share a stem', () {
      expect(
        subscriptionUrlStem('https://p.example.com/sub/u1/k'),
        isNot(subscriptionUrlStem('https://p.example.com/sub/u12/k')),
      );
    });

    test('links of another shape are not matched', () {
      expect(subscriptionUrlStem('https://p.example.com/sub/u1'), isNull);
      expect(subscriptionUrlStem('https://p.example.com/api/u1/k'), isNull);
      expect(subscriptionUrlStem('vless://uuid@host:443'), isNull);
      expect(subscriptionUrlStem('not a url'), isNull);
    });
  });

  group('statsErrorType', () {
    test('connection failures get stable names, not generated class names', () {
      expect(statsErrorType(const ConnectionFailure.missingVpnPermission('text with 1.2.3.4')), 'MissingVpnPermission');
      expect(statsErrorType(const ConnectionFailure.invalidConfig()), 'InvalidConfig');
      expect(statsErrorType(ConnectionFailure.unexpected(StateError('secret'))), 'Unexpected.StateError');
      expect(statsErrorType(const ConnectionFailure.unexpected()), 'Unexpected');
    });

    test('other errors are reduced to their type', () {
      expect(statsErrorType(const FormatException('https://leak.example/sub/x')), 'FormatException');
    });
  });
}
