import 'package:axiom/axiomcore/axiom_core_service_provider.dart';
import 'package:axiom/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'reset_tunnel_notifier.g.dart';

@riverpod
class ResetTunnelNotifier extends _$ResetTunnelNotifier with AppLogger {
  @override
  Future<void> build() async {}

  Future<void> run() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(axiomCoreServiceProvider).resetTunnel().getOrElse((err) {
        loggy.warning("error resetting tunnel", err);
        throw err;
      }).run(),
    );
  }
}
