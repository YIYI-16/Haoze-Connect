package core

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/rules"
	RP "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func TestHaozeOfflineRoutingFixture(t *testing.T) {
	fixture := os.Getenv("HAOZE_ROUTING_FIXTURE")
	if fixture == "" {
		t.Skip("generate the fixture with tool/haoze_route_fixture.dart")
	}
	t.Setenv("SKIP_SYSTEM_IPV6_CHECK", "true")
	content, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	raw := config.DefaultRawConfig()
	if err = yaml.Unmarshal(content, raw); err != nil {
		t.Fatal(err)
	}
	if raw.Tun.Enable {
		t.Fatal("fixture must never enable host TUN")
	}
	previousHome := C.Path.HomeDir()
	home, homeErr := filepath.Abs("..")
	if homeErr != nil {
		t.Fatal(homeErr)
	}
	C.SetHomeDir(home)
	t.Cleanup(func() { C.SetHomeDir(previousHome) })
	parsedConfig, configErr := config.ParseRawConfig(raw)
	if configErr != nil {
		t.Fatalf("generated configuration: %v", configErr)
	}
	if parsedConfig.General.Tun.Enable {
		t.Fatal("configuration parser must not enable test TUN")
	}
	if len(parsedConfig.General.Tun.Inet6Address) != 1 ||
		parsedConfig.General.Tun.Inet6Address[0].String() == "fdfe:dcba:9876::1/126" {
		t.Fatal("managed IPv6 address was lost or reuses the legacy default")
	}

	providers := map[string]P.RuleProvider{}
	RP.SetTunnel(tunnel.Tunnel)
	for name, mapping := range raw.RuleProvider {
		behavior := P.Domain
		if mapping["behavior"] == "ipcidr" {
			behavior = P.IPCIDR
		}
		path := mapping["path"].(string)
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatal(readErr)
		}
		provider := RP.NewRuleSetProvider(name, behavior, P.MrsRule, 0,
			resource.NewFileVehicle(filepath.Join(t.TempDir(), name)),
			nil, nil, rules.ParseRule).(*RP.RuleSetProvider)
		t.Cleanup(func() { _ = provider.Close() })
		if _, _, err = provider.SideUpdate(data); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if provider.Count() == 0 {
			t.Fatalf("%s has no rules", name)
		}
		providers[name] = provider
	}
	withTunnelProviders(t, nil, providers)
	parsed := make([]C.Rule, 0, len(raw.Rule))
	for _, line := range raw.Rule {
		parts := strings.Split(line, ",")
		var payload, target string
		var options []string
		if parts[0] == "MATCH" {
			target = parts[1]
		} else {
			payload, target = parts[1], parts[2]
			options = parts[3:]
		}
		rule, parseErr := rules.ParseRule(parts[0], payload, target, options, nil)
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		parsed = append(parsed, rule)
	}
	cases := []struct{ name, host, ip, want string }{
		{"panel", "www.haoze.cyou", "203.0.113.1", "DIRECT"},
		{"subscription", "subscription.example.test", "203.0.113.2", "DIRECT"},
		{"baidu", "www.baidu.com", "203.0.113.3", "DIRECT"},
		{"qualcomm china", "www.qualcomm.cn", "203.0.113.4", "DIRECT"},
		{"cloudflare china", "www.cloudflare.cn", "203.0.113.5", "DIRECT"},
		{"china ipv4", "unknown.example", "223.5.5.5", "DIRECT"},
		{"youtube", "www.youtube.com", "8.8.8.8", "Proxy"},
		{"international ipv6", "www.youtube.com", "2606:4700:4700::1111", "REJECT"},
		{"china ipv6", "www.baidu.com", "2409:8a20::1", "REJECT"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			metadata := &C.Metadata{Host: tc.host, DstIP: netip.MustParseAddr(tc.ip)}
			got := ""
			for _, rule := range parsed {
				if matched, target := rule.Match(metadata, C.RuleMatchHelper{}); matched {
					got = target
					break
				}
			}
			if got != tc.want {
				t.Fatalf("route = %q, want %q", got, tc.want)
			}
		})
	}
}
