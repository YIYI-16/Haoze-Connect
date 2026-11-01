import 'dart:io';

import 'package:fl_clash/common/managed_routing.dart';
import 'package:fl_clash/common/yaml_writer.dart';
import 'package:fl_clash/models/managed_routing.dart';

void main(List<String> arguments) {
  if (arguments.length != 1) throw ArgumentError('Provide one output path');
  final policy = ManagedRoutingPolicy(
    domainRulesPath: File('assets/data/haoze-cn-domain.mrs').absolute.path,
    ipRulesPath: File('assets/data/haoze-cn-ip.mrs').absolute.path,
    directHosts: {'www.haoze.cyou', 'subscription.example.test'},
  );
  final config = applyManagedRouting({
    'mode': 'rule',
    'dns': {
      'enable': true,
      'enhanced-mode': 'fake-ip',
      'nameserver': ['223.5.5.5'],
      'fallback': ['https://1.1.1.1/dns-query'],
      'fallback-filter': {'geoip': true, 'geoip-code': 'CN'},
    },
    'tun': {'enable': false},
    'proxies': [
      {
        'name': 'Node',
        'type': 'ss',
        'server': '192.0.2.1',
        'port': 443,
        'cipher': 'aes-128-gcm',
        'password': 'unit-fixture',
      },
    ],
    'proxy-groups': [
      {
        'name': 'Proxy',
        'type': 'select',
        'proxies': ['Node'],
      },
    ],
    'rules': ['GEOIP,CN,DIRECT', 'MATCH,Proxy'],
  }, policy);
  File(arguments.single).writeAsStringSync(writeYaml(config));
}
