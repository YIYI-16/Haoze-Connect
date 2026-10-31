import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  final (
    rustTarget,
    includeTarget,
  ) = switch (input.config.code.targetArchitecture) {
    Architecture.arm64 => ('aarch64_linux_android', 'aarch64-linux-android'),
    Architecture.arm => ('armv7_linux_androideabi', 'arm-linux-androideabi'),
    Architecture.x64 => ('x86_64_linux_android', 'x86_64-linux-android'),
    _ => throw UnsupportedError('Unsupported Android architecture'),
  };
  final resource = Process.runSync(compiler.toFilePath(), [
    '-print-resource-dir',
  ]);
  final resourcePath = (resource.stdout as String).trim();
  if (resource.exitCode != 0 ||
      !File('$resourcePath/include/stdbool.h').existsSync()) {
    throw StateError('NDK clang resource headers are unavailable');
  }
  final sysroot = '${llvmRoot.path}/sysroot';
  final args = [
    '--sysroot="$sysroot"',
    '-I"$sysroot/usr/include/$includeTarget"',
    '-resource-dir="$resourcePath"',
  ].join(' ').replaceAll(r'\', '/');
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {
        'LIBCLANG_PATH': directory.path,
        'BINDGEN_EXTRA_CLANG_ARGS_$rustTarget': args,
      };
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
