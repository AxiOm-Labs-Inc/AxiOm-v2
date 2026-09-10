import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/model/windows_admin.dart';
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

  /// У кого автозапуск был включён до 4.4.3, тот держит запись в реестре. Она
  /// продолжает работать, пока приложение стартует без прав, но перестаёт, как
  /// только копия становится elevated. Поэтому переносим на задачу планировщика
  /// молча — но только если процесс сейчас с правами: без них `schtasks
  /// /rl highest` всё равно откажет, и мы бы снесли рабочую запись, не создав
  /// замены.
  Future<void> _migrateWindowsAutoStart() async {
    if (WindowsAdmin.restricted) return;
    try {
      if (!await launchAtStartup.isEnabled()) return;
      loggy.info("migrating windows auto start from registry to scheduled task");
      if (await _WindowsTaskAutoStart.enable()) {
        await launchAtStartup.disable();
      } else {
        loggy.warning("scheduled task not created, keeping registry entry");
      }
    } catch (e) {
      loggy.warning("windows auto start migration failed: $e");
    }
  }

  /// На Windows автозапуск может лежать в двух местах: задача планировщика (когда
  /// приложение запущено с правами) и запись в реестре (когда прав не было и
  /// задачу создать не удалось). Включённым считается любое из них.
  Future<bool> _isEnabled() async {
    if (Platform.isWindows) {
      if (await _WindowsTaskAutoStart.isEnabled()) return true;
      try {
        return await launchAtStartup.isEnabled();
      } catch (_) {
        return false;
      }
    }
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
      // Задача планировщика — основной путь: только она поднимает приложение с
      // правами. Не вышло (нет прав, групповые политики, урезанный планировщик)
      // — откатываемся на запись в реестре: она сработает, пока копия стартует
      // без повышения, а это ровно тот случай, когда задачу и не дали создать.
      if (await _WindowsTaskAutoStart.enable()) {
        state = const AsyncValue.data(true);
        return;
      }
      loggy.warning("autostart task not created, falling back to registry");
      try {
        await launchAtStartup.enable();
        state = const AsyncValue.data(true);
      } catch (e) {
        loggy.warning("registry autostart failed too: $e");
        state = const AsyncValue.data(false);
      }
      return;
    }
    await launchAtStartup.enable();
    state = const AsyncValue.data(true);
  }

  Future<void> disable() async {
    loggy.debug("disabling auto start");
    if (Platform.isWindows) {
      // Снимаем оба варианта: какой из них реально стоит, зависит от того, с
      // правами или без запускалось приложение в момент включения.
      await _WindowsTaskAutoStart.disable();
      try {
        await launchAtStartup.disable();
      } catch (_) {
        // Записи нет — нечего снимать.
      }
      state = const AsyncValue.data(false);
      return;
    }
    await launchAtStartup.disable();
    state = const AsyncValue.data(false);
  }
}
