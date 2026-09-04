import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/account/model/account_models.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/account/widget/payment_webview_page.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/overview/profiles_notifier.dart';
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
    final promoController = useTextEditingController();
    // null = «пользователь ещё не выбирал»; подставляем значение по
    // умолчанию при отрисовке, когда каталог уже загружен.
    final termDays = useState<int?>(null);
    final limitKind = useState<_LimitKind?>(null);
    final promoOpen = useState(false);

    final accountState = ref.watch(accountNotifierProvider);
    final sessionToken = accountState is AccountStateConnected
        ? accountState.session.sessionToken
        : null;
    // Лист открывают и для покупки с нуля, и для продления. Во втором случае
    // «осталось N дней» — единственный контекст, которого здесь не хватало:
    // без него непонятно, к чему именно прибавится новый срок.
    final current = accountState is AccountStateConnected
        ? _longestRunning(accountState.subscriptions)
        : null;

    final hasPending = pending.value != null;

    Future<bool> importSubUrl(String url) async {
      final repo = ref.read(profileRepositoryProvider).valueOrNull;
      if (repo == null) return false;
      final ok = await repo.upsertRemote(url).match(
        (err) {
          loggy.warning('post-payment profile import failed: $err');
          return false;
        },
        (_) => true,
      ).run();
      if (!ok) return false;
      try {
        final entry = await ref.read(profileDataSourceProvider).getByUrl(url);
        if (entry != null) {
          await ref.read(profilesNotifierProvider.notifier).selectActiveProfile(entry.id);
        }
      } catch (e) {
        loggy.warning('mark profile active after purchase failed: $e');
      }
      return true;
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
      if ((url == null || url.isEmpty) && payload['owned'] == true) {
        // Платёж оплачен, но закреплён за другим Telegram-аккаунтом: сервер
        // отдаёт ссылку подписки только владельцу (знать id платежа мало).
        // Без этой ветки экран «оплачено» не показывался бы вовсе — subUrl
        // остаётся null, и лист молча возвращается к списку тарифов.
        if (!context.mounted) return;
        paying.value = false;
        busyIdx.value = null;
        pollTimedOut.value = false;
        payError.value = 'Оплата прошла, но подписка привязана к другому '
            'Telegram-аккаунту. Войдите под ним или напишите в поддержку.';
        await ref.read(accountNotifierProvider.notifier).refresh();
        return;
      }
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
        final promo = promoController.text.trim();
        final created = await api.createPayment(
          tariffIdx: idx,
          promo: promo.isEmpty ? null : promo,
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
          ? 'Подписка добавлена в профили и выбрана активной — если VPN был '
              'включён, соединение переподключилось на неё. Если профиль не '
              'появился, скопируйте ссылку и добавьте вручную.'
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

    // ── выбор тарифа (+ recovery незавершённой оплаты) ───────────────────
    //
    // Каталог приходит с сервера плоским списком (тариф × срок × тип лимита),
    // как его отдаёт /api/app/tariffs. Раскладываем его обратно в две оси —
    // срок и вид ограничения — и показываем только те тарифы, что попали в
    // выбранную ячейку. Плоский список из восьми строк заставлял сравнивать
    // «Эконом 3 месяца · 210 ГБ/мес» с «Стандарт 1 месяц · 15 устройств», то
    // есть по двум различиям сразу.
    final catalog = tariffs.value == null ? null : _Catalog.from(tariffs.value!);
    // Значение по умолчанию считаем здесь, а не пишем в useState: запись
    // состояния во время build запрещена, а «не выбрано» и «выбрано то же
    // самое» для отрисовки неразличимы.
    final days = termDays.value ??
        (catalog != null && catalog.terms.isNotEmpty ? catalog.terms.last : 0);
    final kind = limitKind.value ??
        (catalog != null && catalog.limits.isNotEmpty
            ? catalog.limits.first
            : _LimitKind.devices);
    final shown = catalog?.select(days, kind) ?? const <_Plan>[];
    final interactive = !paying.value && !hasPending;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Тариф', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              sessionToken == null
                  ? 'После оплаты придёт ссылка на подписку'
                  : 'Оплата привяжется к вашему аккаунту',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (current != null) ...[
              const SizedBox(height: 14),
              _CurrentSubscriptionStrip(sub: current),
            ],
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
            const SizedBox(height: 18),
            if (loadError.value != null)
              _ErrorRow(text: 'Не удалось загрузить тарифы. ${loadError.value}')
            else if (catalog == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (catalog.terms.length > 1) ...[
                _Segmented<int>(
                  label: 'Срок',
                  value: days,
                  enabled: interactive,
                  onChanged: (v) => termDays.value = v,
                  options: [
                    for (final d in catalog.terms)
                      (
                        value: d,
                        text: _termLabel(d),
                        hint: catalog.isBestValue(d, kind) ? 'выгоднее' : null,
                      ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (catalog.limits.length > 1) ...[
                _Segmented<_LimitKind>(
                  label: 'Ограничение — выбираете одно',
                  value: kind,
                  enabled: interactive,
                  onChanged: (v) => limitKind.value = v,
                  options: [
                    for (final l in catalog.limits)
                      (value: l, text: l.label, hint: null),
                  ],
                ),
                const SizedBox(height: 18),
              ],
              if (shown.isEmpty)
                Text(
                  'Для этого сочетания срока и ограничения тарифа нет.',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (var i = 0; i < shown.length; i++) ...[
                  _PlanCard(
                    plan: shown[i],
                    // Дороже — выше и с акцентом. Порядок задаёт select().
                    featured: i == 0 && shown.length > 1,
                    anchor: catalog.anchorPrice(shown[i]),
                    cheaper: i == 0 && shown.length > 1 ? shown[1] : null,
                    richer: i > 0 ? shown.first : null,
                    telemostElsewhere: catalog.anyTelemost,
                    busy: busyIdx.value == shown[i].idx,
                    enabled: interactive,
                    onTap: () => buy(shown[i].idx),
                  ),
                  if (i != shown.length - 1) const SizedBox(height: 12),
                ],
            ],
            if (!hasPending) ...[
              const SizedBox(height: 14),
              // Промокод спрятан за ссылкой намеренно: открытое поле «введите
              // код» отправляет человека искать код на стороне вместо оплаты.
              if (!promoOpen.value)
                Center(
                  child: TextButton.icon(
                    onPressed: paying.value ? null : () => promoOpen.value = true,
                    icon: const Icon(Icons.local_offer_outlined, size: 18),
                    label: const Text('У меня есть промокод'),
                  ),
                )
              else
                TextField(
                  controller: promoController,
                  enabled: !paying.value,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Промокод',
                    hintText: 'Введите до оплаты',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    isDense: true,
                    prefixIcon: const Icon(Icons.local_offer_outlined, size: 20),
                  ),
                ),
            ],
            if (payError.value != null) ...[
              const SizedBox(height: 12),
              _ErrorRow(text: payError.value!),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: Text(
                'Оплата картой или через СБП · подписка активируется сразу\n'
                'Автосписаний нет — продление только вручную',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
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
    // Тело приходит то распарсенным, то строкой (см. AccountApi._decode), а в
    // нём лежит причина отказа — например «Код недействителен или исчерпан»
    // на промокод. Без разбора строки пользователь увидел бы только номер.
    var data = e.response?.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
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

/// Вид ограничения. Тарифы продаются парами: либо лимит по устройствам с
/// безлимитным трафиком, либо лимит по трафику без счёта устройств.
enum _LimitKind {
  devices('По устройствам'),
  traffic('По трафику');

  const _LimitKind(this.label);
  final String label;
}

class _Feature {
  const _Feature(this.text, {this.sub = false});
  final String text;

  /// Вложенный пункт («• XHTTP + TLS …» под «4 способа подключения»).
  final bool sub;
}

/// Один тариф каталога, разобранный на оси, по которым его выбирают.
class _Plan {
  const _Plan({
    required this.idx,
    required this.tier,
    required this.days,
    required this.gb,
    required this.ipLimit,
    required this.price,
    required this.telemost,
    required this.rawFeatures,
  });

  factory _Plan.fromJson(Map<String, dynamic> j) {
    final name = '${j['name'] ?? ''}';
    // Имя приходит как «Стандарт — 3 месяца · 15 устройств»: до тире — линейка,
    // после — то, что мы и так знаем из days/ip_limit/gb. Берём только линейку;
    // если тире вдруг не окажется, показываем имя целиком, а не пустую строку.
    final dash = name.indexOf('—');
    final tier = dash > 0 ? name.substring(0, dash).trim() : name.trim();
    return _Plan(
      idx: (j['idx'] as num?)?.toInt() ?? 0,
      tier: tier.isEmpty ? name : tier,
      days: (j['days'] as num?)?.toInt() ?? 0,
      gb: (j['gb'] as num?)?.toInt() ?? 0,
      ipLimit: (j['ip_limit'] as num?)?.toInt() ?? 0,
      price: (j['price'] as num?)?.toInt() ?? 0,
      telemost: j['telemost'] == true,
      rawFeatures: (j['features'] as List? ?? const [])
          .map((e) => '$e')
          .toList(growable: false),
    );
  }

  final int idx;
  final String tier;
  final int days;
  final int gb;
  final int ipLimit;
  final int price;
  final bool telemost;
  final List<String> rawFeatures;

  int get months => math.max(1, (days / 30).round());

  int get pricePerMonth => (price / months).round();

  _LimitKind get limit =>
      ipLimit > 0 ? _LimitKind.devices : _LimitKind.traffic;

  /// Строка ограничения — считаем сами, а не берём из features: она же
  /// определяет, в какую колонку переключателя попал тариф, и расходиться
  /// с ней нельзя.
  String get limitLine {
    if (limit == _LimitKind.devices) {
      final tail = gb > 0 ? '$gb ГБ' : 'трафик безлимитный';
      return 'До $ipLimit ${_plural(ipLimit, 'устройства', 'устройств', 'устройств')}, $tail';
    }
    final perMonth = months > 1 ? (gb / months).round() : gb;
    final suffix = months > 1 ? ' в месяц' : '';
    return '$perMonth ГБ$suffix, устройства без ограничений';
  }

  /// Маркеры пунктов, которые дублируют то, что карточка уже посчитала:
  /// трафик, устройства и цену за месяц. Если в конфиге поменяют эмодзи,
  /// худшее, что случится, — строка покажется дважды.
  static const _computedMarks = ['♾', '📊', '📱', '💰'];

  List<_Feature> get features {
    final out = <_Feature>[];
    for (final raw in rawFeatures) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (_computedMarks.any(t.startsWith)) continue;
      final sub = t.startsWith('•');
      final text = t.replaceFirst(RegExp('^[^0-9A-Za-zА-Яа-яЁё]+'), '').trim();
      if (text.isEmpty) continue;
      out.add(_Feature(text, sub: sub));
    }
    return out;
  }
}

/// Плоский каталог с сервера, разложенный по осям «срок × вид ограничения».
class _Catalog {
  const _Catalog(this.plans);

  factory _Catalog.from(List<Map<String, dynamic>> raw) =>
      _Catalog(raw.map(_Plan.fromJson).toList());

  final List<_Plan> plans;

  List<int> get terms {
    final list = plans.map((p) => p.days).toSet().toList()..sort();
    return list;
  }

  List<_LimitKind> get limits {
    final list = plans.map((p) => p.limit).toSet().toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return list;
  }

  bool get anyTelemost => plans.any((p) => p.telemost);

  /// Тарифы выбранной ячейки, дороже — первым: верхняя карточка задаёт точку
  /// отсчёта, с которой сравнивают остальные.
  List<_Plan> select(int days, _LimitKind kind) {
    final list =
        plans.where((p) => p.days == days && p.limit == kind).toList()
          ..sort((a, b) => b.price.compareTo(a.price));
    return list;
  }

  /// Сколько стоил бы тот же срок помесячными платежами. Не выдуманная «старая
  /// цена», а реальная сумма из этого же каталога — её и зачёркиваем.
  int? anchorPrice(_Plan plan) {
    final same = plans
        .where((p) => p.tier == plan.tier && p.limit == plan.limit)
        .toList()
      ..sort((a, b) => a.days.compareTo(b.days));
    if (same.isEmpty) return null;
    final shortest = same.first;
    if (shortest.days >= plan.days) return null;
    final anchor = shortest.pricePerMonth * plan.months;
    return anchor > plan.price ? anchor : null;
  }

  /// Срок с самой низкой ценой за месяц — на нём и стоит пометка «выгоднее».
  bool isBestValue(int days, _LimitKind kind) {
    if (terms.length < 2) return false;
    int? best;
    var bestDays = -1;
    for (final d in terms) {
      final list = select(d, kind);
      if (list.isEmpty) continue;
      final cheapest = list.map((p) => p.pricePerMonth).reduce(math.min);
      if (best == null || cheapest < best) {
        best = cheapest;
        bestDays = d;
      }
    }
    return bestDays == days;
  }
}

String _plural(int n, String one, String few, String many) {
  final m10 = n % 10;
  final m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

String _termLabel(int days) {
  if (days > 0 && days % 30 == 0) {
    final m = days ~/ 30;
    return '$m ${_plural(m, 'месяц', 'месяца', 'месяцев')}';
  }
  return '$days ${_plural(days, 'день', 'дня', 'дней')}';
}

typedef _SegOption<T> = ({T value, String text, String? hint});

/// Переключатель-сегмент. SegmentedButton из Material не подошёл: он тянет
/// галочку выбранного пункта и не даёт положить рядом с подписью пометку.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.enabled,
  });

  final String label;
  final List<_SegOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          // Подложка выбранного пункта едет отдельным слоем под подписями:
          // перекраска фона у каждого пункта по очереди читалась как мигание,
          // а не как перемещение выбора.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final selected = options.indexWhere((o) => o.value == value);
              final slot = constraints.maxWidth / options.length;
              return SizedBox(
                height: 36,
                child: Stack(
                  children: [
                    if (selected >= 0)
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOutCubic,
                        left: slot * selected,
                        width: slot,
                        top: 0,
                        bottom: 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: cs.surface,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: cs.outlineVariant),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.16),
                                blurRadius: 5,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        for (final o in options)
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: enabled && o.value != value
                                  ? () => onChanged(o.value)
                                  : null,
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: AnimatedDefaultTextStyle(
                                        duration: const Duration(milliseconds: 240),
                                        curve: Curves.easeOutCubic,
                                        style: theme.textTheme.labelLarge!.copyWith(
                                          color: o.value == value
                                              ? cs.onSurface
                                              : cs.onSurfaceVariant,
                                          fontWeight: o.value == value
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                        child: Text(
                                          o.text,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    if (o.hint != null) ...[
                                      const SizedBox(width: 5),
                                      Text(
                                        o.hint!,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(color: Colors.green.shade600),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Карточка тарифа. Дорогой вариант получает рамку, крупную цену и заливную
/// кнопку, дешёвый — приглушённый вид: разница в весе и есть подсказка, что
/// именно мы предлагаем.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.featured,
    required this.anchor,
    required this.cheaper,
    required this.richer,
    required this.telemostElsewhere,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final _Plan plan;
  final bool featured;
  final int? anchor;

  /// Соседний тариф подешевле — нужен, чтобы показать разницу в день.
  final _Plan? cheaper;

  /// Старший тариф — с ним сравниваем, чтобы показать, чего здесь нет.
  final _Plan? richer;
  final bool telemostElsewhere;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final muted = featured ? cs.onSurface : cs.onSurfaceVariant;
    final saving =
        anchor == null ? null : (100 - plan.price * 100 / anchor!).round();
    final totalLine = '${plan.price} ₽ за ${_termLabel(plan.days)}'
        '${saving != null && saving > 0 ? ' · экономия $saving%' : ''}';
    final other = cheaper;
    final perDay = other == null
        ? 0
        : ((plan.pricePerMonth - other.pricePerMonth) / 30).round();

    final card = Container(
      padding: EdgeInsets.fromLTRB(14, featured ? 16 : 14, 14, 14),
      decoration: BoxDecoration(
        color: featured ? cs.surface : cs.surfaceContainerLow,
        border: Border.all(
          color: featured ? cs.primary : cs.outlineVariant,
          width: featured ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.tier,
                  style: featured
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleSmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              if (anchor != null)
                Text(
                  '$anchor ₽',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // Цена не подменяется, а докручивается до нового значения:
              // при смене срока видно, что изменилось именно число, и в какую
              // сторону. Ключей у карточек нет намеренно — иначе Flutter
              // пересоздал бы элемент и анимации не случилось бы.
              TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: plan.pricePerMonth.toDouble(),
                  end: plan.pricePerMonth.toDouble(),
                ),
                duration: const Duration(milliseconds: 340),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => Text(
                  '${value.round()} ₽',
                  style: (featured
                          ? theme.textTheme.headlineMedium
                          : theme.textTheme.headlineSmall)
                      ?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: featured ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'в месяц',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            child: Text(
              totalLine,
              key: ValueKey(totalLine),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 12),
          _bullet(context, plan.limitLine, muted: muted),
          for (final f in plan.features)
            _bullet(context, f.text, muted: muted, sub: f.sub),
          if (plan.telemost) _bullet(context, 'Доступ в Telemost', muted: muted),
          // Что теряет тот, кто выберет тариф подешевле. Пункты выводим из
          // самого каталога, а не из зашитого списка: пропадёт различие в
          // конфиге — пропадёт и строка.
          if (richer != null)
            for (final gap in _missingVersus(plan, richer!))
              _bullet(context, gap, muted: cs.onSurfaceVariant, absent: true)
          else if (!plan.telemost && telemostElsewhere)
            _bullet(context, 'Без Telemost', muted: cs.onSurfaceVariant, absent: true),
          if (featured && other != null && perDay >= 1)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.trending_up_rounded,
                      size: 16, color: cs.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Это +$perDay ₽ в день к «${other.tier}»',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: cs.onPrimaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          if (featured)
            _PayButton(
              label: 'Оплатить ${plan.price} ₽',
              busy: busy,
              onTap: enabled && !busy ? onTap : null,
            )
          else
            SizedBox(
              width: double.infinity,
              height: 42,
              child: OutlinedButton(
                onPressed: enabled && !busy ? onTap : null,
                child: busy
                    ? _ButtonSpinner(color: cs.primary)
                    : Text('Взять «${plan.tier}» за ${plan.price} ₽'),
              ),
            ),
        ],
      ),
    );

    if (!featured) return card;
    // Ярлык висит на границе карточки, поэтому Stack без обрезки, а отступ
    // сверху отдан родителю — иначе половину ярлыка съест предыдущий элемент.
    return Padding(
      padding: const EdgeInsets.only(top: 11),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          Positioned(
            top: -11,
            left: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                'Рекомендуем',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bullet(
    BuildContext context,
    String text, {
    required Color muted,
    bool sub = false,
    bool absent = false,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(left: sub ? 22 : 0, bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            absent ? Icons.remove_rounded : Icons.check_rounded,
            size: 16,
            color: absent
                ? cs.onSurfaceVariant
                : (featured ? Colors.green.shade600 : cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}

/// Подписка, которая кончится позже остальных: её и продлевают. Тарифов у
/// одного аккаунта может быть несколько, а строка вверху нужна одна.
AccountSubscription? _longestRunning(List<AccountSubscription> subs) {
  AccountSubscription? best;
  for (final s in subs) {
    final days = s.daysLeft;
    if (days == null) continue;
    if (best == null || days > best.daysLeft!) best = s;
  }
  return best;
}

/// Что у покупателя есть прямо сейчас. Формулировки взяты из тех же ключей,
/// что и в карточке подписки на экране профилей (`_daysText` там же), чтобы
/// «Последний день» не превратился в двух местах в разные фразы.
class _CurrentSubscriptionStrip extends ConsumerWidget {
  const _CurrentSubscriptionStrip({required this.sub});

  final AccountSubscription sub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = ref.watch(translationsProvider).requireValue.pages.profiles.account;
    final days = sub.daysLeft!;
    // Три дня — порог, после которого напоминание перестаёт быть справкой и
    // становится поводом действовать.
    final urgent = days <= 3;
    final fg = urgent ? cs.onErrorContainer : cs.onSurfaceVariant;
    final text = days < 0
        ? a.expiredAgo(days: '${-days}')
        : days == 0
            ? a.lastDay
            : days == 1
                ? a.oneDayLeft
                : a.daysLeftLabel(days: '$days');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: urgent ? cs.errorContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            days < 0 ? Icons.error_outline_rounded : Icons.schedule_rounded,
            size: 18,
            color: fg,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sub.tariff.isEmpty ? a.defaultTariff : sub.tariff,
                  style: theme.textTheme.labelSmall?.copyWith(color: fg),
                ),
                const SizedBox(height: 1),
                Text(
                  text,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: urgent ? cs.onErrorContainer : cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Чего в тарифе [cheap] нет по сравнению со старшим [rich]. Считаем по
/// каталогу, а не по зашитому списку: строки-различия живут в config.py, и
/// если там что-то уравняют, пункт исчезнет сам.
///
/// Сравнения намеренно узкие — только то, что различает линейки на деле:
/// страна, число способов подключения и Telemost. Полная разница текстов
/// features дала бы «минус» на строку про серверы целиком, хотя серверы есть
/// в обоих тарифах.
List<String> _missingVersus(_Plan cheap, _Plan rich) {
  final out = <String>[];

  bool mentionsRussia(_Plan p) =>
      p.rawFeatures.any((f) => f.contains('Росси'));
  if (mentionsRussia(rich) && !mentionsRussia(cheap)) {
    out.add('Без сервера в России');
  }

  // Способы подключения перечислены вложенными пунктами; когда их нет,
  // способ ровно один.
  int ways(_Plan p) => math.max(1, p.features.where((f) => f.sub).length);
  final richWays = ways(rich);
  final cheapWays = ways(cheap);
  if (richWays > cheapWays) {
    out.add(cheapWays == 1
        ? 'Один способ подключения вместо $richWays'
        : '$cheapWays ${_plural(cheapWays, 'способ', 'способа', 'способов')} подключения вместо $richWays');
  }

  if (rich.telemost && !cheap.telemost) out.add('Без Telemost');
  return out;
}

/// Кнопка оплаты старшего тарифа. Обычная FilledButton весит ровно столько
/// же, сколько «Взять Эконом» рядом, — а она и есть то действие, ради
/// которого экран открыли.
class _PayButton extends StatelessWidget {
  const _PayButton({required this.label, required this.busy, this.onTap});

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final active = onTap != null;
    // Второй цвет градиента берём из той же схемы, а не подбираем константу:
    // тема собирается из seed-цвета, и захардкоженный оттенок разъехался бы
    // с ней при первой же смене брендового цвета.
    final accent = Color.lerp(cs.primary, cs.tertiary, 0.45)!;

    return Opacity(
      opacity: active ? 1 : 0.55,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, accent],
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.32),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: Center(
                child: busy
                    ? _ButtonSpinner(color: cs.onPrimary)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: cs.onPrimary,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                            color: cs.onPrimary,
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
