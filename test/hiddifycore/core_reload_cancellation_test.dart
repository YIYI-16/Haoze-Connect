import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  late _ManagedCore core;
  late _Service service;
  late ProviderContainer container;

  setUp(() {
    core = _ManagedCore();
    container = ProviderContainer();
    service = container.read(Provider((ref) => _Service(ref, core)));
    service.currentState = const CoreStatus.started();
  });
  tearDown(() async {
    if (!core.startFinished.isCompleted) core.startFinished.complete();
    if (!core.nextStartFinished.isCompleted) core.nextStartFinished.complete();
    await service.stopListenSingle('');
    await service.statusController.close();
    await core.channel.shutdown();
    container.dispose();
  });

  test('a stop during options application cancels the later reload', () async {
    final beforeOptions = service.stopGeneration;
    await service.stop().run();
    final result = await service
        .reload('private-config', 'Managed', false, expectedStopGeneration: beforeOptions)
        .run();
    expect(result.isRight(), isTrue);
    expect(core.starts, 0);
    expect(core.stops, 1);
  });

  test('a user stop also stops a managed restart that finishes late', () async {
    final pending = service.reload('private-config', 'Managed', false).run();
    await core.startEntered.future;
    await service.stop().run();
    core.startFinished.complete();
    final result = await pending;
    expect(result.isRight(), isTrue);
    expect(core.starts, 1);
    expect(core.stops, 2);
    expect(service.logSubscriptions, 0);
    expect(service.currentState, isA<CoreStopped>());
  });

  test('an unavailable managed settings channel cannot report success', () async {
    core.optionsError = const GrpcError.unavailable('loopback test endpoint');
    final result = await service.changeOptions(_Options()).run();
    expect(result.isLeft(), isTrue);
    expect(result.fold((message) => message, (_) => ''), contains('UNAVAILABLE'));
  });

  test('late cleanup from a cancelled restart does not stop a newer connection', () async {
    final previous = service.reload('old-config', 'Managed', false).run();
    await core.startEntered.future;
    await service.stop().run();
    final newer = service.start('new-config', 'Managed', false).run();
    await core.nextStartEntered.future;
    core.startFinished.complete();
    await previous;
    expect(core.stops, 1, reason: 'the old request must not stop the newer startup');
    core.nextStartFinished.complete();
    expect((await newer).isRight(), isTrue);
    expect(core.stops, 1);
    expect(service.logSubscriptions, 1);
  });
}

class _Service extends HiddifyCoreService {
  _Service(super.ref, CoreInterface core) : super(core: core);
  int logSubscriptions = 0;

  @override
  Future<void> startListeningLogs(String key, CoreClient cc) async {
    logSubscriptions++;
  }
}

class _ManagedCore extends CoreInterface {
  _ManagedCore() {
    fgClient = bgClient = CoreClient(channel);
  }

  final channel = ClientChannel(
    '127.0.0.1',
    port: 1,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  final startEntered = Completer<void>();
  final startFinished = Completer<void>();
  final nextStartEntered = Completer<void>();
  final nextStartFinished = Completer<void>();
  int starts = 0;
  int stops = 0;
  Object? optionsError;

  @override
  bool get managesLifecycle => true;
  @override
  bool get supportsHotReload => false;

  @override
  Future<void> startManaged(String path, String name, bool disableMemoryLimit) async {
    starts++;
    if (starts == 1) {
      startEntered.complete();
      await startFinished.future;
    } else {
      nextStartEntered.complete();
      await nextStartFinished.future;
    }
  }

  @override
  Future<bool> stop() async {
    stops++;
    return true;
  }

  @override
  Future<void> setOptions(SingboxConfigOption options) async {
    if (optionsError case final error?) throw error;
  }
}

class _Options implements SingboxConfigOption {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
