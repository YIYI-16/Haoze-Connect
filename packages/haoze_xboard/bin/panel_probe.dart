import 'dart:convert';
import 'dart:io';

import 'package:haoze_xboard/haoze_xboard.dart';

Future<void> main() async {
  final client = XboardClient(panelOrigin: Uri.parse('https://www.haoze.cyou'));
  final checks = <Map<String, Object?>>[];
  try {
    for (var i = 1; i <= 4; i++) {
      final elapsed = Stopwatch()..start();
      try {
        final config = await client.publicConfig();
        checks.add({
          'attempt': i,
          'ok': true,
          'jsonObject': true,
          'publicFieldCount': config.length,
          'elapsedMs': elapsed.elapsedMilliseconds,
        });
      } on XboardException catch (error) {
        checks.add({
          'attempt': i,
          'ok': false,
          'category': error.kind.name,
          'httpStatus': error.statusCode,
          'osCode': error.osCode,
          'elapsedMs': elapsed.elapsedMilliseconds,
        });
      }
    }
  } finally {
    client.close();
  }
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'runtime': 'dart',
      'dartVersion': Platform.version.split(' ').first,
      'platform': Platform.operatingSystem,
      'utc': DateTime.now().toUtc().toIso8601String(),
      'proxy': 'DIRECT (VPN/TUN routing may still apply)',
      'certificateVerification': 'required',
      'checks': checks,
    }),
  );
  if (checks.any((check) => check['ok'] != true)) exitCode = 1;
}
