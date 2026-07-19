/// Semantic color constants — single source of truth for brand/accent colors.
///
/// Replace values here to rebrand; no hunting through widget files.
abstract class AppColors {
  AppColors._();

  /// Telegram brand blue — account connection UI.
  static const telegram = 0xFF0088CC;

  /// Success / active / positive.
  static const success = 0xFF5DCAA5;

  /// Info / neutral accent (e.g. traffic bar default).
  static const info = 0xFF5BA3FF;

  /// Warning / approaching limit (traffic >80%, days ≤3).
  static const warning = 0xFFD9CD7B;

  /// Danger / critical (traffic >95%).
  static const danger = 0xFFEF5350;
}
