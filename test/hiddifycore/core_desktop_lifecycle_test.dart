import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_desktop_tun.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  late _ForegroundService native;
  late Server server;
  late ClientChannel channel;
  late CoreInterfaceDesktopTun core;
  late List<CoreStatus> statuses;
  late StreamSubscription<CoreStatus> statusSubscription;

  setUp(() async {
    native = _ForegroundService();
    server = Server.create(services: [native]);
    await server.serve(address: '127.0.0.1', port: 0);
    channel = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    core = CoreInterfaceDesktopTun(
      privilegeProbe: () async => true,
      stopTimeout: const Duration(seconds: 2),
      startTimeout: const Duration(seconds: 2),
      tunCollisionRetryDelay: Duration.zero,
    );
    core.fgClient = core.bgClient = CoreClient(channel);
    statuses = [];
    statusSubscription = core.managedStatus.listen(statuses.add);
    await core.setOptions(_TunOptions());
  });

  tearDown(() async {
    await statusSubscription.cancel();
    await core.dispose();
    await channel.shutdown();
    await server.shutdown();
    await native.status.close();
  });

  Future<void> useRetryDelay(Duration delay) async {
    await statusSubscription.cancel();
    await core.dispose();
    core = CoreInterfaceDesktopTun(
      privilegeProbe: () async => true,
      stopTimeout: const Duration(seconds: 2),
      startTimeout: const Duration(seconds: 2),
      tunCollisionRetryDelay: delay,
    );
    core.fgClient = core.bgClient = CoreClient(channel);
    statuses.clear();
    statusSubscription = core.managedStatus.listen(statuses.add);
    await core.setOptions(_TunOptions());
  }

  test('TUN refresh atomically restarts and waits through teardown for actual startup', () async {
    var finished = false;
    final reload = core.startManaged('managed-config', 'Managed', false).then((_) => finished = true);
    await native.restartEntered.future;
    await _deliverStatuses();
    expect(finished, isFalse);
    expect(native.restartCalls, 1);
    expect(native.startCalls, 0);
    expect(native.stopCalls, 0, reason: 'initial startup uses native serialized Restart without an extra cleanup Stop');

    native.emit(CoreStates.STOPPED);
    await _deliverStatuses();
    expect(finished, isFalse, reason: 'restart teardown is not the startup outcome');
    expect(statuses.whereType<CoreStarted>(), isEmpty);

    native.emit(CoreStates.STARTING);
    await _deliverStatuses();
    expect(finished, isFalse, reason: 'STARTING acknowledges a queued operation');
    native.emit(CoreStates.WAITING);
    await reload;
    await _deliverStatuses();
    expect(statuses.last, isA<CoreStarted>());
  });

  test('public stop waits for native STOPPED after immediate STOPPING acknowledgement', () async {
    var finished = false;
    final stopped = core.stop().then((value) {
      finished = true;
      return value;
    });
    await native.stopEntered.future;
    await _deliverStatuses();
    expect(finished, isFalse);
    expect(statuses.last, isA<CoreStopping>());

    native.emit(CoreStates.STOPPED);
    expect(await stopped, isTrue);
    await _deliverStatuses();
    expect(statuses.last, isA<CoreStopped>());
  });

  test('asynchronous startup failure propagates and cleans up without reporting started', () async {
    final reload = core.startManaged('managed-config', 'Managed', false);
    final failure = expectLater(
      reload,
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('START_SERVICE'))),
    );
    await native.restartEntered.future;
    native.emit(CoreStates.STARTING);
    native.emit(CoreStates.STOPPED, messageType: MessageType.START_SERVICE, message: 'synthetic startup failure');
    await failure;
    await _deliverStatuses();
    expect(native.stopCalls, 1, reason: 'a failed native startup is cancelled before returning its error');
    expect(statuses.whereType<CoreStarted>(), isEmpty);
    expect(statuses.last, isA<CoreStopped>());
  });

  test('an elevated foreground start restores options previously stripped for an admin service', () async {
    core.useAdminBgService = true;
    native.settingsJson = '{"enable-tun":false}';
    final restart = core.startManaged('managed-config', 'Managed', false);
    await native.restartEntered.future;
    final settings = jsonDecode(native.settingsJson) as Map<String, dynamic>;
    expect(settings['enable-tun'], isTrue);
    expect(core.useAdminBgService, isFalse);
    native.emit(CoreStates.STARTING);
    native.emit(CoreStates.WAITING);
    await restart;
  });

  test('stop timeout propagates without claiming native teardown finished', () async {
    await expectLater(core.stop(), throwsA(isA<TimeoutException>()));
    expect(native.stopCalls, 1);
    await _deliverStatuses();
    expect(statuses.last, isA<CoreStopping>());
  });

  test('stop during restart cancels its wait and cannot publish a late started status', () async {
    final reload = core.startManaged('managed-config', 'Managed', false);
    await native.restartEntered.future;
    native.emit(CoreStates.STARTING);
    final stopped = core.stop();
    await native.stopEntered.future;
    native.emit(CoreStates.STOPPED);
    expect(await stopped, isTrue);
    await reload;

    native.emit(CoreStates.WAITING);
    await _deliverStatuses();
    expect(statuses.whereType<CoreStarted>(), isEmpty);
    expect(statuses.last, isA<CoreStopped>());
    expect(native.restartCalls, 1);
    expect(native.startCalls, 0);
    expect(native.stopCalls, 1);
  });

  for (final collision in [_ipv6Collision, _localizedIpv6Collision]) {
    test('exact IPv6 collision stops and retries once before reporting connected: $collision', () async {
      native.restartFailures[1] = collision;
      native.startAutomatically = true;

      await core.startManaged('managed-config', 'Managed', false);
      await _deliverStatuses();

      expect(native.restartCalls, 2);
      expect(native.stopCalls, 1);
      expect(native.startCalls, 0);
      expect(native.commands, ['restart', 'stop', 'restart']);
      expect(statuses.last, isA<CoreStarted>());
      expect((jsonDecode(native.settingsJson) as Map<String, dynamic>)['enable-tun'], isTrue);
    });
  }

  test('a repeated exact IPv6 collision fails with guidance after one retry', () async {
    native.restartFailures.addAll({1: _ipv6Collision, 2: _ipv6Collision});

    await expectLater(
      core.startManaged('managed-config', 'Managed', false),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'original error', contains(_ipv6Collision))
            .having((error) => error.message, 'recovery guidance', contains('VPN 虚拟网卡 IPv6 地址初始化冲突')),
      ),
    );
    await _deliverStatuses();

    expect(native.restartCalls, 2);
    expect(native.stopCalls, 2, reason: 'the final failed retry must also be cleaned up');
    expect(native.startCalls, 0);
    expect(statuses.whereType<CoreStarted>(), isEmpty);
    expect(statuses.last, isA<CoreStopped>());
  });

  test('collision recovery waits for cleanup STOPPED instead of its STOPPING acknowledgement', () async {
    native.restartFailures[1] = _ipv6Collision;
    native.startAutomatically = true;
    native.deferStopConfirmation = true;
    final starting = core.startManaged('managed-config', 'Managed', false);
    await native.stopEntered.future;
    await _deliverStatuses();

    expect(native.restartCalls, 1);
    expect(statuses.whereType<CoreStarted>(), isEmpty);
    native.emit(CoreStates.STOPPED);
    await starting;
    await _deliverStatuses();

    expect(native.restartCalls, 2);
    expect(native.stopCalls, 1);
    expect(statuses.last, isA<CoreStarted>());
  });

  for (final unrelated in [
    'start inbound/tun[tun-in]: configure tun interface: set ipv4 address: The object already exists.',
    'start inbound/tun[tun-in]: configure tun interface: set ipv6 address: Access is denied.',
  ]) {
    test('unrelated startup errors retain the original failure without retry: $unrelated', () async {
      native.restartFailures[1] = unrelated;

      await expectLater(
        core.startManaged('managed-config', 'Managed', false),
        throwsA(isA<StateError>().having((error) => error.message, 'original message', 'UNEXPECTED_ERROR: $unrelated')),
      );

      expect(native.restartCalls, 1);
      expect(native.stopCalls, 1);
      expect(statuses.whereType<CoreStarted>(), isEmpty);
    });
  }

  test('a user stop during the recovery delay cancels the automatic retry', () async {
    await useRetryDelay(const Duration(milliseconds: 200));
    native.restartFailures[1] = _ipv6Collision;
    native.startAutomatically = true;
    final cleanedUp = core.managedStatus.skip(1).whereType<CoreStopped>().first;
    final starting = core.startManaged('old-config', 'Managed', false);
    await cleanedUp;
    await _deliverStatuses();

    expect(await core.stop(), isTrue);
    await starting;
    await _deliverStatuses();

    expect(native.restartCalls, 1);
    expect(native.stopCalls, 2);
    expect(statuses.whereType<CoreStarted>(), isEmpty);
    expect(statuses.last, isA<CoreStopped>());
  });

  test('a newer start supersedes an older delayed retry without stopping the new tunnel', () async {
    await useRetryDelay(const Duration(milliseconds: 200));
    native.restartFailures[1] = _ipv6Collision;
    native.startAutomatically = true;
    final cleanedUp = core.managedStatus.skip(1).whereType<CoreStopped>().first;
    final older = core.startManaged('old-config', 'Managed', false);
    await cleanedUp;
    await _deliverStatuses();

    await core.startManaged('new-config', 'Managed', false);
    await older;
    await _deliverStatuses();

    expect(native.restartCalls, 2);
    expect(native.restartPaths, ['old-config', 'new-config']);
    expect(native.stopCalls, 1, reason: 'only the older failed attempt owns the completed cleanup');
    expect(statuses.last, isA<CoreStarted>());
  });

  test('an unconfirmed cleanup cannot trigger an automatic retry', () async {
    native.restartFailures[1] = _ipv6Collision;
    native.failStop = true;

    await expectLater(
      core.startManaged('managed-config', 'Managed', false),
      throwsA(isA<StateError>().having((error) => error.message, 'original collision', contains(_ipv6Collision))),
    );
    await _deliverStatuses();

    expect(native.restartCalls, 1);
    expect(native.stopCalls, 1);
    expect(statuses.whereType<CoreStarted>(), isEmpty);
    expect(statuses.last, isA<CoreStopped>());
  });
}

const _ipv6Collision =
    'start inbound: start inbound/tun[tun-in]: configure tun interface: set ipv6 address: The object already exists.';
const _localizedIpv6Collision =
    'start inbound: start inbound/tun[tun-in]: configure tun interface: set ipv6 address: 对象已存在。';

Future<void> _deliverStatuses() => Future<void>.delayed(const Duration(milliseconds: 30));

/// Models the native protocol: lifecycle RPCs acknowledge queueing immediately;
/// CoreInfoListener carries their eventual outcome.
class _ForegroundService extends CoreServiceBase {
  final status = BehaviorSubject<CoreInfoResponse>.seeded(CoreInfoResponse(coreState: CoreStates.STARTED));
  final restartEntered = Completer<void>();
  final stopEntered = Completer<void>();
  final restartFailures = <int, String>{};
  final restartPaths = <String>[];
  final commands = <String>[];
  bool startAutomatically = false;
  bool failStop = false;
  bool deferStopConfirmation = false;
  int restartCalls = 0;
  int stopCalls = 0;
  int startCalls = 0;
  String settingsJson = '{}';

  void emit(CoreStates state, {MessageType messageType = MessageType.EMPTY, String message = ''}) {
    status.add(CoreInfoResponse(coreState: state, messageType: messageType, message: message));
  }

  @override
  Stream<CoreInfoResponse> coreInfoListener(ServiceCall call, Empty request) => status.stream;

  @override
  Future<CoreInfoResponse> changeHiddifySettings(ServiceCall call, ChangeHiddifySettingsRequest request) async {
    settingsJson = request.hiddifySettingsJson;
    return CoreInfoResponse(messageType: MessageType.EMPTY);
  }

  @override
  Future<CoreInfoResponse> restart(ServiceCall call, StartRequest request) async {
    restartCalls++;
    restartPaths.add(request.configPath);
    commands.add('restart');
    emit(CoreStates.STOPPING);
    if (!restartEntered.isCompleted) restartEntered.complete();
    final failure = restartFailures[restartCalls];
    if (failure != null) {
      emit(CoreStates.STARTING);
      emit(CoreStates.STOPPED, messageType: MessageType.UNEXPECTED_ERROR, message: failure);
    } else if (startAutomatically) {
      emit(CoreStates.STARTING);
      emit(CoreStates.WAITING);
    }
    return CoreInfoResponse(coreState: CoreStates.STOPPING);
  }

  @override
  Future<CoreInfoResponse> stop(ServiceCall call, Empty request) async {
    stopCalls++;
    commands.add('stop');
    if (!stopEntered.isCompleted) stopEntered.complete();
    if (failStop) throw const GrpcError.unavailable('synthetic cleanup failure');
    if (status.value.coreState == CoreStates.STOPPED && !deferStopConfirmation) {
      return CoreInfoResponse(coreState: CoreStates.STOPPED, messageType: MessageType.ALREADY_STOPPED);
    }
    emit(CoreStates.STOPPING);
    return CoreInfoResponse(coreState: CoreStates.STOPPING);
  }

  @override
  Future<CoreInfoResponse> start(ServiceCall call, StartRequest request) async {
    startCalls++;
    return CoreInfoResponse(coreState: status.value.coreState, messageType: MessageType.INSTANCE_NOT_STOPPED);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TunOptions implements SingboxConfigOption {
  @override
  bool get enableTun => true;

  @override
  Map<String, dynamic> toJson() => {'enable-tun': true};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
