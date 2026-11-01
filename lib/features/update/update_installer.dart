import 'dart:io';

import 'package:fl_clash/common/system.dart';
import 'package:fl_clash/plugins/app.dart';

import 'update_service.dart';

abstract interface class UpdateInstallGateway {
  Future<void> install(File file, UpdateRelease release);
  Future<bool> requestPermission();
}

class SystemUpdateInstallGateway implements UpdateInstallGateway {
  SystemUpdateInstallGateway({
    required this.exitWindows,
    Future<bool> Function(String)? launchWindows,
  }) : launchWindows = launchWindows ?? _launchWindows;
  final Future<void> Function() exitWindows;
  final Future<bool> Function(String) launchWindows;

  static Future<bool> _launchWindows(String path) async =>
      windows?.runas(path, '') ?? false;

  @override
  Future<void> install(File file, UpdateRelease release) async {
    await verifyUpdateFile(file, release);
    try {
      if (release.platform == UpdatePlatform.android) {
        final platform = app;
        if (platform == null) {
          throw const UpdateException(UpdateFailure.install);
        }
        if (!await platform.canInstallUpdate()) {
          throw const UpdateException(UpdateFailure.permission);
        }
        final opened = await platform.installUpdate(
          path: file.path,
          version: release.version,
          versionCode: release.versionCode!,
          sha256: release.sha256,
        );
        if (!opened) throw const UpdateException(UpdateFailure.install);
      } else {
        if (!await launchWindows(file.path)) {
          throw const UpdateException(UpdateFailure.install);
        }
        await exitWindows();
      }
    } on UpdateException {
      rethrow;
    } catch (_) {
      throw const UpdateException(UpdateFailure.install);
    }
  }

  @override
  Future<bool> requestPermission() async =>
      await app?.requestUpdateInstallPermission() ?? false;
}
