# Haoze Connect 6.1.0 unified account update

The Android and Windows application now starts the existing AuthRouter login in
the system browser. Google, password, email-code, Passkey, password-only MFA and
imported-account first-password confirmation remain owned by the identity
service. New accounts are registered and verified at account.zhouhaoze.com; the
existing verification event grants UM-Foundation. No password, OAuth client
secret or administrator service credential is embedded in this application.

## Handoff contract

1. The app generates independent cryptographic state and a 32-byte PKCE verifier
   for each attempt. It sends only state, S256 challenge and method to
   `GET /api/v1/account-bridge/app/login` on the canonical HTTPS XBoard origin.
2. AccountBridge starts its existing confidential OIDC flow with its own separate
   browser state/cookie and PKCE verifier. Existing browser login is preserved.
3. AuthRouter completes all required authentication and account confirmation.
   AccountBridge resolves the existing immutable identity binding; unverified,
   unbound, disabled and unauthorized administrator identities cannot proceed.
4. The plugin creates an opaque, one-use code valid for 60 seconds and returns
   `haoze-connect://auth/callback?code=...&state=...`. This fixed callback never
   contains the XBoard bearer credential, subscription token or email.
5. The app checks the scheme, host, path, state and unique query parameters, then
   sends the code and verifier in the HTTPS JSON body to
   `POST /api/v1/account-bridge/app/exchange`.
6. The server atomically checks S256 and consumes the code. It rechecks account
   status, administrator restrictions and current binding before issuing a
   session. Invalid verifiers do not consume another attempt's code.
7. The SDK uses the server email and normal XBoard session credentials in the
   existing secure-store/profile flow. No local account credentials are copied
   into the system browser. Authentication callbacks are excluded from app logs.

A sign-in attempt times out after five minutes and offers cancellation. Cancel,
retry, disposal, duplicate and stale callbacks do not complete a different login.
If the operating system terminates the app during browser login, start a fresh
attempt; verifiers are intentionally not persisted. Local logout retains the
existing behavior: remove local credentials and the managed profile; it does
not log out the browser's SSO session or revoke all other devices.

## Native integration

- Android adds a separate intent filter for the exact `haoze-connect` auth
  callback. The existing package `com.haoze.connect.mihomo` and pinned signing
  certificate remain unchanged; build number increases to 62100 (the split ARM64
  APK uses version code 64100).
- Windows registers the callback scheme per user when the app starts. Its
  existing single-instance runner forwards browser links to the running app.
  The generic installer cleanup list includes the additional scheme.
- Account settings open `/auth/login?next=security` so the browser's existing SSO
  session can establish the account-center session without an extra security
  confirmation step.
- The direct-routing set includes account.zhouhaoze.com and sso.zhouhaoze.com.
  Subscription, quota refresh, profile validation, rollback, app update signature
  verification and native VPN lifecycle ownership are unchanged.

## Verification and release

Run `flutter pub get`, `flutter analyze --no-fatal-infos`, the account package's
`flutter test`, root `test/features/haoze`, `test/features/update`,
`test/common/link_test.dart`, `test/common/protocol_test.dart`, `test/l10n` and
`test/lint/dynamic_message_key_test.dart`. Run the Python release-gate tests.
The backend includes `XBoard/account-bridge/tests/app-auth.php` for the full
browser/code/exchange, PKCE, expiry, replay, revocation and administrator contract.

Deploy the matching AccountBridge before distributing this update. Otherwise
the new app endpoints return 404. No AuthRouter OAuth client changes, new
administrator credentials or database migrations are required. Keep the prior
plugin files and App 6.0.4 packages for rollback. Preserve the installed app's
signing identity. Do not update XBoard APP download metadata until the actual
Android and Windows packages have been built, verified and published.

Windows binaries require a Windows host. The existing `haoze-build.yml` workflow
can build both platforms from an approved immutable source commit and uploads
artifacts without automatically publishing a release. Signing a Windows
installer with a trusted publisher certificate remains separate; existing
Windows artifacts are explicitly marked unsigned.
