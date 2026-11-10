import 'dart:io';

import 'package:fl_clash/common/haoze_data_migration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('haoze-migration-');
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'moves settings and encrypted credentials before directory lookup',
    () async {
      for (final folder in ['Roaming', 'Local']) {
        final legacy = Directory(
          paths.join(root.path, folder, 'Haoze', 'Haoze Connect Mihomo'),
        );
        await legacy.create(recursive: true);
        await File(
          paths.join(legacy.path, 'database.sqlite'),
        ).writeAsBytes([1, 2]);
        await File(
          paths.join(legacy.path, 'credentials'),
        ).writeAsBytes([0, 255]);
      }
      final roots = [
        'Roaming',
        'Local',
      ].map((name) => paths.join(root.path, name));
      await migrateHaozeData(roots);
      await migrateHaozeData(roots);
      for (final folder in roots) {
        final current = paths.join(folder, 'Haoze', 'Haoze');
        expect(
          await File(paths.join(current, 'database.sqlite')).readAsBytes(),
          [1, 2],
        );
        expect(await File(paths.join(current, 'credentials')).readAsBytes(), [
          0,
          255,
        ]);
        expect(
          await Directory(
            paths.join(folder, 'Haoze', 'Haoze Connect Mihomo'),
          ).exists(),
          false,
        );
      }
    },
  );

  test(
    'preserves both directories when the new account already exists',
    () async {
      final legacy = Directory(
        paths.join(root.path, 'Haoze', 'Haoze Connect Mihomo'),
      );
      final current = Directory(paths.join(root.path, 'Haoze', 'Haoze'));
      await legacy.create(recursive: true);
      await current.create();
      await File(paths.join(legacy.path, 'credentials')).writeAsString('old');
      await File(paths.join(current.path, 'credentials')).writeAsString('new');
      await migrateHaozeData([root.path]);
      expect(
        await File(paths.join(legacy.path, 'credentials')).readAsString(),
        'old',
      );
      expect(
        await File(paths.join(current.path, 'credentials')).readAsString(),
        'new',
      );
    },
  );

  test(
    'fresh installs leave directory creation to the storage plugins',
    () async {
      await migrateHaozeData([root.path]);
      expect(await root.list().isEmpty, true);
    },
  );

  test(
    'a blocked destination fails instead of starting with empty data',
    () async {
      final legacy = Directory(
        paths.join(root.path, 'Haoze', 'Haoze Connect Mihomo'),
      );
      await legacy.create(recursive: true);
      await File(
        paths.join(root.path, 'Haoze', 'Haoze'),
      ).writeAsString('blocked');
      await expectLater(
        migrateHaozeData([root.path]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await legacy.exists(), true);
    },
  );
}
