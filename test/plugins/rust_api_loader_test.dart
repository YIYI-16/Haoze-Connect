import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_api/rust_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production default loader initializes the bundled Rust library',
    () async {
      expect(RustLib.kDefaultExternalLibraryLoaderConfig.stem, 'rust_api');
      await RustLib.init();
      expect(isRustLibInitialized, isTrue);
      final result = await evaluateScript(
        script: 'function main(config) { return config; }',
        config: '{"startup":true}',
      );
      expect(jsonDecode(result), {'startup': true});
    },
  );
}
