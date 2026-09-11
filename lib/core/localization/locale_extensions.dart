import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:axiom/gen/fonts.gen.dart';
import 'package:axiom/gen/translations.g.dart';

extension AppLocaleX on AppLocale {
  String get preferredFontFamily =>
      this == AppLocale.fa ? FontFamily.shabnam : (kIsWeb || !Platform.isWindows ? "" : FontFamily.emoji);

  String get localeName => switch (flutterLocale.toString()) {
    "ar" => "العربية",
    "en" => "English",
    "es" => "Spanish",
    "fa" => "فارسی",
    "fr" => "Français",
    "id" => "Indonesian",
    "pt_BR" => "Portuguese (Brazil)",
    "ru" => "Русский",
    "tr" => "Türkçe",
    "zh" || "zh_CN" => "中文 (中国)",
    "zh_TW" => "中文 (台湾)",
    _ => "Unknown",
  };
}
