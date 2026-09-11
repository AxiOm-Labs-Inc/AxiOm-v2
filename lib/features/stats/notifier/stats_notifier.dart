import 'package:axiom/features/connection/notifier/connection_notifier.dart';
import 'package:axiom/features/stats/data/stats_data_providers.dart';
import 'package:axiom/axiomcore/generated/v2/hcore/hcore.pb.dart';
import 'package:axiom/utils/custom_loggers.dart';
import 'package:axiom/utils/riverpod_utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'stats_notifier.g.dart';

@riverpod
class StatsNotifier extends _$StatsNotifier with AppLogger {
  @override
  Stream<SystemInfo> build() async* {
    ref.disposeDelay(const Duration(seconds: 10));
    final serviceRunning = await ref.watch(serviceRunningProvider.future);
    if (serviceRunning) {
      yield* ref
          .watch(statsRepositoryProvider)
          .watchStats()
          .map((event) => event.getOrElse((_) => SystemInfo.create()));
    } else {
      yield* Stream.value(SystemInfo.create());
    }
  }
}
