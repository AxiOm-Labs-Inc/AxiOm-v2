import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:axiom/core/http_client/dio_http_client.dart';
import 'package:axiom/core/model/constants.dart';
import 'package:axiom/utils/utils.dart';

/// Thrown when the server rejects the session token (HTTP 401) — the session
/// is dead and must be discarded, as opposed to a transient network failure.
class AccountUnauthorizedException implements Exception {
  const AccountUnauthorizedException(this.endpoint);
  final String endpoint;

  @override
  String toString() => 'AccountUnauthorizedException($endpoint)';
}

/// Сервер отказал в сбросе ссылки. [code]: not_found | cooldown | failed.
class AccountResetLinkException implements Exception {
  const AccountResetLinkException(this.code, {this.retryIn});
  final String code;
  final int? retryIn;

  @override
  String toString() => 'AccountResetLinkException($code)';
}

/// Client for the Personal Account API (v4.2.0).
///
/// Base URL: https://axiom.arcohouse.space
/// Uses the same [DioHttpClient] as the rest of the app (proxy routing + retry).
class AccountApi with InfraLogger {
  AccountApi({required this.httpClient, String? baseUrl})
      : baseUrl = baseUrl ?? Constants.accountApiBaseUrl;

  final DioHttpClient httpClient;
  final String baseUrl;

  // ── POST /api/app/login/start ───────────────────────────────────────────

  /// Starts a new login flow. Returns {token, deep_link, expires_in}.
  Future<Map<String, dynamic>> startLogin() async {
    final res = await httpClient.post(
      '$baseUrl/api/app/login/start',
      extraHeaders: {'Content-Type': 'application/json'},
    );
    return _decode(res.data, 'login/start');
  }

  // ── GET /api/app/login/poll?token=... ───────────────────────────────────

  /// Polls for login confirmation. Returns null when the server could not be
  /// reached at all (network failure) — the caller retries. A response with an
  /// HTTP error status means a server-side problem and is thrown immediately.
  /// Response: {"status": "pending"|"confirmed"|"expired", ...}
  Future<Map<String, dynamic>?> pollLogin(String token) async {
    try {
      final res = await httpClient.get(
        '$baseUrl/api/app/login/poll?token=${Uri.encodeQueryComponent(token)}',
      );
      return _decode(res.data, 'login/poll');
    } on DioException catch (e) {
      if (e.response != null) {
        throw Exception('login/poll: server error ${e.response!.statusCode}');
      }
      return null;
    }
  }

  // ── GET /api/app/me ────────────────────────────────────────────────────

  /// Fetches the connected user's profile and subscriptions.
  /// Throws [AccountUnauthorizedException] on HTTP 401 (dead session).
  Future<Map<String, dynamic>> getMe(String sessionToken) async {
    try {
      final res = await httpClient.get(
        '$baseUrl/api/app/me',
        extraHeaders: {'Authorization': 'Bearer $sessionToken'},
      );
      return _decode(res.data, '/me');
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const AccountUnauthorizedException('/me');
      }
      rethrow;
    }
  }

  // ── POST /api/app/logout ───────────────────────────────────────────────

  /// Revokes the session token (best-effort).
  Future<void> logout(String sessionToken) async {
    try {
      await httpClient.post(
        '$baseUrl/api/app/logout',
        extraHeaders: {'Authorization': 'Bearer $sessionToken'},
      );
    } catch (e) {
      loggy.warning('logout request failed (ignoring): $e');
    }
  }

  // ── GET /api/app/telemost/credentials ──────────────────────────────────

  /// Fetches this account's Telemost secret. The secret proves membership to
  /// the room holder without ever leaving the device in the clear: the
  /// handshake sends a per-connection HMAC, never the secret itself.
  ///
  /// Returns null when the account is not entitled (403) or when the server
  /// cannot confirm the subscription right now (503) — in both cases the
  /// caller keeps whatever it already has and simply does not refresh.
  /// Throws [AccountUnauthorizedException] on 401 (dead session).
  Future<Map<String, dynamic>?> getTelemostCredentials(String sessionToken) async {
    try {
      final res = await httpClient.get(
        '$baseUrl/api/app/telemost/credentials',
        extraHeaders: {'Authorization': 'Bearer $sessionToken'},
      );
      return _decode(res.data, '/telemost/credentials');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401) {
        throw const AccountUnauthorizedException('/telemost/credentials');
      }
      if (code == 403 || code == 503 || code == 429) return null;
      rethrow;
    }
  }

  // ── POST /api/app/reset_link ───────────────────────────────────────────

  /// Сбрасывает ссылку подписки: {ok, username, sub_url, old_sub_url}.
  /// Ошибки приходят кодом в [AccountResetLinkException]: not_found,
  /// cooldown (с retry_in в секундах), failed.
  Future<Map<String, dynamic>> resetLink(String sessionToken, String username) async {
    try {
      final res = await httpClient.post(
        '$baseUrl/api/app/reset_link',
        data: jsonEncode({'username': username}),
        extraHeaders: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $sessionToken',
        },
      );
      return _decode(res.data, '/reset_link');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401) throw const AccountUnauthorizedException('/reset_link');
      if (code != null) {
        Map<String, dynamic> body = const {};
        try {
          body = _decode(e.response!.data, '/reset_link');
        } catch (_) {}
        throw AccountResetLinkException(
          body['error'] as String? ?? (code == 429 ? 'cooldown' : 'failed'),
          retryIn: (body['retry_in'] as num?)?.toInt(),
        );
      }
      rethrow;
    }
  }

  // ── GET /api/app/tariffs ───────────────────────────────────────────────

  /// Tariff catalogue for the purchase sheet.
  ///
  /// Served by the backend rather than hardcoded: prices and plans change, and
  /// a shipped build cannot be updated for everyone at once — a hardcoded price
  /// would disagree with what is actually charged.
  Future<Map<String, dynamic>> getTariffs() async {
    final res = await httpClient.get('$baseUrl/api/app/tariffs');
    return _decode(res.data, '/tariffs');
  }

  // ── POST /api/app/payment ──────────────────────────────────────────────

  /// Creates a payment. Returns {payment_id, payment_url}, or
  /// {status: "succeeded", sub_url} when a 100% discount makes it free.
  ///
  /// [sessionToken] is optional: the expiry banner is also shown to users who
  /// never connected a Telegram account. With a token the purchase is bound to
  /// the account, without one the response carries a claim_url to bind later.
  /// [expectedPrice] — цена, которую покупатель видит на кнопке. Каталог
  /// читается один раз, при открытии листа, и к моменту оплаты мог устареть;
  /// сервер сверяет её с текущей и отвечает 409 `price_changed`, не создавая
  /// платёж. Без этого поля (старые сборки) проверки нет.
  Future<Map<String, dynamic>> createPayment({
    required int tariffIdx,
    int? expectedPrice,
    String? method,
    String? promo,
    String? sessionToken,
  }) async {
    final res = await httpClient.post(
      '$baseUrl/api/app/payment',
      data: jsonEncode({
        'tariff_idx': tariffIdx,
        if (expectedPrice != null) 'expected_price': expectedPrice,
        if (method != null) 'method': method,
        if (promo != null && promo.isNotEmpty) 'promo': promo,
      }),
      extraHeaders: {
        'Content-Type': 'application/json',
        if (sessionToken != null) 'Authorization': 'Bearer $sessionToken',
      },
    );
    return _decode(res.data, '/payment');
  }

  // ── GET /api/app/payment/status ────────────────────────────────────────

  /// Polls a payment. Status is one of pending | succeeded | canceled | not_found.
  Future<Map<String, dynamic>> getPaymentStatus(
    String paymentId, {
    String? sessionToken,
  }) async {
    final res = await httpClient.get(
      '$baseUrl/api/app/payment/status?pid=${Uri.encodeQueryComponent(paymentId)}',
      extraHeaders: {
        if (sessionToken != null) 'Authorization': 'Bearer $sessionToken',
      },
    );
    return _decode(res.data, '/payment/status');
  }

  // ── helpers ────────────────────────────────────────────────────────────

  Map<String, dynamic> _decode(dynamic data, String endpoint) {
    if (data is String) return jsonDecode(data) as Map<String, dynamic>;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('$endpoint: unexpected response type ${data.runtimeType}');
  }
}
