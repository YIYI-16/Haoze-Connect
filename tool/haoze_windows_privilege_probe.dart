import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/core/desktop/windows_privileges.dart';

void main(List<String> arguments) {
  if (!Platform.isWindows) throw UnsupportedError('Windows probe only');
  final result = jsonEncode({
    'elevated': readWindowsProcessElevation(),
    'programDirectories': readWindowsProgramDirectories(),
  });
  if (arguments.length != 1) throw ArgumentError('Provide one output path');
  File(arguments.single).writeAsStringSync(result);
}
