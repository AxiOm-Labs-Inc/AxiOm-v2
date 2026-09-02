import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Payment page shown inside the app on Android, so buying a subscription
/// no longer throws the user out into a browser.
///
/// Target platforms for AxiOm payment UX: **Android** (this WebView) and
/// **Windows** (system browser from [PurchaseSheet]). iOS is out of scope.
///
/// Closing is driven by two independent signals, because neither alone is
/// reliable: the payment provider redirects to our return URL on success
/// (caught here), and the sheet keeps polling the payment status anyway. If
/// the redirect never happens — the user pays and closes the page by hand —
/// polling still reports success.
///
/// Non-http(s) navigation is handed to the OS: SBP and bank apps are reached
/// through custom schemes (sbolpay:, bank1000000…:, intent:) that a WebView
/// cannot render — left to itself it shows an error page and the payment dies
/// there.
class PaymentWebViewPage extends StatefulWidget {
  const PaymentWebViewPage({super.key, required this.url});

  final String url;

  @override
  State<PaymentWebViewPage> createState() => _PaymentWebViewPageState();
}

class _PaymentWebViewPageState extends State<PaymentWebViewPage> {
  late final WebViewController _controller;
  int _progress = 0;

  /// Marker our return URL carries after a successful payment. Matched as a
  /// query parameter rather than a substring: `paid=1` anywhere in a payment
  /// provider URL would otherwise close the page mid-flow.
  static bool _isPaidReturn(Uri uri) => uri.queryParameters['paid'] == '1';

  /// Opens a non-http(s) URL with the system handler. [canLaunchUrl] is
  /// deliberately not consulted: without a `<queries>` manifest entry per
  /// scheme it answers false on Android 11+, and listing every bank app is
  /// not maintainable.
  Future<void> _launchExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('payment: cannot open external scheme [$uri]: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onNavigationRequest: (request) {
            if (!mounted) return NavigationDecision.navigate;
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.navigate;

            if (_isPaidReturn(uri)) {
              // Оплата прошла — возвращаемся в приложение, не показывая
              // страницу возврата: подписку всё равно подтвердит опрос статуса.
              Navigator.of(context).maybePop(true);
              return NavigationDecision.prevent;
            }
            // СБП и приложения банков: схема не http(s) — отдаём системе,
            // WebView такую ссылку открыть не может.
            if (uri.scheme != 'http' && uri.scheme != 'https') {
              unawaited(_launchExternal(uri));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Оплата'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Закрыть',
          onPressed: () => Navigator.of(context).maybePop(false),
        ),
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              )
            : null,
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
