import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/app_colors.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/widget/axiom_branding.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hiddify/features/account/widget/home_account_banner.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/data/device_count_provider.dart';
import 'package:hiddify/features/home/widget/connection_button.dart';
import 'package:hiddify/features/home/widget/server_selector_card.dart';
import 'package:hiddify/features/home/widget/split_tunneling_card.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_delay_indicator.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';

class HomePage extends HookConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    // final hasAnyProfile = ref.watch(hasAnyProfileProvider);
    final activeProfile = ref.watch(activeProfileProvider);
    final appUpdate = ref.watch(appUpdateNotifierProvider);
    final appInfo = ref.watch(appInfoProvider).valueOrNull;

    // Periodic URL-test every 30 s while connected and the home screen is visible.
    final connectionStatus = ref.watch(connectionNotifierProvider);
    final isConnected = connectionStatus is AsyncData && connectionStatus.value is Connected;
    final proxiesGroup = ref.watch(proxiesOverviewNotifierProvider).valueOrNull;
    final urlTestTag = proxiesGroup?.tag;

    final lifecycle = useAppLifecycleState();
    final isForeground = lifecycle == null || lifecycle == AppLifecycleState.resumed;

    useEffect(() {
      if (!isConnected || !isForeground || urlTestTag == null) return null;
      final timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest(urlTestTag),
      );
      return timer.cancel;
    }, [isConnected, isForeground, urlTestTag]);

    return Scaffold(
      appBar: AppBar(
        title: const AxiOmAppBarTitle(),
        actions: [
          // IconButton(
          //     onPressed: () => const QuickSettingsRoute().push(context),
          //     icon: const Icon(FluentIcons.options_24_filled),
          //     material: (context, platform) => MaterialIconButtonData(
          //           tooltip: t.config.quickSettings,
          //         )),
          // IconButton(
          //     onPressed: () => const AddProfileRoute().push(context),
          //     icon: const Icon(FluentIcons.add_circle_24_filled),
          //     material: (context, platform) => MaterialIconButtonData(
          //           tooltip: t.profile.add.buttonText,
          //         )),
          Semantics(
            key: const ValueKey("profile_quick_settings"),
            label: t.pages.home.quickSettings,
            child: IconButton(
              icon: Icon(Icons.tune_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showQuickSettings(),
            ),
          ),
          const Gap(8),
          Semantics(
            key: const ValueKey("profile_add_button"),
            label: t.pages.profiles.add,
            child: IconButton(
              icon: Icon(Icons.add_rounded, color: theme.colorScheme.primary),
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
            ),
          ),
          const Gap(8),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: const AssetImage('assets/images/world_map.png'), // Replace with your image path
            fit: BoxFit.cover,
            opacity: 0.09,
            colorFilter: theme.brightness == Brightness.dark
                ? ColorFilter.mode(Colors.white.withValues(alpha: .15), BlendMode.srcIn) //
                : ColorFilter.mode(
                    Colors.grey.withValues(alpha: 1),
                    BlendMode.srcATop,
                  ), // Apply white tint in dark mode
          ),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 600, // Set the maximum width here
                ),
                child: CustomScrollView(
                  slivers: [
                    // switch (activeProfile) {
                    // AsyncData(value: final profile?) =>
                    MultiSliver(
                      children: [
                        switch (activeProfile) {
                          AsyncData(value: final profile?) => _ProfileChip(profile: profile),
                          _ => const SizedBox.shrink(),
                        },
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              if (appUpdate case AppUpdateStateAvailable(:final versionInfo))
                                _UpdateBanner(
                                  title: t.pages.home.update.available(version: versionInfo.presentVersion),
                                  subtitle: PlatformUtils.isDesktop
                                      ? t.pages.home.update.clickToUpdate
                                      : t.pages.home.update.tapToUpdate,
                                  onTap: () {
                                    if (appInfo == null) return;
                                    ref.read(dialogNotifierProvider.notifier).showNewVersion(
                                      currentVersion: appInfo.presentVersion,
                                      newVersion: versionInfo,
                                      canIgnore: false,
                                    );
                                  },
                                ),
                              const HomeAccountBanner(),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [ConnectionButton(), ActiveProxyDelayIndicator()],
                                ),
                              ),
                              _StatRow(),
                              const ServerSelectorCard(),
                              const SplitTunnelingCard(),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // AsyncData() => switch (hasAnyProfile) {
                    //     AsyncData(value: true) => const EmptyActiveProfileHomeBody(),
                    //     _ => const EmptyProfilesHomeBody(),
                    //   },
                    // AsyncError(:final error) => SliverErrorBodyPlaceholder(t.presentShortError(error)),
                    // _ => const SliverToBoxAdapter(),
                    // },
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Compact pill showing active profile name — taps open profiles overview
class _ProfileChip extends ConsumerWidget {
  const _ProfileChip({required this.profile});
  final ProfileEntity profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    const activeColor = Color(AppColors.success);

    return GestureDetector(
      onTap: () => ref.read(bottomSheetsNotifierProvider.notifier).showProfilesOverview(),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: theme.colorScheme.outline.withValues(alpha: .3)),
        ),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: profile.active ? activeColor : theme.colorScheme.outlineVariant,
                shape: BoxShape.circle,
                boxShadow: profile.active
                    ? [BoxShadow(color: activeColor.withValues(alpha: .55), blurRadius: 5)]
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

// 4-column stats bar: traffic / days / ping / devices
class _StatRow extends HookConsumerWidget {
  const _StatRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeProfile = ref.watch(activeProfileProvider).valueOrNull;
    final activeProxy = ref.watch(activeProxyNotifierProvider).valueOrNull;
    final theme = Theme.of(context);
    final s = ref.watch(translationsProvider).requireValue.pages.home.stats;

    final subInfo = activeProfile is RemoteProfileEntity ? activeProfile.subInfo : null;

    String trafficStr = '—';
    String daysStr = '—';
    if (subInfo != null) {
      // The parser maps "no limit" (server total=0 / expire=0) to sentinel
      // values above these thresholds — treat them as unlimited (∞).
      final usedGB = subInfo.consumption / 1073741824.0;
      if (subInfo.total > ProfileParser.infiniteTrafficThreshold) {
        trafficStr = '${usedGB.toStringAsFixed(1)}/∞ ${s.gb}';
      } else {
        final totalGB = subInfo.total / 1073741824.0;
        trafficStr = '${usedGB.toStringAsFixed(1)}/${totalGB.toStringAsFixed(0)} ${s.gb}';
      }
      final unlimitedTime =
          subInfo.expire.millisecondsSinceEpoch >= ProfileParser.infiniteTimeThreshold * 1000;
      daysStr = unlimitedTime ? '∞' : (subInfo.isExpired ? '0' : '${subInfo.remaining.inDays}');
    }

    final url = activeProfile is RemoteProfileEntity ? activeProfile.url : null;
    final token = url != null ? extractDeviceUsername(url) : null;

    // Refresh device count on connect/disconnect transitions.
    ref.listen(connectionNotifierProvider, (prev, next) {
      final was = prev?.valueOrNull is Connected;
      final now = next.valueOrNull is Connected;
      if (was != now && token != null) {
        ref.invalidate(deviceCountProvider(token));
      }
    });

    // Poll every 10 s while the app is in the foreground; stop when backgrounded.
    final lifecycle = useAppLifecycleState();
    final isForeground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    useEffect(() {
      if (token == null || !isForeground) return null;
      final timer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => ref.invalidate(deviceCountProvider(token)),
      );
      return timer.cancel;
    }, [token, isForeground]);

    final deviceInfo =
        token != null ? ref.watch(deviceCountProvider(token)).valueOrNull : null;
    String devicesStr = '—';
    if (deviceInfo != null) {
      final limitStr = deviceInfo.limit == 0 ? '∞' : '${deviceInfo.limit}';
      devicesStr = '${deviceInfo.connected}/$limitStr';
    }

    final connectionStatus = ref.watch(connectionNotifierProvider);
    final isConnected = connectionStatus is AsyncData && connectionStatus.value is Connected;
    final delay = activeProxy?.urlTestDelay ?? 0;
    final pingStr = (isConnected && delay > 0 && delay < 65000) ? '${delay}${s.ms}' : '—';
    final pingColor = (isConnected && delay > 0 && delay < 65000)
        ? (delay < 300 ? const Color(AppColors.success) : const Color(AppColors.warning))
        : null;

    final dividerColor = theme.colorScheme.outline.withValues(alpha: .2);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dividerColor),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            _StatCell(label: s.traffic, value: trafficStr),
            VerticalDivider(width: 1, color: dividerColor),
            _StatCell(label: s.days, value: daysStr),
            VerticalDivider(width: 1, color: dividerColor),
            _StatCell(label: s.ping, value: pingStr, valueColor: pingColor),
            VerticalDivider(width: 1, color: dividerColor),
            _StatCell(
              label: s.devices,
              value: devicesStr,
              onTap: token != null ? () => ref.invalidate(deviceCountProvider(token)) : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends HookWidget {
  const _StatCell({required this.label, required this.value, this.valueColor, this.onTap});
  final String label;
  final String value;
  final Color? valueColor;

  /// When set, the cell becomes tappable (used to force-refresh the value) and
  /// shows a small refresh hint next to the value.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Brief spinner after a manual refresh tap so the action isn't "mute".
    final refreshing = useState(false);
    final valueStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w500,
      color: valueColor ?? theme.colorScheme.onSurface,
      letterSpacing: -0.2,
    );

    final valueWidget = onTap == null
        ? Text(value, style: valueStyle)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(value, overflow: TextOverflow.ellipsis, style: valueStyle)),
              const SizedBox(width: 4),
              refreshing.value
                  ? SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .6),
                      ),
                    )
                  : Icon(
                      Icons.refresh_rounded,
                      size: 12,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .6),
                    ),
            ],
          );

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 8.5,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: .55),
            ),
          ),
          const SizedBox(height: 3),
          valueWidget,
        ],
      ),
    );

    return Expanded(
      child: onTap == null
          ? content
          : InkWell(
              onTap: () {
                onTap!();
                refreshing.value = true;
                Future.delayed(const Duration(milliseconds: 800), () {
                  if (context.mounted) refreshing.value = false;
                });
              },
              borderRadius: BorderRadius.circular(8),
              child: content,
            ),
    );
  }
}

/// Banner shown on home page when a new version is available.
/// Only disappears once the user updates the app — no dismiss/ignore.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.title, required this.subtitle, required this.onTap});
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  static const _leftBorderColor = Color(AppColors.success);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              border: const Border(left: BorderSide(color: _leftBorderColor, width: 3)),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.system_update_rounded, size: 20, color: _leftBorderColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 20, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
