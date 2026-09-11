import 'package:axiom/core/directories/directories_provider.dart';
import 'package:axiom/core/notification/in_app_notification_controller.dart';
import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/axiomcore/axiom_core_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'axiom_core_service_provider.g.dart';

@Riverpod(keepAlive: true, dependencies: [AppDirectories, DebugModeNotifier, inAppNotificationController])
AxiomCoreService axiomCoreService(Ref ref) {
  return AxiomCoreService(ref);
}
