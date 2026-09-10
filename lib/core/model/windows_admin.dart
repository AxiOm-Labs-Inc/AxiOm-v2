import 'dart:io';

/// Windows: работает ли приложение с правами администратора.
///
/// Права нужны режиму службы **VPN (TUN)** — он поднимает виртуальный адаптер и
/// правит таблицу маршрутов. Манифест их намеренно **не** требует: с
/// `requireAdministrator` отказ в окне UAC означал бы, что приложение не
/// запускается вообще. Вместо этого runner при старте пробует поднять себя сам
/// (`windows/runner/main.cpp`, `RelaunchElevated`), а если пользователь нажал
/// «Нет» — продолжает работу и передаёт в Dart аргумент `--no-admin`.
///
/// В этом режиме приложение остаётся рабочим, но:
/// * режим службы подменяется на системный прокси
///   (`config_option_repository.dart`), потому что TUN всё равно не поднимется;
/// * на главном экране висит плашка с кнопкой перезапуска
///   (`windows_admin_banner.dart`).
abstract final class WindowsAdmin {
  static bool _restricted = false;

  /// `true` — Windows-сборка работает без прав администратора.
  ///
  /// На других платформах всегда `false`: там режим службы от elevation не
  /// зависит, а Android/iOS вообще не знают такого понятия.
  static bool get restricted => _restricted;

  /// Вызывается из `main()` до старта приложения.
  static void init(List<String> args) {
    _restricted = Platform.isWindows && args.contains("--no-admin");
  }

  /// Перезапуск с запросом прав администратора.
  ///
  /// Запускается отдельный процесс powershell, который **сначала ждёт**, пока
  /// текущая копия закроется: иначе новая копия найдёт живое окно, решит, что
  /// приложение уже запущено, и просто выйдет (см. `SendAppLinkToInstance` и
  /// мьютекс `AxiOmMutex` в `main.cpp`). Поэтому мы стартуем помощника
  /// detached и немедленно завершаемся.
  ///
  /// Ничего не возвращает: если UAC отклонят снова, поднимется обычная
  /// ограниченная копия — то есть ровно то состояние, из которого пользователь
  /// нажал кнопку.
  static Future<void> relaunchAsAdmin() async {
    if (!Platform.isWindows) return;
    final exe = Platform.resolvedExecutable;
    await Process.start(
      "powershell",
      [
        "-NoProfile",
        "-WindowStyle",
        "Hidden",
        "-Command",
        "Start-Sleep -Milliseconds 1500; Start-Process -FilePath '$exe' -Verb RunAs",
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
}
