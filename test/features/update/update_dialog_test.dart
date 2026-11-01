import 'dart:async';
import 'dart:io';

import 'package:fl_clash/features/update/update_dialog.dart';
import 'package:fl_clash/features/update/update_installer.dart';
import 'package:fl_clash/features/update/update_service.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

class PreviewService extends HaozeUpdateService {
  PreviewService()
    : super(
        panelOrigin: Uri.https('panel.example'),
        transport: IoUpdateTransport(),
        platform: UpdatePlatform.windows,
        identity: const UpdateIdentity(version: '6.0.3', versionCode: 62003),
        directory: () async => Directory.systemTemp,
      );
  int checks = 0;
  int downloads = 0;
  bool failCheck = false;
  UpdateFailure checkFailure = UpdateFailure.network;
  bool upToDate = false;
  bool pendingDownload = false;
  UpdateCancellation? token;
  Completer<File>? completion;
  void Function(double)? showProgress;
  @override
  Future<UpdateRelease?> check(UpdateCancellation cancellation) async {
    checks++;
    if (failCheck) throw UpdateException(checkFailure);
    if (upToDate) return null;
    return parseManifest({
      'schema': 1,
      'channel': 'stable',
      'version': '6.0.4',
      'platforms': {
        'windows': {
          'name': 'HaozeConnect-Windows-Setup-x64-6.0.4.exe',
          'bytes': 8,
          'sha256': 'a' * 64,
        },
      },
    }, '6.0.4');
  }

  @override
  Future<File> download(
    UpdateRelease release,
    UpdateCancellation cancellation, {
    required void Function(double) progress,
    required void Function() verifying,
  }) async {
    downloads++;
    token = cancellation;
    showProgress = progress;
    if (pendingDownload) {
      completion = Completer<File>();
      return completion!.future;
    }
    progress(1);
    verifying();
    return File('preview-update.exe');
  }
}

class PreviewInstaller implements UpdateInstallGateway {
  int installs = 0;
  int permissions = 0;
  bool denied = false;
  @override
  Future<void> install(File file, UpdateRelease release) async {
    installs++;
    if (denied) throw const UpdateException(UpdateFailure.permission);
  }

  @override
  Future<bool> requestPermission() async {
    permissions++;
    return true;
  }
}

void main() {
  late PreviewService service;
  late PreviewInstaller installer;
  setUp(() {
    service = PreviewService();
    installer = PreviewInstaller();
  });
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TestApp(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFloatingDialog<void>(
              context: context,
              child: HaozeUpdateDialog(
                serviceFactory: () async => service,
                installer: installer,
              ),
            ),
            child: const Text('Open updater'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open updater'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'checking and downloading never install before explicit consent',
    (tester) async {
      await open(tester);
      expect(find.text('v6.0.4'), findsOneWidget);
      expect(installer.installs, 0);
      expect(find.byKey(const ValueKey('update-install')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('update-download')));
      await tester.pumpAndSettle();
      expect(service.downloads, 1);
      expect(installer.installs, 0);
      expect(find.text('The update package has been verified'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-install')));
      await tester.pumpAndSettle();
      expect(installer.installs, 1);
      expect(
        find.text(
          'The system installer has opened. Confirm installation there.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'network errors cannot be reported as up to date and allow retry',
    (tester) async {
      service.failCheck = true;
      await open(tester);
      expect(find.text('The app is up to date'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      service.failCheck = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(service.checks, 2);
      expect(find.text('v6.0.4'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets('up-to-date result offers no installer action', (tester) async {
    service.upToDate = true;
    await open(tester);
    expect(find.text('The app is up to date'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-download')), findsNothing);
    expect(installer.installs, 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
  for (final entry in {
    UpdateFailure.panelAccess:
        'The panel version endpoint denied access. Ask the administrator to enable public update checks.',
    UpdateFailure.panelConfiguration:
        'The panel has not configured a valid version and download URL for this platform. Contact the administrator.',
  }.entries) {
    testWidgets(
      '${entry.key.name} explains the panel problem without claiming current',
      (tester) async {
        service.failCheck = true;
        service.checkFailure = entry.key;
        await open(tester);
        expect(find.text(entry.value), findsOneWidget);
        expect(find.text('The app is up to date'), findsNothing);
        expect(find.text('Retry'), findsOneWidget);
        expect(installer.installs, 0);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      },
    );
  }
  testWidgets(
    'progress is shown and cancellation never launches an installer',
    (tester) async {
      service.pendingDownload = true;
      await open(tester);
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('update-download')),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(service.downloads, 1);
      service.showProgress!(.5);
      await tester.pump();
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.token!.cancelled, true);
      expect(installer.installs, 0);
      service.completion!.complete(File('cancelled.exe'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'permission denial retains the verified file and requires another install tap',
    (tester) async {
      installer.denied = true;
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('update-download')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('update-install')));
      await tester.pumpAndSettle();
      expect(find.text('Allow update installation'), findsOneWidget);
      expect(installer.installs, 1);
      await tester.tap(find.text('Allow update installation'));
      await tester.pumpAndSettle();
      expect(installer.permissions, 1);
      expect(installer.installs, 1);
      installer.denied = false;
      await tester.tap(find.byKey(const ValueKey('update-install')));
      await tester.pumpAndSettle();
      expect(installer.installs, 2);
      expect(service.downloads, 1);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );
}
