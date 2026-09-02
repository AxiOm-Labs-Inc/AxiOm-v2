import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/features/account/model/account_state.dart';
import 'package:hiddify/features/account/notifier/account_notifier.dart';
import 'package:hiddify/features/account/widget/payment_webview_page.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Bottom-sheet for buying or renewing a subscription without leaving the app.
///
/// Before v4.4 the expiry banner sent the user to the Telegram sales bot; the
/// purchase happened outside the app and came back as a link to paste. Here the
/// app asks the backend for the tariff list, creates a payment and opens only
/// the payment page itself, then polls until the subscription is issued.
///
/// The tariff list is deliberately **not** hardcoded: prices and plans change
/// (they were renamed and yearly plans replaced by three-month ones in August),
/// and a shipped build cannot be updated for everyone at once — a hardcoded
/// price would disagree with what is actually charged.
class PurchaseSheet extends HookConsumerWidget with PresLogger {
  const PurchaseSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final tariffs = useState<List<Map<String, dynamic>>?>(null);
    final loadError = useState<String?>(null);
    final busyIdx = useState<int?>(null); // тариф, по которому идёт оплата
    final paying = useState(false);
    final subUrl = useState<String?>(null);
    final payError = useState<String?>(null);
    final pollTimer = useRef<Timer?>(null);

    final accountState = ref.watch(accountNotifierProvider);
    final sessionToken = accountState is AccountStateConnected
        ? accountState.session.sessionToken
        : null;

    // ── загрузка каталога ────────────────────────────────────────────────
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
            if (!disposed) loadError.value = '$e';
          }
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

        // Скидка 100%: подписка выдаётся сразу, платить нечего.
        if (created['status'] == 'succeeded') {
          subUrl.value = created['sub_url'] as String?;
          paying.value = false;
          busyIdx.value = null;
          await ref.read(accountNotifierProvider.notifier).refresh();
          return;
        }

        final url = created['payment_url'] as String?;
        final pid = created['payment_id'] as String?;
        if (url == null || pid == null) {
          throw Exception(created['error'] ?? 'Не удалось создать платёж');
        }
        // Оплата внутри приложения там, где webview существует.
        // webview_flutter умеет android/ios/macos; на windows/linux его нет,
        // и единственный рабочий путь — системный браузер.
        if (PlatformUtils.isMobile) {
          await Navigator.of(context, rootNavigator: true).push<bool>(
            MaterialPageRoute(builder: (_) => PaymentWebViewPage(url: url)),
          );
        } else {
          await UriUtils.tryLaunch(Uri.parse(url));
        }

        // Платёж уходит во внешний браузер, вернуться в приложение может и
        // молча — поэтому опрашиваем статус, а не ждём возврата с колбэком.
        var elapsed = 0;
        pollTimer.value?.cancel();
        pollTimer.value = Timer.periodic(const Duration(seconds: 3), (t) async {
          elapsed += 3;
          if (elapsed > 15 * 60) {
            t.cancel();
            paying.value = false;
            busyIdx.value = null;
            return;
          }
          try {
            final st = await api.getPaymentStatus(pid, sessionToken: sessionToken);
            final status = st['status'];
            if (status == 'succeeded') {
              t.cancel();
              subUrl.value = st['sub_url'] as String?;
              paying.value = false;
              busyIdx.value = null;
              await ref.read(accountNotifierProvider.notifier).refresh();
            } else if (status == 'canceled') {
              t.cancel();
              paying.value = false;
              busyIdx.value = null;
              payError.value = 'Платёж отменён';
            }
          } catch (e) {
            loggy.warning('payment poll failed (will retry): $e');
          }
        });
      } catch (e) {
        paying.value = false;
        busyIdx.value = null;
        payError.value = '$e';
      }
    }

    // ── экран «оплачено» ─────────────────────────────────────────────────
    if (subUrl.value != null) {
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
              Text(
                'Ссылка на подписку добавлена в профили. Если профиль не появился — '
                'скопируйте ссылку и добавьте вручную.',
                style: theme.textTheme.bodySmall,
              ),
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
              _ErrorRow(text: 'Не удалось загрузить тарифы: ${loadError.value}')
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
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final t = tariffs.value![i];
                    final idx = t['idx'] as int;
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
                      PlatformUtils.isMobile
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
