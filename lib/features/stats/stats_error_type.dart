import 'package:axiom/features/connection/model/connection_failure.dart';

/// Тип ошибки для анонимной статистики — имя, а не текст: в тексте ошибок
/// бывают адреса серверов и ссылки подписок.
String statsErrorType(Object error) {
  // Ошибки подключения — freezed-классы, их runtimeType выглядит как
  // _$MissingVpnPermissionImpl. Даём устойчивые имена явно.
  if (error is ConnectionFailure) {
    return switch (error) {
      UnexpectedConnectionFailure(:final error) =>
        error == null ? 'Unexpected' : 'Unexpected.${_typeName(error)}',
      MissingVpnPermission() => 'MissingVpnPermission',
      MissingNotificationPermission() => 'MissingNotificationPermission',
      MissingPrivilege() => 'MissingPrivilege',
      InvalidConfigOption() => 'InvalidConfigOption',
      InvalidConfig() => 'InvalidConfig',
      BackgroundCoreNotAvailable() => 'BackgroundCoreNotAvailable',
      MissingWarpLicense() => 'MissingWarpLicense',
    };
  }
  return _typeName(error);
}

String _typeName(Object error) {
  var name = error.runtimeType.toString().replaceAll(RegExp('<.*>'), '');
  if (name.startsWith('_\$') && name.endsWith('Impl')) name = name.substring(2, name.length - 4);
  return name.replaceAll(RegExp('[^A-Za-z0-9_]'), '');
}
