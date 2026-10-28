import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/xboard/widget/xboard_ui_common.dart';

void main() {
  test('traffic uses binary units at powers of 1024', () {
    final cases = <int, String>{
      0: '0 B',
      1023: '1023 B',
      1024: '1 KiB',
      1048576: '1.00 MiB',
      1073741824: '1.00 GiB',
      1099511627776: '1.00 TiB',
      1125899906842624: '1.00 PiB',
      1610612736: '1.50 GiB',
    };

    for (final entry in cases.entries) {
      expect(formatXboardBytes(entry.key), entry.value, reason: '${entry.key} bytes');
    }
  });
}
