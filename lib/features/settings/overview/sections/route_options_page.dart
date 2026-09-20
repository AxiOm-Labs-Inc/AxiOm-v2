import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:axiom/core/localization/translations.dart';
import 'package:axiom/core/preferences/general_preferences.dart';
import 'package:axiom/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:axiom/features/settings/data/config_option_repository.dart';
import 'package:axiom/features/settings/widget/preference_tile.dart';
import 'package:axiom/singbox/model/singbox_config_enum.dart';
import 'package:axiom/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class RouteOptionsPage extends HookConsumerWidget {
  const RouteOptionsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final perAppProxy = ref.watch(Preferences.perAppProxyMode).enabled;
    return Scaffold(
      appBar: AppBar(title: Text(t.pages.settings.routing.title)),
      body: ListView(
        children: [
          if (PlatformUtils.isAndroid)
            ListTile(
              title: Text(t.pages.settings.routing.perAppProxy.title),
              leading: const Icon(Icons.apps_rounded),
              trailing: Switch(
                value: perAppProxy,
                onChanged: (value) async {
                  final newMode = perAppProxy ? PerAppProxyMode.off : PerAppProxyMode.exclude;
                  await ref.read(Preferences.perAppProxyMode.notifier).update(newMode);
                  if (!perAppProxy && context.mounted) context.goNamed('perAppProxy');
                },
              ),
              onTap: () async {
                if (!perAppProxy) {
                  await ref.read(Preferences.perAppProxyMode.notifier).update(PerAppProxyMode.exclude);
                }
                if (context.mounted) context.goNamed('perAppProxy');
              },
            ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.routing.newRouting),
            subtitle: Text(t.pages.settings.routing.newRoutingMsg),
            secondary: const Icon(Icons.alt_route_rounded),
            value: ref.watch(ConfigOptions.newRoutingEnabled),
            onChanged: ref.read(ConfigOptions.newRoutingEnabled.notifier).update,
          ),
          ChoicePreferenceWidget(
            title: t.pages.settings.routing.balancerStrategy.title,
            icon: Icons.balance_rounded,
            selected: ref.watch(ConfigOptions.balancerStrategy),
            preferences: ref.watch(ConfigOptions.balancerStrategy.notifier),
            choices: BalancerStrategy.values,
            presentChoice: (value) => value.present(t),
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.routing.blockAds),
            secondary: const Icon(Icons.block_rounded),
            value: ref.watch(ConfigOptions.blockAds),
            onChanged: ref.read(ConfigOptions.blockAds.notifier).update,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.routing.bypassLan),
            secondary: const Icon(Icons.call_split_rounded),
            value: ref.watch(ConfigOptions.bypassLan),
            onChanged: ref.read(ConfigOptions.bypassLan.notifier).update,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.routing.resolveDestination),
            secondary: const Icon(Icons.security_rounded),
            value: ref.watch(ConfigOptions.resolveDestination),
            onChanged: ref.read(ConfigOptions.resolveDestination.notifier).update,
          ),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.ipv6Mode),
            preferences: ref.watch(ConfigOptions.ipv6Mode.notifier),
            choices: IPv6Mode.values,
            title: t.pages.settings.routing.ipv6Route,
            icon: Icons.looks_6_rounded,
            presentChoice: (value) => value.present(t),
          ),
        ],
      ),
    );
  }
}
