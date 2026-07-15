import 'dart:io';

import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages update download — persists state, avoids re-download.
class UpdateDownloader with InfraLogger {
  UpdateDownloader({required this.httpClient});

  final DioHttpClient httpClient;

  // ---- persisted keys ----
  static const _prefsKeyDownloadedPath = 'update_downloaded_path';
  static const _prefsKeyDownloadedSize = 'update_downloaded_size';
  static const _prefsKeyDownloadedUrl = 'update_downloaded_url';

  /// Returns the cached file path if already downloaded for [url], or null.
  Future<String?> getCachedUpdate(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedUrl = prefs.getString(_prefsKeyDownloadedUrl);
    final cachedPath = prefs.getString(_prefsKeyDownloadedPath);
    final cachedSize = prefs.getInt(_prefsKeyDownloadedSize) ?? 0;

    if (cachedUrl == url && cachedPath != null) {
      final file = File(cachedPath);
      if (await file.exists() && await file.length() == cachedSize) {
        return cachedPath;
      }
      // Stale cache — clean up
      await _clearCache();
    }
    return null;
  }

  /// Download update from [url] to temp dir, reporting progress.
  /// Returns the local file path. Caches the result for later install.
  Future<String> downloadUpdate({
    required String url,
    void Function(int received, int total)? onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final fileName = url.split('/').last;
    final file = File('${dir.path}/$fileName');
    if (await file.exists()) await file.delete();

    await httpClient.download(
      url,
      file.path,
      onReceiveProgress: onProgress,
    );

    // Persist cache info
    final size = await file.length();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyDownloadedUrl, url);
    await prefs.setString(_prefsKeyDownloadedPath, file.path);
    await prefs.setInt(_prefsKeyDownloadedSize, size);

    return file.path;
  }

  /// Install/launch the downloaded update at [filePath].
  /// On Windows: opens the containing folder in Explorer.
  /// On Android: opens the APK with the system package installer.
  Future<void> installUpdate(String filePath) async {
    if (PlatformUtils.isWindows) {
      // Open the containing folder so the user can extract the zip / run the installer
      final file = File(filePath);
      final dir = file.parent;
      if (await dir.exists()) {
        await OpenFilex.open(dir.path);
      }
    } else {
      // Android: use system package installer
      await OpenFilex.open(filePath, type: 'application/vnd.android.package-archive');
      // Give the installer a moment to start, then clean up
      await Future.delayed(const Duration(seconds: 2));
      await _clearCache();
      final file = File(filePath);
      if (await file.exists()) {
        try { await file.delete(); } catch (_) {}
      }
    }
  }

  Future<void> _clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_prefsKeyDownloadedPath);
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        try { await file.delete(); } catch (_) {}
      }
    }
    await prefs.remove(_prefsKeyDownloadedUrl);
    await prefs.remove(_prefsKeyDownloadedPath);
    await prefs.remove(_prefsKeyDownloadedSize);
  }

  /// Clean up any previously downloaded update (call when update is done).
  Future<void> cleanup() => _clearCache();
}
