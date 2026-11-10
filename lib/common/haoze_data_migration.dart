import 'dart:io';

import 'package:path/path.dart' as paths;

Future<void> migrateHaozeData(Iterable<String> appDataRoots) async {
  for (final root in appDataRoots.toSet()) {
    final company = paths.join(root, 'Haoze');
    final legacy = Directory(paths.join(company, 'Haoze Connect Mihomo'));
    final current = Directory(paths.join(company, 'Haoze'));
    if (await legacy.exists() && !await current.exists()) {
      await legacy.rename(current.path);
    }
  }
}
