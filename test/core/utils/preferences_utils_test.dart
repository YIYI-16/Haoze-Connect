import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final key in ['extra-security-profile-id', 'unblocker-profile-id']) {
    test('$key can be cleared directly and through raw updates', () async {
      SharedPreferences.setMockInitialValues({key: 'saved-profile'});
      final preferences = await SharedPreferences.getInstance();
      final provider = PreferencesNotifier.create<String?, String?>(key, null);
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)],
      );
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);
      expect(container.read(provider), 'saved-profile');

      await container.read(provider.notifier).update(null);
      expect(container.read(provider), isNull);
      await preferences.reload();
      expect(preferences.containsKey(key), isFalse);

      await container.read(provider.notifier).update('another-profile');
      await container.read(provider.notifier).updateRaw(null);
      expect(container.read(provider), isNull);
      await preferences.reload();
      expect(preferences.containsKey(key), isFalse);
    });
  }

  test('raw mapping can successfully publish a nullable value', () async {
    SharedPreferences.setMockInitialValues({'nullable': 'saved'});
    final preferences = await SharedPreferences.getInstance();
    final provider = PreferencesNotifier.create<String?, String>(
      'nullable',
      null,
      mapFrom: (value) => value == 'clear' ? null : value,
    );
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);

    expect(container.read(provider), 'saved');
    await container.read(provider.notifier).updateRaw('clear');

    expect(container.read(provider), isNull);
    await preferences.reload();
    expect(preferences.containsKey('nullable'), isFalse);
  });

  for (final throwsOnWrite in [false, true]) {
    test('failed persistence preserves nullable and nonnullable state (throws: $throwsOnWrite)', () async {
      final preferences = _FailingPreferences(throwsOnWrite);
      final nullable = PreferencesNotifier.create<String?, String?>('nullable', null);
      final nonnullable = PreferencesNotifier.create<String, String>('nonnullable', 'default');
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWith((ref) => preferences)],
      );
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);
      expect(container.read(nullable), 'saved');
      expect(container.read(nonnullable), 'saved');

      await container.read(nullable.notifier).updateRaw(null);
      await container.read(nullable.notifier).update('new');
      await container.read(nonnullable.notifier).updateRaw('new');

      expect(container.read(nullable), 'saved');
      expect(container.read(nonnullable), 'saved');
    });
  }

  test('validation can reject clearing without removing the saved value', () async {
    SharedPreferences.setMockInitialValues({'nullable': 'saved'});
    final preferences = await SharedPreferences.getInstance();
    final entry = PreferencesEntry<String?, String?>(
      preferences: preferences,
      key: 'nullable',
      defaultValue: null,
      validator: (value) => value != null,
    );

    expect(await entry.write(null), isFalse);
    expect(entry.read(), 'saved');
    await preferences.reload();
    expect(preferences.getString('nullable'), 'saved');
  });

  test('clearing a nullable value does not require a persisted representation', () async {
    SharedPreferences.setMockInitialValues({'nullable': 'SAVED'});
    final preferences = await SharedPreferences.getInstance();
    final entry = PreferencesEntry<String?, String>(
      preferences: preferences,
      key: 'nullable',
      defaultValue: null,
      mapFrom: (value) => value.toLowerCase(),
      mapTo: (value) => value!.toUpperCase(),
    );

    expect(await entry.write(null), isTrue);
    await preferences.reload();
    expect(preferences.containsKey('nullable'), isFalse);
    expect(entry.read(), isNull);
  });

  test('supported nonnullable preference types retain their storage formats', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    Future<void> roundTrip<T>(String key, T initial, T value, Object stored) async {
      final entry = PreferencesEntry<T, T>(preferences: preferences, key: key, defaultValue: initial);
      expect(await entry.write(value), isTrue);
      await preferences.reload();
      expect(preferences.get(key), stored);
      expect(entry.read(), value);
    }

    await roundTrip('string', '', 'profile', 'profile');
    await roundTrip('bool', false, true, true);
    await roundTrip('int', 0, 3, 3);
    await roundTrip('double', 0.0, 2.5, 2.5);
    await roundTrip<List<String>>('list', [], ['one', 'two'], 'one;two');
  });
}

class _FailingPreferences extends Fake implements SharedPreferences {
  _FailingPreferences(this.throwsOnWrite);
  final bool throwsOnWrite;

  @override
  Object? get(String key) => 'saved';

  Future<bool> _fail() async {
    if (throwsOnWrite) throw StateError('persistence unavailable');
    return false;
  }

  @override
  Future<bool> remove(String key) => _fail();

  @override
  Future<bool> setString(String key, String value) => _fail();
}
