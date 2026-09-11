import 'package:axiom/core/preferences/preferences_provider.dart';
import 'package:axiom/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'analytics_controller.g.dart';

const String enableAnalyticsPrefKey = "enable_analytics";

@Riverpod(keepAlive: true)
class AnalyticsController extends _$AnalyticsController with AppLogger {
  @override
  Future<bool> build() async {
    // Analytics are permanently disabled in AxiOm
    return false;
  }

  SharedPreferences get _preferences => ref.read(sharedPreferencesProvider).requireValue;

  Future<void> enableAnalytics() async {
    // No-op: analytics are disabled in AxiOm
    loggy.debug("analytics disabled in AxiOm, ignoring enableAnalytics()");
  }

  Future<void> disableAnalytics() async {
    if (state case AsyncData()) {
      loggy.debug("disabling analytics");
      await _preferences.setBool(enableAnalyticsPrefKey, false);
      state = const AsyncData(false);
    }
  }
}
