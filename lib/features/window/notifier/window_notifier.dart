import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:axiom/core/model/constants.dart';
import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/features/connection/notifier/connection_notifier.dart';
import 'package:axiom/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

part 'window_notifier.g.dart';

/// Fixed mobile-like desktop window (matches mobile UI layout).
const fixedWindowSize = Size(390, 780);
const minimumWindowSize = fixedWindowSize;
const defaultWindowSize = fixedWindowSize;

@Riverpod(keepAlive: true)
class WindowNotifier extends _$WindowNotifier with AppLogger {
  @override
  Future<void> build() async {
    if (!PlatformUtils.isDesktop) return;


    await windowManager.ensureInitialized();
    await initWindowState();
  }

  Future<void> saveWindowState() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }
    final position = await windowManager.getPosition();

    await ref.read(Preferences.windowMaximized.notifier).update(false);
    await ref.read(Preferences.windowSize.notifier).update(fixedWindowSize);
    await ref.read(Preferences.windowPosition.notifier).update(position);
  }

  Future<void> initWindowState() async {
    final position = ref.read(Preferences.windowPosition);
    final isWindowVisible = position != null && await checkWindowVisivility(position, fixedWindowSize);
    final silentStart = ref.read(Preferences.silentStart);
    loggy.debug("window state. size: $fixedWindowSize (fixed)");
    loggy.debug("window state. position: ${isWindowVisible ? position : "centered"}");
    loggy.debug("window state. silent start: ${silentStart ? "Enabled" : "Disabled"}");

    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: fixedWindowSize,
        center: !isWindowVisible,
        minimumSize: fixedWindowSize,
        maximumSize: fixedWindowSize,
      ),
    );
    await windowManager.setMinimumSize(fixedWindowSize);
    await windowManager.setMaximumSize(fixedWindowSize);
    await windowManager.setSize(fixedWindowSize);
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    await windowManager.setTitle(Constants.appName);

    if (isWindowVisible) {
      await windowManager.setPosition(position);
      loggy.debug("restoring window to position: $position");
    } else {
      await windowManager.center();
      loggy.debug("centering window");
    }
    if (!silentStart) {
      await ref.read(windowNotifierProvider.notifier).show(focus: false);
      loggy.debug("showing app window on start");
    } else {
      loggy.debug("silent start, remain hidden accessible via tray");
    }
  }

  Future<bool> checkWindowVisivility(Offset windowPos, Size windowSize, {double tolerance = 10.0}) async {
    final Rect windowRect = windowPos & windowSize;

    final displays = await screenRetriever.getAllDisplays();

    for (final display in displays) {
      if (display.visiblePosition == null || display.visibleSize == null) {
        continue;
      }
      final Rect monitorRect = display.visiblePosition! & display.visibleSize!;
      if (windowRect.left >= (monitorRect.left - tolerance) &&
          windowRect.top >= (monitorRect.top - tolerance) &&
          windowRect.right <= (monitorRect.right + tolerance) &&
          windowRect.bottom <= (monitorRect.bottom + tolerance)) {
        return true;
      }
    }
    return false;
  }

  Future<void> show({bool focus = true}) async {
    await windowManager.show();
    if (focus) await windowManager.focus();
    if (Platform.isMacOS) {
      await windowManager.setSkipTaskbar(false);
    }
  }

  Future<void> hide() async {
    await windowManager.hide();
    if (Platform.isMacOS) {
      await windowManager.setSkipTaskbar(true);
    }
  }

  Future<void> showOrHide() async {
    if (await windowManager.isVisible()) {
      await hide();
    } else {
      await show();
    }
  }

  Future<void> exit() async {
    await ref
        .read(connectionNotifierProvider.notifier)
        .abortConnection()
        .timeout(const Duration(seconds: 2))
        .catchError((e) {
          loggy.warning("error aborting connection on quit", e);
        });
    await trayManager.destroy();
    await windowManager.destroy();
  }
}
