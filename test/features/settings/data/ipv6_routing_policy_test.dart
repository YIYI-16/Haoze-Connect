import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/data/ipv6_routing_policy.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Directories extends AppDirectories {
  _Directories(this.directory);

  final Directory directory;

  @override
  Future<Directories> build() async => (baseDir: directory, workingDir: directory, tempDir: directory);
}

void main() {
  late Directory directory;
  late ProviderContainer container;
  late SharedPreferences preferences;
  late SingboxConfigOption base;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('ipv6_routing_policy');
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(overrides: [appDirectoriesProvider.overrideWith(() => _Directories(directory))]);
    await container.read(appDirectoriesProvider.future);
    preferences = await container.read(sharedPreferencesProvider.future);
    base = container.read(ConfigOptions.singboxConfigOptions);
  });

  tearDown(() {
    container.dispose();
    directory.deleteSync(recursive: true);
  });

  SingboxConfigOption withRules(List<Rule> rules, {IPv6Mode mode = IPv6Mode.disable}) => base.copyWith(
    ipv6Mode: mode,
    routeRule: RouteRule(rules: rules).toProto3Json()! as Map<String, dynamic>,
  );

  ConfigOptionRepository repository(SingboxConfigOption options) =>
      ConfigOptionRepository(preferences: preferences, getConfigOptions: () => options);

  List<Rule> rules(SingboxConfigOption options) => (RouteRule()..mergeFromProto3Json(options.routeRule)).rules;

  SingboxConfigOption result(ConfigOptionRepository repo, {String? override, bool applyOverride = false}) =>
      (applyOverride ? repo.fullOptionsOverrided(override) : repo.fullOptions()).fold(
        (failure) => throw StateError('$failure'),
        (options) => options,
      );

  void expectGuard(Rule rule) {
    expect(rule.name, 'system:ipv6-disabled');
    expect(rule.enabled, isTrue);
    expect(rule.listOrder, 0);
    expect(rule.outbound, Outbound.block);
    expect(rule.ipCidrs, ['::/0']);
    expect(rule.network, Network.all);
    expect(rule.protocols, isEmpty);
    expect(rule.domains, isEmpty);
    expect(rule.processNames, isEmpty);
    expect(rule.portRanges, isEmpty);
  }

  test('disabled mode adds a nonpersisted IPv6 block before the provider rules', () {
    final saved = container.read(rulesNotifierProvider);
    final original = RouteRule(rules: saved).writeToBuffer();
    final originalOptions = jsonEncode(base.toJson());
    final output = result(repository(base));
    final effective = rules(output);

    expectGuard(effective.first);
    expect(effective.skip(1).map((rule) => rule.name), saved.map((rule) => rule.name));
    expect(effective.skip(1).map((rule) => rule.enabled), saved.map((rule) => rule.enabled));
    expect(effective.map((rule) => rule.listOrder), List.generate(saved.length + 1, (index) => index));
    expect(RouteRule(rules: saved).writeToBuffer(), original);
    expect(jsonEncode(base.toJson()), originalOptions);
    expect(File('${directory.path}/route_rule.proto').existsSync(), isFalse);
  });

  test('reindexes in native list order and preserves the order of equal priorities', () {
    final options = withRules([
      Rule(name: 'last', listOrder: 99, enabled: true, outbound: Outbound.direct, ipCidrs: ['::/0']),
      Rule(name: 'first tie', listOrder: 0, enabled: false, outbound: Outbound.proxy, domains: ['first.example']),
      Rule(name: 'second tie', listOrder: 0, enabled: true, outbound: Outbound.direct, domains: ['second.example']),
    ]);
    final original = jsonEncode(options.toJson());
    final effective = rules(result(repository(options)));

    expect(effective.map((rule) => rule.name), ['system:ipv6-disabled', 'first tie', 'second tie', 'last']);
    expect(effective.map((rule) => rule.listOrder), [0, 1, 2, 3]);
    expect(effective[1].enabled, isFalse);
    expect(effective.last.ipCidrs, ['::/0']);
    expect(jsonEncode(options.toJson()), original);
  });

  for (final mode in [IPv6Mode.enable, IPv6Mode.prefer, IPv6Mode.only]) {
    test('$mode does not inject a block', () {
      final output = result(
        repository(
          withRules([
            Rule(name: 'user IPv6 direct', enabled: true, outbound: Outbound.direct, ipCidrs: ['::/0']),
          ], mode: mode),
        ),
      );
      expect(output.ipv6Mode, mode);
      expect(rules(output).single.name, 'user IPv6 direct');
      expect(rules(output).single.outbound, Outbound.direct);
    });
  }

  test('manual profile overrides cannot weaken global disable and do not mutate their input', () {
    final options = withRules([
      Rule(name: 'original', enabled: false, outbound: Outbound.proxy, domains: ['original.example']),
    ]);
    final original = jsonEncode(options.toJson());
    final overrideRules = RouteRule(
      rules: [
        Rule(name: 'override direct', enabled: true, outbound: Outbound.direct, ipCidrs: ['::/0']),
      ],
    ).toProto3Json();
    final output = result(
      repository(options),
      applyOverride: true,
      override: jsonEncode({
        'ipv6-mode': 'prefer_ipv6',
        'route-rule': overrideRules,
        'direct-dns-address': 'udp://9.9.9.9',
        'ipinfo-url': 'https://example.com/ip',
      }),
    );

    expect(output.ipv6Mode, IPv6Mode.disable);
    expectGuard(rules(output).first);
    expect(rules(output).last.name, 'override direct');
    expect(rules(output).last.listOrder, 1);
    expect(output.directDnsAddress, 'udp://9.9.9.9');
    expect(output.ipinfoUrl, 'https://example.com/ip');
    expect(jsonEncode(options.toJson()), original);
  });

  test('both repository paths are idempotent when given previously guarded transient options', () {
    final once = result(repository(base));
    final twice = result(repository(once));
    final afterOverride = result(repository(once), applyOverride: true);

    expect(twice.toJson(), once.toJson());
    expect(afterOverride.toJson(), once.toJson());
    expect(rules(twice).where((rule) => rule.name == 'system:ipv6-disabled'), hasLength(1));
  });

  test('enabling IPv6 removes only the exact prior system guard', () {
    final guarded = result(
      repository(
        withRules([
          Rule(name: 'system:ipv6-disabled', enabled: true, outbound: Outbound.direct, domains: ['user.example']),
          Rule(name: 'user block', enabled: true, outbound: Outbound.block, ipCidrs: ['::/0']),
        ]),
      ),
    );
    final output = applyIPv6RoutingPolicy(guarded, globalMode: IPv6Mode.enable);

    expect(output.ipv6Mode, IPv6Mode.enable);
    expect(rules(output).map((rule) => rule.name), ['system:ipv6-disabled', 'user block']);
    expect(rules(output).map((rule) => rule.listOrder), [0, 1]);
    expect(rules(output).first.outbound, Outbound.direct);
    expect(rules(guarded), hasLength(3));
  });

  test('global enabled mode stays authoritative over an override and removes an injected old guard', () {
    final priorGuard = rules(result(repository(base))).first;
    final output = result(
      repository(withRules([], mode: IPv6Mode.enable)),
      applyOverride: true,
      override: jsonEncode({
        'ipv6-mode': 'ipv4_only',
        'route-rule': RouteRule(rules: [priorGuard]).toProto3Json(),
      }),
    );
    expect(output.ipv6Mode, IPv6Mode.enable);
    expect(rules(output), isEmpty);
  });

  test('output routing maps and nested lists never share provider-owned mutable values', () {
    final options = withRules([
      Rule(name: 'original', enabled: true, outbound: Outbound.direct, domains: ['original.example']),
    ]);
    final original = jsonEncode(options.toJson());
    final output = result(repository(options));
    final outputRules = output.routeRule['rules'] as List;
    final userRule = outputRules.last as Map;
    (userRule['domain'] as List).add('changed.example');
    outputRules.removeAt(0);
    expect(jsonEncode(options.toJson()), original);
  });
}
