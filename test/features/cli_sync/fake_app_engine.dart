import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/cli_sync/cli_sync_service.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';

/// Подставной движок приложения для тестов синхронизации.
class FakeAppEngine implements AppEngineAdapter {
  FakeAppEngine({this.status = AppEngineStatus.disconnected, List<ServerOption>? options})
    : knownOptions = options ?? const [];

  @override
  AppEngineStatus status;

  @override
  String? rawTag;

  @override
  ServerSelection storedSelection = ServerSelection.auto;

  @override
  List<ServerOption> knownOptions;

  final persisted = <ServerSelection>[];
  final applied = <ServerSelection>[];
  int stopCalls = 0;
  String? stopError;
  String? applyError;
  Duration stopDelay = Duration.zero;

  @override
  Future<void> persistSelection(ServerSelection selection) async {
    persisted.add(selection);
    storedSelection = selection.isAuto ? storedSelection.copyWith(c: autoCountryKey) : selection;
  }

  @override
  Future<String?> applyToEngine(ServerSelection selection) async {
    applied.add(selection);
    return applyError;
  }

  @override
  Future<String?> stopEngine() async {
    stopCalls++;
    await Future<void>.delayed(stopDelay);
    if (stopError != null) return stopError;
    status = AppEngineStatus.disconnected;
    return null;
  }
}
