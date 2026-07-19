import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/features/account/model/account_models.dart';

part 'account_state.freezed.dart';

@freezed
class AccountState with _$AccountState {
  /// Checking for a stored session on startup — UI shows nothing / skeleton.
  const factory AccountState.restoring() = AccountStateRestoring;

  /// Not connected — initial state or after logout.
  const factory AccountState.disconnected() = AccountStateDisconnected;

  /// Login started, waiting for user to confirm in Telegram bot.
  const factory AccountState.connecting({
    required String token,
    required String deepLink,
    required DateTime expiresAt,
  }) = AccountStateConnecting;

  /// Successfully connected.
  const factory AccountState.connected({
    required AccountSession session,
    @Default([]) List<AccountSubscription> subscriptions,
  }) = AccountStateConnected;

  /// Login failed or network error.
  const factory AccountState.error({@Default('') String message}) = AccountStateError;
}
