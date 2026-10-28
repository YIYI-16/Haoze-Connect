import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_desktop.dart';
import 'package:hiddify/hiddifycore/core_interface/vpn_config_snapshot.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

/// Windows and Linux: full core usually runs in elevated admin_bgservice
/// (`HiddifyAdminBG`). Flutter never elevates; [NeedAdminBgService] /
/// [EnsureAdminBgService] live in hiddify-core.
class CoreInterfaceDesktopTun extends CoreInterfaceDesktop {
  CoreInterfaceDesktopTun({
    Future<bool> Function()? privilegeProbe,
    this.stopTimeout = const Duration(seconds: 8),
    this.startTimeout = const Duration(seconds: 30),
    this.tunCollisionRetryDelay = const Duration(milliseconds: 500),
  }) : _privilegeProbe = privilegeProbe,
       super(port: 17078);

  final Future<bool> Function()? _privilegeProbe;
  final Duration stopTimeout;
  final Duration startTimeout;
  final Duration tunCollisionRetryDelay;
  int _stopEpoch = 0;
  int _startOperation = 0;
  final _operationChanges = StreamController<void>.broadcast(sync: true);

  static const _servicePort = 18020;
  final _status = BehaviorSubject<CoreStatus>.seeded(const CoreStatus.stopped());
  final _clientChanges = StreamController<void>.broadcast();
  ClientChannel? _serviceChannel;
  Future<void>? _pendingAdminEnsure;
  Directory? _workingDirectory;
  SingboxConfigOption? _options;
  bool _usingAdminBg = false;
  bool? _privileged;
  late String _secret;

  /// When true, start via admin_bgservice even in proxy mode (Mode C prefer-admin).
  bool useAdminBgService = false;

  /// Optional UI wrapper around elevation (waiting dialog). Returns false if the user stops.
  Future<bool> Function(Future<void> work)? wrapAdminElevation;

  /// AppImage payload lives under a user FUSE mount; root/`pkexec` cannot exec that path.
  bool get _isAppImage => Platform.isLinux && (Platform.environment['APPIMAGE'] ?? '').isNotEmpty;

  @override
  bool get managesLifecycle => true;
  // The privileged control service permits observation and node selection;
  // changed configurations must go through Ensure with a fresh snapshot.
  @override
  bool get supportsHotReload => !_usingAdminBg && !useAdminBgService && !(_options?.enableTun ?? false);
  @override
  bool get persistsAfterAppExit => false;
  @override
  Stream<CoreStatus> get managedStatus => _status.stream;
  @override
  Stream<void> get clientChanges => _clientChanges.stream;

  String get _cliPath {
    final dir = p.dirname(Platform.resolvedExecutable);
    return p.join(dir, Platform.isWindows ? 'HiddifyCli.exe' : 'HiddifyCli');
  }

  String get _dataDir {
    if (Platform.isWindows) {
      final base = Platform.environment['PROGRAMDATA'] ?? r'C:\ProgramData';
      return p.join(base, 'Hiddify', 'AdminBgService');
    }
    return '/var/lib/hiddify-admin-bgservice';
  }

  String get _secretPath => p.join(_dataDir, 'control.secret');

  String get _ownerUser =>
      Platform.isWindows ? (Platform.environment['USERNAME'] ?? '') : (Platform.environment['USER'] ?? '');

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    final error = await super.setup(directories, debug, mode);
    if (error.isNotEmpty) return error;
    _workingDirectory = directories.workingDir.absolute;
    return '';
  }

  @override
  Future<void> setOptions(SingboxConfigOption options) async {
    _options = options;
    // When admin_bgservice will own TUN, fg must not enable TUN; full settings go in Ensure.
    final adminOwnsTun = useAdminBgService || (options.enableTun && !await _isPrivileged());
    final forFg = adminOwnsTun ? options.copyWith(enableTun: false) : options;
    final response = await fgClient.changeHiddifySettings(
      ChangeHiddifySettingsRequest(hiddifySettingsJson: jsonEncode(forFg.toJson())),
    );
    _checkResponse(response);
  }

  Future<NeedAdminBgServiceResponse> needAdminBgService({
    required String serviceMode,
    required String settingsJson,
    required AdminPreference adminPreference,
    bool privilegeErrorRemembered = false,
  }) {
    return fgClient.needAdminBgService(
      NeedAdminBgServiceRequest(
        serviceMode: serviceMode,
        hiddifySettingsJson: settingsJson,
        adminPreference: adminPreference,
        privilegeErrorRemembered: privilegeErrorRemembered,
      ),
    );
  }

  @override
  Future<void> startManaged(String path, String name, bool disableMemoryLimit) async {
    final operation = ++_startOperation;
    _operationChanges.add(null);
    final options = _options;
    if (options == null) throw StateError('Apply connection options before starting the core.');
    var epoch = _stopEpoch;
    final wantAdminBg = useAdminBgService || _usingAdminBg || options.enableTun;
    final elevationWrapper = wrapAdminElevation;
    final privileged = wantAdminBg && await _isPrivileged();
    if (!_ownsStart(operation, epoch)) return;
    final foreground = !wantAdminBg || privileged;
    final restoreForegroundOptions = privileged && (useAdminBgService || _usingAdminBg);

    if (!foreground || _usingAdminBg || _pendingAdminEnsure != null) {
      final expected = epoch + 1;
      final stopped = await stop();
      if (!stopped || !_ownsStart(operation, expected)) return;
      epoch = expected;
    }
    if (!foreground && _isAppImage) {
      throw StateError('VPN mode in the AppImage needs root. Quit and run: sudo ${Platform.environment['APPIMAGE']}');
    }
    if (foreground) {
      _usingAdminBg = false;
      useAdminBgService = false;
      wrapAdminElevation = null;
      bgClient = fgClient;
      _clientChanges.add(null);
    }

    // Restart already serializes native close/start. The retry below is only
    // for the specific IPv6-address collision, whose cleanup can remain stale
    // even after that serialized teardown. Never retry a generic TUN failure.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!_ownsStart(operation, epoch)) return;
      _status.add(const CoreStatus.starting());
      try {
        if (foreground) {
          if (restoreForegroundOptions) {
            _checkResponse(
              await fgClient.changeHiddifySettings(
                ChangeHiddifySettingsRequest(hiddifySettingsJson: jsonEncode(options.toJson())),
              ),
            );
            if (!_ownsStart(operation, epoch)) return;
          }
          final started = await _foregroundCommand(
            starting: true,
            epoch: epoch,
            operation: operation,
            send: () => fgClient.restart(
              StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit),
            ),
          );
          if (!started || !_ownsStart(operation, epoch)) return;
        } else {
          late final Future<void> ensure;
          ensure =
              _ensureAdminBgAndAttach(
                path: path,
                name: name,
                options: options,
                disableMemoryLimit: disableMemoryLimit,
                operation: operation,
                epoch: epoch,
              ).whenComplete(() {
                if (identical(_pendingAdminEnsure, ensure)) _pendingAdminEnsure = null;
              });
          _pendingAdminEnsure = ensure;
          if (elevationWrapper != null) {
            final ok = await elevationWrapper(ensure);
            await ensure;
            if (!_ownsStart(operation, epoch)) return;
            wrapAdminElevation = null;
            if (!ok) {
              throw StateError('Administrator permission was not given, so VPN mode could not connect.');
            }
          } else {
            await ensure;
          }
          if (!_ownsStart(operation, epoch)) return;
        }
        _status.add(const CoreStatus.started());
        return;
      } catch (error, stackTrace) {
        if (!_ownsStart(operation, epoch)) return;
        final collision = options.enableTun && _isTunIpv6AddressCollision(error);
        final expectedCleanup = epoch + 1;
        var stopped = false;
        // Public stop increments the epoch too. Only our exact cleanup epoch
        // may resume this operation; a user stop or newer start owns it otherwise.
        try {
          stopped = await _stop(confirmAdminStop: !foreground);
        } catch (stopError) {
          loggy.warning('could not confirm cleanup after native startup failure: ${stopError.runtimeType}');
        }
        if (!_ownsStart(operation, expectedCleanup)) return;
        epoch = expectedCleanup;
        if (collision && attempt == 0 && stopped) {
          await Future<void>.delayed(tunCollisionRetryDelay);
          if (!_ownsStart(operation, epoch)) return;
          continue;
        }
        final failure = collision ? StateError('$error\nVPN 虚拟网卡 IPv6 地址初始化冲突，无法安全恢复。请退出客户端后重新启动；若仍失败，请保留日志。') : error;
        _status.add(CoreStatus.stopped(alert: foreground ? null : CoreAlert.startFailed, message: failure.toString()));
        Error.throwWithStackTrace(failure, stackTrace);
      }
    }
  }

  bool _ownsStart(int operation, int epoch) => operation == _startOperation && epoch == _stopEpoch;

  bool _isTunIpv6AddressCollision(Object error) {
    const prefix = 'start inbound/tun[tun-in]: configure tun interface: set ipv6 address: ';
    const duplicates = ['The object already exists.', '对象已存在。'];
    final message = error.toString();
    return duplicates.any((suffix) => message.contains('$prefix$suffix'));
  }

  /// Wait for the native outcome, not the immediate RPC acknowledgement.
  Future<bool> _foregroundCommand({
    required bool starting,
    required Future<CoreInfoResponse> Function() send,
    int? epoch,
    int? operation,
  }) async {
    final ready = Completer<void>();
    final outcome = Completer<CoreInfoResponse?>();
    Object? streamFailure;
    var issued = false;
    var sawStarting = false;
    bool isCurrent() => (epoch == null || _stopEpoch == epoch) && (operation == null || _startOperation == operation);
    var cancelled = !isCurrent();
    void finish(CoreInfoResponse? info) {
      if (!outcome.isCompleted) outcome.complete(info);
    }

    void fail(Object error) {
      if (outcome.isCompleted) return;
      streamFailure = error;
      if (!ready.isCompleted) ready.complete();
      finish(null);
    }

    final statuses = fgClient
        .coreInfoListener(Empty())
        .listen(
          (info) {
            // Arm after the initial snapshot: an earlier STOPPED is not the
            // outcome of the command about to be issued.
            if (!ready.isCompleted) {
              ready.complete();
              return;
            }
            if (!issued) return;
            if (!starting) {
              if (info.coreState == CoreStates.STOPPED) finish(info);
              return;
            }
            if (info.coreState == CoreStates.STARTING) sawStarting = true;
            if (_isRunningState(info.coreState) ||
                (info.coreState == CoreStates.STOPPED &&
                    (sawStarting ||
                        (info.messageType != MessageType.EMPTY && info.messageType != MessageType.ALREADY_STOPPED)))) {
              finish(info);
            }
          },
          onError: (Object error) => fail(error),
          onDone: () => fail(StateError('The native status channel closed.')),
        );
    final cancellation = epoch == null && operation == null
        ? null
        : _operationChanges.stream.listen((_) {
            if (isCurrent()) return;
            cancelled = true;
            if (!ready.isCompleted) ready.complete();
            finish(null);
          });
    try {
      return await (() async {
        await ready.future;
        if (cancelled) return false;
        if (streamFailure != null) throw StateError('The native status channel is unavailable.');
        issued = true;
        final response = await send();
        if (cancelled) return false;
        _checkResponse(response, allowStopped: !starting);
        if (!starting && response.coreState == CoreStates.STOPPED) return true;
        if (starting && _isRunningState(response.coreState)) return true;
        final finalState = await outcome.future;
        if (cancelled) return false;
        if (streamFailure != null || finalState == null) {
          throw StateError('The native status channel is unavailable.');
        }
        _checkResponse(finalState, allowStopped: !starting);
        if (starting && !_isRunningState(finalState.coreState)) {
          throw StateError('The native core stopped before startup completed.');
        }
        return true;
      })().timeout(starting ? startTimeout : stopTimeout);
    } finally {
      await cancellation?.cancel();
      await statuses.cancel();
    }
  }

  bool _isRunningState(CoreStates state) =>
      state == CoreStates.WAITING || state == CoreStates.STARTED || state == CoreStates.NO_AVAILABLE_PROXIES;

  Future<void> _ensureAdminBgAndAttach({
    required String path,
    required String name,
    required SingboxConfigOption options,
    required bool disableMemoryLimit,
    required int operation,
    required int epoch,
  }) async {
    final workingDirectory = _workingDirectory;
    if (workingDirectory == null) throw StateError('Set up the core before starting VPN mode.');
    final snapshot = await snapshotVpnConfiguration(path, workingDirectory);
    if (!_ownsStart(operation, epoch)) return;
    final resources = <String, List<int>>{};
    for (final entry in snapshot.$2.entries) {
      resources[entry.key] = entry.value;
    }

    EnsureAdminBgServiceProgress? last;
    String? lastMessage;
    await for (final event in fgClient.ensureAdminBgService(
      EnsureAdminBgServiceRequest(
        configContent: snapshot.$1,
        configName: name,
        settingsJson: jsonEncode(options.toJson()),
        resources: resources,
        disableMemoryLimit: disableMemoryLimit,
        ownerPid: pid,
        cliPath: _cliPath,
        ownerUser: _ownerUser,
      ),
    )) {
      last = event.progress;
      lastMessage = event.message;
      if (event.progress == EnsureAdminBgServiceProgress.ENSURE_ADMIN_BG_FAILED_PERMISSION_DENIED ||
          event.progress == EnsureAdminBgServiceProgress.ENSURE_ADMIN_BG_FAILED_OTHER) {
        throw StateError(
          (event.message.isNotEmpty)
              ? event.message
              : 'Could not start the VPN service. Allow the administrator prompt and try again.',
        );
      }
    }
    if (!_ownsStart(operation, epoch)) return;
    if (last != EnsureAdminBgServiceProgress.ENSURE_ADMIN_BG_SERVICE_CONNECTED) {
      throw StateError(
        (lastMessage != null && lastMessage.isNotEmpty) ? lastMessage : 'The VPN service did not become ready.',
      );
    }

    final secret = (await File(_secretPath).readAsString()).trim();
    if (!_ownsStart(operation, epoch)) return;
    if (secret.length < 32) {
      throw StateError('The VPN service secret is missing. Reinstall the VPN service.');
    }
    _secret = secret;
    final old = _serviceChannel;
    _serviceChannel = ClientChannel(
      '127.0.0.1',
      port: _servicePort,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    bgClient = CoreClient(_serviceChannel!, options: CallOptions(metadata: {'x-hiddify-secret': _secret}));
    if (old != null) unawaited(old.shutdown());
    _usingAdminBg = true;
    _clientChanges.add(null);
  }

  /// A successful CLI exit alone is insufficient after a partially failed
  /// Ensure. Require the authenticated native core to report STOPPED as well.
  Future<void> _confirmAdminBgStopped() async {
    final secret = (await File(_secretPath).readAsString()).trim();
    if (secret.length < 32) throw StateError('The VPN service secret is missing.');
    final channel = ClientChannel(
      '127.0.0.1',
      port: _servicePort,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    try {
      final client = CoreClient(
        channel,
        options: CallOptions(metadata: {'x-hiddify-secret': secret}, timeout: stopTimeout),
      );
      final state = await client.coreInfoListener(Empty()).first.timeout(stopTimeout);
      if (state.coreState != CoreStates.STOPPED) throw StateError('The VPN service did not confirm shutdown.');
    } finally {
      await channel.terminate();
    }
  }

  Future<bool> _isPrivileged() async {
    final cached = _privileged;
    if (cached != null) return cached;
    if (_privilegeProbe case final probe?) return _privileged = await probe();
    if (Platform.isLinux || Platform.isMacOS) {
      final result = await Process.run('id', ['-u']);
      _privileged = result.exitCode == 0 && result.stdout.toString().trim() == '0';
    } else if (Platform.isWindows) {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        '([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
      ]);
      _privileged = result.stdout.toString().trim().toLowerCase() == 'true';
    } else {
      _privileged = false;
    }
    return _privileged!;
  }

  Future<void> _runCli(List<String> args) async {
    final result = await Process.run(_cliPath, args);
    if (result.exitCode != 0) {
      final message = result.stderr.toString().trim();
      throw StateError(message.isEmpty ? 'The VPN service command failed.' : message);
    }
  }

  void _checkResponse(CoreInfoResponse response, {bool allowStopped = false}) {
    if (response.messageType != MessageType.EMPTY &&
        response.messageType != MessageType.ALREADY_STARTED &&
        !(allowStopped && response.messageType == MessageType.ALREADY_STOPPED)) {
      throw StateError('${response.messageType}: ${response.message}');
    }
  }

  @override
  Future<bool> stop() => _stop();

  Future<bool> _stop({bool confirmAdminStop = false}) async {
    final epoch = ++_stopEpoch;
    final operation = _startOperation;
    _operationChanges.add(null);
    _status.add(const CoreStatus.stopping());
    final wasAdminBg = _usingAdminBg;
    final pendingEnsure = _pendingAdminEnsure;
    final old = _serviceChannel;
    _serviceChannel = null;
    _usingAdminBg = false;
    useAdminBgService = false;
    wrapAdminElevation = null;
    bgClient = fgClient;
    _clientChanges.add(null);
    if (old != null) {
      unawaited(() async {
        try {
          await old.shutdown();
        } catch (error) {
          loggy.warning('service channel shutdown failed: $error');
        }
      }());
    }
    // Canceling the Ensure stream does not cancel its native CLI subprocess.
    // Observe its completion before disconnecting, so it cannot start a tunnel
    // after this stop has already reported success or after a newer start.
    if (pendingEnsure != null) {
      await pendingEnsure.catchError((Object _) {}).timeout(startTimeout);
      if (!_ownsStart(operation, epoch)) return false;
    }
    if (wasAdminBg || pendingEnsure != null || confirmAdminStop) {
      try {
        await _runCli(['admin_bgservice', 'disconnect']).timeout(stopTimeout);
        if (!_ownsStart(operation, epoch)) return false;
        if (confirmAdminStop) await _confirmAdminBgStopped();
      } catch (error) {
        if (!_ownsStart(operation, epoch)) return false;
        loggy.warning('stopping the VPN service failed: $error');
        rethrow;
      }
    }
    if (!_ownsStart(operation, epoch)) return false;
    try {
      final stopped = await _foregroundCommand(
        starting: false,
        epoch: epoch,
        operation: operation,
        send: () => fgClient.stop(Empty()),
      );
      if (!stopped || !_ownsStart(operation, epoch)) return false;
    } catch (error) {
      if (!_ownsStart(operation, epoch)) return false;
      loggy.warning('stopping the in-process core failed: ${error.runtimeType}');
      rethrow;
    }
    _status.add(const CoreStatus.stopped());
    return true;
  }

  @override
  Future<bool> isBgClientAvailable() async {
    if (!_usingAdminBg) return true;
    try {
      final socket = await Socket.connect('127.0.0.1', _servicePort, timeout: const Duration(milliseconds: 200));
      socket.destroy();
      return File(_secretPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> resetTunnel() async {
    await stop();
    return true;
  }

  @override
  Future<void> dispose() async {
    await _serviceChannel?.shutdown();
    await _clientChanges.close();
    await _operationChanges.close();
    await _status.close();
  }
}
