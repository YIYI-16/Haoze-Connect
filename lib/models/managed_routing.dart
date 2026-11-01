class ManagedRoutingPolicy {
  ManagedRoutingPolicy({
    required this.domainRulesPath,
    required this.ipRulesPath,
    required Set<String> directHosts,
  }) : directHosts = Set.unmodifiable(directHosts);

  final String domainRulesPath;
  final String ipRulesPath;
  final Set<String> directHosts;
}
