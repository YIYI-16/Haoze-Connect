# Haoze XBoard account integration

The application baseline is FlClash v0.9.2, commit
`7fd417fb9a9a277c6a9339a8ac87f907df7c25f7`; its core submodule is
`c5062921054902b25215a6a933e72ccd714c9bfa`. No Hiddify application code is
copied into this prototype. FlClash's GPLv3 license and attribution remain.

`packages/haoze_xboard` is an independent account/configuration module. The
integration connects it to AuthRouter native login and account views,
system secure storage, one managed profile and the existing lifecycle owners.
The current update is 6.1.0; release publication is separate from source validation.
No affected-device HTTPS fix or complete routing/IPv6 acceptance is claimed.

## Backend evidence

The supplied screenshot identifies `v20260807-60ba571`. The local Xboard
checkout is `8e4864b4c7f6240e3ef08ecd7b59447e5d9dd363`; comparison with
`60ba57142b7b04c74dbd943b551e32df98df0101` changes only one line in
`app/Protocols/General.php`. The routes, authentication, AppController and
ClashMeta implementation discussed here are identical between those commits.
Deployed plugins, configuration and reverse proxies still need runtime checks.

The screenshot's six APP settings are update metadata:

| Setting | Meaning |
| --- | --- |
| `windows_version` / `windows_download_url` | Published Windows version and installer link |
| `android_version` / `android_download_url` | Published Android version and APK link |
| `macos_version` / `macos_download_url` | Published macOS version and package link; optional for this product |

They are read by V1/V2 `Client/AppController::getVersion`, not by the TLS
handshake or login logic. Filling them neither enables integration nor builds
or signs packages. Backend save rules do not validate version/URL formats;
this client requires HTTPS links. The client must implement version comparison
and the update prompt. Blank metadata is not an account or VPN failure.

## Client contract

All paths below are relative to `https://www.haoze.cyou`. No administrator API
key, server token or administrator route belongs in the app.

| Request | Authentication | Use |
| --- | --- | --- |
| GET `/api/v1/account-bridge/app/login` | Fresh state + S256 challenge | Start browser OIDC authentication |
| POST `/api/v1/account-bridge/app/exchange` | One-use code + PKCE verifier | Receive the verified email and two credentials below |
| GET `/api/v1/user/info` | Exact `Authorization: <auth_data>` | Account information |
| GET `/api/v1/user/getSubscribe` | Exact `Authorization: <auth_data>` | Traffic, expiry and real subscription URL |
| GET `/api/v1/client/app/getVersion?token=<subscription-token>` | Subscription token, not Bearer | Screenshot's platform versions/downloads |

`AuthService::generateAuthData` returns `data.auth_data` already containing
`Bearer ` and `data.token` containing the user's subscription token. Their
roles must not be interchanged. Never log request URLs containing subscription
tokens, auth headers, passwords or raw response payloads.

Remaining bytes are `max(transfer_enable - u - d, 0)`. The subscription URL
comes from `getSubscribe`; its domain and path are not hardcoded. Preserve its
query parameters and set `flag=meta/<actual-core-version>` (for this pinned
baseline, `meta/v1.19.33`). Xboard's `ClashMeta` explicitly recognizes `meta`
and `flclash`; the version must come from the core, not the branded app version.

V1 `/client/app/getConfig` is legacy Clash YAML assembling only certain SS,
VMess and Trojan nodes. V2 `/client/app/getConfig` returns app/UI/features JSON,
not a modern node subscription. Both, like `getVersion`, require subscription
token authentication. The V2 configuration contains fallback display values;
it is not a replacement for actual registration/backend permission checks.

The V2 passport aliases exist, but V2 user routes do not provide `getSubscribe`.
The prototype consistently uses the checked V1 contract.

## Isolated network verification

The SDK-only Dart transport creates its own HTTP context instead of inheriting
FlClash's global proxy/certificate override. It requires normal certificate
verification, refuses redirects, sends no request logs and automatically
replays no operations. DIRECT bypasses an application/system HTTP proxy; an
active VPN/TUN can still capture these sockets. Platform socket exclusion is
separate integration work.

From `packages/haoze_xboard`:

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
dart bin/panel_probe.dart
```

The probe only requests public configuration and prints timings and safe error
categories. It never logs in, creates an account or prints the JSON body.
`tool/haoze_panel_probe_windows.ps1` performs the same four public requests
through Windows System.Net.Http with normal platform TLS validation. It writes
`haoze-panel-native.json`, without credentials or raw exception messages. It
does not alter certificate stores, execution policy, proxies, adapters or routes.

Compare browser, the standalone Dart probe and the native probe on the actual
failing device/network, disconnected and connected. Browser success alone does
not establish equal DNS, trust roots, proxy selection or request behavior.
Tests on the build server cannot establish a fix on that device.


## Account integration and current limits

First launch opens the managed account screen without the upstream
no-service restatement gate; no upstream consent version is silently accepted.
The GPL license and upstream attribution remain available.

Unified login automatically obtains a Meta subscription, downloads it over
an isolated strictly verified transport, validates it with the core, and selects
one account-owned file profile. The URL is not retained in ordinary profile
metadata. A content comparison skips unchanged configuration; usage refresh does
not reapply profiles. A failed file/metadata commit retains the old content, and
node selections edited during the download win at commit time.

Only the secure store retains email, panel origin, Bearer credential,
subscription token, managed profile id and subscription host. Passwords are never persisted.
Account origins cannot cross-restore. Logout locks further refresh/connection
attempts immediately, stops the tunnel and removes only the managed profile.
A secure-store failure remains visible and requires a cleanup retry; the locked
session cannot reactivate. This is local sign-out, not server-session revocation.

Passwords, email codes, first-password confirmation and password MFA are handled
in the app by AuthRouter's native APIs. Android Google sign-in uses Credential
Manager; Windows uses the system browser with a state/nonce/PKCE-bound loopback
callback. Google tokens and passwords go only to AuthRouter. An opaque one-use
grant is exchanged by AccountBridge using its existing confidential client,
then mapped through the same immutable ordinary/administrator bindings.
Desktop Google secrets and internal service secrets remain server-side.
Registration, email verification and Passkey management remain in the account
center; the native login page does not offer Passkey sign-in.
Legacy browser endpoints remain compatible with installed clients.
See [the current auth contract](../../UNIFIED-ACCOUNT.md).
Updates use `/client/app/getVersion` and retain signature/checksum verification.
Empty/invalid update metadata does
not invalidate the account. No automatic upstream updater is started.

Android's native state machine independently rejects a start without a live
account-ready state. Persisted SharedState always records accountReady=false;
therefore unattended/headless cold starts (including Always-on after process
loss) are intentionally unavailable in this preview until Flutter restores the
secure account. This avoids treating a cached subscription as account authority.
System VPN behavior and permission UI still require device acceptance.

Android preview identity: com.haoze.connect (debug-signed fallback adds
.dev). Windows: Haoze.exe, CompanyName Haoze, ProductName Haoze. Both are separate from the prior Hiddify app. Native core/helper names
remain upstream names; helper coexistence and installation remain unverified.

Local checks cover account/session failure boundaries, real widget layouts in
light/dark at phone/desktop widths, storage revocation, profile validation and
rollback, and Android JVM lifecycle transitions. They do not establish successful
VPN routing, IPv6 containment, Smart App Control compatibility or panel access on
the user's affected Windows/Android devices. Those remain UNKNOWN.


## China routing and IPv6 policy

The managed subscription and final generated configuration both apply the same
policy after user/configuration overlays. API, account, SSO and subscription hosts go DIRECT;
Chinese domain/IP fallback rules go DIRECT while explicit subscription routes
and rejections retain their priority. HTTP/TLS/QUIC name inspection also classifies real-IP
connections whose DNS result was cached before VPN startup, without changing the
destination or weakening HTTPS verification. Other destinations retain the subscription's
proxy rules and selected groups. This is China split routing by default: DIRECT
uses the device's own country/IP, not a Chinese server selected by the client.

Country domain/IP MRS data is bundled from MetaCubeX/meta-rules-dat commit
cf25ccf5046dd902befc64bff21c0047244796a9. The manifest in assets/data records
immutable source URLs, Git object ids, sizes and SHA256 values; the GPLv3 license
is bundled alongside it. Startup does not need to fetch this CN rule data.
The default template's GEOIP,CN rule and GeoIP DNS fallback are replaced by the
local policy so they do not force an initial MMDB download.

In the default rule mode, engine IPv6 remains enabled to keep IPv6 inside the TUN. DNS AAAA replies are
disabled, and an IPv6 REJECT rule precedes all direct/country rules. The TUN
captures both default routes, uses a separate ULA address and enables strict
routing. New installations enable Windows TUN and Android IPv6 capture, with
Android application bypass disabled. The existing platform lifecycle owners
still decide when to create or stop the tunnel; policy generation never starts
one. A managed connection applies its configuration successfully before starting
listeners, so a failed apply cannot briefly use the core's default DIRECT state.

The native test consumes the actual Dart-generated fixture, parses it using the
pinned Mihomo version and reads the bundled MRS data. It checks panel/subscription
DIRECT, Baidu/China DIRECT, YouTube Proxy, and rejection of Chinese/international
IPv6 destinations. These are configuration/rule decisions, not measured public
IP egress. Windows Server IPv4, true dual-stack Windows/Android, QUIC/WebRTC,
connect/disconnect cleanup, user proxy-only modes and Smart App Control remain
separate runtime acceptance requirements. No device leak fix is claimed here.

The Windows preview installer uses its own AppId and a fixed Program Files folder
with administrator installation. User-local previous directories are not reused.
It does not install, delete or stop a shared FlClash helper during install or
uninstall, and keeps user data. An already elevated process uses its own direct
core. A copy in a user directory cannot use or register the persistent helper; it
requires an elevated direct core for TUN. A managed TUN permission failure stops the connection instead of switching to
proxy-only operation. Helper/UAC behavior still requires platform
acceptance. All preview Windows binaries are unsigned.
