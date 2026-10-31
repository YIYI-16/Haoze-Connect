# Haoze Xboard integration prototype

The application baseline is FlClash v0.9.2, commit
`7fd417fb9a9a277c6a9339a8ac87f907df7c25f7`; its core submodule is
`c5062921054902b25215a6a933e72ccd714c9bfa`. No Hiddify application code is
copied into this prototype. FlClash's GPLv3 license and attribution remain.

`packages/haoze_xboard` is an independent account/configuration module. It is
not yet connected to the FlClash UI, session persistence or VPN lifecycle.
Successful module tests and an upstream build do not establish a finished
Haoze client, successful login on the affected devices, or an HTTPS fix.

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
| GET `/api/v1/guest/comm/config` | None | Actual registration verification/invite requirements |
| POST `/api/v1/passport/auth/login` | Email/password JSON | Returns the two distinct credentials below |
| POST `/api/v1/passport/auth/register` | Email/password; required verification fields | Register and receive credentials |
| POST `/api/v1/passport/comm/sendEmailVerify` | Email and required captcha fields | Request an email code |
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
