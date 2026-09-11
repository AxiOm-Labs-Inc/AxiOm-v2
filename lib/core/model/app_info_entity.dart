import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:axiom/core/model/environment.dart';

part 'app_info_entity.freezed.dart';

/// Имя продукта в начале User-Agent. По нему панель выбирает формат подписки:
/// `^AxiOm/` → sing-box JSON (с ShadowTLS и Naive), `^AxiOmX` → base64-ссылки.
/// Правила добавлены в панель 11.09.2026 **до** релиза с этим UA; прежние
/// `^HiddifyNext`/`^HiddifyNextX`/`^Dart/` там оставлены навсегда — их шлют
/// уже установленные копии. Сменить имя здесь, не добавив правило в панель, =
/// пользователи получат base64 и потеряют ShadowTLS/Naive.
const kUserAgentProduct = "AxiOm";

/// UA для xray-режима («Use xray-core when possible»): суффикс `X` у имени
/// продукта. В xray нет Naive, поэтому панель по `^AxiOmX` отдаёт base64-ссылки.
String xrayUserAgent(String userAgent) => userAgent.startsWith("$kUserAgentProduct/")
    ? userAgent.replaceFirst("$kUserAgentProduct/", "${kUserAgentProduct}X/")
    : userAgent;

@freezed
class AppInfoEntity with _$AppInfoEntity {
  const AppInfoEntity._();

  const factory AppInfoEntity({
    required String name,
    required String version,
    required String buildNumber,
    required Release release,
    required String operatingSystem,
    required String operatingSystemVersion,
    required Environment environment,
  }) = _AppInfoEntity;

  // Хвост `like ClashMeta v2ray sing-box` оставлен: по нему формат определяют
  // чужие панели, куда пользователь может вставить ссылку.
  String get userAgent => "$kUserAgentProduct/$version ($operatingSystem) like ClashMeta v2ray sing-box";

  String get presentVersion => environment == Environment.prod ? version : "$version ${environment.name}";

  /// formats app info for sharing
  String format() =>
      '''
$name v$version ($buildNumber) [${environment.name}]
${release.name} release
$operatingSystem [$operatingSystemVersion]''';
}
