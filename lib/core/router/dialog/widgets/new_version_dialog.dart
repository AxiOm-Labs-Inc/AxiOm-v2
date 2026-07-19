import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/app_update/data/update_downloader.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class NewVersionDialog extends HookConsumerWidget with PresLogger {
  NewVersionDialog(this.currentVersion, this.newVersion, {super.key, this.canIgnore = true});

  final String currentVersion;
  final RemoteVersionEntity newVersion;
  final bool canIgnore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final isWindows = PlatformUtils.isWindows;
    final downloader = UpdateDownloader(httpClient: ref.read(httpClientProvider));

    final downloadUrl = newVersion.assetDownloadUrl;
    final downloadProgress = useState<double?>(null);
    final isDownloading = useState(false);
    final downloadError = useState<String?>(null);
    // True once we have a local APK ready to install.
    final readyToInstall = useState(false);
    final cachedPath = useState<String?>(null);

    // Check cache on first build
    final didCheck = useRef(false);
    useEffect(() {
      if (didCheck.value || downloadUrl == null) return null;
      didCheck.value = true;
      downloader.getCachedUpdate(downloadUrl).then((path) {
        if (path != null) {
          cachedPath.value = path;
          readyToInstall.value = true;
        }
      });
      return null;
    }, [downloadUrl]);

    Future<void> startDownload() async {
      if (downloadUrl == null) {
        // Fallback: open release page in browser
        await UriUtils.tryLaunch(Uri.parse(newVersion.url));
        return;
      }

      // Already have the file — go straight to install
      if (readyToInstall.value && cachedPath.value != null) {
        if (context.mounted) context.pop();
        await downloader.installUpdate(cachedPath.value!);
        return;
      }

      isDownloading.value = true;
      downloadError.value = null;
      downloadProgress.value = 0;

      try {
        final filePath = await downloader.downloadUpdate(
          url: downloadUrl,
          onProgress: (received, total) {
            if (!context.mounted) return;
            if (total > 0) {
              downloadProgress.value = received / total;
            }
          },
        );

        isDownloading.value = false;
        cachedPath.value = filePath;
        readyToInstall.value = true;
      } catch (e) {
        isDownloading.value = false;
        downloadProgress.value = null;
        downloadError.value =
            'Ошибка загрузки. Проверьте соединение и попробуйте снова.\n${e.toString().length > 100 ? '${e.toString().substring(0, 100)}...' : e}';
        loggy.warning("download failed", e);
      }
    }

    Future<void> install() async {
      if (cachedPath.value == null) return;
      if (context.mounted) context.pop();
      await downloader.installUpdate(cachedPath.value!);
    }

    final canAct = !isDownloading.value;

    return AlertDialog(
      title: Text(t.dialogs.newVersion.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.dialogs.newVersion.msg),
          const Gap(8),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: t.dialogs.newVersion.currentVersion, style: theme.textTheme.bodySmall),
              TextSpan(text: currentVersion, style: theme.textTheme.labelMedium),
            ]),
          ),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: t.dialogs.newVersion.newVersion, style: theme.textTheme.bodySmall),
              TextSpan(text: newVersion.presentVersion, style: theme.textTheme.labelMedium),
            ]),
          ),
          if (isDownloading.value || downloadProgress.value != null) ...[
            const Gap(16),
            if (downloadError.value != null)
              Text(downloadError.value!, style: TextStyle(color: theme.colorScheme.error, fontSize: 12))
            else ...[
              LinearProgressIndicator(value: downloadProgress.value),
              const Gap(6),
              Text(
                downloadProgress.value != null
                    ? '${(downloadProgress.value! * 100).toStringAsFixed(0)}% — не сворачивайте приложение'
                    : 'Подготовка...',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
          // Show when ready to install but no download in progress
          if (readyToInstall.value && !isDownloading.value && downloadError.value == null) ...[
            const Gap(12),
            Row(children: [
              Icon(Icons.check_circle, size: 18, color: const Color(0xFF5DCAA5)),
              const SizedBox(width: 8),
              Text(isWindows ? 'Загрузка завершена' : 'APK готов к установке', style: TextStyle(color: const Color(0xFF5DCAA5), fontSize: 13)),
            ]),
          ],
        ],
      ),
      actions: [
        if (canIgnore && canAct)
          TextButton(
            onPressed: () {
              ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
              if (context.mounted) context.pop();
            },
            child: Text(t.common.ignore),
          ),
        if (readyToInstall.value && canAct)
          FilledButton.icon(
            onPressed: install,
            icon: Icon(isWindows ? Icons.folder_open : Icons.install_mobile, size: 18),
            label: Text(isWindows ? 'Открыть папку' : 'Установить'),
          )
        else if (canAct && !readyToInstall.value)
          FilledButton(
            onPressed: startDownload,
            child: const Text('Скачать и установить'),
          ),
        if (isDownloading.value)
          TextButton(
            onPressed: () {
              if (context.mounted) context.pop();
            },
            child: const Text('Скрыть'),
          ),
      ],
    );
  }
}
