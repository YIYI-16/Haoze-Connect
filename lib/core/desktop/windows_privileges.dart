import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as paths;
import 'package:win32_registry/win32_registry.dart';

const _tokenQuery = 0x0008;
const _tokenElevation = 20;

enum WindowsTunPrivilege { direct, helper, administratorRequired }

WindowsTunPrivilege windowsTunPrivilege({
  required bool elevated,
  required String executableDirectory,
  required Iterable<String> programDirectories,
}) {
  if (elevated) return WindowsTunPrivilege.direct;
  final directory = paths.windows.normalize(executableDirectory).toLowerCase();
  if (paths.windows.isAbsolute(directory)) {
    for (final root in programDirectories) {
      final base = paths.windows.normalize(root).toLowerCase();
      if (paths.windows.isAbsolute(base) &&
          paths.windows.isWithin(base, directory)) {
        return WindowsTunPrivilege.helper;
      }
    }
  }
  return WindowsTunPrivilege.administratorRequired;
}

List<String> readWindowsProgramDirectories() {
  if (!Platform.isWindows) return const [];
  try {
    final key = LOCAL_MACHINE.open(
      r'SOFTWARE\Microsoft\Windows\CurrentVersion',
    );
    try {
      return [
        for (final name in ['ProgramFilesDir', 'ProgramFilesDir (x86)'])
          if (key.getString(name) case final String directory) directory,
      ];
    } finally {
      key.close();
    }
  } catch (_) {
    return const [];
  }
}

bool readWindowsProcessElevation() {
  if (!Platform.isWindows) return false;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final security = DynamicLibrary.open('advapi32.dll');
  final currentProcess = kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
  final openToken = security
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<IntPtr>),
        int Function(int, int, Pointer<IntPtr>)
      >('OpenProcessToken');
  final getInformation = security
      .lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
      >('GetTokenInformation');
  final close = kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final token = calloc<IntPtr>();
  final elevation = calloc<Uint32>();
  final length = calloc<Uint32>();
  try {
    if (openToken(currentProcess(), _tokenQuery, token) == 0) return false;
    return getInformation(
              token.value,
              _tokenElevation,
              elevation.cast(),
              sizeOf<Uint32>(),
              length,
            ) !=
            0 &&
        length.value == sizeOf<Uint32>() &&
        elevation.value != 0;
  } finally {
    if (token.value != 0) close(token.value);
    calloc.free(token);
    calloc.free(elevation);
    calloc.free(length);
  }
}
