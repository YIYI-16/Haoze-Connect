import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';

import 'update_installer.dart';
import 'update_service.dart';

Future<void> showHaozeUpdateDialog(BuildContext context) async {
  if (!system.isAndroid && !system.isWindows) {
    await dialogs.showAlert(
      title: context.appLocalizations.checkUpdate,
      message: TextSpan(text: context.appLocalizations.haozeUpdateUnsupported),
    );
    return;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final loading = loadingProvider(LoadingTag.checkUpdate);
  if (container.read(loading)) return;
  container.read(loading.notifier).value = true;
  try {
    await dialogs.showCommonDialog<void>(
      context: context,
      dismissible: false,
      child: HaozeUpdateDialog(
        serviceFactory: () async {
          final package = globalState.packageInfo;
          final native = system.isAndroid ? await app!.updateIdentity() : null;
          return HaozeUpdateService(
            transport: IoUpdateTransport(
              findProxy: (uri) =>
                  FlClashHttpOverrides.findProxyFor(container, uri),
            ),
            platform: system.isAndroid
                ? UpdatePlatform.android
                : UpdatePlatform.windows,
            identity: UpdateIdentity(
              version: native?['version'] as String? ?? package.version,
              versionCode:
                  (native?['versionCode'] as num?)?.toInt() ??
                  int.parse(package.buildNumber),
              package: native?['package'] as String?,
              certificate: native?['certificate'] as String?,
            ),
            directory: () async => Directory(
              paths.join((await getTemporaryDirectory()).path, 'haoze-updates'),
            ),
          );
        },
        installer: SystemUpdateInstallGateway(
          exitWindows: () =>
              container.read(systemActionProvider.notifier).handleExit(),
        ),
      ),
    );
  } finally {
    if (context.mounted) container.read(loading.notifier).value = false;
  }
}

enum _Phase {
  checking,
  current,
  available,
  downloading,
  verifying,
  ready,
  permission,
  installing,
  handedOff,
  failed,
}

class HaozeUpdateDialog extends StatefulWidget {
  const HaozeUpdateDialog({
    super.key,
    required this.serviceFactory,
    required this.installer,
  });
  final Future<HaozeUpdateService> Function() serviceFactory;
  final UpdateInstallGateway installer;

  @override
  State<HaozeUpdateDialog> createState() => _HaozeUpdateDialogState();
}

class _HaozeUpdateDialogState extends State<HaozeUpdateDialog> {
  _Phase _phase = _Phase.checking;
  UpdateFailure? _error;
  HaozeUpdateService? _service;
  UpdateRelease? _release;
  File? _file;
  var _progress = 0.0;
  var _permissionOpening = false;
  var _generation = 0;
  var _cancellation = UpdateCancellation();
  bool get _busy => [
    _Phase.checking,
    _Phase.downloading,
    _Phase.verifying,
    _Phase.installing,
  ].contains(_phase);

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void dispose() {
    _generation++;
    _cancellation.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final generation = ++_generation;
    _cancellation.cancel();
    _cancellation = UpdateCancellation();
    setState(() {
      _phase = _Phase.checking;
      _error = null;
      _file = null;
      _release = null;
    });
    try {
      final service = await widget.serviceFactory();
      final release = await service.check(_cancellation);
      if (!mounted || generation != _generation) return;
      setState(() {
        _service = service;
        _release = release;
        _phase = release == null ? _Phase.current : _Phase.available;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _phase = _Phase.failed;
          _error = _failure(error);
        });
      }
    }
  }

  UpdateFailure _failure(Object error) =>
      error is UpdateException ? error.failure : UpdateFailure.network;

  Future<void> _download() async {
    if (_busy || _release == null || _service == null) return;
    final generation = ++_generation;
    _cancellation.cancel();
    _cancellation = UpdateCancellation();
    setState(() {
      _phase = _Phase.downloading;
      _error = null;
      _progress = 0;
    });
    try {
      final file = await _service!.download(
        _release!,
        _cancellation,
        progress: (value) {
          if (mounted &&
              generation == _generation &&
              (value - _progress >= .01 || value == 1)) {
            setState(() => _progress = value);
          }
        },
        verifying: () {
          if (mounted && generation == _generation) {
            setState(() => _phase = _Phase.verifying);
          }
        },
      );
      if (mounted && generation == _generation) {
        setState(() {
          _file = file;
          _phase = _Phase.ready;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _phase = _Phase.failed;
          _error = _failure(error);
        });
      }
    }
  }

  Future<void> _install() async {
    if (_busy || _file == null || _release == null) return;
    setState(() {
      _phase = _Phase.installing;
      _error = null;
    });
    try {
      await widget.installer.install(_file!, _release!);
      if (mounted) setState(() => _phase = _Phase.handedOff);
    } catch (error) {
      if (!mounted) return;
      final failure = _failure(error);
      setState(() {
        _error = failure;
        _phase = failure == UpdateFailure.permission
            ? _Phase.permission
            : _Phase.ready;
      });
    }
  }

  Future<void> _permission() async {
    if (_permissionOpening) return;
    setState(() => _permissionOpening = true);
    try {
      if (!await widget.installer.requestPermission() && mounted) {
        setState(() => _error = UpdateFailure.install);
      }
    } catch (_) {
      if (mounted) setState(() => _error = UpdateFailure.install);
    } finally {
      if (mounted) setState(() => _permissionOpening = false);
    }
  }

  void _cancel() {
    _generation++;
    _cancellation.cancel();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final failureText = switch (_error) {
      UpdateFailure.metadata ||
      UpdateFailure.integrity => l10n.haozeUpdateInvalid,
      UpdateFailure.install => l10n.haozeUpdateInstallFailed,
      _ => l10n.haozeUpdateFailed,
    };
    final status = switch (_phase) {
      _Phase.checking => l10n.haozeUpdateChecking,
      _Phase.current => l10n.haozeUpdateCurrent,
      _Phase.available => l10n.discoverNewVersion,
      _Phase.downloading => l10n.haozeUpdateDownloading,
      _Phase.verifying => l10n.haozeUpdateVerifying,
      _Phase.ready => l10n.haozeUpdateReady,
      _Phase.permission => l10n.haozeUpdatePermission,
      _Phase.installing => l10n.haozeUpdateOpening,
      _Phase.handedOff => l10n.haozeUpdateHandedOff,
      _Phase.failed => failureText,
    };
    return PopScope(
      canPop: _phase != _Phase.installing,
      child: CommonDialog(
        title: l10n.checkUpdate,
        actions: [
          TextButton(
            onPressed: _phase == _Phase.installing ? null : _cancel,
            child: Text(_busy ? l10n.cancel : l10n.close),
          ),
          if (_phase == _Phase.available)
            TextButton(
              key: const ValueKey('update-download'),
              onPressed: _download,
              child: Text(l10n.download),
            ),
          if (_phase == _Phase.failed)
            TextButton(
              onPressed: _release == null ? _check : _download,
              child: Text(l10n.retry),
            ),
          if (_phase == _Phase.permission)
            TextButton(
              onPressed: _permissionOpening ? null : _permission,
              child: Text(l10n.haozeUpdateOpenPermission),
            ),
          if ([
            _Phase.ready,
            _Phase.permission,
            _Phase.handedOff,
          ].contains(_phase))
            TextButton(
              key: const ValueKey('update-install'),
              onPressed: _install,
              child: Text(l10n.haozeUpdateInstall),
            ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (_release case final release?)
              Text(
                'v${release.version}',
                style: AppTextStyle.headline.of(context),
              ),
            Text(status),
            if (_phase == _Phase.downloading || _phase == _Phase.verifying)
              LinearProgressIndicator(
                value: _phase == _Phase.downloading ? _progress : null,
              ),
            if (_phase == _Phase.downloading)
              Text('${(_progress * 100).floor()}%'),
            if (_error != null &&
                _phase != _Phase.permission &&
                _phase != _Phase.failed)
              Text(
                failureText,
                style: AppTextStyle.subheadline
                    .of(context)
                    .copyWith(color: context.colorScheme.error),
              ),
            if (_release?.platform == UpdatePlatform.windows &&
                _phase == _Phase.ready)
              Text(l10n.haozeUpdateWindowsHint),
          ],
        ),
      ),
    );
  }
}
