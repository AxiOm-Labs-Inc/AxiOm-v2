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

/// Bottom-sheet for buying or renewing a subscription without leaving the app.
///
/// Shown when the subscription has already expired (while still-active “few
/// days left” banners still open the Telegram sales bot). The app asks the
/// backend for the tariff list, creates a payment and opens only the payment
/// page itself, then polls until the subscription is issued.
///
/// Supported payment UX: Android (in-app WebView) and Windows (system browser).
/// iOS is out of scope. See `docs/in-app-payment.md`.
///
/// The tariff list is deliberately **not** hardcoded: prices and plans change,
/// and a shipped build cannot be updated for everyone at once — a hardcoded
/// price would disagree with what is actually charged.
///
/// A payment in flight is persisted (see [_pendingPaymentKey]) before the
/// payment page opens. The sheet is a modal bottom sheet: one swipe closes it,
/// and without persistence the poll would die with it — money taken, sub_url
/// never shown, and for a guest with no Telegram account nowhere to recover it
/// from. On the next open the sheet resumes the poll instead.
class PurchaseSheet extends HookConsumerWidget with PresLogger {
  const PurchaseSheet({super.key});

  /// Payment in flight: {"pid": ..., "ts": epochSeconds}.
  static const _pendingPaymentKey = 'pending_payment';

  /// How long a stored payment is still worth polling. The provider keeps an
  /// unpaid payment alive for about a day; beyond that the record is noise.
  static const _pendingTtl = Duration(hours: 24);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final tariffs = useState<List<Map<String, dynamic>>?>(null);
    final loadError = useState<String?>(null);
    final busyIdx = useState<int?>(null); // тариф, по которому идёт оплата
    final paying = useState(false);
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

    Future<void> clearPending() async {
      await ref.read(sharedPreferencesProvider).requireValue.remove(_pendingPaymentKey);
    }

    Future<void> onPaymentSucceeded(Map<String, dynamic> payload) async {
      await clearPending();
      final url = payload['sub_url'] as String?;
      final claim = payload['claim_url'] as String?;
      final ok = url != null && url.isNotEmpty && await importSubUrl(url);
      // Лист могли закрыть, пока шёл импорт: писать в хуки после этого нельзя.
      if (!context.mounted) return;
      subUrl.value = url;
      claimUrl.value = claim;
      imported.value = ok;
      paying.value = false;
      busyIdx.value = null;
      await ref.read(accountNotifierProvider.notifier).refresh();
    }

    // Опрос статуса: оплата часто завершается молча — webview закрывают руками,
    // из браузера возвращаются без колбэка. Событию доверять нельзя, поэтому
    // спрашиваем сервер.
    void startPolling(String pid) {
      final api = ref.read(accountApiProvider);
      var elapsed = 0;
      pollTimer.value?.cancel();
      pollInFlight.value = false;
      paying.value = true;
      pollTimer.value = Timer.periodic(const Duration(seconds: 3), (t) async {
        if (pollInFlight.value) return;
        elapsed += 3;
        if (elapsed > 15 * 60) {
          t.cancel();
          if (!context.mounted) return;
          paying.value = false;
          busyIdx.value = null;
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

        // Платёж, начатый в прошлый раз: лист закрыли до подтверждения.
        Future<void>(() async {
          final prefs = ref.read(sharedPreferencesProvider).requireValue;
          final raw = prefs.getString(_pendingPaymentKey);
          if (raw == null || disposed) return;
          String pid;
          int ts;
          try {
            final m = jsonDecode(raw) as Map<String, dynamic>;
            pid = m['pid'] as String;
            ts = (m['ts'] as num).toInt();
          } catch (e) {
            await prefs.remove(_pendingPaymentKey);
            return;
          }
          final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - ts;
          if (age < 0 || age > _pendingTtl.inSeconds) {
            await prefs.remove(_pendingPaymentKey);
            return;
          }
          if (disposed) return;
          startPolling(pid);
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
      if (paying.value) return;
      paying.value = true;
      busyIdx.value = idx;
      payError.value = null;
      try {
        final api = ref.read(accountApiProvider);
        final created = await api.createPayment(
          tariffIdx: idx,
          sessionToken: sessionToken,
        );

        // Лист могли закрыть, пока шёл запрос: и context, и состояние хуков
        // после этого трогать нельзя.
        if (!context.mounted) return;

        // Скидка 100%: подписка выдаётся сразу, платить нечего.
        if (created['status'] == 'succeeded') {
          await onPaymentSucceeded(created);
          return;
        }

        final url = created['payment_url'] as String?;
        final pid = created['payment_id'] as String?;
        if (url == null || pid == null) {
          throw Exception(created['error'] ?? 'Не удалось создать платёж');
        }

        // Запоминаем ДО открытия оплаты: дальше лист может не пережить
        // возврата в приложение, а платёж уже существует.
        await ref.read(sharedPreferencesProvider).requireValue.setString(
              _pendingPaymentKey,
              jsonEncode({
                'pid': pid,
                'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
              }),
            );
        if (!context.mounted) return;

        // Опрос до открытия оплаты: на Android пользователь может уйти в
        // приложение банка (СБП) надолго, пока await WebView ещё не вернулся.
        // Без раннего опроса статус не подтянется, пока не закроют экран оплаты.
        startPolling(pid);

        // Android: страница оплаты во встроенном WebView.
        // Windows: системный браузер (webview_flutter под Windows нет).
        // iOS не в scope продукта — WebView оплаты для него не используем.
        if (PlatformUtils.isAndroid) {
          await Navigator.of(context, rootNavigator: true).push<bool>(
            MaterialPageRoute(builder: (_) => PaymentWebViewPage(url: url)),
          );
        } else {
          await UriUtils.tryLaunch(Uri.parse(url));
        }
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

    // ── список тарифов ───────────────────────────────────────────────────
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
                      enabled: !paying.value,
                      onTap: () => buy(idx),
                    );
                  },
                ),
              ),
            if (payError.value != null) ...[
              const SizedBox(height: 12),
              _ErrorRow(text: payError.value!),
            ],
            if (paying.value) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      PlatformUtils.isAndroid
                          ? 'Ждём подтверждение оплаты.'
                          : 'Ждём оплату. Страница оплаты открылась в браузере — '
                              'после оплаты вернитесь сюда.',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ],
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
