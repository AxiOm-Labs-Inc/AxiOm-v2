import 'dart:async';

import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Bottom-sheet for connecting a Telegram account to the app.
class ConnectAccountSheet extends HookConsumerWidget with PresLogger {
  const ConnectAccountSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountState = ref.watch(accountNotifierProvider);
    final theme = Theme.of(context);
    final a = ref.watch(translationsProvider).requireValue.pages.profiles.account;

    // Initialized from the actual expiry once the connecting state arrives;
    // 0 means "no deadline known yet" (indicator shows no bogus time).
    final countdown = useState(0);
    final cancelToken = useRef(CancelToken());
    final started = useRef(false);

    // Start login on first build; cancel polling when the sheet is disposed
    // (e.g. dismissed with a swipe, not just the Cancel button).
    useEffect(() {
      if (!started.value) {
        started.value = true;
        Future.microtask(() => ref.read(accountNotifierProvider.notifier).startLogin());
      }
      return () {
        if (!cancelToken.value.isCancelled) cancelToken.value.cancel();
      };
    }, []);

    // Listen for state transitions
    ref.listen(accountNotifierProvider, (prev, next) {
      if (next is AccountStateConnecting) {
        final remaining = next.expiresAt.difference(DateTime.now()).inSeconds;
        countdown.value = remaining > 0 ? remaining : 0;

        final ct = CancelToken();
        cancelToken.value = ct;
        ref.read(accountNotifierProvider.notifier).pollAndConnect(ct);
      }
      if (next is AccountStateConnected) {
        Future.microtask(() {
          if (context.mounted) Navigator.of(context).pop();
        });
      }
    });

    // Countdown timer while connecting
    useEffect(() {
      final state = accountState;
      if (state is! AccountStateConnecting) return null;
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        final remaining = state.expiresAt.difference(DateTime.now()).inSeconds;
        countdown.value = remaining > 0 ? remaining : 0;
      });
      return timer.cancel;
    }, [accountState]);

    final isConnecting = accountState is AccountStateConnecting;
    final isError = accountState is AccountStateError;
    final deepLink = isConnecting ? accountState.deepLink : null;
    final fallbackLink = deepLink ?? Constants.telegramBuyBotUrl;
    final errorMessage = isError ? accountState.message : '';
    final isDesktop = !PlatformUtils.isMobile;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            Text(
              a.connectTitle,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              a.connectHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),

            // QR + Telegram button — desktop: QR first; mobile: Telegram first
            if (isConnecting || accountState is AccountStateDisconnected) ...[
              if (isDesktop) ...[
                _QrSection(deepLink: deepLink, theme: theme),
                const SizedBox(height: 20),
                _OpenTelegramButton(deepLink: deepLink, label: a.openTelegram),
              ] else ...[
                _OpenTelegramButton(deepLink: deepLink, label: a.openTelegram),
                const SizedBox(height: 20),
                _QrSection(deepLink: deepLink, theme: theme),
              ],
              const SizedBox(height: 12),
              _CopyLinkButton(link: fallbackLink, label: a.copyLink, copiedLabel: a.linkCopied),
              const SizedBox(height: 16),
              _PollingIndicator(countdown: countdown.value, theme: theme, label: a.waiting),
            ] else if (isError) ...[
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                errorMessage.isNotEmpty ? errorMessage : a.connectError,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              _OpenTelegramButton(deepLink: Constants.telegramBuyBotUrl, label: a.openTelegram),
            ],

            const SizedBox(height: 16),
            if (isConnecting)
              TextButton(
                onPressed: () {
                  cancelToken.value.cancel();
                  ref.read(accountNotifierProvider.notifier).cancelLogin();
                  Navigator.of(context).pop();
                },
                child: Text(a.cancel),
              )
            else if (isError)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(a.close),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () {
                      ref.read(accountNotifierProvider.notifier).cancelLogin();
                      ref.read(accountNotifierProvider.notifier).startLogin();
                    },
                    child: Text(a.retry),
                  ),
                ],
              )
            else
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(a.close),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── QR Code Section ─────────────────────────────────────────────────────────

class _QrSection extends StatelessWidget {
  const _QrSection({required this.deepLink, required this.theme});
  final String? deepLink;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final link = deepLink ?? Constants.telegramBuyBotUrl;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: QrImageView(
        data: link,
        size: 200,
        backgroundColor: Colors.white,
      ),
    );
  }
}

// ── "Open Telegram" Button ──────────────────────────────────────────────────

class _OpenTelegramButton extends StatelessWidget {
  const _OpenTelegramButton({required this.deepLink, required this.label});
  final String? deepLink;
  final String label;

  @override
  Widget build(BuildContext context) {
    final link = deepLink ?? Constants.telegramBuyBotUrl;
    return FilledButton.icon(
      onPressed: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
      icon: const Icon(Icons.telegram, size: 20),
      label: Text(label),
    );
  }
}

// ── Copy Link Button ────────────────────────────────────────────────────────

class _CopyLinkButton extends StatelessWidget {
  const _CopyLinkButton({required this.link, required this.label, required this.copiedLabel});
  final String link;
  final String label;
  final String copiedLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton.icon(
      onPressed: () {
        Clipboard.setData(ClipboardData(text: link));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(copiedLabel), duration: const Duration(seconds: 2)),
        );
      },
      icon: Icon(Icons.copy_rounded, size: 16, color: theme.colorScheme.primary),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    );
  }
}

// ── Polling Indicator ───────────────────────────────────────────────────────

class _PollingIndicator extends StatelessWidget {
  const _PollingIndicator({required this.countdown, required this.theme, required this.label});
  final int countdown;
  final ThemeData theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    final minutes = countdown ~/ 60;
    final seconds = countdown % 60;
    final text = countdown > 0 ? '$label $minutes:${seconds.toString().padLeft(2, '0')}' : label;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
