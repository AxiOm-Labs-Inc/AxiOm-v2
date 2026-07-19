import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/account/data/account_api.dart';
import 'package:hiddify/features/account/model/account_models.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'account_notifier.g.dart';

const _sessionKey = 'account_session';

@riverpod
AccountApi accountApi(AccountApiRef ref) {
  return AccountApi(httpClient: ref.watch(httpClientProvider));
}

@Riverpod(keepAlive: true)
class AccountNotifier extends _$AccountNotifier with AppLogger {
  final _secureStorage = const FlutterSecureStorage();

  @override
  AccountState build() {
    // Try restoring session on startup — fire-and-forget
    unawaited(_restoreSession());
    return const AccountState.restoring();
  }

  // ── Session persistence ────────────────────────────────────────────────

  Future<void> _saveSession(AccountSession session) async {
    await _secureStorage.write(
      key: _sessionKey,
      value: jsonEncode(session.toJson()),
    );
  }

  Future<void> _clearSession() async {
    await _secureStorage.delete(key: _sessionKey);
  }

  Future<void> _restoreSession() async {
    try {
      final raw = await _secureStorage.read(key: _sessionKey);
      if (raw == null) {
        if (state is AccountStateRestoring) state = const AccountState.disconnected();
        return;
      }
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final session = parseSession(json);
      // Load fresh data
      final api = ref.read(accountApiProvider);
      final me = await api.getMe(session.sessionToken);
      final subs = (me['subscriptions'] as List<dynamic>?)
              ?.map((s) => parseSubscription(s as Map<String, dynamic>))
              .toList() ??
          [];
      // Don't clobber a state set by a login flow that started meanwhile
      if (state is! AccountStateRestoring) return;
      state = AccountState.connected(session: session, subscriptions: subs);
    } on AccountUnauthorizedException {
      // Token is dead (revoked/expired on the server) — drop it for good
      loggy.info('stored session is no longer valid, clearing');
      await _clearSession();
      if (state is AccountStateRestoring) state = const AccountState.disconnected();
    } catch (e) {
      // Transient failure (network down, VPN not up yet, server hiccup):
      // keep the session so the user isn't logged out by a momentary blip.
      // But we MUST leave the restoring state so the UI doesn't flash.
      if (state is AccountStateRestoring) state = const AccountState.disconnected();
      loggy.warning('failed to restore session (keeping it): $e');
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────

  /// Starts login flow. Sets [AccountStateConnecting] state.
  ///
  /// Transient network failures (e.g. a brief DNS hiccup while the tunnel is
  /// coming up) are retried a few times before surfacing an error, so the user
  /// isn't shown a scary message for a momentary blip.
  Future<void> startLogin() async {
    const maxAttempts = 3;
    const retryDelay = Duration(seconds: 2);

    for (var attempt = 1;; attempt++) {
      try {
        final api = ref.read(accountApiProvider);
        final data = await api.startLogin();
        final token = data['token'] as String;
        final deepLink = data['deep_link'] as String;
        final expiresIn = (data['expires_in'] as num).toInt();
        state = AccountState.connecting(
          token: token,
          deepLink: deepLink,
          expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
        );
        return;
      } catch (e) {
        if (_isNetworkError(e) && attempt < maxAttempts) {
          loggy.warning('startLogin network error (attempt $attempt/$maxAttempts), retrying: $e');
          await Future.delayed(retryDelay);
          continue;
        }
        loggy.warning('startLogin failed: $e');
        state = AccountState.error(message: _friendlyError(e));
        return;
      }
    }
  }

  /// Polls until the user confirms in Telegram, then fetches profile.
  /// [cancelToken] cancels the polling (e.g. when user taps Cancel).
  Future<void> pollAndConnect(CancelToken cancelToken) async {
    final connecting = state;
    if (connecting is! AccountStateConnecting) return;

    final api = ref.read(accountApiProvider);
    const pollInterval = Duration(seconds: 2);

    try {
      while (true) {
        if (cancelToken.isCancelled) {
          state = const AccountState.disconnected();
          return;
        }

        // Check timeout
        if (DateTime.now().isAfter(connecting.expiresAt)) {
          state = AccountState.error(message: ref.read(translationsProvider).requireValue.pages.profiles.account.timeout);
          return;
        }

        final response = await api.pollLogin(connecting.token);
        if (response == null) {
          // Network error — retry after interval
          await Future.delayed(pollInterval);
          continue;
        }

        final status = response['status'] as String?;
        switch (status) {
          case 'confirmed':
            final sessionToken = response['session_token'] as String;
            // Fetch user profile
            final me = await api.getMe(sessionToken);
            final session = AccountSession(
              sessionToken: sessionToken,
              telegramId: (me['telegram_id'] as num).toInt(),
              firstName: me['first_name'] as String? ?? '',
              createdAt: DateTime.now(),
            );
            await _saveSession(session);
            final subs = (me['subscriptions'] as List<dynamic>?)
                    ?.map((s) => parseSubscription(s as Map<String, dynamic>))
                    .toList() ??
                [];
            state = AccountState.connected(session: session, subscriptions: subs);
            return;

          case 'expired':
            state = AccountState.error(message: ref.read(translationsProvider).requireValue.pages.profiles.account.timeout);
            return;

          case 'pending':
          default:
            // Keep polling
            break;
        }

        await Future.delayed(pollInterval);
      }
    } catch (e) {
      if (cancelToken.isCancelled) {
        state = const AccountState.disconnected();
        return;
      }
      loggy.warning('pollAndConnect failed: $e');
      state = AccountState.error(message: _friendlyError(e));
    }
  }

  /// Cancels an ongoing login attempt.
  void cancelLogin() {
    if (state is AccountStateConnecting || state is AccountStateError) {
      state = const AccountState.disconnected();
    }
  }

  /// Refreshes subscription list from server.
  /// Returns true on success so the UI can give feedback on failure.
  Future<bool> refresh() async {
    final current = state;
    if (current is! AccountStateConnected) return false;

    try {
      final api = ref.read(accountApiProvider);
      final me = await api.getMe(current.session.sessionToken);
      final subs = (me['subscriptions'] as List<dynamic>?)
              ?.map((s) => parseSubscription(s as Map<String, dynamic>))
              .toList() ??
          [];
      state = AccountState.connected(session: current.session, subscriptions: subs);
      return true;
    } catch (e) {
      loggy.warning('refresh failed: $e');
      return false;
    }
  }

  /// Logs out: revokes session token (best-effort), clears secure storage.
  Future<void> logout() async {
    final current = state;
    if (current is AccountStateConnected) {
      try {
        final api = ref.read(accountApiProvider);
        await api.logout(current.session.sessionToken);
      } catch (_) {}
    }
    await _clearSession();
    state = const AccountState.disconnected();
  }

  // ── Error helpers ──────────────────────────────────────────────────────────

  /// True for DNS / socket / timeout failures — i.e. "couldn't reach the server"
  /// rather than a server-side or parsing error.
  bool _isNetworkError(Object e) {
    if (e is SocketException) return true;
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return true;
        default:
          return e.error is SocketException;
      }
    }
    return false;
  }

  /// Maps an exception to a localized, user-friendly message instead of dumping
  /// the raw exception text (e.g. "DioException [connection error]: …").
  String _friendlyError(Object e) {
    final a = ref.read(translationsProvider).requireValue.pages.profiles.account;
    return _isNetworkError(e) ? a.networkError : a.connectError;
  }
}
