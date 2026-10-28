# Xboard Client

This fork ships a managed Hiddify client for a self-hosted Xboard panel. The
account owns exactly one managed subscription profile; legacy profile-import
deep links are ignored so they cannot bypass the panel.

From 5.0.1, an unset region defaults to China (`cn`). This activates the built-in
region-direct rule and selects `223.5.5.5` as the default direct DNS. Upgrading
from 5.0.0 also uses China if no region was saved; explicit region selections,
custom DNS values and rule switches remain user preferences. Connection modes
retain their existing platform defaults.

## Build configuration

The panel URL and the brand shown on the Xboard screens are compile-time
values:

Prepare the pinned native core and generated code first (Flutter 3.38.5,
Python 3, and Java 17/Android SDK for APK builds):

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run slang
python3 scripts/haoze_core.py fetch --platform android
```

For Windows, use `--platform windows` on a Windows build machine instead.
Do not use the stale stable core version from `dependencies.properties`;
see [the native-core lock](DISTRIBUTION.md#native-core-pinning-hash-lock).

```sh
flutter build apk \
  --dart-define=XBOARD_BASE_URL=https://www.haoze.cyou \
  --dart-define=XBOARD_APP_NAME="Haoze Connect"
```

```powershell
flutter build windows `
  --dart-define=XBOARD_BASE_URL=https://www.haoze.cyou `
  --dart-define=XBOARD_APP_NAME="Haoze Connect"
```

Defaults:

- `XBOARD_BASE_URL=https://www.haoze.cyou`
- `XBOARD_APP_NAME=Haoze Connect`

`XBOARD_BASE_URL` must be an HTTPS origin. Credentials, query strings and
fragments are rejected. The client appends `/api/v1` unless the supplied path
already ends with it.

Android uses package identity `com.haoze.connect`; the Windows executable is
`HaozeConnect.exe`. Branding, internal-test signing and the unexecuted Windows
build workflow are described in [DISTRIBUTION.md](DISTRIBUTION.md).

## Runtime flow

1. The app starts at `/login`. The old intro/managed-import onboarding does not
   gate first login anymore.
2. `GET /api/v1/guest/comm/config` loads the registration switches.
3. Login/register uses `passport/auth/login` or `passport/auth/register`.
   Xboard returns `data.auth_data` already prefixed with `Bearer`; it is stored
   verbatim and never prefixed twice.
4. The Bearer token, account email, panel origin and managed profile id are
   stored in platform secure storage. Passwords are never persisted.
5. `GET /api/v1/user/getSubscribe` returns traffic and `subscribe_url` only
   after an authenticated request. The subscription URL is passed unchanged to
   the existing profile parser. Different subscription domains are supported;
   the panel `Authorization` header is not sent to the subscription host.
6. `profileRepositoryProvider.future.upsertRemote(url)` validates the config
   before the profile is activated with `setAsActive`. URL rotation removes the
   previous managed profile after the new one is active. Ownership is committed
   before reloading a running connection, including updates that retain the
   same subscription URL and profile ID.
7. On refresh/foreground resume, a single shared request updates traffic. A
   network failure preserves the session. Authenticated `401`/`403` means the
   session is invalid and triggers cleanup.
8. Expired plans, exhausted traffic and missing plans are not "session expired":
   the old managed profile is stopped/removed and the account stays logged in so
   the user can see the reason and renew. A brand-new account without a plan
   still logs in successfully and shows zero usage.
9. Logout stops the tunnel first, removes the managed profile, disables
   connection restoration and clears secure storage. If secure storage cannot
   be cleared, logout reports a retryable error instead of pretending the token
   is gone. A tombstone entry is used when deletion alone fails. Native stop
   failure also keeps the account and profile available for retry.
10. Desktop startup waits for online session initialization in the background
    before evaluating the user's previous-connection preference. Both startup
    restoration and manual connection require the current managed profile ID.

## Account/UI contract

The account feature exports:

- `lib/features/xboard/notifier/xboard_session_controller.dart`
  - `xboardSessionProvider`
- `lib/features/xboard/model/xboard_models.dart`
  - `XboardPublicConfig`, `XboardSubscription`

Pages:

- `lib/features/xboard/widget/xboard_login_page.dart`
- `lib/features/xboard/widget/xboard_register_page.dart`
- `lib/features/xboard/widget/xboard_account_page.dart`
- `lib/features/xboard/widget/xboard_usage_card.dart`

Routes: `/login`, `/register`, `/account`, `/home`, `/home/proxies`.

The controller exposes `initialize`, `loadPublicConfig`, `login`, `register`,
`sendEmailCode`, `refresh` and `logout`. Initialization is started by the
provider; UI widgets only watch state. Failures may throw `XboardException` and
also populate `state.error` with a user-safe message.

## Security notes

- API traffic uses a dedicated Dio client without Sentry or URL logging.
- Only HTTPS panel URLs are accepted.
- A session is bound to the panel origin stored with it. Changing the build URL
  invalidates the old secure session instead of sending its token to the new
  origin.
- Registration captchas are never bypassed. When a panel enables captcha,
  registration asks the user to use the panel website.
- The upstream user agent (`HiddifyNext/<version> ...`) is preserved; no
  `flag=sing-box` is appended or version overridden.

## Tests

```sh
flutter analyze
flutter test test/features/xboard test/features/xboard_ui \
  test/features/profile/data/profile_repository_test.dart \
  test/features/connection/model/startup_connection_test.dart
python3 scripts/haoze_validate.py
```

The integrated app and real UI compile together. Tests use simulated API and
secure storage responses, and exercise the real session controller and real
Riverpod profile bridge with in-memory repositories. They cover registration
switches, password confirmation, login navigation, usage and expiry, invalid
sessions, account isolation, native stop/reload failure, same-ID updates and
startup/logout races. No test registers a real account or sends email.

The final local acceptance run passed 140 related Flutter tests (including
the full `test/features/profile` suite), strict analysis and 37 distribution
checks. The additional native database tests in the full profile suite need
SQLite's shared library on the host loader path. The CI command above keeps
the focused profile-repository regression tests platform independent.

Real-device account login, node connectivity, Windows build and installation
remain unverified until their corresponding build/device checks finish.
The user authorized a private GitHub repository and Windows test builds;
no public fork, public release or store submission is authorized.
