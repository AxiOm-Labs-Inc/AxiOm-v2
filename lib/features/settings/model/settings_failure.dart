import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:axiom/core/localization/translations.dart';
import 'package:axiom/core/model/failures.dart';

part 'settings_failure.freezed.dart';

@freezed
sealed class SettingsFailure with _$SettingsFailure, Failure {
  const SettingsFailure._();

  @With<UnexpectedFailure>()
  const factory SettingsFailure.unexpected([Object? error, StackTrace? stackTrace]) = SettingsUnexpectedFailure;

  @override
  ({String type, String? message}) present(TranslationsEn t) {
    return switch (this) {
      SettingsUnexpectedFailure() => (type: t.errors.unexpected, message: null),
    };
  }
}
