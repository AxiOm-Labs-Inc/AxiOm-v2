import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Payment page shown inside the app, so buying a subscription no longer
/// throws the user out into a browser.
///
/// Only used where a webview exists: `webview_flutter` supports Android, iOS
/// and macOS, but not Windows or Linux — desktop builds keep opening the
/// payment page in the system browser (see [PurchaseSheet]).
///
/// Closing is driven by two independent signals, because neither alone is
/// reliable: the payment provider redirects to our return URL on success
/// (caught here), and the sheet keeps polling the payment status anyway. If
/// the redirect never happens — the user pays and closes the page by hand —
/// polling still reports success.
class PaymentWebViewPage extends StatefulWidget {
  const PaymentWebViewPage({super.key, required this.url});

  final String url;

  @override
  State<PaymentWebViewPage> createState() => _PaymentWebViewPageState();
}

class _PaymentWebViewPageState extends State<PaymentWebViewPage> {
  late final WebViewController _controller;
  int _progress = 0;

  /// Marker our return URL carries after a successful payment.
  static const _paidMarker = 'paid=1';

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
            if (request.url.contains(_paidMarker)) {
              // Оплата прошла — возвращаемся в приложение, не показывая
              // страницу возврата: подписку всё равно подтвердит опрос статуса.
              Navigator.of(context).maybePop(true);
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
