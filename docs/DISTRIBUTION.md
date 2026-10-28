# Haoze Connect — internal distribution guide

Haoze Connect is an internal, free client distribution of a self-hosted Xboard
panel (`https://www.haoze.cyou`), derived from the upstream
[Hiddify app](https://github.com/hiddify/hiddify-app). This document describes
the branding/build configuration in this repository and how internal builds are
produced. Nothing here is a statement about the legal sufficiency of the
license interpretation below — read `LICENSE.md` yourself before any public
distribution.

Public source mirror: [YIYI-16/Haoze-Connect](https://github.com/YIYI-16/Haoze-Connect).
The source history is merged with the repository's existing download website;
`index.html`, `css/` and `js/` are preserved. The GitHub repository is a
standalone mirror rather than an upstream-registered fork. Earlier development
and Windows test builds remain in the authorized private
`HaozeZane/Haoze-Connect` repository. No public Release or store submission has
been made. See `LICENSE.md` and the license notes below before distributing
binaries publicly.

## 5.0.3 Windows runtime correction

The Windows job uses the `windows-2022` / Visual Studio 2022 runner instead of
the moving `windows-latest` toolchain. App-local Microsoft CRT DLLs come from
the selected compiler's Visual Studio installation; the older fixed DLLs from
the `vclibs` plugin are excluded. Configure verifies their architecture,
minimum toolset version and Microsoft Authenticode signature using local trust
without online revocation requests. Release/Profile installation retains the
original signed Microsoft files.

In-process desktop VPN refreshes now use the native atomic Restart operation.
The client waits for the actual startup/stop state instead of treating an RPC
acknowledgement as completed teardown; a user disconnect cancels the pending
startup. Local gRPC regressions model delayed teardown, startup failure, stop
timeout and disconnect during restart.

CI also starts the built application and checks for a stable, responsive native
window before packaging. This checks native loading, not account or VPN
functionality. TLS failures now explain the system-time/certificate-trust check
without logging request details or weakening HTTPS verification.

The app's own EXE/DLL files remain unsigned internal test builds. Windows Smart
App Control or another enforced Code Integrity policy can block these files;
recompilation or signing only the installer does not establish trust in its
payload. Trusted signing must cover the application binaries and installer.
No test procedure disables Windows security policy. Real-machine evidence and
the new build results are recorded under `artifacts/5.0.3/verification/`.

## Current 5.0.3 validation

Binary source commit: `50704d3df42e4fc118db824c5f6d4f601be6fe0b`.
The local suite passed 201 related Flutter tests, 38 distribution checks and
strict analysis. The Android ARM64 Release-mode test APK passed v2 signature
verification; it retains the same internal Android debug certificate.
Android device installation and VPN behavior have not been exercised here.

The private [Windows run 40668753377](https://github.com/HaozeZane/Haoze-Connect/actions/runs/40668753377)
passed strict analysis, 106 Flutter tests, the native launch smoke test, and
x64 EXE/standalone ZIP packaging. Downloaded packages passed CRC, safe-path,
architecture and pinned-core verification. The real installed app's EXE and
AOT hashes match this final package, distinguishing it from the preliminary
runtime-only build with the same displayed version.

Manual acceptance on the supplied Windows Server 2022 build 20348 machine
(elevated Administrator session) verified the final installed EXE: restored
account/quota after upgrade, real System Proxy egress, real VPN/TUN egress,
and a subscription refresh while VPN was connected with continued node egress
and no error banner. Logout stopped the tunnel and restored direct egress;
reopening the installed app kept the account logged out. The temporary RDP
peer route created for the VPN test was removed afterwards.
This reproduces the baseline 5.0.2 refresh failure with
the corrected result. Evidence is in the `final-*` verification files.
This server does not reproduce the user's Windows 11 Smart App Control policy;
unsigned payloads can still be blocked on that machine. Unelevated helper
installation, upstream-service coexistence and local Windows 11 SAC behavior
remain unverified.

Current artifacts and verification records are in `artifacts/5.0.3/`.
The requested delivery contains the Windows Setup EXE, standalone ZIP and
Android ARM64 APK in `HaozeConnect-Android-Windows-Test-5.0.3.zip`, under
`/home/zhou/` with owner `zhou:zhou` (delivery hash verified).

## Historical 5.0.1 default-China test build

The managed app defaults to region `cn`, including the built-in region-direct
rule and `223.5.5.5` direct DNS. An upgrade uses this default when no region was
saved. Explicit user selections, DNS overrides and rule switches are preserved.

Build source: `605ce607c32419281ca8c49b5337c6f7689ebb92`.
Local verification: 160 related Flutter tests, 37 distribution checks, strict
analysis and a real ARM64 Release-mode APK build passed. The APK version is
`5.0.1+50001`; its test certificate matches the previous APK.

The private [Windows run 40638363439](https://github.com/HaozeZane/Haoze-Connect/actions/runs/40638363439)
succeeded, including strict analysis, 81 Flutter tests, x64 compilation and
EXE/ZIP packaging. Downloaded packages passed integrity, architecture, app
version and pinned native-core checks.

Historical artifacts and verification records are in `artifacts/5.0.1/`. The
three-package bundle is `HaozeConnect-Android-Windows-Test-5.0.1.zip` (Windows
Setup EXE, Windows standalone ZIP, Android ARM64 APK). The requested home
delivery location is `/home/zhou/` with owner `zhou:zhou`.
These remain unsigned Windows / debug-certificate Android test packages;
real-device installation, login and VPN routing behavior were unverified for that build.

## Repository migration

The download website remains on `main`; client source is maintained on the
`client` branch. The manually dispatched `haoze-build.yml` workflow is present
on the default branch for Actions discovery and on the client branch. Its
`source_ref` input defaults to `client`, so a dispatch from the website branch
still checks out app source. Android artifacts include only the verified ARM64
split. This workflow builds artifacts; publishing a Release remains a separate
explicit operation.

Migration acceptance: [run 40684285128](https://github.com/YIYI-16/Haoze-Connect/actions/runs/40684285128)
succeeded for both Android and Windows on client source `a79e9c48`. Downloaded
validation artifacts passed ZIP CRC, Windows x64/pinned-core checks, and Android
package/version/ARM64/signature checks. The public [5.0.3 Release](https://github.com/YIYI-16/Haoze-Connect/releases/tag/v5.0.3)
contains the previously accepted binary bytes; downloads and checksums were
verified anonymously after publication. `main` keeps the website with its
placeholder URLs replaced by these real Release assets. The user retained
responsibility for deleting the old repository; this workflow did not delete it.

Historical build and runtime evidence remains under local `artifacts/5.0.3/`
and the repository migration backup. Old Actions runs cannot be moved between
repositories. Existing 5.0.3 release assets retain their original signing and
binary provenance; a validation rebuild is recorded separately.

## Branding & package identity

| Item | Value | Where |
| --- | --- | --- |
| Android applicationId | `com.haoze.connect` | `android/app/build.gradle` |
| Kotlin/native namespaces | `com.hiddify.hiddify` (unchanged, required by native plugins/protos) | `android/app/build.gradle` |
| Android display name | `Haoze Connect` | `android/app/src/main/AndroidManifest.xml` |
| Android launcher icon | original blue vector "Haoze" mark (adaptive icon, API 26+; legacy PNG fallback for plain-API<26 devices left as-is) | `android/app/src/main/res/drawable/ic_launcher_foreground.xml` |
| Windows exe | `HaozeConnect.exe` | `windows/CMakeLists.txt` (`BINARY_NAME`), `windows/runner/Runner.rc` |
| Windows window title / single-instance | `Haoze Connect` / `HaozeConnectMutex` | `windows/runner/main.cpp` |
| Installer identity | own Inno Setup AppId GUID | `scripts/haoze-windows-installer.iss`, `windows/packaging/exe/make_config.yaml` |
| MSIX identity | `Haoze.HaozeConnect` | `windows/packaging/msix/make_config.yaml` |

Deliberately NOT renamed (owned by the bundled `hiddify-lib` Go core; renaming
them breaks the kernel/plugin contract):

- `hiddify-core.dll`, `HiddifyCli.exe` (shipped beside the app exe),
- service names `HiddifyAdminBG` / `HiddifyTunnelService`,
- gRPC/MethodChannel identifiers (`adminbgservice.*`, `com.hiddify.app/...`).

Both Inno installer entry points (the standalone script and fastforge template)
perform **no global service stop/delete** and have
**no `[UninstallDelete]`** section (uninstall preserves user data at
`%APPDATA%\Haoze\Haoze Connect`). Caveat, needs real testing on Windows: the
elevated helper service name `HiddifyAdminBG` is fixed inside the core and
upstream Hiddify installs also use it, so simultaneous operation of Haoze
Connect and native Hiddify on one machine is not promised.
The post-install launch uses the original user's credentials. Starting the
installer itself from an already elevated process cannot restore a prior
unelevated user token; launch it normally from Explorer.

## In-app branding & updates

- App name inside the app: `--dart-define=XBOARD_APP_NAME` (default
  `Haoze Connect`), see `lib/core/model/constants.dart`.
- Panel base URL: `--dart-define=XBOARD_BASE_URL`
  (`https://www.haoze.cyou` in CI).
- Updates: **disabled by default.** The app never contacts upstream Hiddify
  release/appcast endpoints. If the maintainer provides their own feed, build
  with `--dart-define=XBOARD_UPDATE_URL=https://example.invalid/appcast.xml`.
  Requirements enforced in code:
  - HTTPS only (http / invalid URLs count as "no channel"),
  - GitHub repository URLs and any upstream Hiddify endpoint (hiddify.com,
    `raw.githubusercontent.com/hiddify/...`, `api.github.com/repos/hiddify/...`)
    are rejected — a repo URL is not an appcast feed and no fake feed is
    implied,
  - manual "check for update" stays disabled (appcast only),
  - without a channel the updater performs no network request at all.

## Native core pinning (hash lock)

`dependencies.properties` still says `core.version=4.1.0`, but that stable
`hiddify-lib-android` AAR is **incompatible** with this app tree: the app's
`main`-branch `PlatformInterface` uses members such as
`NeighborUpdateListener` / `PlatformUser` that the 4.1.0 AAR does not export,
so the first real APK compile failed. CI therefore does not use
`core.version` and does not blindly download whatever the `draft` release
currently contains.

`hiddify-core.lock.json` is the single source of truth. It records:

- the app source commit and the `hiddify-core` gitlink commit,
- for Android and Windows: the exact draft asset URL, SHA256, the release-API
  asset timestamp, the archive name, extraction target and required files.

Current pinned assets (details and digests in the lock file):

| Platform | Asset | Extracted to | Required files |
| --- | --- | --- | --- |
| Android | `hiddify-lib-android.tar.gz` | `android/app/libs` | `hiddify-core.aar` |
| Windows | `hiddify-lib-windows-amd64.tar.gz` | `hiddify-core/bin` | `hiddify-core.dll`, `HiddifyCli.exe`, `libcronet.dll` |

`scripts/haoze_core.py` (Python 3 stdlib only) reads the lock, downloads or
reuses a cached archive, verifies the full SHA256, rejects unsafe tar paths
(absolute/`..`/symlink/hardlink/device/FIFO) and required-file omissions, and
extracts without preserving archive ownership. It never executes the
downloaded Windows binaries. Useful invocations:

```bash
python3 scripts/haoze_core.py show
python3 scripts/haoze_core.py verify --platform android --archive <local.tar.gz>
python3 scripts/haoze_core.py fetch  --platform windows --cache <cache-dir>
```

A digest mismatch is a hard error: the build does **not** adopt the new hash.
To rotate the core deliberately, download the asset from the release API,
independently re-check its digest and timestamp, confirm the required files
and interface compatibility, then update the lock in a reviewed commit. A
draft asset can change at any time; the lock is what makes builds reproducible.

## Building (CI)

`.github/workflows/haoze-build.yml` — `workflow_dispatch` only. It uploads
**artifacts** to the Actions run page; it never creates releases, never uses
upstream project secrets, and does not sign Windows artifacts (unsigned
artifacts are explicitly named `-unsigned`).
The old CI, tag release, store upload, WinGet and VirusTotal workflows (including
the reusable upstream build) only run for `hiddify/hiddify-app`. Fork pushes and
tags cannot run those upstream distribution jobs; use the Haoze manual workflow.

- Both jobs run `flutter analyze` and the Xboard / Xboard UI / profile /
  startup-connection regression tests before packaging, so CI is not merely a
  build job.
- Android APKs (Flutter 3.38.5, Java 17) use the hash-verified Android core
  from `hiddify-core.lock.json`. Release APKs use a production signing key only
  when the `ANDROID_SIGNING_KEY(+PASSWORD/ALIAS)` secrets are all present; otherwise
  the run builds a debug-signed APK and the artifact is explicitly named
  `HaozeConnect-Android-debug-signed-test` — never distribute it to real users.
- Windows standalone ZIP + Inno Setup EXE use the hash-verified Windows core
  from `hiddify-core.lock.json`. Packaging:
  `scripts/haoze-package-windows.ps1` + `scripts/haoze-windows-installer.iss`
  (Inno Setup 6.5+; installed via choco in CI).
  The **standalone ZIP / 免安装 ZIP** uses the same non-portable build as Setup:
  settings and accounts stay in `%APPDATA%\Haoze\Haoze Connect`, and do not move
  with the ZIP directory. It is named `HaozeConnect-Windows-Standalone-x64.zip`.
  Packaging parameters `-BuildDir` and `-OutDir` resolve relative to the repository
  root (absolute paths are also accepted), regardless of the current directory;
  ZIP and Setup consume the same source tree and write to the same output folder.
  The Simplified Chinese translation is bundled under `scripts/inno-languages`
  from the official Inno Setup 6.7.1 source tag, with its credits/license. The
  runner's compiler installation does not include that contributed language.

Windows branding asset is still pending: `windows/runner/resources/app_icon.ico`
remains the upstream placeholder icon until Haoze icon material exists.

## Earlier 5.0.0 validation baseline

- `python3 scripts/haoze_validate.py` — configuration/unittest checks:
  Android id/label/allowBackup/namespace, original launcher vector, Windows exe
  name + RC metadata + single-instance strings consistency, installer
  identity/paths, no invented service names, no `[Code]`/`[UninstallDelete]`
  global actions, dart constants (XBOARD defines, removed upstream update
  endpoints, nullable update feed/callback), workflow (dispatch-only, no
  publishing, lock-based hash-pinned core, secrets via step `env`, no upstream
  secrets, analyze/test steps), logo originality, README/docs/license presence,
  and `.gitignore` keeping the lock/scripts while ignoring build caches.
- `scripts/haoze_core.py` was exercised offline against independently
  downloaded copies of both draft archives: the Android SHA256
  `7ea92f0c…98dc5` and Windows SHA256 `ed3251c3…28f5` matched the lock, the
  required entries were present, and extraction produced only the expected
  regular files.
- 140 related Flutter tests and 37 distribution checks passed after the Sol
  review fixes; strict `flutter analyze` reported no issues. The expanded
  profile database tests use the host SQLite shared library. An initial
  Android ARM64 debug build also succeeded with the pinned draft AAR; the
  delivered APK is the smaller Release-mode test build described below.
- Android packages are built locally. The user subsequently authorized the
  private `HaozeZane/Haoze-Connect` repository and Windows test-artifact builds.
  The later source-mirror upload to `YIYI-16/Haoze-Connect` is authorized;
  no public binary release or store submission is included.
- After the final Sol fixes, a local Release-mode ARM64 build also succeeded.
  The delivered `artifacts/HaozeConnect-Android-arm64-test.apk` is the
  `app-arm64-v8a-release.apk` split (56,330,486 bytes, about 54 MiB), has only
  `arm64-v8a` native code, and its v2 signature was verified. The certificate
  is `Android Debug`, so this is an internal test package, not a production
  signing key. An ARM64-only build can still emit other split filenames due
  to the upstream Gradle configuration; only the verified ARM64 split is
  delivered here.
- **Windows build and packaging PASS.** The private Windows run
  [40630912669](https://github.com/HaozeZane/Haoze-Connect/actions/runs/40630912669),
  source commit `ff44ec874ac0066236c13e5fac796ece13774835`, passed strict
  analysis, 61 focused Flutter tests and 37 distribution checks, then compiled
  the x64 Release application and produced:
  - `artifacts/HaozeConnect-Windows-Setup-x64-5.0.0.exe` (44,859,206 bytes).
  - `artifacts/HaozeConnect-Windows-Standalone-x64.zip` (60,851,110 bytes).
  The downloaded ZIP passed CRC/path checks and contains the x64 app,
  Flutter runtime, AOT code and all three required native-core files. Each
  bundled core file matches the independently hash-verified pinned archive.
  SHA256 values and audit details are in `artifacts/SHA256SUMS` and
  `artifacts/verification/windows-package-audit.json`.
  Both packages are unsigned internal tests. **Real Windows installation,
  login, VPN connectivity and coexistence with upstream services were
  UNKNOWN for that 5.0.0 build**; downloading and inspecting a binary does not verify its runtime.

## License notes for distribution

`LICENSE.md` (Hiddify Extended GNU GPL v3) requires, among other conditions:
publishing the source as a public GitHub fork kept up to date with any
published app release, producing all releases with GitHub Actions, attribution
to the Hiddify project with the original license linked and changes documented
in the Readme, noncommercial use only, and no app-store publication with a
similar name/UI. Development uses a local checkout and an authorized private
repository for Windows test builds. Source is also published in the standalone
`YIYI-16/Haoze-Connect` mirror; no public binary release exists. Before a public
binary distribution, review the public-fork and GitHub Actions requirements.
The attribution links in `constants.dart`/
`README.md` have to stay, and app stores stay out of scope. Whether this
satisfies every clause is not asserted here — double-check before public
distribution.
