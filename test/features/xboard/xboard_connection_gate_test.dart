import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The managed account is the only owner of the subscription, so the
/// connection controller must not start a tunnel for an account that has no
/// usable plan. Disconnecting stays possible.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'haptic_feedback': false});
  });

  test('a start is blocked while the account has no usable plan', () async {
    final repository = _FakeConnectionRepository();
    final container = ProviderContainer(
      overrides: [
        connectionRepositoryProvider.overrideWithValue(repository),
        // A real profile is active: without the account gate the controller
        // would happily connect through it, so this test can only pass while
        // the gate is in place.
        activeProfileProvider.overrideWith(_ActiveProfile.new),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        xboardConnectionAllowedProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);

    await container.read(sharedPreferencesProvider.future);
    await container.read(connectionNotifierProvider.future);
    await container.read(connectionNotifierProvider.notifier).toggleConnection();

    expect(repository.connectCalls, 0);
  });

  test('a stop is always allowed, even when the account may not start', () async {
    final repository = _FakeConnectionRepository(connected: true);
    final container = ProviderContainer(
      overrides: [
        connectionRepositoryProvider.overrideWithValue(repository),
        activeProfileProvider.overrideWith(_EmptyActiveProfile.new),
        xboardConnectionAllowedProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);

    await container.read(sharedPreferencesProvider.future);
    await container.read(connectionNotifierProvider.future);
    await container.read(connectionNotifierProvider.notifier).toggleConnection();

    expect(repository.disconnectCalls, 1);
    expect(repository.connectCalls, 0);
  });

  test('an allowed account cannot connect or reconnect an unmanaged active profile', () async {
    final repository = _FakeConnectionRepository();
    final container = ProviderContainer(
      overrides: [
        connectionRepositoryProvider.overrideWithValue(repository),
        activeProfileProvider.overrideWith(_ActiveProfile.new),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        xboardConnectionAllowedProvider.overrideWithValue(true),
        xboardManagedProfileIdProvider.overrideWithValue('another-managed-profile'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    await container.read(connectionNotifierProvider.future);
    final notifier = container.read(connectionNotifierProvider.notifier);
    await notifier.toggleConnection();
    expect(repository.connectCalls, 0);

    // Exercise the separate reconnect path while a tunnel is already running.
    final runningRepository = _FakeConnectionRepository(connected: true);
    final running = ProviderContainer(
      overrides: [
        connectionRepositoryProvider.overrideWithValue(runningRepository),
        activeProfileProvider.overrideWith(_ActiveProfile.new),
        xboardConnectionAllowedProvider.overrideWithValue(true),
        xboardManagedProfileIdProvider.overrideWithValue('another-managed-profile'),
      ],
    );
    addTearDown(running.dispose);
    await running.read(sharedPreferencesProvider.future);
    await running.read(connectionNotifierProvider.future);
    await running.read(connectionNotifierProvider.notifier).reconnect(await running.read(activeProfileProvider.future));
    expect(runningRepository.reconnectCalls, 0);
  });

  test('the same setup connects once the account allows it', () async {
    // The control for the test above: with the same active profile and the
    // same fake repository, an allowed account does connect. Without it the
    // blocked test could pass for the wrong reason.
    final repository = _FakeConnectionRepository();
    final container = ProviderContainer(
      overrides: [
        connectionRepositoryProvider.overrideWithValue(repository),
        activeProfileProvider.overrideWith(_ActiveProfile.new),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
        xboardConnectionAllowedProvider.overrideWithValue(true),
        xboardManagedProfileIdProvider.overrideWithValue('profile-1'),
      ],
    );
    addTearDown(container.dispose);

    await container.read(sharedPreferencesProvider.future);
    await container.read(translationsProvider.future);
    await container.read(connectionNotifierProvider.future);
    await container.read(connectionNotifierProvider.notifier).toggleConnection();

    expect(repository.connectCalls, 1);
  });
}

class _EmptyActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(null);
}

/// An account with a real, active profile behind it.
///
/// The gate has to stop this one: a profile that exists would otherwise be
/// enough to start a tunnel.
class _ActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(
    ProfileEntity.remote(
      id: 'profile-1',
      active: true,
      name: 'Managed',
      url: 'https://sub.example.net/api/v1/client/subscribe?token=abc',
      lastUpdate: DateTime.fromMillisecondsSinceEpoch(0),
    ),
  );
}

class _FakeConnectionRepository implements ConnectionRepository {
  _FakeConnectionRepository({bool connected = false}) : _status = connected ? const Connected() : const Disconnected();

  final ConnectionStatus _status;
  int connectCalls = 0;
  int disconnectCalls = 0;
  int reconnectCalls = 0;

  @override
  SingboxConfigOption? get configOptionsSnapshot => null;

  @override
  TaskEither<ConnectionFailure, Unit> setup() => TaskEither.of(unit);

  @override
  Stream<ConnectionStatus> watchConnectionStatus() => Stream.value(_status);

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) {
    connectCalls++;
    return TaskEither.of(unit);
  }

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() {
    disconnectCalls++;
    return TaskEither.of(unit);
  }

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) {
    reconnectCalls++;
    return TaskEither.of(unit);
  }
}
