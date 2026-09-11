import 'package:flutter/material.dart';
import 'package:axiom/core/localization/translations.dart';
import 'package:axiom/features/home/widget/server_selector_card.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxiesOverviewPage extends HookConsumerWidget {
  const ProxiesOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.proxies.title),
      ),
      body: const SingleChildScrollView(
        child: ServerSelectorCard(expanded: true),
      ),
    );
  }
}
