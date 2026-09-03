import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/widget/adaptive_icon.dart';
import 'package:hiddify/core/widget/axiom_branding.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/features/telemost_tunnel/notifier/whitepass_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AboutPage extends HookConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final appInfo = ref.watch(appInfoProvider).requireValue;
    final appUpdate = ref.watch(appUpdateNotifierProvider);

    ref.listen(appUpdateNotifierProvider, (_, next) async {
      if (!context.mounted) return;
      switch (next) {
        case AppUpdateStateAvailable(:final versionInfo) || AppUpdateStateIgnored(:final versionInfo):
          return await ref
              .read(dialogNotifierProvider.notifier)
              .showNewVersion(currentVersion: appInfo.presentVersion, newVersion: versionInfo, canIgnore: false);
        case AppUpdateStateError(:final error):
          return CustomToast.error(t.presentShortError(error)).show(context);
        case AppUpdateStateNotAvailable():
          return CustomToast.success(t.pages.about.notAvailableMsg).show(context);
      }
    });

    final conditionalTiles = [
      if (appInfo.release.allowCustomUpdateChecker)
        ListTile(
          title: Text(t.pages.about.checkForUpdate),
          trailing: switch (appUpdate) {
            AppUpdateStateChecking() => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator()),
            _ => const Icon(FluentIcons.arrow_sync_24_regular),
          },
          onTap: () async {
            await ref.read(appUpdateNotifierProvider.notifier).check();
          },
        ),
      if (PlatformUtils.isDesktop)
        ListTile(
          title: Text(t.pages.about.openWorkingDir),
          trailing: const Icon(FluentIcons.open_folder_24_regular),
          onTap: () async {
            final path = ref.watch(appDirectoriesProvider).requireValue.workingDir.uri;
            await UriUtils.tryLaunch(path);
          },
        ),
    ];

    // Easter egg: 10 quick taps on the title open the WhitePass code dialog.
    final titleTapCount = useState(0);
    final lastTitleTapAt = useRef<DateTime?>(null);

    void onTitleTap() {
      final now = DateTime.now();
      final last = lastTitleTapAt.value;
      lastTitleTapAt.value = now;
      if (last == null || now.difference(last) > const Duration(seconds: 2)) {
        titleTapCount.value = 1;
      } else {
        titleTapCount.value += 1;
      }
      if (titleTapCount.value >= 10) {
        titleTapCount.value = 0;
        _showWhitePassDialog(context, ref);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTitleTap,
          child: AxiOmSectionTitle(title: t.pages.about.title),
        ),
        actions: [
          PopupMenuButton(
            icon: Icon(AdaptiveIcon(context).more),
            itemBuilder: (context) {
              return [
                PopupMenuItem(
                  child: Text(t.common.addToClipboard),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: appInfo.format()));
                  },
                ),
              ];
            },
          ),
          const Gap(8),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Assets.images.logo.svg(width: 64, height: 64),
                  const Gap(16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.common.appTitle, style: Theme.of(context).textTheme.titleLarge),
                      const Gap(4),
                      Text("${t.common.version} ${appInfo.presentVersion}"),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              ...conditionalTiles,
              if (conditionalTiles.isNotEmpty) const Divider(),
              ListTile(
                title: Text(t.pages.about.sourceCode),
                trailing: const Icon(FluentIcons.open_24_regular),
                onTap: () async {
                  await UriUtils.tryLaunch(Uri.parse(Constants.githubUrl));
                },
              ),
              ListTile(
                title: const Text('Официальный канал'),
                subtitle: const Text('@AxiOm_freedom', style: TextStyle(fontSize: 13)),
                trailing: const Icon(FluentIcons.open_24_regular),
                onTap: () async {
                  await UriUtils.tryLaunch(Uri.parse(Constants.telegramChannelUrl));
                },
              ),
              ListTile(
                title: const Text('Бот для покупки'),
                subtitle: const Text('@AxiOm_buy_bot', style: TextStyle(fontSize: 13)),
                trailing: const Icon(FluentIcons.open_24_regular),
                onTap: () async {
                  await UriUtils.tryLaunch(Uri.parse(Constants.telegramBuyBotUrl));
                },
              ),
              ListTile(
                title: const Text('Поддержка'),
                subtitle: const Text('@AxiOm_Npv_support_bot', style: TextStyle(fontSize: 13)),
                trailing: const Icon(FluentIcons.open_24_regular),
                onTap: () async {
                  await UriUtils.tryLaunch(Uri.parse(Constants.telegramSupportBotUrl));
                },
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// WhitePass cheat-code dialog (opened by the 10-tap title easter egg).
void _showWhitePassDialog(BuildContext context, WidgetRef ref) {
  final controller = TextEditingController();

  Future<void> submit(BuildContext dialogContext) async {
    final ok = await ref.read(whitePassNotifierProvider.notifier).tryUnlock(controller.text);
    if (!dialogContext.mounted) return;
    if (ok) {
      Navigator.of(dialogContext).pop();
      if (context.mounted) {
        CustomToast.success('Доступ к обходу открыт на 2 часа').show(context);
      }
    } else {
      CustomToast.error('Неверный код').show(dialogContext);
    }
  }

  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Код доступа'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Введите код'),
        onSubmitted: (_) => submit(dialogContext),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => submit(dialogContext),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
