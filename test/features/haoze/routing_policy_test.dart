import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/managed_routing.dart';
import 'package:fl_clash/models/managed_routing.dart';
import 'package:fl_clash/features/haoze/routing_resources.dart';
import '../../helpers/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final policy = ManagedRoutingPolicy(
    domainRulesPath: '/home/app/haoze-routing/cn-domain.mrs',
    ipRulesPath: '/home/app/haoze-routing/cn-ip.mrs',
    directHosts: {'www.haoze.cyou', 'subscription.example.test'},
  );
  Map<String, dynamic> source() => {
    'mode': 'rule',
    'ipv6': false,
    'dns': {
      'nameserver': ['https://dns.example/dns-query'],
      'ipv6': true,
    },
    'tun': {'enable': false},
    'proxies': [
      {'name': 'Node', 'server': '192.0.2.1'},
    ],
    'proxy-groups': [
      {
        'name': 'Proxy',
        'type': 'select',
        'proxies': ['Node'],
      },
    ],
    'rules': [
      'DOMAIN-SUFFIX,youtube.com,Proxy',
      'GEOIP,CN,DIRECT',
      'MATCH,Proxy',
    ],
  };
  test(
    'policy precedes catch-all without replacing nodes or selected proxy groups',
    () {
      final original = source();
      final result = applyManagedRouting(original, policy);
      expect(result['proxies'], original['proxies']);
      expect(result['proxy-groups'], original['proxy-groups']);
      final rules = result['rules'] as List;
      expect(rules.first, 'IP-CIDR6,::/0,REJECT,no-resolve');
      expect(
        rules.indexOf('DOMAIN,www.haoze.cyou,DIRECT'),
        lessThan(rules.indexOf('MATCH,Proxy')),
      );
      expect(
        rules.indexOf('DOMAIN,subscription.example.test,DIRECT'),
        lessThan(rules.indexOf('MATCH,Proxy')),
      );
      expect(rules, contains('DOMAIN-SUFFIX,youtube.com,Proxy'));
      expect(rules, contains('RULE-SET,Haoze-CN-IPs,DIRECT'));
      expect(rules, isNot(contains('GEOIP,CN,DIRECT')));
      expect(original['ipv6'], false);
      expect((original['dns'] as Map)['ipv6'], true);
    },
  );
  test(
    'capture and DNS are separate and policy never enables the host tunnel',
    () {
      final result = applyManagedRouting(source(), policy);
      expect(result['ipv6'], true);
      expect((result['dns'] as Map)['ipv6'], false);
      expect((result['dns'] as Map)['fallback-filter']['geoip'], false);
      expect((result['dns'] as Map)['nameserver'], [
        'https://dns.example/dns-query',
      ]);
      final tun = result['tun'] as Map;
      expect(tun['enable'], false);
      expect(tun['route-address'], ['0.0.0.0/0', '::/0']);
      expect(tun['inet6-address'], [managedTunIpv6]);
      expect(tun['strict-route'], true);
      expect(tun['route-exclude-address'], isNot(contains('::/0')));
    },
  );
  test('reapplication is stable and reserved provider names stay local', () {
    final original = source()
      ..['rule-providers'] = {
        managedDomainProvider: {
          'type': 'http',
          'url': 'https://remote.example/rules',
        },
      };
    final first = applyManagedRouting(original, policy);
    expect(applyManagedRouting(first, policy), first);
    final providers = first['rule-providers'] as Map;
    expect(providers[managedDomainProvider]['type'], 'file');
    expect(providers[managedDomainProvider]['url'], isNull);
    expect(providers[managedIpProvider]['format'], 'mrs');
  });
  test('malformed rules and direct-host delimiter injection fail closed', () {
    expect(
      () => applyManagedRouting({
        'rules': [1],
      }, policy),
      throwsFormatException,
    );
    expect(
      () => applyManagedRouting(
        source(),
        ManagedRoutingPolicy(
          domainRulesPath: 'a',
          ipRulesPath: 'b',
          directHosts: {'example.com,REJECT'},
        ),
      ),
      throwsFormatException,
    );
  });
  test('bundled routing data matches the pinned upstream manifest', () {
    final manifest =
        jsonDecode(
              File('assets/data/haoze-routing-data.json').readAsStringSync(),
            )
            as Map;
    expect(manifest['commit'], 'cf25ccf5046dd902befc64bff21c0047244796a9');
    for (final item in manifest['files'] as List) {
      final bytes = File('assets/data/${item['name']}').readAsBytesSync();
      expect(bytes.length, item['bytes']);
      expect(sha256.convert(bytes).toString(), item['sha256']);
    }
  });
  test('Android VPN and core policy agree on virtual interface addresses', () {
    final service = File(
      'android/service/src/main/java/com/follow/clash/service/VpnService.kt',
    ).readAsStringSync();
    expect(service, contains('IPV4_ADDRESS = "$managedTunIpv4"'));
    expect(service, contains('IPV6_ADDRESS = "$managedTunIpv6"'));
    expect(service, contains('DNS = "198.19.0.2"'));
    expect(service, contains('DNS6 = "fd63:4841:4f5a:4500::2"'));
  });
  test(
    'concurrent policy installation leaves complete verified local files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'haoze-routing-resources-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await useAppPaths(directory);
      final installed = await Future.wait([
        HaozeRoutingResources().ensure({'panel.example'}),
        HaozeRoutingResources().ensure({'panel.example'}),
      ]);
      expect(installed[0].domainRulesPath, installed[1].domainRulesPath);
      final manifest =
          jsonDecode(
                File('assets/data/haoze-routing-data.json').readAsStringSync(),
              )
              as Map;
      expect(
        sha256
            .convert(await File(installed[0].domainRulesPath).readAsBytes())
            .toString(),
        manifest['files'][0]['sha256'],
      );
      expect(
        sha256
            .convert(await File(installed[0].ipRulesPath).readAsBytes())
            .toString(),
        manifest['files'][1]['sha256'],
      );
    },
  );
}
