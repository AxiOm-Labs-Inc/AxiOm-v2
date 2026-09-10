import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auto_start_notifier.g.dart';

/// Автозапуск на Windows — задачей планировщика, а не записью в `HKCU\...\Run`.
///
/// С 4.4.3 манифест приложения запрашивает права администратора (нужны режиму
/// VPN/TUN). Elevated-процессы Windows из ключа `Run` и из папки «Автозагрузка»
/// не поднимает — молча пропускает, то есть штатный `launch_at_startup` там
/// просто перестал бы работать. Задача с `/rl highest` это ограничение снимает:
/// создать её может сам процесс, потому что он уже elevated.
class _WindowsTaskAutoStart {
  static const taskName = "AxiOmAutostart";

  static Future<bool> isEnabled() async {
    try {
      final res = await Process.run("schtasks", ["/query", "/tn", taskName]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// `/f` перезаписывает задачу — путь к exe меняется при переустановке.
  static Future<bool> enable() async {
    try {
      final res = await Process.run("schtasks", [
        "/create",
        "/tn", taskName,
        "/tr", '"${Platform.resolvedExecutable}"',
        "/sc", "onlogon",
        "/rl", "highest",
        "/f",
      ]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<void> disable() async {
    try {
      await Process.run("schtasks", ["/delete", "/tn", taskName, "/f"]);
    } catch (_) {
      // Задачи нет — считаем, что выключено.
    }
  }
}

@Riverpod(keepAlive: true)
class AutoStartNotifier extends _$AutoStartNotifier with InfraLogger {
  Timer? _timer;

  @override
  Future<bool> build() async {
    if (!PlatformUtils.isDesktop) return false;
    final appInfo = ref.watch(appInfoProvider).requireValue;
    launchAtStartup.setup(
      appName: appInfo.name,
      appPath: Platform.resolvedExecutable,
      packageName: "Hiddify.HiddifyNext",
    );
    if (Platform.isWindows) await _migrateWindowsAutoStart();
    final isEnabled = await _isEnabled();
    loggy.info("auto start is [${isEnabled ? "Enabled" : "Disabled"}]");
    _startTimer();
    ref.onDispose(() => _timer?.cancel());
    return isEnabled;
  }

  /// У кого автозапуск был включён до 4.4.3, тот держит запись в реестре — она
  /// теперь не срабатывает. Переносим такого пользователя на задачу планировщика
  /// молча: он автозапуск уже включал, спрашивать заново незачем.
  Future<void> _migrateWindowsAutoStart() async {
    try {
      if (!await launchAtStartup.isEnabled()) return;
      loggy.info("migrating windows auto start from registry to scheduled task");
      await launchAtStartup.disable();
      await _WindowsTaskAutoStart.enable();
    } catch (e) {
      loggy.warning("windows auto start migration failed: $e");
    }
  }

  Future<bool> _isEnabled() async {
    if (Platform.isWindows) return _WindowsTaskAutoStart.isEnabled();
    return launchAtStartup.isEnabled();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 15), (timer) => updateStatus());
  }

  Future<bool> updateStatus() async {
    loggy.debug("update auto start status");
    final isEnabled = await _isEnabled();
    state = AsyncValue.data(isEnabled);
    return isEnabled;
  }

  Future<void> enable() async {
    loggy.debug("enabling auto start");
    if (Platform.isWindows) {
      // Задача может не создаться (групповые политики, урезанный планировщик) —
      // тогда переключатель обязан вернуться в «выключено», а не соврать.
      final ok = await _WindowsTaskAutoStart.enable();
      if (!ok) loggy.warning("failed to create autostart task");
      state = AsyncValue.data(ok);
      return;
    }
    await launchAtStartup.enable();
    state = const AsyncValue.data(true);
  }

  Future<void> disable() async {
    loggy.debug("disabling auto start");
    if (Platform.isWindows) {
      await _WindowsTaskAutoStart.disable();
      state = const AsyncValue.data(false);
      return;
    }
    await launchAtStartup.disable();
    state = const AsyncValue.data(false);
  }
}
