import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/adaptive_layout/shell_route_action.dart';
import 'package:hiddify/core/router/go_router/routing_config_notifier.dart';
import 'package:hiddify/core/widget/axiom_branding.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class MyAdaptiveLayout extends HookConsumerWidget {
  const MyAdaptiveLayout({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final primaryFocusHash = useState<int?>(null);
    final navScopeNode = useFocusScopeNode();
    useEffect(() {
      bool handler(KeyEvent event) {
        if (!KeyboardConst.verticalArrows.contains(event.logicalKey)) return false;
        if (event is KeyDownEvent) {
          primaryFocusHash.value = FocusManager.instance.primaryFocus.hashCode;
        } else {
          if (primaryFocusHash.value == FocusManager.instance.primaryFocus.hashCode) {
            if (branchesScope.values.any((node) => node.hasFocus)) {
              navScopeNode.requestFocus();
            } else if (navScopeNode.hasFocus) {
              branchesScope[getNameOfBranch(navigationShell.currentIndex)]?.requestFocus();
            }
          }
        }
        return true;
      }

      HardwareKeyboard.instance.addHandler(handler);
      return () {
        HardwareKeyboard.instance.removeHandler(handler);
      };
    }, [navigationShell.currentIndex]);

    return Material(
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: FocusScope(
          node: navScopeNode,
          child: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            destinations: _navDests(_actions(t)),
            onDestinationSelected: (index) => _onTap(context, index),
          ),
        ),
      ),
    );
  }

  void _onTap(BuildContext context, int index) {
    navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);
  }

  List<ShellRouteAction> _actions(Translations t) => [
    ShellRouteAction(
      icon: const AxiOmLogoIcon(size: 24),
      selectedIcon: const AxiOmLogoIcon(size: 24),
      title: t.common.appTitle,
    ),
    ShellRouteAction.material(Icons.video_call_rounded, t.pages.telemost.title),
    ShellRouteAction.material(Icons.view_list_rounded, t.pages.profiles.title),
    ShellRouteAction.material(Icons.settings_rounded, t.pages.settings.title),
  ];

  List<NavigationDestination> _navDests(List<ShellRouteAction> actions) => actions
      .map(
        (action) => NavigationDestination(
          icon: action.icon,
          selectedIcon: action.selectedIcon ?? action.icon,
          label: action.title,
        ),
      )
      .toList();
}
