import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('overlapping replacements keep only the newest log stream', () async {
    final cancelled = Completer<void>();
    final old = StreamController<int>(onCancel: () => cancelled.future);
    final first = StreamController<int>();
    final latest = StreamController<int>();
    final provider = Provider((ref) => HiddifyCoreService(ref, core: CoreInterface()));
    final container = ProviderContainer();
    final service = container.read(provider);
    addTearDown(() async {
      if (!cancelled.isCompleted) cancelled.complete();
      await service.stopListenSingle('');
      await old.close();
      unawaited(first.close());
      await latest.close();
      await service.statusController.close();
      container.dispose();
    });

    await service.listenSingle('bgLogListener', () => old.stream);
    final earlierReplacement = service.listenSingle('bgLogListener', () => first.stream);
    await Future<void>.delayed(Duration.zero);
    final newerReplacement = service.listenSingle('bgLogListener', () => latest.stream);
    cancelled.complete();
    await Future.wait([earlierReplacement, newerReplacement]);

    expect(first.hasListener, isFalse, reason: 'an obsolete connection must not retain an untracked listener');
    expect(latest.hasListener, isTrue);
    expect(service.subscriptions.keys, ['bgLogListener']);
  });

  test('a stop cancels a replacement still waiting for its old stream to close', () async {
    final cancelled = Completer<void>();
    final old = StreamController<int>(onCancel: () => cancelled.future);
    final replacement = StreamController<int>();
    final container = ProviderContainer();
    final service = container.read(Provider((ref) => HiddifyCoreService(ref, core: CoreInterface())));
    addTearDown(() async {
      if (!cancelled.isCompleted) cancelled.complete();
      await service.stopListenSingle('');
      await old.close();
      unawaited(replacement.close());
      await service.statusController.close();
      container.dispose();
    });
    await service.listenSingle('bgLogListener', () => old.stream);
    final pending = service.listenSingle('bgLogListener', () => replacement.stream);
    await Future<void>.delayed(Duration.zero);
    await service.stopListenSingle('bg');
    cancelled.complete();
    await pending;
    expect(replacement.hasListener, isFalse);
    expect(service.subscriptions, isEmpty);
  });
}
