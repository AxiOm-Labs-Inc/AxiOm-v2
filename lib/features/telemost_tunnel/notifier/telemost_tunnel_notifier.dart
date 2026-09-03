import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/model/core_owner.dart';
import 'package:hiddify/features/settings/data/battery_optimization_repository.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/telemost_tunnel/data/disk_link_provider.dart';
import 'package:hiddify/features/telemost_tunnel/data/disk_mailbox_api.dart';
import 'package:hiddify/features/telemost_tunnel/data/telemost_config_service.dart';
import 'package:hiddify/features/telemost_tunnel/data/telemost_relay_service.dart';
import 'package:hiddify/features/telemost_tunnel/data/telemost_service_accounts.dart';
import 'package:hiddify/features/telemost_tunnel/data/wlb_manager_api.dart';
import 'package:hiddify/features/telemost_tunnel/data/yandex_auth_storage.dart';
import 'package:hiddify/features/telemost_tunnel/data/yandex_telemost_api.dart';
import 'package:hiddify/features/telemost_tunnel/model/telemost_settings.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';

final telemostTunnelNotifierProvider =
    StateNotifierProvider<TelemostTunnelNotifier, TelemostTunnelState>(
  (ref) => TelemostTunnelNotifier(ref),
);

const _settingsKey = 'telemost_settings';

/// SharedPreferences keys for the on-demand path.
const _accountIndexKey = 'telemost_service_account_index';
const _deviceIdKey = 'telemost_device_id';

/// How long to wait for STATUS:TUNNEL_CONNECTED per disk slot (A/B failover).
const _slotConnectTimeout = Duration(seconds: 90);

/// How long to wait for STATUS:TUNNEL_CONNECTED on the manual/legacy path.
const _connectTimeout = Duration(seconds: 180);

/// Total budget for the post-connect data-flow probe (SOCKS5 round-trip
/// through the tunnel). Covers the creator spawn window (~15-30s) on the
/// on-demand path; with an already-running creator the first attempt
/// succeeds, so disk slots pay no extra delay.
const _probeBudget = Duration(seconds: 45);

/// Timeout of a single probe attempt and pause between attempts.
const _probeAttemptTimeout = Duration(seconds: 5);
const _probeRetryDelay = Duration(seconds: 4);

/// Probe target: any HTTP response from it proves bidirectional data flow
/// through the tunnel. Plain HTTP on port 80 — a redirect is good enough.
const _probeHost = 'telemost.yandex.ru';

/// Watchdog full-path probe target. MUST be a host that is unreachable
/// directly under whitelists (unlike telemost.yandex.ru): a probe through
/// the core has to prove the core → WG → relay → internet chain, and a
/// whitelisted host could be routed direct by the core, passing the probe
/// while WG is dead.
const _watchdogProbeHost = 'www.gstatic.com';
const _watchdogProbePath = '/generate_204';

/// Watchdog: while connected, the tunnel is probed every [_watchdogInterval];
/// two consecutive failures trigger a relay restart. Catches the uplink-only
/// SFU slot kill, which the native joiner does not reliably notice (its
/// downlink keeps receiving keepalives, so the tunnel looks alive).
const _watchdogInterval = Duration(seconds: 12);

/// Drives the Telemost tunnel mode: starts/stops the librelay process via
/// [TelemostRelayService] and maps its status lines onto the state machine.
/// Plain StateNotifier (no codegen) on purpose.
///
/// Primary connect path: create a fresh conference on-demand via the
/// built-in service accounts → post the request to the Yandex.Disk mailbox
/// (best-effort) → best-effort creator spawn → start relay → wait for the
/// tunnel → verify real data flow with a SOCKS5 probe. Fallback:
/// server-side links from Yandex.Disk (slots A/B, last good first), then
/// the manual join link, then Yandex session auto-create.
class TelemostTunnelNotifier extends StateNotifier<TelemostTunnelState> with AppLogger {
  TelemostTunnelNotifier(this._ref) : super(const TelemostIdle()) {
    _loadSettings();
  }

  final Ref _ref;

  TelemostSettings _settings = const TelemostSettings();
  TelemostSettings get settings => _settings;

  StreamSubscription<TelemostStatusEvent>? _statusSub;

  /// In-flight [activate] call (returned to concurrent callers).
  Completer<bool>? _connectCompleter;

  /// Completed by [_onStatus] for the current relay start attempt.
  Completer<bool>? _attemptCompleter;
  TelemostSocks? _socks;

  /// Disk slot of the current attempt (null on the manual/legacy path).
  String? _currentSlot;

  /// The link the relay was last started with (for the manager stop call).
  String? _activeLink;

  /// True once the data-flow probe has passed for the running relay. Gates
  /// status handling: only a verified tunnel may show TelemostConnected/
  /// TelemostLost, so the SFU slot-kill reconnect cycle neither flashes
  /// «connected» before the probe nor «lost» while the probe is running.
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

  /// Consecutive failed attempts to bring the core up while the tunnel tab
  /// shows Connected (the «says it works, nothing loads» state).
  int _coreStartFailures = 0;

  TelemostRelayService get _service => _ref.read(telemostRelayServiceProvider);

  // ── Settings ───────────────────────────────────────────────────────────

  void _loadSettings() {
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    final raw = prefs.getString(_settingsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      _settings = TelemostSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      loggy.warning('failed to read telemost settings: $e');
    }
  }

  Future<void> saveSettings(TelemostSettings settings) async {
    _settings = settings;
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
  }

  // ── Yandex auth / conference creation (manual fallback) ───────────────

  Future<bool> hasYandexSession() => _ref.read(yandexAuthStorageProvider).hasSession();

  Future<String?> yandexLogin() => _ref.read(yandexAuthStorageProvider).readLogin();

  /// Drops the stored Yandex session (the WebView cookie jar is cleared by
  /// the UI side, it owns the CookieManager).
  Future<void> yandexLogout() => _ref.read(yandexAuthStorageProvider).clear();

  /// Creates a Telemost conference via the Yandex API and stores its link as
  /// the active joinLink. Throws [YandexSessionExpired] on a dead session
  /// and [StateError] when there is no session at all.
  ///
  /// Also asks the creator-manager to spawn the server side for the new
  /// link — best-effort: a manager failure never blocks the tunnel.
  Future<String> createConference() async {
    final cookieHeader = await _ref.read(yandexAuthStorageProvider).cookieHeader();
    if (cookieHeader == null) throw StateError('no yandex session');
    final uri = await _ref.read(yandexTelemostApiProvider).createConference(cookieHeader);
    await saveSettings(_settings.copyWith(joinLink: uri));
    unawaited(_spawnCreator(uri));
    return uri;
  }

  /// Best-effort spawn on the creator-manager. Errors are logged, never
  /// thrown — the creator is always-on (encode-on-demand), so the tunnel is
  /// tried even when the manager is unreachable.
  Future<void> _spawnCreator(String link) async {
    try {
      final user = await yandexLogin() ?? 'app';
      await _ref.read(wlbManagerApiProvider).spawn(link, user.isEmpty ? 'app' : user);
    } catch (e) {
      loggy.warning('wlb manager spawn failed (continuing anyway): $e');
    }
  }

  // ── On-demand conference creation (service accounts) ──────────────────

  /// Creates a fresh conference via the built-in service accounts, trying
  /// them round-robin (the next start index is persisted). Returns the join
  /// link on success, null when every account failed — never throws.
  Future<String?> createOnDemandConference() async {
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    final accounts = telemostServiceAccounts;
    final start = prefs.getInt(_accountIndexKey) ?? 0;
    for (var i = 0; i < accounts.length; i++) {
      final index = (start + i) % accounts.length;
      final account = accounts[index];
      try {
        final uri = await _ref.read(yandexTelemostApiProvider).createConference(account.cookieHeader);
        await prefs.setInt(_accountIndexKey, (index + 1) % accounts.length);
        loggy.info('telemost: on-demand conference created via ${account.login}');
        return uri;
      } catch (e) {
        loggy.warning('telemost: create conference via ${account.login} failed: $e');
      }
    }
    return null;
  }

  /// Stable per-install id used as the mailbox file name. Generated once
  /// and persisted in SharedPreferences.
  Future<String> _deviceId() async {
    final prefs = _ref.read(sharedPreferencesProvider).requireValue;
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await prefs.setString(_deviceIdKey, id);
    return id;
  }

  /// Best-effort write of the conference request to the Yandex.Disk
  /// mailbox (the channel that reaches the server under whitelists).
  /// Errors are logged, never thrown.
  Future<void> _postMailboxRequest(String link) async {
    try {
      final deviceId = await _deviceId();
      await _ref.read(diskMailboxApiProvider).postRequest(deviceId, link);
    } catch (e) {
      loggy.warning('disk mailbox: request write failed (continuing anyway): $e');
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────

  /// Starts the relay and waits until the tunnel is connected (or fails).
  /// On-demand conference creation is tried first (unless [joinLink] is
  /// passed), then disk slots A/B, then the manual link, then Yandex
  /// session auto-create.
  Future<bool> activate({String? joinLink}) {
    if (state is TelemostConnected) return Future.value(true);
    final inFlight = _connectCompleter;
    if (inFlight != null && !inFlight.isCompleted) return inFlight.future;
    final completer = Completer<bool>();
    _connectCompleter = completer;
    _runActivate(joinLink).then((ok) {
      if (!completer.isCompleted) completer.complete(ok);
    });
    return completer.future;
  }

  Future<bool> _runActivate(String? joinLink) async {
    _statusSub ??= _service.watchStatus().listen(_onStatus);
    unawaited(_maybeRequestBatteryExemption());

    if (joinLink == null) {
      // 1) On-demand: create a fresh conference via the service accounts,
      //    post the request to the Disk mailbox, spawn the creator.
      state = const TelemostStarting(slot: 'on-demand');
      final onDemandLink = await createOnDemandConference();
      if (onDemandLink != null) {
        unawaited(_postMailboxRequest(onDemandLink));
        unawaited(_spawnCreator(onDemandLink));
        if (await _startAndWait(onDemandLink, _slotConnectTimeout, slot: 'on-demand')) {
          return true;
        }
        await _service.stop();
        loggy.warning('telemost: on-demand conference failed, falling back to disk slots');
      } else {
        loggy.warning('telemost: on-demand creation failed on all accounts, falling back to disk slots');
      }

      // 2) Server-side links from Yandex.Disk with A/B failover.
      final slots = _slotOrder();
      String? failedSlot;
      for (final slot in slots) {
        state = TelemostStarting(slot: slot, failedSlot: failedSlot);
        final link = await _ref.read(diskLinkProvider).fetchJoinLink(_diskUrlFor(slot));
        if (link == null) {
          failedSlot = slot;
          continue;
        }
        unawaited(_spawnCreator(link));
        if (await _startAndWait(link, _slotConnectTimeout, slot: slot)) {
          await saveSettings(_settings.copyWith(lastGoodSlot: slot));
          return true;
        }
        await _service.stop();
        failedSlot = slot;
      }
      if (failedSlot != null) {
        loggy.warning('telemost: all disk slots failed (${slots.join(',')})');
      }

      // 3) Manual link fallback (old behavior).
      final manual = _settings.joinLink;
      if (TelemostSettings.isValidJoinLink(manual)) {
        return _startManual(manual);
      }
      if (slots.isNotEmpty) {
        state = const TelemostError('Серверы A/B не ответили, ручная ссылка не задана');
        return false;
      }
    } else {
      // Explicit manual link — straight to the manual path.
      await saveSettings(_settings.copyWith(joinLink: joinLink));
      return _startManual(joinLink);
    }

    // 4) Legacy: auto-create a conference via the Yandex session.
    if (await hasYandexSession()) {
      state = const TelemostStarting();
      try {
        final uri = await createConference();
        final ok = await _startAndWait(uri, _connectTimeout);
        if (!ok) await _service.stop();
        return ok;
      } on YandexSessionExpired {
        state = const TelemostError('Сессия Яндекса истекла — войдите снова в настройках Телемоста');
        return false;
      } catch (e) {
        loggy.warning('telemost: auto-create conference failed: $e');
        state = TelemostError('Не удалось создать конференцию: $e');
        return false;
      }
    }

    state = const TelemostError('Не задана ссылка на конференцию Телемоста');
    return false;
  }

  /// Asks once per install for the battery-optimization exemption. Without
  /// it Doze/vendor power managers suspend the relay a few minutes after
  /// screen-off (the tunnel holds a wake lock, but the exemption is what
  /// keeps network access in deep sleep).
  Future<void> _maybeRequestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    const askedKey = 'telemost_batt_opt_asked';
    try {
      final prefs = _ref.read(sharedPreferencesProvider).requireValue;
      if (prefs.getBool(askedKey) ?? false) return;
      final repo = BatteryOptimizationRepositoryImpl();
      if (await repo.isIgnoringBatteryOptimizations() ?? false) return;
      await prefs.setBool(askedKey, true);
      await repo.requestIgnoreBatteryOptimizations();
    } catch (e) {
      loggy.warning('telemost: battery exemption request failed: $e');
    }
  }

  /// Manual-link path (old single-shot behavior, 180s timeout).
  Future<bool> _startManual(String link) async {
    state = const TelemostStarting();
    final ok = await _startAndWait(link, _connectTimeout);
    if (!ok) await _service.stop();
    return ok;
  }

  /// Slots with a configured disk URL, last-good first.
  List<String> _slotOrder() {
    final slots = <String>[
      if (_settings.diskUrlA.trim().isNotEmpty) 'A',
      if (_settings.diskUrlB.trim().isNotEmpty) 'B',
    ];
    final last = _settings.lastGoodSlot;
    if (slots.contains(last)) {
      slots
        ..remove(last)
        ..insert(0, last);
    }
    return slots;
  }

  String _diskUrlFor(String slot) => slot == 'A' ? _settings.diskUrlA : _settings.diskUrlB;

  /// Starts the relay with [link] and waits for STATUS:TUNNEL_CONNECTED up
  /// to [timeout], then verifies real data flow through the tunnel's local
  /// SOCKS5 (the relay reports "connected" right after joining the call,
  /// before the creator shows up — without the probe a dead room looks
  /// connected). [TelemostConnected] is set only after the probe passes.
  /// On failure the caller is responsible for stopping.
  Future<bool> _startAndWait(String link, Duration timeout, {String? slot}) async {
    _currentSlot = slot;
    _activeLink = link;
    _tunnelVerified = false;
    _attemptCompleter = Completer<bool>();
    try {
      _socks = await _service.start(_settings.copyWith(joinLink: link));
    } catch (e) {
      loggy.warning('telemost: start failed: $e');
      state = TelemostError('Не удалось запустить relay: $e');
      return false;
    }
    final joined = await _attemptCompleter!.future.timeout(
      timeout,
      onTimeout: () {
        loggy.warning('telemost: connect timeout (${timeout.inSeconds}s)${slot != null ? ' on slot $slot' : ''}');
        return false;
      },
    );
    if (!joined) return false;
    if (!await _probeTunnel()) return false;
    final socks = _socks;
    _tunnelVerified = true;
    if (socks != null) state = TelemostConnected(socks);
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
    // Not TelemostConnected means a reconnect cycle is already in flight
    // (native slot-kill reconnect or a manual retry) — do not interfere.
    if (state is! TelemostConnected) return;
    final socks = _socks;
    if (socks == null) return;
    // Connected without a telemost-owned core is the «says it works,
    // nothing loads» state (TUN/WG path down while the relay is fine):
    // bring the core up before probing anything.
    if (_ref.read(coreOwnerProvider) != CoreOwner.telemost) {
      unawaited(_recoverCore());
      return;
    }
    // Probe the path user traffic actually takes: through the core's mixed
    // inbound (core → WG → relay → internet) to a host that cannot be
    // reached directly under whitelists — a whitelisted target could be
    // routed direct by the core and pass while WG is dead.
    final ok = await _probeOnce(
      TelemostSocks(host: '127.0.0.1', port: _ref.read(ConfigOptions.mixedPort), user: '', pass: ''),
      host: _watchdogProbeHost,
      path: _watchdogProbePath,
    );
    if (ok) {
      _watchdogFailures = 0;
      _coreRestartTried = false;
      _coreStartFailures = 0;
      return;
    }
    _watchdogFailures++;
    loggy.warning('telemost: watchdog probe failed ($_watchdogFailures/3)');
    if (_watchdogFailures < 3) return;
    _watchdogFailures = 0;
    if (!_coreRestartTried) {
      _coreRestartTried = true;
      unawaited(_restartCore());
    } else {
      unawaited(_restartRelay());
    }
  }

  /// Brings the core up while the tunnel claims Connected. Two failures in
  /// a row escalate to a relay restart — a plausible reason the core refuses
  /// to start is that the relay's local SOCKS endpoint died.
  Future<void> _recoverCore() async {
    if (_restartingTunnel) return;
    final last = _lastWatchdogRestart;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _restartingTunnel = true;
    _lastWatchdogRestart = DateTime.now();
    var escalate = false;
    try {
      loggy.warning('telemost: core not running while connected — starting it');
      if (await startCore()) {
        _coreStartFailures = 0;
      } else {
        _coreStartFailures++;
        escalate = _coreStartFailures >= 2;
      }
    } finally {
      _restartingTunnel = false;
    }
    if (escalate) {
      _coreStartFailures = 0;
      // Bypass the relay-restart cooldown: this escalation is the reason the
      // core would not start, blocking it would loop forever.
      _lastWatchdogRestart = null;
      await _restartRelay();
    }
  }

  /// Cheap watchdog remedy: bounce the sing-box core so the WG outbound
  /// re-handshakes through the (alive) tunnel. Fixes the «relay alive, WG
  /// dead» state without touching the conference.
  Future<void> _restartCore() async {
    if (_restartingTunnel) return;
    _restartingTunnel = true;
    try {
      loggy.warning('telemost: watchdog restarting core (full-path probe silent)');
      await stopCore();
      // The core stop is not instantaneous; starting on top of a still-
      // dying session fails and leaves «relay alive, core dead» for good.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!await startCore()) {
        loggy.warning('telemost: core restart failed');
      }
    } finally {
      _restartingTunnel = false;
    }
  }

  /// Restarts the relay on the same conference link and repoints the core at
  /// the new local SOCKS endpoint (the native side picks a fresh random port
  /// on every start, so the sing-box config must be rewritten). Used by the
  /// watchdog when the tunnel goes silent without the native joiner noticing.
  Future<void> _restartRelay() async {
    if (_restartingTunnel) return;
    final last = _lastWatchdogRestart;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 60)) {
      loggy.info('telemost: watchdog restart skipped (cooldown)');
      return;
    }
    final link = _activeLink;
    if (link == null || link.isEmpty) return;
    _restartingTunnel = true;
    _watchdogFailures = 0;
    _lastWatchdogRestart = DateTime.now();
    try {
      loggy.warning('telemost: watchdog restarting relay (tunnel silent)');
      await _service.stop();
      // Best-effort: if the silence lasted long enough for the reaper to
      // collect the creator, spawn a fresh one before rejoining the room.
      unawaited(_spawnCreator(link));
      final ok = await _startAndWait(link, _slotConnectTimeout, slot: _currentSlot);
      if (!ok) {
        loggy.warning('telemost: watchdog restart failed');
        await _service.stop();
        state = const TelemostLost();
        return;
      }
      if (_ref.read(coreOwnerProvider) == CoreOwner.telemost) {
        await stopCore();
        // Let the old core fully die before starting on the new endpoint
        // (same race as in _restartCore).
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!await startCore()) {
          loggy.warning('telemost: core restart after relay restart failed');
          state = const TelemostLost();
        }
      }
    } finally {
      _restartingTunnel = false;
    }
  }

  // ── Data-flow probe ────────────────────────────────────────────────────

  /// Retries a SOCKS5 round-trip through the tunnel until one succeeds or
  /// [_probeBudget] runs out. The state stays TelemostConnecting while this
  /// runs — the UI must not show «connected» before real data flows.
  Future<bool> _probeTunnel() async {
    final socks = _socks;
    if (socks == null) return false;
    final sw = Stopwatch()..start();
    var attempt = 0;
    while (true) {
      attempt++;
      if (await _probeOnce(socks)) {
        loggy.info('telemost: data-flow probe OK on attempt $attempt (${sw.elapsed.inSeconds}s)');
        return true;
      }
      final remaining = _probeBudget - sw.elapsed - _probeRetryDelay;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(remaining < _probeRetryDelay ? remaining : _probeRetryDelay);
    }
    loggy.warning('telemost: data-flow probe failed after $attempt attempts (${sw.elapsed.inSeconds}s) — creator never showed up?');
    return false;
  }

  /// One SOCKS5 round-trip: handshake (user/pass auth when the server picks
  /// it), CONNECT to [host]:80, then a HEAD request — any response
  /// bytes prove the tunnel actually carries data. Raw dart:io Socket, no
  /// proxy-adapter dependency.
  Future<bool> _probeOnce(TelemostSocks socks, {String host = _probeHost, String path = '/'}) async {
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

  /// Starts the sing-box core on the Telemost config (WG over the relay's
  /// local SOCKS5). Requires a verified tunnel ([TelemostConnected]). The
  /// core is marked telemost-owned so the main-VPN UI keeps showing «off»
  /// and a later VPN connect knows whom to tear down.
  Future<bool> startCore() async {
    final current = state;
    if (current is! TelemostConnected) return false;
    if (await _tryStartCore(current)) return true;
    // One retry after a full stop + settle: a half-dead previous session is
    // the common reason a start fails mid-tunnel.
    loggy.info('telemost: core start failed, retrying after stop+settle');
    await _forceStopCore();
    await Future<void>.delayed(const Duration(seconds: 2));
    return _tryStartCore(current);
  }

  /// Unconditional core stop (stopCore no-ops when the owner tag was already
  /// reset by a failed start, leaving a wedged session behind).
  Future<void> _forceStopCore() async {
    await _ref.read(connectionRepositoryProvider).disconnect().mapLeft((failure) {
      loggy.warning('telemost: core stop failed: $failure');
    }).run();
    _ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
  }

  Future<bool> _tryStartCore(TelemostConnected current) async {
    final file = await _ref.read(telemostConfigServiceProvider).writeConfig(current.socks);
    if (file == null) return false;
    _ref.read(coreOwnerProvider.notifier).state = CoreOwner.telemost;
    final result = await _ref
        .read(connectionRepositoryProvider)
        .connectConfig(file.path, telemostProfileName, _ref.read(Preferences.disableMemoryLimit))
        .run();
    return result.match(
      (failure) {
        loggy.warning('telemost: core start failed: $failure');
        _ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
        return false;
      },
      (_) => true,
    );
  }

  /// Stops the core when it is telemost-owned. A VPN-owned session is never
  /// touched.
  Future<void> stopCore() async {
    if (_ref.read(coreOwnerProvider) != CoreOwner.telemost) return;
    await _ref.read(connectionRepositoryProvider).disconnect().mapLeft((failure) {
      loggy.warning('telemost: core stop failed: $failure');
    }).run();
    _ref.read(coreOwnerProvider.notifier).state = CoreOwner.none;
  }

  Future<void> deactivate() async {
    _stopWatchdog();
    await stopCore();
    await _statusSub?.cancel();
    _statusSub = null;
    _socks = null;
    _currentSlot = null;
    _tunnelVerified = false;
    await _service.stop();
    // Best-effort: tell the creator-manager to stop the server side too.
    final link = _activeLink ?? _settings.joinLink;
    _activeLink = null;
    if (link.isNotEmpty) {
      unawaited(
        _ref.read(wlbManagerApiProvider).stop(link).catchError((Object e) {
          loggy.warning('wlb manager stop failed (ignoring): $e');
        }),
      );
    }
    if (state is! TelemostIdle) state = const TelemostIdle();
  }

  /// Leaves [TelemostError]/[TelemostLost] back to idle so the user can retry.
  void resetError() {
    if (state is TelemostError || state is TelemostLost) {
      state = const TelemostIdle();
    }
  }

  // ── Status handling ────────────────────────────────────────────────────

  void _completeAttempt(bool value) {
    final completer = _attemptCompleter;
    if (completer != null && !completer.isCompleted) completer.complete(value);
  }

  void _onStatus(TelemostStatusEvent event) {
    loggy.info('telemost status: ${event.status} ${event.message ?? ''}');
    switch (event.status) {
      case 'starting':
        if (state is! TelemostConnected) state = TelemostStarting(slot: _currentSlot);
      case 'connecting':
        if (state is! TelemostConnected) state = TelemostConnecting(slot: _currentSlot);
      case 'connected':
        // The relay reports "connected" right after joining the call —
        // possibly before the creator shows up. The first signal of an
        // attempt only unblocks _startAndWait, which runs the data-flow
        // probe and sets TelemostConnected itself once the probe passes.
        // Every later signal (the SFU slot-kill reconnect cycle emits
        // connected → lost → connecting → connected every ~53s) restores
        // TelemostConnected — but only for a probe-verified tunnel, and
        // from ANY state: after 'lost' the state is TelemostConnecting by
        // the time 'connected' arrives, so a state-based guard would stick
        // in the Connecting/Lost loop forever.
        final completer = _attemptCompleter;
        if (completer != null && !completer.isCompleted) {
          _completeAttempt(true);
        } else if (_tunnelVerified) {
          // Native self-recovery from the slot-kill cycle: the tunnel is
          // alive again, so any watchdog failures counted during the outage
          // are stale.
          _watchdogFailures = 0;
          final socks = _socks;
          if (socks != null) state = TelemostConnected(socks);
        }
      case 'lost':
        // Mid-probe the slot-kill reconnect cycle must not flash «lost» —
        // the tunnel swap kills the probe attempt and the retry rides the
        // new tunnel. On a verified tunnel 'lost' is reported as before.
        if (_tunnelVerified) state = const TelemostLost();
        _completeAttempt(false);
      case 'captcha':
        state = TelemostError(
          'Яндекс запросил капчу. Откройте ссылку в браузере и пройдите проверку:\n${event.message ?? ''}',
        );
        _completeAttempt(false);
      case 'error':
        state = TelemostError(event.message ?? 'неизвестная ошибка relay');
        _completeAttempt(false);
      case 'stopped':
        if (state is TelemostStarting || state is TelemostConnecting) {
          state = const TelemostIdle();
        }
    }
  }

  @override
  void dispose() {
    _watchdogTimer?.cancel();
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
