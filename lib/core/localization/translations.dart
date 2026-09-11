import 'package:axiom/core/localization/locale_preferences.dart';
import 'package:axiom/gen/translations.g.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

export 'package:axiom/gen/translations.g.dart';

part 'translations.g.dart';

@Riverpod(keepAlive: true)
Future<Translations> translations(Ref ref) async {
  return await ref.watch(localePreferencesProvider).build();
}
