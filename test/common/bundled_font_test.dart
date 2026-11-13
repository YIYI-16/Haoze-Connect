import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled Chinese font renders distinct regular, semibold and bold faces',
    () async {
      final loader = FontLoader('Noto Sans SC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
      await loader.load();
      final coverage = <int>[];
      for (final weight in [
        ui.FontWeight.w400,
        ui.FontWeight.w600,
        ui.FontWeight.w700,
      ]) {
        final builder = ui.ParagraphBuilder(
          ui.ParagraphStyle(fontFamily: 'Noto Sans SC', fontSize: 48),
        )..pushStyle(ui.TextStyle(fontWeight: weight));
        builder.addText('账户套餐与流量');
        final paragraph = builder.build()
          ..layout(const ui.ParagraphConstraints(width: 480));
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawParagraph(paragraph, ui.Offset.zero);
        final picture = recorder.endRecording();
        final image = await picture.toImage(480, 100);
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        var ink = 0;
        for (var i = 3; i < bytes.length; i += 4) {
          ink += bytes[i];
        }
        coverage.add(ink);
        image.dispose();
        picture.dispose();
        paragraph.dispose();
      }
      expect(coverage.first, greaterThan(0));
      expect(coverage[1], greaterThan(coverage[0]));
      expect(coverage[2], greaterThan(coverage[1]));
    },
  );
}
