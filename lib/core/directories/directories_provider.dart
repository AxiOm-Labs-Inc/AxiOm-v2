import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:axiom/core/model/directories.dart';
import 'package:axiom/core/model/environment.dart';
import 'package:axiom/utils/custom_loggers.dart';
import 'package:axiom/utils/platform_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'directories_provider.g.dart';

@Riverpod(keepAlive: true)
class AppDirectories extends _$AppDirectories with InfraLogger {
  final _methodChannel = const MethodChannel("app.axiom/platform");

  @override
  Future<Directories> build() async {
    final Directories dirs;
    if (kIsWeb) {
      return (baseDir: Directory("."), workingDir: Directory("."), tempDir: Directory("."));
    }
    if (PlatformUtils.isIOS) {
      final paths = await _methodChannel.invokeMethod<Map>("get_paths");
      loggy.debug("paths: $paths");
      dirs = (
        baseDir: Directory(paths?["base"]! as String),
        workingDir: Directory(paths?["working"]! as String),
        tempDir: Directory(paths?["temp"]! as String),
      );
    } else if (PlatformUtils.isWindows &&
        Environment.isPortable &&
        await checkDirectoryAccess(getPortableDirectory())) {
      final portableDir = getPortableDirectory();
      dirs = (baseDir: portableDir, workingDir: portableDir, tempDir: await getTemporaryDirectory());
    } else {
      final baseDir = await getApplicationSupportDirectory();
      final workingDir = Platform.isAndroid ? await _getAndroidWorkingDirectory() : baseDir;
      final tempDir = await getTemporaryDirectory();
      dirs = (baseDir: baseDir, workingDir: workingDir!, tempDir: tempDir);
    }

    if (!dirs.baseDir.existsSync()) {
      await dirs.baseDir.create(recursive: true);
    }
    if (!dirs.workingDir.existsSync()) {
      await dirs.workingDir.create(recursive: true);
    }

    return dirs;
  }

  static Future<Directory> _getAndroidWorkingDirectory() async {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir == null) return getApplicationDocumentsDirectory();
      if (extDir.existsSync()) return extDir;
      await extDir.create(recursive: true);
      return extDir;
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }

  static Future<Directory> getDatabaseDirectory() async {
    if (kIsWeb) {
      return Directory(".");
    }
    if (PlatformUtils.isIOS || PlatformUtils.isMacOS) {
      return await getLibraryDirectory();
    } else if (PlatformUtils.isWindows &&
        Environment.isPortable &&
        await checkDirectoryAccess(getPortableDirectory())) {
      final portableDir = getPortableDirectory();
      return portableDir;
    } else if (PlatformUtils.isWindows || PlatformUtils.isLinux) {
      return await getApplicationSupportDirectory();
    }
    return await getApplicationDocumentsDirectory();
  }

  static Directory getPortableDirectory() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final dir = Directory(p.join(exeDir.path, 'axiom_portable_data'));
    // До 4.5.0 каталог назывался по апстриму. Переносим один раз; если
    // переименовать не вышло (нет прав, файлы заняты) — работаем со старым,
    // чтобы пользователь портативной версии не остался без своих данных.
    final legacy = Directory(p.join(exeDir.path, 'hiddify_portable_data'));
    if (!dir.existsSync() && legacy.existsSync()) {
      try {
        legacy.renameSync(dir.path);
      } catch (_) {
        return legacy;
      }
    }
    return dir;
  }

  static Future<bool> checkDirectoryAccess(Directory dir) async {
    final testFile = File(p.join(dir.path, 'access_test.txt'));

    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      await testFile.writeAsString('Testing write permission...');
      await testFile.readAsString();
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
