import 'package:fl_clash/models/managed_routing.dart';

const managedDomainProvider = 'Haoze-CN-Domains';
const managedIpProvider = 'Haoze-CN-IPs';
const managedTunIpv4 = '198.19.0.1/30';
const managedFakeIpRange = '198.19.0.1/16';
const managedTunIpv6 = 'fd63:4841:4f5a:4500::1/126';

Map<String, dynamic> applyManagedRouting(
  Map<String, dynamic> config,
  ManagedRoutingPolicy policy,
) {
  final result = Map<String, dynamic>.from(config);
  final rules = config['rules'];
  if (rules != null && rules is! List) {
    throw const FormatException('Invalid rules');
  }
  final normalized = <String>[];
  for (final item in (rules as List? ?? const [])) {
    if (item is! String) throw const FormatException('Invalid rule');
    final parts = item.split(',').map((part) => part.trim()).toList();
    if (parts.length >= 3 &&
        parts[0].toUpperCase() == 'GEOIP' &&
        parts[1].toUpperCase() == 'CN') {
      continue;
    } else if (!policy.directHosts.any(
          (host) => item == 'DOMAIN,$host,DIRECT',
        ) &&
        item != 'DOMAIN-SUFFIX,cn,DIRECT' &&
        !(parts.length >= 2 &&
            parts[0].toUpperCase() == 'RULE-SET' &&
            {managedDomainProvider, managedIpProvider}.contains(parts[1])) &&
        item != 'IP-CIDR6,::/0,REJECT,no-resolve') {
      normalized.add(item);
    }
  }
  final hosts = policy.directHosts.toList()..sort();
  final directRules = <String>[];
  for (final host in hosts) {
    if (!RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(host)) {
      throw const FormatException('Invalid direct host');
    }
    directRules.add('DOMAIN,$host,DIRECT');
  }
  result['rules'] = [
    'IP-CIDR6,::/0,REJECT,no-resolve',
    ...directRules,
    'RULE-SET,$managedDomainProvider,DIRECT',
    'DOMAIN-SUFFIX,cn,DIRECT',
    'RULE-SET,$managedIpProvider,DIRECT',
    ...normalized,
  ];
  result['rule-providers'] = {
    if (config['rule-providers'] case final Map providers) ...providers,
    managedDomainProvider: {
      'type': 'file',
      'behavior': 'domain',
      'format': 'mrs',
      'path': policy.domainRulesPath,
    },
    managedIpProvider: {
      'type': 'file',
      'behavior': 'ipcidr',
      'format': 'mrs',
      'path': policy.ipRulesPath,
    },
  };
  // IPv6 must reach the TUN before the first rule can reject literal destinations.
  result['ipv6'] = true;
  result['dns'] = {
    if (config['dns'] case final Map dns) ...dns,
    'ipv6': false,
    'fake-ip-range': managedFakeIpRange,
    'fallback-filter': {
      if (config['dns'] is Map &&
          (config['dns'] as Map)['fallback-filter'] is Map)
        ...(config['dns'] as Map)['fallback-filter'] as Map,
      'geoip': false,
    },
  };
  result['tun'] = {
    if (config['tun'] case final Map tun) ...tun,
    'device': 'HaozeMihomo',
    'inet4-address': [managedTunIpv4],
    'inet6-address': [managedTunIpv6],
    'route-address': ['0.0.0.0/0', '::/0'],
    'strict-route': true,
    'route-exclude-address': [
      '0.0.0.0/8',
      '10.0.0.0/8',
      '127.0.0.0/8',
      '169.254.0.0/16',
      '172.16.0.0/12',
      '192.168.0.0/16',
      '224.0.0.0/4',
      '255.255.255.255/32',
      'fc00::/7',
      'fe80::/10',
      'ff00::/8',
    ],
  };
  return result;
}
