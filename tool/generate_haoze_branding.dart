import 'dart:io';
import 'dart:math' as math;
import 'package:image/image.dart' as image;
import 'src/icons/ico.dart';

final _background = image.ColorRgb8(245, 247, 250);
const _source = 'assets_source/images/icon/haoze.png';

Future<void> main() => generateHaozeBranding();

Future<void> generateHaozeBranding() async {
  final original = image.decodePng(File(_source).readAsBytesSync())!;
  final mark = _darkMark(original);
  final icon = _lightTile();
  image.compositeImage(
    icon,
    image.copyResize(
      mark,
      width: 320,
      height: 320,
      interpolation: image.Interpolation.cubic,
    ),
    dstX: 96,
    dstY: 96,
  );
  await _png('assets/images/icon.png', icon);
  final ico = buildIco([
    for (final size in icoSizes)
      IcoEntry(
        size: size,
        png: image.encodePng(
          image.copyResize(
            icon,
            width: size,
            height: size,
            interpolation: image.Interpolation.average,
          ),
        ),
      ),
  ]);
  await File('windows/runner/resources/app_icon.ico').writeAsBytes(ico);
  await File('assets/images/icon.ico').writeAsBytes(ico);

  const sizes = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  const tvSizes = {
    'mdpi': 80,
    'hdpi': 120,
    'xhdpi': 160,
    'xxhdpi': 240,
    'xxxhdpi': 320,
  };
  const res = 'android/app/src/main/res';
  for (final entry in sizes.entries) {
    final resized = image.copyResize(
      icon,
      width: entry.value,
      height: entry.value,
      interpolation: image.Interpolation.average,
    );
    for (final name in ['ic_launcher', 'ic_launcher_round']) {
      await _png('$res/mipmap-${entry.key}/$name.png', resized);
      final old = File('$res/mipmap-${entry.key}/$name.webp');
      if (old.existsSync()) await old.delete();
    }
    final tvSize = tvSizes[entry.key]!;
    await _png(
      '$res/mipmap-television-${entry.key}/ic_launcher.png',
      image.copyResize(
        icon,
        width: tvSize,
        height: tvSize,
        interpolation: image.Interpolation.average,
      ),
    );
    final oldTv = File('$res/mipmap-television-${entry.key}/ic_launcher.webp');
    if (oldTv.existsSync()) await oldTv.delete();
  }
  await _png('$res/drawable-nodpi/haoze_mark.png', mark);
  const foreground =
      '<?xml version="1.0" encoding="utf-8"?>\n<inset xmlns:android="http://schemas.android.com/apk/res/android" android:insetLeft="32dp" android:insetRight="32dp" android:insetTop="32dp" android:insetBottom="32dp"><bitmap android:src="@drawable/haoze_mark" android:gravity="fill" android:filter="true" /></inset>\n';
  for (final name in ['ic_launcher_foreground', 'ic_launcher_foreground_tv']) {
    await File('$res/drawable/$name.xml').writeAsString(foreground);
  }
  await File('$res/values/ic_launcher_background.xml').writeAsString(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources><color name="ic_launcher_background">#F5F7FA</color></resources>\n',
  );
  final monochrome = image.Image.from(mark);
  for (final pixel in monochrome) {
    pixel.setRgba(255, 255, 255, pixel.a);
  }
  const notificationSizes = {
    'mdpi': 24,
    'hdpi': 36,
    'xhdpi': 48,
    'xxhdpi': 72,
    'xxxhdpi': 96,
  };
  for (final entry in notificationSizes.entries) {
    const serviceRes = 'android/service/src/main/res';
    await _png(
      '$serviceRes/drawable-${entry.key}/ic.png',
      image.copyResize(
        monochrome,
        width: entry.value,
        height: entry.value,
        interpolation: image.Interpolation.average,
      ),
    );
    await _png(
      '$serviceRes/drawable-${entry.key}/ic_service.png',
      image.copyResize(
        icon,
        width: entry.value * 2,
        height: entry.value * 2,
        interpolation: image.Interpolation.average,
      ),
    );
  }
  for (final name in ['ic', 'ic_service']) {
    final old = File('android/service/src/main/res/drawable/$name.xml');
    if (old.existsSync()) await old.delete();
  }
  final banner = image.Image(width: 320, height: 180, numChannels: 4);
  image.fill(banner, color: _background);
  image.compositeImage(
    banner,
    image.copyResize(mark, width: 108, height: 108),
    dstX: 24,
    dstY: 36,
  );
  image.drawString(
    banner,
    'Haoze',
    font: image.arial48,
    x: 148,
    y: 64,
    color: image.ColorRgb8(35, 51, 62),
  );
  await _png('$res/mipmap-xhdpi/ic_banner.png', banner);

  for (var state = 1; state <= 3; state++) {
    final tray = image.Image.from(icon);
    image.fillCircle(tray, x: 418, y: 418, radius: 72, color: _background);
    image.fillCircle(
      tray,
      x: 418,
      y: 418,
      radius: 48,
      color: switch (state) {
        1 => image.ColorRgb8(148, 163, 184),
        2 => image.ColorRgb8(59, 130, 246),
        _ => image.ColorRgb8(34, 197, 94),
      },
    );
    await File('assets/images/tray/windows/status_$state.ico').writeAsBytes(
      buildIco([
        for (final size in trayIcoSizes)
          IcoEntry(
            size: size,
            png: image.encodePng(
              image.copyResize(
                tray,
                width: size,
                height: size,
                interpolation: image.Interpolation.average,
              ),
            ),
          ),
      ]),
    );
    for (var scale = 1; scale <= 4; scale++) {
      final size = 18 * scale;
      final dir = scale == 1 ? '' : '$scale.0x/';
      await _png(
        'assets/images/tray/unix/${dir}status_$state.png',
        image.copyResize(
          tray,
          width: size,
          height: size,
          interpolation: image.Interpolation.average,
        ),
      );
    }
  }
  stdout.writeln(
    'Generated Haoze launcher, Windows, tray and Android TV branding from the original HZ logo',
  );
}

Future<void> _png(String path, image.Image value) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(image.encodePng(value));
}

image.Image _darkMark(image.Image original) {
  final mark = image.Image(
    width: original.width,
    height: original.height,
    numChannels: 4,
  );
  for (final pixel in mark) {
    var alpha = 0;
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        if (dx * dx + dy * dy > 4) continue;
        final x = pixel.x + dx;
        final y = pixel.y + dy;
        if (x < 0 || y < 0 || x >= original.width || y >= original.height) {
          continue;
        }
        alpha = math.max(alpha, original.getPixel(x, y).a.toInt());
      }
    }
    pixel.setRgba(35, 51, 62, alpha < 16 ? 0 : alpha);
  }
  return image.gaussianBlur(mark, radius: 1);
}

image.Image _lightTile() {
  final tile = image.Image(width: 512, height: 512, numChannels: 4);
  for (final pixel in tile) {
    final x = (pixel.x + 0.5 - 256) / 246;
    final y = (pixel.y + 0.5 - 256) / 246;
    final contour = math.pow(x.abs(), 4) + math.pow(y.abs(), 4);
    final alpha = ((1 - contour) * 70 + 0.5).clamp(0.0, 1.0);
    final t = pixel.y / 511;
    final edge = ((contour - 0.965) / 0.035).clamp(0.0, 1.0) * 12;
    pixel.setRgba(
      (253 - 10 * t - edge).round(),
      (254 - 9 * t - edge).round(),
      (255 - 8 * t - edge).round(),
      (alpha * 255).round(),
    );
  }
  return tile;
}
