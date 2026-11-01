import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/models/managed_routing.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as paths;

class HaozeRoutingResources {
  static int _stagingRevision = 0;
  static const _digests = {
    'haoze-cn-domain.mrs':
        '0b8c7c4d9773471991dd65737fdb16f3bf1baf2512c8b764d4c235318f01b7c6',
    'haoze-cn-ip.mrs':
        '1cd97d734afafcac0708895cefa931ed19aeac28933458afdc4f9c13e915fcb5',
  };

  Future<ManagedRoutingPolicy> ensure(Set<String> directHosts) async {
    final directory = Directory(
      paths.join(await appPath.homeDirPath, 'haoze-routing'),
    );
    await directory.create(recursive: true);
    for (final entry in _digests.entries) {
      final file = File(paths.join(directory.path, entry.key));
      if (await file.exists() &&
          sha256.convert(await file.readAsBytes()).toString() == entry.value) {
        continue;
      }
      final data = await rootBundle.load('assets/data/${entry.key}');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      if (sha256.convert(bytes).toString() != entry.value) {
        throw StateError('Routing asset checksum mismatch');
      }
      final staged = File('${file.path}.tmp-$pid-${_stagingRevision++}');
      try {
        await staged.writeAsBytes(bytes, flush: true);
        await staged.rename(file.path);
      } finally {
        if (await staged.exists()) await staged.delete();
      }
    }
    return ManagedRoutingPolicy(
      domainRulesPath: paths.join(directory.path, 'haoze-cn-domain.mrs'),
      ipRulesPath: paths.join(directory.path, 'haoze-cn-ip.mrs'),
      directHosts: directHosts,
    );
  }
}
