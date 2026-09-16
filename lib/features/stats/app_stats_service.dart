import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:axiom/core/app_info/app_info_provider.dart';
import 'package:axiom/core/http_client/http_client_provider.dart';
import 'package:axiom/core/model/constants.dart';
import 'package:axiom/core/model/windows_admin.dart';
import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/core/preferences/preferences_provider.dart';
import 'package:axiom/features/proxy/data/proxy_data_providers.dart';
import 'package:axiom/features/settings/data/config_option_repository.dart';
import 'package:axiom/features/stats/stats_error_type.dart';
import 'package:axiom/singbox/model/singbox_config_enum.dart';
import 'package:axiom/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Анонимная статистика AxiOm.
///
/// Зачем: сервер видит, что он жив, но не видит, что у абонентов какого-то
/// провайдера не подключается протокол. Приложение сообщает исход попыток
/// подключения и падения; сводка — команда `/appstats` в боте.
///
/// Что уходит: версия приложения, платформа и версия ОС, протокол и режим,
/// успех или тип ошибки, время до подключения, тип падения, провайдер
/// (автономная система по адресу, на Android в мобильной сети — оператор с
/// SIM) и случайный номер установки. Номер не связан ни с аккаунтом, ни с
/// подпиской и стирается вместе с очередью, когда статистику выключают.
///
/// Чего не уходит: IP (сервер определяет по нему провайдера и не хранит),
/// ссылки подписок, Telegram ID, текст ошибок — только их тип.
///
/// Провайдера спрашиваем, пока VPN выключен: через туннель сервер увидел бы
/// адрес нашего же узла. Поэтому запрос уходит в момент нажатия «подключить»,
/// до старта ядра, и после каждого отключения.
final appStatsProvider = Provider<AppStatsService>((ref) {
  final service = AppStatsService(ref);
  ref.listen<bool>(Preferences.anonymousStats, (_, enabled) {
    if (!enabled) unawaited(service.optOut());
  });
  ref.onDispose(service.dispose);
  service.start();
  return service;
});

/// Падения ловит bootstrap раньше, чем поднимется Riverpod: пишем через
/// статическую точку, которую сервис подключает при старте.
abstract final class AppStatsCrashSink {
  static void Function(Object error)? _record;

  static void record(Object error) {
    try {
      _record?.call(error);
    } catch (_) {}
  }
}

class AppStatsService {
  AppStatsService(this._ref);

  final Ref _ref;
  final _log = Loggy('stats');

  static const _queueKey = 'stats_queue';
  static const _installKey = 'stats_install_id';
  static const _maxQueue = 200;
  static const _batch = 100;
  static const _channel = MethodChannel('app.axiom/platform');

  Timer? _timer;
  bool _flushing = false;

  // Провайдер по последнему запросу при выключенном VPN
  Map<String, Object?>? _net;
  DateTime? _netAt;

  // Текущая попытка подключения. Дольше двух минут — уже не «время до
  // подключения»: так выглядит VPN, поднятый системой без нажатия.
  static const _attemptTtl = Duration(minutes: 2);
  Stopwatch? _attempt;
  Map<String, Object?> _attemptNet = const {};

  // Одинаковые падения в кадре сыплются десятками — пишем одно в минуту
  final _lastCrash = <String, DateTime>{};

  bool get _enabled => _ref.read(Preferences.anonymousStats);

  void start() {
    AppStatsCrashSink._record = recordCrash;
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => unawaited(flush()));
    Future<void>.delayed(const Duration(seconds: 30), flush);
  }

  void dispose() {
    _timer?.cancel();
    if (AppStatsCrashSink._record == recordCrash) AppStatsCrashSink._record = null;
  }

  // ── Подключение ──────────────────────────────────────────────────────────

  /// Нажали «подключить» (или сработал автозапуск). VPN ещё не поднят.
  void connectStarted() {
    if (!_enabled) return;
    _attempt = Stopwatch()..start();
    // Провайдер из последнего запроса при выключенном VPN; свежий догонит,
    // если успеет до конца попытки.
    _attemptNet = {...?_net};
    unawaited(_captureNetwork());
  }

  /// Подключились. Время фиксируем сразу, протокол ядро отдаёт чуть позже.
  ///
  /// Статус «подключено» бывает и без нажатия: Телемост, смена профиля,
  /// VPN, поднятый системой. Такие не считаем — попытки у них нет.
  Future<void> connectSucceeded(Future<String?> Function() protocol) async {
    final sw = _attempt;
    if (sw == null) return;
    _attempt = null;
    final ms = sw.elapsedMilliseconds;
    if (sw.elapsed > _attemptTtl) return;
    final net = _attemptNet;
    String? proto;
    try {
      proto = await protocol().timeout(const Duration(seconds: 15));
    } catch (_) {}
    _add({'type': 'connect', 'ok': true, 'ms': ms, 'protocol': proto, 'mode': _mode(), ...net});
  }

  /// [error] — тип ошибки (имя класса), не текст: в тексте бывают адреса.
  void connectFailed(Object error) {
    final sw = _attempt;
    if (sw == null) return;
    _attempt = null;
    if (sw.elapsed > _attemptTtl) return;
    _add({'type': 'connect', 'ok': false, 'error': statsErrorType(error), 'mode': _mode(), ..._attemptNet});
  }

  /// VPN отключился — самое время обновить провайдера: сеть могла смениться.
  void disconnected() {
    if (!_enabled) return;
    unawaited(_refreshNet());
  }

  /// Протокол сервера, через который реально идёт трафик. Выбранный в
  /// списке элемент часто сам группа («авто» выбирает сервер по пингу),
  /// поэтому идём по цепочке выбора до настоящего сервера. Никогда не
  /// бросает: сбой здесь — просто «протокол неизвестен».
  Future<String?> activeProtocol() async {
    try {
      // Ядро отдаёт список серверов не сразу после статуса «подключено»
      await Future<void>.delayed(const Duration(seconds: 2));
      final group = await _ref
          .read(proxyRepositoryProvider)
          .watchProxies()
          .map((e) => e.getOrElse((_) => null))
          .firstWhere((g) => g != null && g.items.isNotEmpty)
          .timeout(const Duration(seconds: 10));
      var tag = group!.selected;
      for (var hop = 0; hop < 4; hop++) {
        final item = group.items.where((i) => i.tag == tag).firstOrNull;
        if (item == null) return null;
        if (!item.isGroup) return item.type;
        tag = item.groupSelectedTag;
      }
    } catch (e) {
      _log.debug('active protocol lookup failed: $e');
    }
    return null;
  }

  void recordCrash(Object error) {
    if (!_enabled) return;
    final type = statsErrorType(error);
    final now = DateTime.now();
    final last = _lastCrash[type];
    if (last != null && now.difference(last) < const Duration(minutes: 1)) return;
    _lastCrash[type] = now;
    _add({'type': 'crash', 'error': type});
  }

  // ── Провайдер ────────────────────────────────────────────────────────────

  Future<void> _captureNetwork() async {
    final nativeFuture = _nativeNetwork();
    await _refreshNet();
    final native = await nativeFuture ?? const <String, Object?>{};
    if (_attempt == null) return; // попытка уже закончилась
    _attemptNet = {...?_net, ...native};
  }

  Future<Map<String, Object?>?> _refreshNet() async {
    final fresh = _netAt != null && DateTime.now().difference(_netAt!) < const Duration(minutes: 10);
    if (fresh) return _net;
    try {
      final res = await _ref
          .read(httpClientProvider)
          .get<dynamic>('${Constants.accountApiBaseUrl}/api/app/stats/net')
          .timeout(const Duration(seconds: 4));
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (data is Map && data['via_vpn'] != true) {
        _net = {
          if (data['asn'] is num) 'asn': (data['asn'] as num).toInt(),
          if (data['provider'] is String) 'provider': data['provider'],
        };
        _netAt = DateTime.now();
      }
    } catch (e) {
      _log.debug('network provider lookup failed: $e');
    }
    return _net;
  }

  /// Android: оператор SIM и тип сети. На остальных платформах — пусто.
  Future<Map<String, Object?>?> _nativeNetwork() async {
    if (!PlatformUtils.isAndroid) return null;
    try {
      final res = await _channel
          .invokeMapMethod<String, Object?>('get_network_info')
          .timeout(const Duration(seconds: 2));
      if (res == null) return null;
      final netType = res['net_type'];
      final carrier = res['carrier'];
      return {
        if (netType is String) 'net_type': netType,
        // Оператор с SIM интересен, только когда через него и идёт трафик
        if (netType == 'cellular' && carrier is String && carrier.isNotEmpty) 'carrier': carrier,
      };
    } catch (e) {
      _log.debug('native network info failed: $e');
      return null;
    }
  }

  // ── Очередь и отправка ───────────────────────────────────────────────────

  void _add(Map<String, Object?> event) {
    if (!_enabled) return;
    try {
      final prefs = _ref.read(sharedPreferencesProvider).requireValue;
      final queue = _readQueue();
      event.removeWhere((_, v) => v == null);
      queue.add({'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000, ...event});
      if (queue.length > _maxQueue) queue.removeRange(0, queue.length - _maxQueue);
      unawaited(prefs.setString(_queueKey, jsonEncode(queue)));
      if (queue.length >= 20) unawaited(flush());
    } catch (e) {
      _log.debug('failed to queue stats event: $e');
    }
  }

  List<Map<String, Object?>> _readQueue() {
    try {
      final raw = _ref.read(sharedPreferencesProvider).requireValue.getString(_queueKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).whereType<Map>().map((e) => Map<String, Object?>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> flush() async {
    if (!_enabled || _flushing) return;
    _flushing = true;
    try {
      final prefs = _ref.read(sharedPreferencesProvider).requireValue;
      final queue = _readQueue();
      if (queue.isEmpty) return;
      final batch = queue.take(_batch).toList();
      final info = await _ref.read(appInfoProvider.future);
      await _ref.read(httpClientProvider).post(
        '${Constants.accountApiBaseUrl}/api/app/stats',
        data: jsonEncode({
          'install_id': _installId(prefs),
          'app_version': info.version,
          'platform': info.operatingSystem,
          'os_version': info.operatingSystemVersion,
          'events': batch,
        }),
        extraHeaders: {'Content-Type': 'application/json'},
      );
      // Пока шла отправка, в очередь могли добавить новые события
      final rest = _readQueue();
      rest.removeRange(0, batch.length.clamp(0, rest.length));
      await prefs.setString(_queueKey, jsonEncode(rest));
    } catch (e) {
      _log.debug('stats flush failed, will retry: $e');
    } finally {
      _flushing = false;
    }
  }

  /// Статистику выключили: очередь и номер установки стираем, чтобы при
  /// повторном включении установка выглядела новой, а не той же самой.
  Future<void> optOut() async {
    _attempt = null;
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    await prefs.remove(_queueKey);
    await prefs.remove(_installKey);
  }

  String _installId(SharedPreferences prefs) {
    final existing = prefs.getString(_installKey);
    if (existing != null && existing.length >= 16) return existing;
    final id = const Uuid().v4();
    unawaited(prefs.setString(_installKey, id));
    return id;
  }

  String _mode() {
    final selected = _ref.read(ConfigOptions.serviceMode);
    // Без прав администратора на Windows TUN подменяется системным прокси —
    // считаем то, чем реально подключались (см. ConfigOptions.singboxConfigOptions).
    final mode = WindowsAdmin.restricted && selected == ServiceMode.tun ? ServiceMode.systemProxy : selected;
    return mode.key;
  }
}
