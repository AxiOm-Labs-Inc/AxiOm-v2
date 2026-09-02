import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/account/widget/payment_webview_page.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opens the in-app purchase bottom sheet (tariffs → payment → poll).
Future<void> showPurchaseSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const PurchaseSheet(),
  );
}

/// Unfinished payment stored while the buyer is away from the sheet.
class PendingPayment {
  const PendingPayment({required this.pid, required this.ts, this.url});

  final String pid;
  final String? url;
  final int ts;

  Map<String, dynamic> toJson() => {
        'pid': pid,
        'ts': ts,
        if (url != null && url!.isNotEmpty) 'url': url,
      };

  static PendingPayment? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final pid = m['pid'] as String?;
      if (pid == null || pid.isEmpty) return null;
      return PendingPayment(
        pid: pid,
        url: m['url'] as String?,
        ts: (m['ts'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  bool get isExpired {
    final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
    return age < 0 || age > PurchaseSheet.pendingTtl.inSeconds;
  }
}

/// Mirrors [PurchaseSheet] prefs so Profiles / banners can show a pending chip
/// without opening the sheet. Updated whenever the sheet saves or clears.
final pendingPaymentProvider = StateProvider<PendingPayment?>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider).valueOrNull;
  if (prefs == null) return null;
  final pending = PendingPayment.tryParse(prefs.getString(PurchaseSheet.pendingPaymentKey));
  if (pending == null || pending.isExpired) return null;
  return pending;
});

PendingPayment? _readValidPending(SharedPreferences prefs) {
  final pending = PendingPayment.tryParse(prefs.getString(PurchaseSheet.pendingPaymentKey));
  if (pending == null) return null;
  if (pending.isExpired) {
    unawaited(prefs.remove(PurchaseSheet.pendingPaymentKey));
    return null;
  }
  return pending;
}

/// Bottom-sheet for buying or renewing a subscription without leaving the app.
///
/// Shown when the subscription has already expired (while still-active “few
/// days left” banners still open the Telegram sales bot), or from Profiles
/// via «Купить подписку». See `docs/in-app-payment.md`.
///
/// A payment in flight is persisted as `{pid, url, ts}` before the payment
/// page opens. Closing the WebView or swiping the sheet away no longer loses
/// the order: the sheet resumes with «Оплата не завершена» and Continue /
/// Cancel actions.
class PurchaseSheet extends HookConsumerWidget with PresLogger {
  const PurchaseSheet({super.key});

  /// Payment in flight: {"pid": ..., "url": ..., "ts": epochSeconds}.
  static const pendingPaymentKey = 'pending_payment';

  /// How long a stored payment is still worth polling / resuming.
  static const pendingTtl = Duration(hours: 24);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final tariffs = useState<List<Map<String, dynamic>>?>(null);
    final loadError = useState<String?>(null);
    final busyIdx = useState<int?>(null);
    final paying = useState(false);
    final pending = useState<PendingPayment?>(null);
    final pollTimedOut = useState(false);
    final subUrl = useState<String?>(null);
    final claimUrl = useState<String?>(null);
    final imported = useState(false);
    final payError = useState<String?>(null);
    final pollTimer = useRef<Timer?>(null);
    final pollInFlight = useRef(false);

    final accountState = ref.watch(accountNotifierProvider);
    final sessionToken = accountState is AccountStateConnected
        ? accountState.session.sessionToken
        : null;

    final hasPending = pending.value != null;

    Future<bool> importSubUrl(String url) async {
      final repo = ref.read(profileRepositoryProvider).valueOrNull;
      if (repo == null) return false;
      return repo.upsertRemote(url).match(
        (err) {
          loggy.warning('post-payment profile import failed: $err');
          return false;
        },
        (_) => true,
      ).run();
    }

    // Зеркало для Профилей. ref живёт вместе с листом, а сюда можно попасть
    // из зависшего onPaymentSucceeded уже после его закрытия — prefs к этому
    // моменту записаны, и провайдер перечитает их сам.
    void syncPendingProvider(PendingPayment? value) {
      try {
        ref.read(pendingPaymentProvider.notifier).state = value;
      } catch (e) {
        loggy.warning('pending provider sync skipped (sheet gone): $e');
      }
    }

    Future<void> clearPending() async {
      await ref.read(sharedPreferencesProvider).requireValue.remove(pendingPaymentKey);
      syncPendingProvider(null);
      if (context.mounted) pending.value = null;
    }

    Future<void> savePending(PendingPayment value) async {
      await ref.read(sharedPreferencesProvider).requireValue.setString(
            pendingPaymentKey,
            jsonEncode(value.toJson()),
          );
      syncPendingProvider(value);
      if (context.mounted) pending.value = value;
    }

    Future<void> onPaymentSucceeded(Map<String, dynamic> payload) async {
      await clearPending();
      final url = payload['sub_url'] as String?;
      final claim = payload['claim_url'] as String?;
      final ok = url != null && url.isNotEmpty && await importSubUrl(url);
      if (!context.mounted) return;
      subUrl.value = url;
      claimUrl.value = claim;
      imported.value = ok;
      paying.value = false;
      busyIdx.value = null;
      pollTimedOut.value = false;
      payError.value = null;
      await ref.read(accountNotifierProvider.notifier).refresh();
    }

    void stopPolling() {
      pollTimer.value?.cancel();
      pollTimer.value = null;
      pollInFlight.value = false;
    }

    void startPolling(String pid) {
      final api = ref.read(accountApiProvider);
      var elapsed = 0;
      stopPolling();
      pollTimedOut.value = false;
      paying.value = true;
      pollTimer.value = Timer.periodic(const Duration(seconds: 3), (t) async {
        if (pollInFlight.value) return;
        elapsed += 3;
        if (elapsed > 15 * 60) {
          t.cancel();
          if (!context.mounted) return;
          // Prefs stay: buyer can «Проверить снова» / «Продолжить оплату».
          paying.value = false;
          busyIdx.value = null;
          pollTimedOut.value = true;
          payError.value = 'Время ожидания истекло. Можно проверить статус или открыть оплату снова.';
          return;
        }
        pollInFlight.value = true;
        try {
          final st = await api.getPaymentStatus(pid, sessionToken: sessionToken);
          if (!context.mounted) {
            t.cancel();
            return;
          }
          final status = st['status'];
          if (status == 'succeeded') {
            t.cancel();
            await onPaymentSucceeded(st);
          } else if (status == 'canceled' || status == 'not_found') {
            t.cancel();
            await clearPending();
            if (!context.mounted) return;
            paying.value = false;
            busyIdx.value = null;
            pollTimedOut.value = false;
            payError.value = status == 'canceled'
                ? 'Платёж отменён'
                : 'Платёж не найден';
          }
        } catch (e) {
          loggy.warning('payment poll failed (will retry): $e');
        } finally {
          pollInFlight.value = false;
        }
      });
    }

    Future<void> openPaymentPage(String url) async {
      if (PlatformUtils.isAndroid) {
        await Navigator.of(context, rootNavigator: true).push<bool>(
          MaterialPageRoute(builder: (_) => PaymentWebViewPage(url: url)),
        );
      } else {
        await UriUtils.tryLaunch(Uri.parse(url));
      }
    }

    Future<void> cancelWaiting() async {
      final p = pending.value;
      stopPolling();
      // Спрашиваем сервер до очистки: кнопка отменяет ОЖИДАНИЕ, а не платёж.
      // Её жмут и после успешной оплаты — опрос мог не успеть тикнуть или
      // моргнула сеть. Гость без Telegram-аккаунта после очистки prefs теряет
      // и sub_url, и claim_url, восстановить их неоткуда.
      if (p != null) {
        try {
          final st = await ref
              .read(accountApiProvider)
              .getPaymentStatus(p.pid, sessionToken: sessionToken);
          if (st['status'] == 'succeeded') {
            if (!context.mounted) return;
            await onPaymentSucceeded(st);
            return;
          }
        } catch (e) {
          // Сервер недоступен — отменяем как просили, платёж остаётся на
          // сервере и подтянется при следующей покупке или через /me.
          loggy.warning('cancel: status check failed, clearing anyway: $e');
        }
      }
      await clearPending();
      if (!context.mounted) return;
      paying.value = false;
      busyIdx.value = null;
      pollTimedOut.value = false;
      payError.value = null;
    }

    Future<void> continuePayment() async {
      final p = pending.value;
      if (p == null) return;
      payError.value = null;
      pollTimedOut.value = false;
      startPolling(p.pid);
      final url = p.url;
      if (url == null || url.isEmpty) return;
      if (!context.mounted) return;
      await openPaymentPage(url);
    }

    Future<void> checkAgain() async {
      final p = pending.value;
      if (p == null) return;
      payError.value = null;
      pollTimedOut.value = false;
      startPolling(p.pid);
    }

    // ── загрузка каталога и подхват незавершённой оплаты ─────────────────
    useEffect(
      () {
        var disposed = false;
        Future<void>(() async {
          try {
            final api = ref.read(accountApiProvider);
            final res = await api.getTariffs();
            if (disposed) return;
            final list = (res['tariffs'] as List? ?? [])
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            tariffs.value = list;
          } catch (e) {
            if (!disposed) loadError.value = _describeError(e);
          }
        });

        Future<void>(() {
          final prefs = ref.read(sharedPreferencesProvider).requireValue;
          final stored = _readValidPending(prefs);
          if (stored == null || disposed) {
            if (stored == null) {
              ref.read(pendingPaymentProvider.notifier).state = null;
            }
            return;
          }
          ref.read(pendingPaymentProvider.notifier).state = stored;
          if (disposed) return;
          pending.value = stored;
          startPolling(stored.pid);
        });

        return () {
          disposed = true;
          pollTimer.value?.cancel();
        };
      },
      const [],
    );

    // ── покупка ──────────────────────────────────────────────────────────
    Future<void> buy(int idx) async {
      if (paying.value || hasPending) return;
      paying.value = true;
      busyIdx.value = idx;
      payError.value = null;
      pollTimedOut.value = false;
      try {
        final api = ref.read(accountApiProvider);
        final created = await api.createPayment(
          tariffIdx: idx,
          sessionToken: sessionToken,
        );

        if (!context.mounted) return;

        if (created['status'] == 'succeeded') {
          await onPaymentSucceeded(created);
          return;
        }

        final url = created['payment_url'] as String?;
        final pid = created['payment_id'] as String?;
        if (url == null || pid == null) {
          throw Exception(created['error'] ?? 'Не удалось создать платёж');
        }

        final stored = PendingPayment(
          pid: pid,
          url: url,
          ts: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
        await savePending(stored);
        if (!context.mounted) return;

        startPolling(pid);
        await openPaymentPage(url);
      } catch (e) {
        if (!context.mounted) return;
        paying.value = false;
        busyIdx.value = null;
        payError.value = _describeError(e);
      }
    }

    // ── экран «оплачено» ─────────────────────────────────────────────────
    if (subUrl.value != null) {
      final hint = imported.value
          ? 'Ссылка на подписку добавлена в профили. Если профиль не появился — '
              'скопируйте ссылку и добавьте вручную.'
          : 'Скопируйте ссылку и добавьте её в профили вручную.';
      final claim = claimUrl.value;

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.green, size: 26),
                  const SizedBox(width: 10),
                  Text('Подписка активна', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 12),
              Text(hint, style: theme.textTheme.bodySmall),
              if (claim != null && claim.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Чтобы привязать покупку к Telegram-аккаунту, откройте ссылку ниже.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 12),
              SelectableText(
                subUrl.value!,
                maxLines: 2,
                style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: subUrl.value!));
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Скопировать'),
                  ),
                  if (claim != null && claim.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => UriUtils.tryLaunch(Uri.parse(claim)),
                      icon: const Icon(Icons.link_rounded, size: 18),
                      label: const Text('Привязать'),
                    ),
                  ],
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Готово'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // ── список тарифов (+ recovery незавершённой оплаты) ─────────────────
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Продлить подписку', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              sessionToken == null
                  ? 'После оплаты придёт ссылка на подписку'
                  : 'Оплата привяжется к вашему аккаунту',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (hasPending) ...[
              const SizedBox(height: 16),
              _PendingRecoveryCard(
                paying: paying.value,
                timedOut: pollTimedOut.value,
                hasUrl: pending.value?.url?.isNotEmpty == true,
                onContinue: continuePayment,
                onCheckAgain: checkAgain,
                onCancel: cancelWaiting,
              ),
            ],
            const SizedBox(height: 16),
            if (loadError.value != null)
              _ErrorRow(text: 'Не удалось загрузить тарифы. ${loadError.value}')
            else if (tariffs.value == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: tariffs.value!.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final t = tariffs.value![i];
                    final idx = (t['idx'] as num).toInt();
                    final busy = busyIdx.value == idx;
                    return _TariffTile(
                      name: '${t['name']}',
                      price: '${t['price']} ₽',
                      telemost: t['telemost'] == true,
                      busy: busy,
                      enabled: !paying.value && !hasPending,
                      onTap: () => buy(idx),
                    );
                  },
                ),
              ),
            if (payError.value != null) ...[
              const SizedBox(height: 12),
              _ErrorRow(text: payError.value!),
            ],
          ],
        ),
      ),
    );
  }
}

class _PendingRecoveryCard extends StatelessWidget {
  const _PendingRecoveryCard({
    required this.paying,
    required this.timedOut,
    required this.hasUrl,
    required this.onContinue,
    required this.onCheckAgain,
    required this.onCancel,
  });

  final bool paying;
  final bool timedOut;
  final bool hasUrl;
  final VoidCallback onContinue;
  final VoidCallback onCheckAgain;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = paying && !timedOut;
    // Пока опрос идёт, это штатное ожидание, а не проблема: карточку видит и
    // тот, кто просто вернулся из WebView и ждёт подтверждения.
    final title = waiting ? 'Ожидаем оплату' : 'Оплата не завершена';
    final subtitle = timedOut
        ? 'Ожидание истекло — проверьте статус или откройте оплату снова.'
        : paying
            ? (PlatformUtils.isAndroid
                ? 'Ждём подтверждение. Можно снова открыть страницу оплаты.'
                : 'Ждём оплату в браузере. После оплаты вернитесь сюда.')
            : 'Есть незавершённый платёж.';

    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (waiting) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ] else ...[
                  Icon(Icons.pending_actions_rounded, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(title, style: theme.textTheme.labelLarge),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (hasUrl)
                  FilledButton.tonal(
                    onPressed: onContinue,
                    child: const Text('Продолжить оплату'),
                  ),
                if (timedOut || !paying)
                  OutlinedButton(
                    onPressed: onCheckAgain,
                    child: const Text('Проверить снова'),
                  ),
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Отменить ожидание'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Turns an exception into something a buyer can act on. A raw
/// `DioException [bad response]: …` in the sheet tells the user nothing.
/// 429 on `/payment/status` is rare now (limit keyed by `pid`), but creation
/// and tariffs still rate-limit by Authorization/IP — show a clear retry hint.
String _describeError(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code == 429) {
      return 'Сервер занят, попробуйте через минуту.';
    }
    final data = e.response?.data;
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    if (code != null) {
      return 'Сервер ответил ошибкой ($code).';
    }
    return 'Нет связи с сервером. Проверьте подключение.';
  }
  return '$e';
}

class _TariffTile extends StatelessWidget {
  const _TariffTile({
    required this.name,
    required this.price,
    required this.telemost,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final String name;
  final String price;
  final bool telemost;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: theme.textTheme.labelLarge),
                    if (telemost) ...[
                      const SizedBox(height: 2),
                      Text(
                        'с доступом к Telemost',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(price, style: theme.textTheme.titleSmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 18, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
          ),
        ),
      ],
    );
  }
}
