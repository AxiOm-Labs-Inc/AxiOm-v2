import 'package:dartx/dartx.dart';
import 'package:axiom/core/model/environment.dart';
import 'package:axiom/features/app_update/model/remote_version_entity.dart';
import 'package:axiom/utils/platform_utils.dart';

abstract class GithubReleaseParser {
  static RemoteVersionEntity parse(Map<String, dynamic> json) {
    final fullTag = json['tag_name'] as String;
    final fullVersion = fullTag.removePrefix("v").split("-").first.split("+");
    var version = fullVersion.first;
    var buildNumber = fullVersion.elementAtOrElse(1, (index) => "");
    var flavor = Environment.prod;
    for (final env in Environment.values) {
      final suffix = ".${env.name}";
      if (version.endsWith(suffix)) {
        version = version.removeSuffix(suffix);
        flavor = env;
        break;
      } else if (buildNumber.endsWith(suffix)) {
        buildNumber = buildNumber.removeSuffix(suffix);
        flavor = env;
        break;
      }
    }
    final preRelease = json["prerelease"] as bool;
    final publishedAt = DateTime.parse(json["published_at"] as String);
    String? assetDownloadUrl;
    final assets = json["assets"] as List<dynamic>?;
    if (assets != null) {
      if (PlatformUtils.isWindows) {
        // Windows: prefer Setup.exe installer, then any .exe, zip only as fallback
        final maps = assets.cast<Map<String, dynamic>>();
        for (final a in maps) {
          final name = (a["name"] as String?) ?? '';
          if (name.toLowerCase().endsWith('.exe') && name.toLowerCase().contains('setup')) {
            assetDownloadUrl = a["browser_download_url"] as String?;
            break;
          }
        }
        if (assetDownloadUrl == null) {
          for (final a in maps) {
            if ((a["name"] as String?)?.toLowerCase().endsWith('.exe') == true) {
              assetDownloadUrl = a["browser_download_url"] as String?;
              break;
            }
          }
        }
        if (assetDownloadUrl == null) {
          for (final a in maps) {
            if ((a["name"] as String?)?.toLowerCase().endsWith('.zip') == true) {
              assetDownloadUrl = a["browser_download_url"] as String?;
              break;
            }
          }
        }
      } else {
        // Android: arm64 APK preferred, fallback to any APK
        for (final asset in assets) {
          final name = (asset as Map<String, dynamic>)["name"] as String? ?? '';
          if (name.endsWith('.apk') && name.contains('arm64')) {
            assetDownloadUrl = asset["browser_download_url"] as String?;
            break;
          }
        }
        if (assetDownloadUrl == null) {
          for (final a in assets.cast<Map<String, dynamic>>()) {
            if ((a["name"] as String?)?.endsWith('.apk') == true) {
              assetDownloadUrl = a["browser_download_url"] as String?;
              break;
            }
          }
        }
      }
    }
    return RemoteVersionEntity(
      version: version,
      buildNumber: buildNumber,
      releaseTag: fullTag,
      preRelease: preRelease,
      url: json["html_url"] as String,
      publishedAt: publishedAt,
      flavor: flavor,
      assetDownloadUrl: assetDownloadUrl,
    );
  }
}
