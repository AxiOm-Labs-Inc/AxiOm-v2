// Единые правила выбора сервера для приложения и CLI (DESIGN-sync v2, п. 6):
// - c = '__auto__' — авто, p/t игнорируются и публикуются как '';
// - пустой p — первый протокол страны в порядке приложения, пустой t — первый транспорт этой пары.

import 'package:hiddify/features/cli_sync/cli_sync_protocol.dart';
import 'package:hiddify/features/proxy/model/server_option.dart';

/// Каноническая полная тройка. Если список серверов неизвестен, пустые p/t остаются пустыми.
ServerSelection canonicalSelection(ServerSelection selection, List<ServerOption> options) {
  if (selection.isAuto) return ServerSelection.auto;
  var protocol = selection.p;
  if (protocol.isEmpty) {
    final protocols = ServerOption.protocolsFor(options, selection.c);
    if (protocols.isNotEmpty) protocol = protocols.first;
  }
  var transport = selection.t;
  if (transport.isEmpty && protocol.isNotEmpty) {
    final transports = ServerOption.transportsFor(options, selection.c, protocol);
    if (transports.isNotEmpty) transport = transports.first;
  }
  return ServerSelection(c: selection.c, p: protocol, t: transport);
}

/// Ошибка выбора, пришедшего от CLI, или null. Выбор уже канонический.
String? validateSelection(ServerSelection selection, List<ServerOption> options) {
  if (selection.isAuto) return null;
  if (options.isEmpty) {
    if (selection.p.isEmpty || selection.t.isEmpty) {
      return 'список серверов приложения пуст — укажите сервер полностью (СТРАНА|ПРОТОКОЛ|ТРАНСПОРТ)';
    }
    return null;
  }
  if (ServerOption.find(options, selection.c, selection.p, selection.t) == null) {
    return 'сервера «${selection.toSelectArg()}» нет в списке приложения';
  }
  return null;
}
