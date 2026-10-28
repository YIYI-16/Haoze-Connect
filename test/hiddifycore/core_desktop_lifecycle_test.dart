import 'dart:async';

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

  test('TUN refresh atomically restarts and waits through teardown for actual startup', () async {
    var finished = false;
    final reload = core.startManaged('managed-config', 'Managed', false).then((_) => finished = true);
    await native.restartEntered.future;
    await _deliverStatuses();
    expect(finished, isFalse);
    expect(native.restartCalls, 1);
    expect(native.startCalls, 0);
    expect(native.stopCalls, 0, reason: 'manual Stop then Start races native asynchronous teardown');

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
}

Future<void> _deliverStatuses() => Future<void>.delayed(const Duration(milliseconds: 30));

/// Models the native protocol: lifecycle RPCs acknowledge queueing immediately;
/// CoreInfoListener carries their eventual outcome.
class _ForegroundService extends CoreServiceBase {
  final status = BehaviorSubject<CoreInfoResponse>.seeded(CoreInfoResponse(coreState: CoreStates.STARTED));
  final restartEntered = Completer<void>();
  final stopEntered = Completer<void>();
  int restartCalls = 0;
  int stopCalls = 0;
  int startCalls = 0;

  void emit(CoreStates state, {MessageType messageType = MessageType.EMPTY, String message = ''}) {
    status.add(CoreInfoResponse(coreState: state, messageType: messageType, message: message));
  }

  @override
  Stream<CoreInfoResponse> coreInfoListener(ServiceCall call, Empty request) => status.stream;

  @override
  Future<CoreInfoResponse> changeHiddifySettings(ServiceCall call, ChangeHiddifySettingsRequest request) async =>
      CoreInfoResponse(messageType: MessageType.EMPTY);

  @override
  Future<CoreInfoResponse> restart(ServiceCall call, StartRequest request) async {
    restartCalls++;
    emit(CoreStates.STOPPING);
    if (!restartEntered.isCompleted) restartEntered.complete();
    return CoreInfoResponse(coreState: CoreStates.STOPPING);
  }

  @override
  Future<CoreInfoResponse> stop(ServiceCall call, Empty request) async {
    stopCalls++;
    if (!stopEntered.isCompleted) stopEntered.complete();
    if (status.value.coreState == CoreStates.STOPPED) {
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
