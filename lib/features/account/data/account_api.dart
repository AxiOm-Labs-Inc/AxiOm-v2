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
        throw AccountUnauthorizedException('/me');
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

  // ── helpers ────────────────────────────────────────────────────────────

  Map<String, dynamic> _decode(dynamic data, String endpoint) {
    if (data is String) return jsonDecode(data) as Map<String, dynamic>;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('$endpoint: unexpected response type ${data.runtimeType}');
  }
}
