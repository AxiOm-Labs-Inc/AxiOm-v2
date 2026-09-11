import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/core/preferences/preferences_provider.dart';
import 'package:axiom/features/connection/data/connection_data_providers.dart';
import 'package:axiom/features/connection/model/connection_status.dart';
import 'package:axiom/features/connection/model/core_owner.dart';
import 'package:axiom/features/profile/data/profile_data_providers.dart';
import 'package:axiom/features/settings/data/battery_optimization_repository.dart';
import 'package:axiom/features/settings/data/config_option_repository.dart';
import 'package:axiom/features/wbstream_tunnel/data/telemost_credentials_service.dart';
import 'package:axiom/features/wbstream_tunnel/data/wbstream_relay_service.dart';
import 'package:axiom/features/wbstream_tunnel/model/wbstream_settings.dart';
import 'package:axiom/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final wbstreamTunnelNotifierProvider =
    StateNotifierProvider<WbstreamTunnelNotifier, WbstreamTunnelState>(
  (ref) => WbstreamTunnelNotifier(ref),
);

// v2: the v1 key persisted the built-in room id into SharedPreferences on
// early installs; bumping the key drops that saved value (the new default is
// an empty field — the native relay resolves everything).
const _settingsKey = 'wbstream_settings_v2';

/// How long to wait for STATUS:TUNNEL_CONNECTED after starting the relay.
/// The WB Stream room is held open by the keeper/creator permanently, so
/// there is no spawn window to cover — 90s is ample.
const _connectTimeout = Duration(seconds: 90);

/// Timeout of a single probe attempt (watchdog full-path probe).
const _probeAttemptTimeout = Duration(seconds: 5);

/// Watchdog full-path probe target. MUST be a host that is unreachable
/// directly under whitelists: a probe through the core has to prove the
/// core → WG → relay → internet chain, and a whitelisted host could be
/// routed direct by the core, passing the probe while WG is dead.
const _watchdogProbeHost = 'www.gstatic.com';
const _watchdogProbePath = '/generate_204';

/// Watchdog: while connected, the tunnel is probed every [_watchdogInterval];
/// two consecutive failures trigger a relay restart. Catches the uplink-only
/// uplink slot kill, which the native relay does not reliably notice (its
/// downlink keeps receiving keepalives, so the tunnel looks alive).
const _watchdogInterval = Duration(seconds: 12);

/// Drives the WB Stream tunnel mode: starts/stops the librelay process via
/// [WbstreamRelayService] and maps its status lines onto the state machine.
/// Plain StateNotifier (no codegen) on purpose.
///
/// The connect path is a single shot: the static WB Stream room is held
/// open server-side (keeper + Go creator on NL), so activation is just
/// start relay → wait for the tunnel → verify real data flow with a SOCKS5
/// probe. No accounts, no on-demand room creation, no manager API.
class WbstreamTunnelNotifier extends StateNotifier<WbstreamTunnelState> with AppLogger {
  WbstreamTunnelNotifier(this._ref) : super(const WbstreamIdle()) {
    _loadSettings();
  }

  final Ref _ref;

  WbstreamSettings _settings = const WbstreamSettings();
  WbstreamSettings get settings => _settings;

  StreamSubscription<WbstreamStatusEvent>? _statusSub;

  /// In-flight [activate] call (returned to concurrent callers).
  Completer<bool>? _connectCompleter;

  /// Completed by [_onStatus] for the current relay start attempt.
  Completer<bool>? _attemptCompleter;
  WbstreamSocks? _socks;

  /// Секрет Телемоста этой сессии подключения. Пусто — идём без авторизации:
  /// пока держатели не в strict, это рабочий путь, а в strict такой клиент
  /// получит предсказуемый отказ.
  String? _tmSecret;

  /// Причина последнего отказа держателя (`auth_denied:<reason>`) и признак
  /// того, что секрет за эту активацию уже обновляли — иначе `unknown_uid`
  /// зациклил бы перезапуск relay на запросах к RU.
  String? _lastDenyReason;
  bool _credentialsRefreshed = false;

  /// Готовый фрагмент конфига sing-box, присланный relay событием `config`.
  /// Комнату находит нативная часть, приложение её не знает — только пишет
  /// этот конфиг в файл и передаёт ядру.
  String? _coreConfig;

  /// True once the data-flow probe has passed for the running relay. Gates
  /// status handling: only a verified tunnel may show WbstreamConnected/
  /// WbstreamLost, so the SFU reconnect cycle neither flashes «connected»
  /// before the probe nor «lost» while the probe is running.
  bool _tunnelVerified = false;

  /// Periodic tunnel probe while connected (see [_watchdogInterval]).
  Timer? _watchdogTimer;
  int _watchdogFailures = 0;
  bool _restartingTunnel = false;

  /// Last watchdog-triggered relay restart. Restart storms made things worse
  /// than the disease (a restart mid native recovery spawns competing
  /// participants), so restarts are at most one per 60s and only after 3
  /// consecutive silent probes (~36s of dead tunnel).
  DateTime? _lastWatchdogRestart;

  /// Escalation state for the watchdog: a silent full-path probe first costs
  /// the core a restart (cheap, fixes a dead WG layer); only continued
  /// silence after that justifies the heavy relay restart.
  bool _coreRestartTried = false;

  /// Статус ядра — чтобы заметить его остановку снаружи (кнопка в
  /// уведомлении) и выключить Телемост целиком, см. [_onCoreStatus].
  StreamSubscription<ConnectionStatus>? _coreStatusSub;
  bool _coreSeenConnected = false;

  /// Ядро останавливаем мы сами (stopCore/_forceStopCore) — это не внешняя
  /// остановка.
  bool _stoppingCore = false;

  /// Room the relay is currently bound to. The WG identity is derived from it,
  /// so the core config must be rebuilt whenever the room changes.

  WbstreamRelayService get _service => _ref.read(wbstreamRelayServiceProvider);

  // ── Settings ───────────────────────────────────────────────────────────

  void _loadSettings() {
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    final raw = prefs.getString(_settingsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      _settings = WbstreamSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      loggy.warning('failed to read wbstream settings: $e');
    }
  }

  Future<void> saveSettings(WbstreamSettings settings) async {
    _settings = settings;
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  // ── Public API ─────────────────────────────────────────────────────────

  /// Starts the relay and waits until the tunnel is connected (or fails).
  /// The room is static and server-held — a single start attempt is the
  /// whole path.
  Future<bool> activate() {
    if (state is WbstreamConnected) return Future.value(true);
    final inFlight = _connectCompleter;
    if (inFlight != null && !inFlight.isCompleted) return inFlight.future;
    final completer = Completer<bool>();
    _connectCompleter = completer;
    _runActivate().then((ok) {
      if (!completer.isCompleted) completer.complete(ok);
    });
    return completer.future;
  }

  Future<bool> _runActivate() async {
    _statusSub ??= _service.watchStatus().listen(_onStatus);
    _coreStatusSub ??= _ref.read(connectionRepositoryProvider).watchConnectionStatus().listen(_onCoreStatus);
    unawaited(_maybeRequestBatteryExemption());

    state = const WbstreamStarting();
    _credentialsRefreshed = false;
    // Секрет берётся один раз за активацию: держателю он не отдаётся, из него
    // считается одноразовое доказательство. Дальше комнату находит relay сам.
    _tmSecret = await _ref.read(telemostCredentialsServiceProvider).secret();

    _lastDenyReason = null;
    if (await _attemptConnect()) return true;
    await _service.stop();

    // Держатель не опознал секрет (на сервере подняли поколение) — обновляем
    // и перезапускаем relay один раз.
    if (_lastDenyReason == 'unknown_uid' && !_credentialsRefreshed) {
      _credentialsRefreshed = true;
      _tmSecret = await _ref
          .read(telemostCredentialsServiceProvider)
          .secret(forceRefresh: true);
      _lastDenyReason = null;
      if (await _attemptConnect()) return true;
      await _service.stop();
    }
    // Отказ по существу — показать причину; иначе общая ошибка.
    if (_isTerminalDeny(_lastDenyReason)) {
      state = WbstreamError(_denyMessage(_lastDenyReason!));
    } else if (state is! WbstreamError) {
      state = const WbstreamError('Не удалось подключиться к конференции');
    }
    return false;
  }

  /// Asks once per install for the battery-optimization exemption. Without
  /// it Doze/vendor power managers suspend the relay a few minutes after
  /// screen-off (the tunnel holds a wake lock, but the exemption is what
  /// keeps network access in deep sleep).
  Future<void> _maybeRequestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    const askedKey = 'wbstream_batt_opt_asked';
    try {
      final prefs = _ref.read(sharedPreferencesProvider).requireValue;
      if (prefs.getBool(askedKey) ?? false) return;
      final repo = BatteryOptimizationRepositoryImpl();
      if (await repo.isIgnoringBatteryOptimizations() ?? false) return;
      await prefs.setBool(askedKey, true);
      await repo.requestIgnoreBatteryOptimizations();
    } catch (e) {
      loggy.warning('wbstream: battery exemption request failed: $e');
    }
  }

  /// Запускает relay и ждёт STATUS:TUNNEL_CONNECTED. Комнату relay находит и
  /// пробит сам (нативная часть), поэтому 'connected' уже означает живой
  /// туннель — отдельной Dart-пробы здесь больше нет. Вместе с 'connected'
  /// приходит событие `config` с фрагментом для ядра; ждём и его.
  Future<bool> _attemptConnect() async {
    _tunnelVerified = false;
    _coreConfig = null;
    _attemptCompleter = Completer<bool>();
    try {
      _socks = await _service.start(_settings, tmSecret: _tmSecret);
    } catch (e) {
      loggy.warning('tunnel: start failed: $e');
      state = WbstreamError('Не удалось запустить relay: $e');
      return false;
    }
    final joined = await _attemptCompleter!.future.timeout(
      _connectTimeout,
      onTimeout: () {
        loggy.warning('tunnel: connect timeout (${_connectTimeout.inSeconds}s)');
        return false;
      },
    );
    if (!joined) return false;
    if (_coreConfig == null) {
      loggy.warning('tunnel: connected but no config received');
      return false;
    }
    final socks = _socks;
    _tunnelVerified = true;
    if (socks != null) state = WbstreamConnected(socks);
    _startWatchdog();
    return true;
  }

  // ── Tunnel watchdog ────────────────────────────────────────────────────

  void _startWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogFailures = 0;
    _coreRestartTried = false;
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) => _watchdogTick());
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _watchdogFailures = 0;
  }

  Future<void> _watchdogTick() async {
    if (_restartingTunnel) return;
    // Not WbstreamConnected means a reconnect cycle is already in flight
    // (native reconnect or a manual retry) — do not interfere.
    if (state is! WbstreamConnected) return;
    final socks = _socks;
    if (socks == null) return;
    // Туннель без своего ядра — Телемост фактически выключен (ядро не
    // стартовало или его остановили). Автоподъём ядра убран: он не давал
    // выключить Телемост кнопкой в уведомлении.
    if (_ref.read(coreOwnerProvider) != CoreOwner.wbstream) {
      loggy.info('wbstream: core is not running — turning Telemost off');
      unawaited(deactivate());
      return;
    }
    // Probe the path user traffic actually takes: through the core's mixed
    // inbound (core → WG → relay → internet) to a host that cannot be
    // reached directly under whitelists — a whitelisted target could be
    // routed direct by the core and pass while WG is dead.
    final ok = await _probeOnce(
      WbstreamSocks(host: '127.0.0.1', port: _ref.read(ConfigOptions.mixedPort), user: '', pass: ''),
      host: _watchdogProbeHost,
      path: _watchdogProbePath,
    );
    if (ok) {
      _watchdogFailures = 0;
      _coreRestartTried = false;
      return;
    }
    _watchdogFailures++;
    loggy.warning('wbstream: watchdog probe failed ($_watchdogFailures/3)');
    if (_watchdogFailures < 3) return;
    _watchdogFailures = 0;
    if (!_coreRestartTried) {
      _coreRestartTried = true;
      unawaited(_restartCore());
    } else {
      unawaited(_restartRelay());
    }
  }

  /// Cheap watchdog remedy: bounce the sing-box core so the WG outbound
  /// re-handshakes through the (alive) tunnel. Fixes the «relay alive, WG
  /// dead» state without touching the conference.
  Future<void> _restartCore() async {
    if (_restartingTunnel) return;
    _restartingTunnel = true;
    try {
      loggy.warning('wbstream: watchdog restarting core (full-path probe silent)');
      await stopCore();
      // The core stop is not instantaneous; starting on top of a still-
      // dying session fails and leaves «relay alive, core dead» for good.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!await startCore()) {
        loggy.warning('wbstream: core restart failed');
      }
    } finally {
      _restartingTunnel = false;
    }
  }

  /// Restarts the relay on the same room and repoints the core at the new
  /// local SOCKS endpoint (the native side picks a fresh random port on
  /// every start, so the sing-box config must be rewritten). Used by the
  /// watchdog when the tunnel goes silent without the native joiner
  /// noticing.
  Future<void> _restartRelay() async {
    if (_restartingTunnel) return;
    final last = _lastWatchdogRestart;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      loggy.info('wbstream: watchdog restart skipped (cooldown)');
      return;
    }
    _restartingTunnel = true;
    _watchdogFailures = 0;
    _lastWatchdogRestart = DateTime.now();
    try {
      loggy.warning('tunnel: watchdog restarting relay (tunnel silent)');
      await _service.stop();
      // Relay сам заново обойдёт комнаты: молчание могло значить, что наша
      // комната закрыта, и тогда поможет только другая.
      final ok = await _attemptConnect();
      if (!ok) {
        loggy.warning('wbstream: watchdog restart failed');
        await _service.stop();
        state = const WbstreamLost();
        return;
      }
      if (_ref.read(coreOwnerProvider) == CoreOwner.wbstream) {
        await stopCore();
        // Let the old core fully die before starting on the new endpoint
        // (same race as in _restartCore).
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!await startCore()) {
          loggy.warning('wbstream: core restart after relay restart failed');
          state = const WbstreamLost();
        }
      }
    } finally {
      _restartingTunnel = false;
    }
  }

  /// One SOCKS5 round-trip: handshake (user/pass auth when the server picks
  /// it), CONNECT to [host]:80, then a HEAD request — any response
  /// bytes prove the tunnel actually carries data. Raw dart:io Socket, no
  /// proxy-adapter dependency.
  Future<bool> _probeOnce(WbstreamSocks socks, {required String host, String path = '/'}) async {
    Socket? socket;
    _ByteReader? reader;
    try {
      socket = await Socket.connect(socks.host, socks.port, timeout: _probeAttemptTimeout);
      reader = _ByteReader(socket);
      Future<List<int>> read(int n) => reader!.read(n, _probeAttemptTimeout);

      // Greeting: offer no-auth and user/pass, let the server pick.
      socket.add([0x05, 0x02, 0x00, 0x02]);
      final method = await read(2);
      if (method[0] != 0x05) return false;
      if (method[1] == 0x02) {
        final user = utf8.encode(socks.user);
        final pass = utf8.encode(socks.pass);
        if (user.length > 255 || pass.length > 255) return false;
        socket.add([0x01, user.length, ...user, pass.length, ...pass]);
        final auth = await read(2);
        if (auth[1] != 0x00) return false;
      } else if (method[1] != 0x00) {
        return false;
      }

      // CONNECT host:80 (domain form, ATYP=0x03).
      final hostBytes = utf8.encode(host);
      socket.add([0x05, 0x01, 0x00, 0x03, hostBytes.length, ...hostBytes, 0x00, 0x50]);
      final reply = await read(4);
      if (reply[0] != 0x05 || reply[1] != 0x00) return false;
      // Consume the bound address (length depends on ATYP).
      switch (reply[3]) {
        case 0x01:
          await read(4 + 2);
        case 0x03:
          final len = (await read(1))[0];
          await read(len + 2);
        case 0x04:
          await read(16 + 2);
        default:
          return false;
      }

      // Any HTTP response (even a redirect) proves bidirectional flow.
      socket.add(utf8.encode('HEAD $path HTTP/1.0\r\nHost: $host\r\n\r\n'));
      await read(1);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
      unawaited(reader?.cancel());
    }
  }

  /// Used by the connection path: guarantees the tunnel is up before the
  /// sing-box core is pointed at the relay's local SOCKS5.
  Future<bool> ensureConnected() => activate();

  // ── Core (sing-box) control ────────────────────────────────────────────

  /// Starts the sing-box core on the WBStream config (WG over the relay's
  /// local SOCKS5). Requires a verified tunnel ([WbstreamConnected]). The
  /// core is marked wbstream-owned so the main-VPN UI keeps showing «off»
  /// and a later VPN connect knows whom to tear down.
  Future<bool> startCore() async {
    final current = state;
    if (current is! WbstreamConnected) return false;
    if (await _tryStartCore(current)) return true;
    // One retry after a full stop + settle: a half-dead previous session is
    // the common reason a start fails mid-tunnel.
    loggy.info('wbstream: core start failed, retrying after stop+settle');
    await _forceStopCore();
    await Future<void>.delayed(const Duration(seconds: 2));
    return _tryStartCore(current);
  }

  /// Unconditional core stop (stopCore no-ops when the owner tag was already
  /// reset by a failed start, leaving a wedged session behind).
  Future<void> _forceStopCore() async {
    _stoppingCore = true;
    try {
      await _ref.read(connectionRepositoryProvider).disconnect().mapLeft((failure) {
        loggy.warning('wbstream: core stop failed: $failure');
      }).run();
    } finally {
      _stoppingCore = false;
    }
    _ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
  }

  /// Имя сессии ядра в системном уведомлении. Профиль в списке не создаётся —
  /// туннель отдельный сервис, не подписка.
  static const _profileName = 'AxiOm Telemost';

  /// Пишет присланный relay фрагмент конфига в отдельный файл (в обход стора
  /// профилей) и возвращает его.
  Future<File?> _writeCoreConfig(String content) async {
    try {
      final file = _ref.read(profilePathResolverProvider).file('wbstream');
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
      return file;
    } catch (e) {
      loggy.warning('tunnel: failed to write core config: $e');
      return null;
    }
  }

  Future<bool> _tryStartCore(WbstreamConnected current) async {
    final cfg = _coreConfig;
    if (cfg == null || cfg.isEmpty) {
      loggy.warning('tunnel: no config from relay, cannot start the core');
      return false;
    }
    final file = await _writeCoreConfig(cfg);
    if (file == null) return false;
    _coreSeenConnected = false;
    _ref.read(coreOwnerProvider.notifier).state = CoreOwner.wbstream;
    final result = await _ref
        .read(connectionRepositoryProvider)
        .connectConfig(file.path, _profileName, _ref.read(Preferences.disableMemoryLimit))
        .run();
    return result.match(
      (failure) {
        loggy.warning('wbstream: core start failed: $failure');
        _ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
        return false;
      },
      (_) => true,
    );
  }

  /// Stops the core when it is wbstream-owned. A VPN-owned session is never
  /// touched.
  Future<void> stopCore() async {
    if (_ref.read(coreOwnerProvider) != CoreOwner.wbstream) return;
    _stoppingCore = true;
    try {
      await _ref.read(connectionRepositoryProvider).disconnect().mapLeft((failure) {
        loggy.warning('wbstream: core stop failed: $failure');
      }).run();
    } finally {
      _stoppingCore = false;
    }
    _ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
  }

  Future<void> deactivate() async {
    _stopWatchdog();
    await stopCore();
    await _coreStatusSub?.cancel();
    _coreStatusSub = null;
    await _statusSub?.cancel();
    _statusSub = null;
    _socks = null;
    _tunnelVerified = false;
    await _service.stop();
    if (state is! WbstreamIdle) state = const WbstreamIdle();
  }

  /// Leaves [WbstreamError]/[WbstreamLost] back to idle so the user can retry.
  void resetError() {
    if (state is WbstreamError || state is WbstreamLost) {
      state = const WbstreamIdle();
    }
  }

  // ── Авторизация Телемоста ──────────────────────────────────────────────

  /// Отказ, который повторится в любой комнате: дело в самом аккаунте.
  static bool _isTerminalDeny(String? reason) =>
      reason == 'no_telemost' || reason == 'no_subscription' || reason == 'no_account';

  static String _denyMessage(String reason) {
    switch (reason) {
      case 'no_subscription':
        return 'Подписка неактивна — Телемост недоступен';
      case 'no_telemost':
        return 'В вашем тарифе нет Телемоста';
      case 'no_account':
        return 'Подключите Telegram-аккаунт, чтобы пользоваться Телемостом';
      default:
        return 'Не удалось подтвердить доступ к Телемосту';
    }
  }

  // ── Status handling ────────────────────────────────────────────────────

  void _completeAttempt(bool value) {
    final completer = _attemptCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(value);
  }

  /// Ядро Телемоста остановили снаружи — кнопкой в уведомлении или системой.
  /// Раньше watchdog поднимал его обратно, и выключить Телемост из
  /// уведомления было нельзя. Теперь такая остановка выключает Телемост
  /// целиком (relay тоже). Свои остановки (stopCore, перезапуск watchdog)
  /// отсекаются флагами.
  void _onCoreStatus(ConnectionStatus status) {
    if (_ref.read(coreOwnerProvider) != CoreOwner.wbstream) return;
    if (status is Connected) {
      _coreSeenConnected = true;
      return;
    }
    if (status is! Disconnected || !_coreSeenConnected) return;
    if (_stoppingCore || _restartingTunnel) return;
    loggy.info('wbstream: core stopped outside the app — turning Telemost off');
    _coreSeenConnected = false;
    _ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
    unawaited(deactivate());
  }

  void _onStatus(WbstreamStatusEvent event) {
    // Тело config не логируем: в нём приватный WG-ключ и пароль SOCKS relay.
    final message = event.status == 'config' ? '(${event.message?.length ?? 0} bytes)' : event.message ?? '';
    loggy.info('wbstream status: ${event.status} $message');
    switch (event.status) {
      case 'starting':
        if (state is! WbstreamConnected) state = const WbstreamStarting();
      case 'connecting':
        if (state is! WbstreamConnected) state = const WbstreamConnecting();
      case 'config':
        // Relay нашёл комнату и прислал готовый фрагмент конфига ядра. Комнату
        // приложение не знает — только пишет этот конфиг в файл.
        _coreConfig = event.message;
      case 'connected':
        // Relay сообщает "connected", уже проверив поток данных сам. Первый
        // сигнал попытки разблокирует _attemptConnect, который и ставит
        // WbstreamConnected. Every later signal (the SFU reconnect cycle emits
        // connected → lost → connecting → connected) restores
        // WbstreamConnected — but only for a probe-verified tunnel, and
        // from ANY state: after 'lost' the state is WbstreamConnecting by
        // the time 'connected' arrives, so a state-based guard would stick
        // in the Connecting/Lost loop forever.
        final completer = _attemptCompleter;
        if (completer != null && !completer.isCompleted) {
          _completeAttempt(true);
        } else if (_tunnelVerified) {
          // Native self-recovery from the reconnect cycle: the tunnel is
          // alive again, so any watchdog failures counted during the outage
          // are stale.
          _watchdogFailures = 0;
          final socks = _socks;
          if (socks != null) state = WbstreamConnected(socks);
        }
      case 'lost':
        // Mid-probe the reconnect cycle must not flash «lost» — the tunnel
        // swap kills the probe attempt and the retry rides the new tunnel.
        // On a verified tunnel 'lost' is reported as before.
        if (_tunnelVerified) state = const WbstreamLost();
        _completeAttempt(false);
      case 'error':
        final message = event.message ?? '';
        if (message.startsWith('auth_denied:')) {
          // Отказ авторизации — не поломка relay. Что делать дальше, решает
          // обход кандидатов: в большинстве причин лечение — следующая комната.
          _lastDenyReason = message.substring('auth_denied:'.length);
          loggy.info('wbstream: держатель отказал: $_lastDenyReason');
          _completeAttempt(false);
          return;
        }
        state = WbstreamError(message.isEmpty ? 'неизвестная ошибка relay' : message);
        _completeAttempt(false);
      case 'stopped':
        if (state is WbstreamStarting || state is WbstreamConnecting) {
          state = const WbstreamIdle();
        }
    }
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
    unawaited(_coreStatusSub?.cancel());
    unawaited(_statusSub?.cancel());
    unawaited(_service.stop());
    super.dispose();
  }
}

/// Minimal buffered reader over a byte stream (the probe's Socket): waits
/// until exactly N bytes have arrived or [timeout] elapses. Saves pulling
/// in package:async just for StreamQueue.
class _ByteReader {
  _ByteReader(Stream<List<int>> stream) {
    _sub = stream.listen(
      (chunk) {
        _buf.addAll(chunk);
        _pump();
      },
      onError: (Object e) {
        _error = e;
        _pump();
      },
      onDone: () {
        _closed = true;
        _pump();
      },
    );
  }

  late final StreamSubscription<List<int>> _sub;
  final List<int> _buf = [];
  final List<void Function()> _waiters = [];
  Object? _error;
  bool _closed = false;

  void _pump() {
    final waiters = List<void Function()>.of(_waiters);
    _waiters.clear();
    for (final wake in waiters) {
      wake();
    }
  }

  Future<List<int>> read(int n, Duration timeout) async {
    final sw = Stopwatch()..start();
    while (_buf.length < n) {
      final error = _error;
      if (error != null) throw error;
      if (_closed) throw const SocketException('stream closed');
      final remaining = timeout - sw.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('read timeout', timeout);
      final signaled = Completer<void>();
      _waiters.add(signaled.complete);
      await signaled.future.timeout(remaining);
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  Future<void> cancel() => _sub.cancel();
}
