import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/cli_sync/cli_process.dart';
import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/cli_version.dart';
import 'package:hiddify/features/cli_sync/selection_resolution.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';

ServerOption opt(String c, String p, String t) => ServerOption(country: c, protocol: p, transport: t, rawTag: '$c-$t', delay: 0);

void main() {
  group('versions', () {
    CliRunResult run(String out, [int code = 0]) => CliRunResult(exitCode: code, stdout: out, stderr: '');

    test('SBX >= 1.4.0 is required', () {
      expect(parseSbxVersion('axiom 1.4.0\n'), (1, 4, 0));
      expect(isCompatibleSbxRun(run('axiom 1.4.0')), isTrue);
      expect(isCompatibleSbxRun(run('axiom 2.0.1\nmore')), isTrue);
      expect(isCompatibleSbxRun(run('axiom 1.3.9')), isFalse);
      expect(isCompatibleSbxRun(run('axiom 1.4.0', 1)), isFalse, reason: 'non-zero exit');
      expect(isCompatibleSbxRun(run('sbx 1.4.0')), isFalse);
      expect(isCompatibleSbxRun(run('axiom-cli 0.0.3 (linux/amd64)')), isFalse);
    });

    test('old Go CLI only on exit 0 with an anchored first line', () {
      expect(isLegacyCliRun(run('axiom-cli 0.0.3 (linux/amd64)\n')), isTrue);
      expect(isLegacyCliRun(run('\x1B[1maxiom-cli 0.0.2 (windows/amd64)\x1B[0m')), isTrue);
      expect(isLegacyCliRun(run('axiom-cli 0.0.3', 1)), isFalse);
      expect(isLegacyCliRun(run('hello\naxiom-cli 0.0.3')), isFalse, reason: 'not the first line');
      expect(isLegacyCliRun(const CliRunResult(exitCode: -1, stdout: '', stderr: '/home/u/axiom-cli/axiom: not found')), isFalse);
      expect(isLegacyCliRun(run('axiom 1.4.0')), isFalse);
    });

    test('release tags', () {
      expect(isSyncCompatible(parseReleaseTag('v1.4.0')), isTrue);
      expect(isSyncCompatible(parseReleaseTag('1.10.0')), isTrue);
      expect(isSyncCompatible(parseReleaseTag('v1.3.0')), isFalse);
      expect(parseReleaseTag('v1.4.0-rc1'), isNull);
    });
  });

  group('selection resolution (same rules as the CLI)', () {
    final options = [
      opt('France', 'hysteria2', 'hy2'),
      opt('France', 'vless', 'ws'),
      opt('France', 'vless', 'tcp'),
      opt('Germany', 'naive', 'naive'),
    ];

    test('auto ignores protocol and transport', () {
      expect(canonicalSelection(const ServerSelection(c: autoCountryKey, p: 'vless', t: 'ws'), options), ServerSelection.auto);
      expect(ServerSelection.auto.toJson(), {'c': '__auto__', 'p': '', 't': ''});
    });

    test('empty protocol/transport take the first in app order', () {
      expect(canonicalSelection(const ServerSelection(c: 'France'), options), const ServerSelection(c: 'France', p: 'vless', t: 'tcp'));
      expect(
        canonicalSelection(const ServerSelection(c: 'France', p: 'hysteria2'), options),
        const ServerSelection(c: 'France', p: 'hysteria2', t: 'hy2'),
      );
      expect(
        canonicalSelection(const ServerSelection(c: 'France', p: 'vless', t: 'ws'), options),
        const ServerSelection(c: 'France', p: 'vless', t: 'ws'),
      );
    });

    test('validation', () {
      expect(validateSelection(const ServerSelection(c: 'France', p: 'vless', t: 'ws'), options), isNull);
      expect(validateSelection(ServerSelection.auto, const []), isNull);
      expect(validateSelection(const ServerSelection(c: 'Spain', p: 'vless', t: 'ws'), options), isNotNull);
      expect(validateSelection(const ServerSelection(c: 'France', p: 'vless', t: 'hy2'), options), isNotNull);
      expect(validateSelection(const ServerSelection(c: 'France'), const []), isNotNull, reason: 'cannot resolve');
      expect(validateSelection(const ServerSelection(c: 'France', p: 'vless', t: 'ws'), const []), isNull);
    });
  });
}
