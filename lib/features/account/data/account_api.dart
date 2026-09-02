import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/utils/utils.dart';

/// Thrown when the server rejects the session token (HTTP 401) — the session
/// is dead and must be discarded, as opposed to a transient network failure.
class AccountUnauthorizedException implements Exception {
  const AccountUnauthorizedException(this.endpoint);
  final String endpoint;

  @override
  String toString() => 'AccountUnauthorizedException($endpoint)';
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
  Future<Map<String, dynamic>> createPayment({
    required int tariffIdx,
    String? method,
    String? promo,
    String? sessionToken,
  }) async {
    final res = await httpClient.post(
      '$baseUrl/api/app/payment',
      data: jsonEncode({
        'tariff_idx': tariffIdx,
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
