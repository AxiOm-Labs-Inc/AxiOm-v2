import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hiddify/features/telemost_tunnel/data/yandex_auth_storage.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Yandex login page: a WebView on telemost.yandex.ru (its «Войти» button
/// leads through passport.yandex.ru and lands the session cookies on
/// .yandex.ru). Polls the CookieManager for `Session_id`; once it appears,
/// the whole .yandex.ru cookie set is stored in secure storage and the page
/// pops with `true`.
class YandexLoginPage extends HookConsumerWidget with PresLogger {
  const YandexLoginPage({super.key});

  static const _startUrl = 'https://telemost.yandex.ru';
  static const _cookieUrls = [
    'https://telemost.yandex.ru',
    'https://cloud-api.yandex.ru',
    'https://passport.yandex.ru',
  ];
  static const _pollInterval = Duration(milliseconds: 1500);
  static const _loginTimeout = Duration(minutes: 3);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cookieManager = useMemoized(CookieManager.instance);
    final timedOut = useState(false);
    final saving = useState(false);

    /// Collects .yandex.ru cookies across the relevant hosts. Returns the
    /// deduplicated list, or null when Session_id is not there yet.
    Future<List<YandexCookie>?> extractCookies() async {
      final byName = <String, YandexCookie>{};
      for (final url in _cookieUrls) {
        try {
          final cookies = await cookieManager.getCookies(url: WebUri(url));
          for (final cookie in cookies) {
            final domain = cookie.domain ?? '';
            if (!domain.contains('yandex')) continue;
            byName[cookie.name] = YandexCookie(name: cookie.name, value: cookie.value?.toString() ?? '');
          }
        } catch (e) {
          loggy.debug('cookie read failed for $url: $e');
        }
      }
      if (!byName.containsKey('Session_id')) return null;
      return byName.values.toList();
    }

    Future<void> finish(BuildContext context) async {
      final cookies = await extractCookies();
      if (cookies == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Вход пока не обнаружен — войдите в аккаунт')),
          );
        }
        return;
      }
      saving.value = true;
      await ref.read(yandexAuthStorageProvider).saveCookies(cookies);
      if (context.mounted) Navigator.of(context).pop(true);
    }

    // Poll for Session_id until it appears or the timeout hits.
    useEffect(() {
      var elapsed = Duration.zero;
      final timer = Timer.periodic(_pollInterval, (timer) async {
        elapsed += _pollInterval;
        if (elapsed >= _loginTimeout) {
          timer.cancel();
          timedOut.value = true;
          return;
        }
        final cookies = await extractCookies();
        if (cookies != null) {
          timer.cancel();
          saving.value = true;
          await ref.read(yandexAuthStorageProvider).saveCookies(cookies);
          if (context.mounted) Navigator.of(context).pop(true);
        }
      });
      return timer.cancel;
    }, []);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Вход в Яндекс'),
        actions: [
          if (saving.value)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton(
              onPressed: () => finish(context),
              child: const Text('Готово'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (timedOut.value)
            MaterialBanner(
              content: const Text('Время ожидания вышло. Войдите и нажмите «Готово».'),
              actions: [
                TextButton(
                  onPressed: () => timedOut.value = false,
                  child: const Text('ОК'),
                ),
              ],
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_startUrl)),
              initialSettings: InAppWebViewSettings(),
            ),
          ),
        ],
      ),
    );
  }
}
