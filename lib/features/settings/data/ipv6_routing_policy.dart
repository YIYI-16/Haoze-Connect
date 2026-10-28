import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';

const _guardName = 'system:ipv6-disabled';

Rule _guard() => Rule(name: _guardName, enabled: true, outbound: Outbound.block, ipCidrs: ['::/0']);

bool _isGuard(Rule rule) {
  if (rule.name != _guardName) return false;
  // A similarly named user rule with different conditions must survive.
  return (rule.deepCopy()..clearListOrder()) == _guard();
}

/// Adds the global IPv6 data policy only to the options sent to the core.
///
/// Keep the IPv6 TUN address/routes: suppressing AAAA answers alone cannot stop
/// literal or cached IPv6 destinations. Native DNS hijack and its special proxy
/// range precede app rules; this guard applies to ordinary routed data.
SingboxConfigOption applyIPv6RoutingPolicy(SingboxConfigOption options, {required IPv6Mode globalMode}) {
  final routes = RouteRule()..mergeFromProto3Json(options.routeRule);
  final ordered = routes.rules.where((rule) => !_isGuard(rule)).indexed.toList()
    ..sort((a, b) {
      final order = a.$2.listOrder.compareTo(b.$2.listOrder);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  final disabled = globalMode == IPv6Mode.disable;
  final rules = <Rule>[if (disabled) _guard(), ...ordered.map((entry) => entry.$2)];
  for (final (index, rule) in rules.indexed) {
    rule.listOrder = index;
  }
  return options.copyWith(
    ipv6Mode: globalMode,
    routeRule: RouteRule(rules: rules).toProto3Json()! as Map<String, dynamic>,
  );
}
