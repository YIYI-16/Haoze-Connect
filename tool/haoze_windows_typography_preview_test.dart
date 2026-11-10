import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/helpers/test_app.dart';

void main() {
  testWidgets('render Windows typography with native fonts', (tester) async {
    if (!Platform.isWindows) {
      markTestSkipped('Requires Windows system fonts');
      return;
    }
    final fonts = '${Platform.environment['WINDIR']}/Fonts';
    if (!File('$fonts/msyh.ttc').existsSync()) {
      markTestSkipped(
        'Microsoft YaHei is not installed on this Windows runner',
      );
      return;
    }
    await tester.runAsync(() async {
      for (final entry in {
        'Segoe UI': ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf'],
        'Microsoft YaHei UI': ['msyh.ttc', 'msyhbd.ttc'],
      }.entries) {
        final loader = FontLoader(entry.key);
        for (final name in entry.value) {
          final bytes = await File('$fonts/$name').readAsBytes();
          loader.addFont(Future.value(ByteData.sublistView(bytes)));
        }
        await loader.load();
      }
    });
    await tester.binding.setSurfaceSize(const Size(1100, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final theme = ThemeData(
      platform: TargetPlatform.windows,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Microsoft YaHei UI'],
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    ).withAppShapes.withAppSurfaces.withAppTypography;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      TestApp(
        theme: theme,
        locale: const Locale('zh', 'CN'),
        homeBuilder: (child) => Scaffold(body: child),
        child: RepaintBoundary(
          key: boundary,
          child: const Row(
            children: [
              Expanded(child: _Preview(before: true)),
              Expanded(child: _Preview(before: false)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await box.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final directory = Directory(
        '${Platform.environment['RUNNER_TEMP']}/haoze-typography-preview',
      );
      await directory.create(recursive: true);
      await File(
        '${directory.path}/windows-before-after.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}

class _Preview extends StatelessWidget {
  const _Preview({required this.before});
  final bool before;

  @override
  Widget build(BuildContext context) {
    final heading = AppTextStyle.headline
        .of(context)
        .copyWith(fontWeight: before ? FontWeight.w600 : null);
    final label = AppTextStyle.subheadline
        .of(context, emphasized: true)
        .copyWith(fontWeight: before ? FontWeight.w600 : null);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text('套餐与流量', style: heading),
        const Text('剩余流量：88.50 GiB'),
        const Text('总流量：100.00 GiB'),
        const Text('到期时间：长期有效'),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          Text(
            before ? '修复前' : '修复后',
            style: AppTextStyle.footnote.of(context),
          ),
          Text(
            '账户',
            style: AppTextStyle.pageTitle
                .of(context)
                .copyWith(fontWeight: before ? FontWeight.w600 : null),
          ),
          const Text('user@example.com'),
          CommonCard(
            inert: true,
            padding: const EdgeInsets.all(16),
            child: before
                ? DefaultTextStyle.merge(
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    child: content,
                  )
                : content,
          ),
          const Text('订阅已就绪\n最近刷新：2026-11-10 13:41:54'),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                onPressed: () {},
                style: FilledButton.styleFrom(textStyle: label),
                child: const Text('刷新流量'),
              ),
              OutlinedButton(
                onPressed: () {},
                style: OutlinedButton.styleFrom(textStyle: label),
                child: const Text('同步订阅'),
              ),
              TextButton(
                onPressed: () {},
                style: TextButton.styleFrom(textStyle: label),
                child: const Text('退出登录'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
