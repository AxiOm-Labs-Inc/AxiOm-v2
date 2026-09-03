import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:intl/intl.dart';

part 'account_models.freezed.dart';

// ── API /me subscription ────────────────────────────────────────────────────

@Freezed()
class AccountSubscription with _$AccountSubscription {
  const AccountSubscription._();

  const factory AccountSubscription({
    required String subUrl,
    required String status,
    String? expire,
    int? expireEpoch,
    @Default(0) int usedTraffic,
    @Default(0) int dataLimit,
    @Default('') String tariff,
  }) = _AccountSubscription;

  /// Whole days until expiry, or null when there's no expiry / it's unknown.
  /// Negative means already expired.
  ///
  /// Time already past is rounded away from zero: plain truncation reported a
  /// subscription that died 12 hours ago as 0 — «last day» — which reads as
  /// still alive. Time remaining keeps truncating, so half a day left is 0 and
  /// really is the last day.
  int? get daysLeft {
    if (expireEpoch == null) return null;
    final expiry = DateTime.fromMillisecondsSinceEpoch(expireEpoch! * 1000, isUtc: true);
    final diff = expiry.difference(DateTime.now().toUtc());
    if (diff.isNegative) return -((-diff.inSeconds) / Duration.secondsPerDay).ceil();
    return diff.inDays;
  }

  /// Human-readable traffic: "12.3 GB / 210 GB"
  String get trafficLabel {
    if (dataLimit <= 0) return '∞';
    final used = usedTraffic;
    final limit = dataLimit;
    if (used >= 1024 * 1024 * 1024 || limit >= 1024 * 1024 * 1024) {
      return '${(used / (1024 * 1024 * 1024)).toStringAsFixed(1)} / ${(limit / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(used / (1024 * 1024)).toStringAsFixed(0)} / ${(limit / (1024 * 1024)).toStringAsFixed(0)} MB';
  }

  /// Traffic ratio 0..1 for progress bar
  double get trafficRatio {
    if (dataLimit <= 0) return 0;
    return (usedTraffic / dataLimit).clamp(0.0, 1.0);
  }
}

/// Parsed from /api/app/me response JSON.
AccountSubscription parseSubscription(Map<String, dynamic> json) {
  return AccountSubscription(
    subUrl: json['sub_url'] as String? ?? '',
    status: json['status'] as String? ?? 'unknown',
    expire: _parseExpire(json['expire']),
    expireEpoch: _parseExpireEpoch(json['expire']),
    usedTraffic: (json['used_traffic'] as num?)?.toInt() ?? 0,
    dataLimit: (json['data_limit'] as num?)?.toInt() ?? 0,
    tariff: json['tariff'] as String? ?? '',
  );
}

/// Raw expiry as Unix seconds when the backend sends a numeric timestamp;
/// null for "no expiry" or a non-numeric format (used for the days-left color).
int? _parseExpireEpoch(dynamic raw) {
  if (raw is num) {
    final seconds = raw.toInt();
    return seconds > 0 ? seconds : null;
  }
  return null;
}

/// The backend sends `expire` as a Unix timestamp in seconds (int), or `0`/null
/// when there's no expiry. Formats it as a human-readable date; returns null for
/// "no expiry" so the UI hides the expire row.
String? _parseExpire(dynamic raw) {
  if (raw == null) return null;
  if (raw is String) return raw.isEmpty ? null : raw; // tolerate a future string format
  if (raw is num) {
    final seconds = raw.toInt();
    if (seconds <= 0) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal();
    return DateFormat('dd.MM.yyyy').format(date);
  }
  return null;
}

// ── API /me feature flags ───────────────────────────────────────────────────

/// Top-level "features" object of GET /api/app/me. Not freezed — a plain
/// value class is enough for a flat bool map.
class AccountFeatures {
  const AccountFeatures({this.telemost = false});

  final bool telemost;
}

/// Parsed from /api/app/me response JSON; a missing/null object or flag
/// maps to false (fail-closed).
AccountFeatures parseFeatures(Map<String, dynamic>? json) {
  return AccountFeatures(telemost: json?['telemost'] as bool? ?? false);
}

// ── Session (persisted in secure storage) ───────────────────────────────────

@Freezed()
class AccountSession with _$AccountSession {
  const AccountSession._();

  const factory AccountSession({
    required String sessionToken,
    required int telegramId,
    @Default('') String firstName,
    DateTime? createdAt,
  }) = _AccountSession;

  Map<String, dynamic> toJson() => {
        'session_token': sessionToken,
        'telegram_id': telegramId,
        'first_name': firstName,
        'created_at': createdAt?.toIso8601String(),
      };
}

/// Parsed from stored JSON in secure storage.
AccountSession parseSession(Map<String, dynamic> json) {
  return AccountSession(
    sessionToken: json['session_token'] as String,
    telegramId: (json['telegram_id'] as num).toInt(),
    firstName: json['first_name'] as String? ?? '',
    createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'] as String) : null,
  );
}
