import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_mobile.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Core core;
  late _Service service;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    core = _Core();
    container = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWith(_Directories.new),
        sharedPreferencesProvider.overrideWith((ref) => preferences),
      ],
    );
    await container.read(appDirectoriesProvider.future);
    await container.read(sharedPreferencesProvider.future);
    service = container.read(Provider((ref) => _Service(ref, core)));
  });

  tearDown(() async {
    await service.stopListenSingle('');
    await service.statusController.close();
    await core.status.close();
    await core.fgChannel.shutdown();
    await core.bgChannel.shutdown();
    container.dispose();
  });

  test('overlapping setup calls share initialization and keep mTLS enabled', () async {
    core.setupGate = Completer<void>();
    core.backgroundAvailable = true;
    final first = service.setup().run();
    final second = service.setup().run();
    await Future<void>.delayed(Duration.zero);
    expect(core.setupCalls, 1);
    core.setupGate!.complete();

    expect((await first).isRight(), isTrue);
    expect((await second).isRight(), isTrue);
    expect(core.setupModes, [1]);
    expect(service.logKeys, ['fgLogListener', 'bgLogListener']);
    expect(core.statusBindings, 1);
  });

  test('resume skips background logs until available and binds platform status once', () async {
    expect((await service.setup().run()).isRight(), isTrue);
    expect(service.logKeys, ['fgLogListener']);
    expect(core.statusBindings, 1);

    core.backgroundAvailable = true;
    expect((await service.setup().run()).isRight(), isTrue);
    expect(service.logKeys, ['fgLogListener', 'fgLogListener', 'bgLogListener']);
    expect(core.statusBindings, 1);
    expect(core.setupCalls, 2, reason: 'a later resume must still refresh native state');
  });

  test('failed setup is shared and a later setup can retry', () async {
    core.setupGate = Completer<void>();
    core.setupError = 'mTLS test failure';
    final first = service.setup().run();
    final second = service.setup().run();
    core.setupGate!.complete();

    expect((await first).fold((error) => error, (_) => ''), 'mTLS test failure');
    expect((await second).isLeft(), isTrue);
    expect(core.setupCalls, 1);
    expect(service.logKeys, isEmpty);

    core.setupError = '';
    expect((await service.setup().run()).isRight(), isTrue);
    expect(core.setupCalls, 2);
  });

  test('a missing background removes its old log listener', () async {
    final logs = StreamController<int>();
    addTearDown(logs.close);
    service.subscriptions['bgLogListener'] = logs.stream.listen((_) {});
    expect(logs.hasListener, isTrue);

    await service.startListeningLogs('bg', core.bgClient);

    expect(logs.hasListener, isFalse);
    expect(service.subscriptions.containsKey('bgLogListener'), isFalse);
    expect(service.logKeys, isEmpty);
  });

  test('mobile availability follows the background service throughout its lifecycle', () async {
    final mobile = _MobileCore();
    addTearDown(mobile.dispose);
    expect(await mobile.isBgClientAvailable(), isFalse);

    mobile.available = true;
    expect(await mobile.isBgClientAvailable(), isTrue);

    mobile.available = false;
    expect(await mobile.isBgClientAvailable(), isFalse);
  });
}

class _Service extends HiddifyCoreService {
  _Service(super.ref, CoreInterface core) : super(core: core);
  final logKeys = <String>[];

  @override
  Future<StreamSubscription<T>?> listenSingle<T>(
    String key,
    Stream<T> Function() stream, {
    Function(dynamic error)? onError,
  }) async {
    logKeys.add(key);
    return null;
  }
}

class _Core extends CoreInterface {
  _Core() {
    fgClient = CoreClient(fgChannel);
    bgClient = CoreClient(bgChannel);
    status = StreamController<CoreStatus>.broadcast(onListen: () => statusBindings++);
  }

  final fgChannel = ClientChannel('127.0.0.1', port: 1);
  final bgChannel = ClientChannel('127.0.0.1', port: 2);
  late final StreamController<CoreStatus> status;
  int statusBindings = 0;
  int setupCalls = 0;
  final setupModes = <int>[];
  bool backgroundAvailable = false;
  String setupError = '';
  Completer<void>? setupGate;

  @override
  Stream<CoreStatus> get managedStatus => status.stream;

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    setupCalls++;
    setupModes.add(mode);
    await setupGate?.future;
    return setupError;
  }

  @override
  Future<bool> isBgClientAvailable() async => backgroundAvailable;
}

class _Directories extends AppDirectories {
  @override
  Future<Directories> build() async {
    final dir = Directory('.');
    return (baseDir: dir, workingDir: dir, tempDir: dir);
  }
}

class _MobileCore extends CoreInterfaceMobile {
  bool available = false;

  @override
  Future<bool> isActiveBg() async => available;
}
