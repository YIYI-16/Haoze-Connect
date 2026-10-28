# Haoze Connect — internal distribution guide

Haoze Connect is an internal, free client distribution of a self-hosted Xboard
panel (`https://www.haoze.cyou`), derived from the upstream
[Hiddify app](https://github.com/hiddify/hiddify-app). This document describes
the branding/build configuration in this repository and how internal builds are
produced. Nothing here is a statement about the legal sufficiency of the
license interpretation below — read `LICENSE.md` yourself before any public
distribution.

**No public fork exists yet.** This repository is currently only a local
checkout; nothing has been published or released. Before any public
distribution, a public fork must be created and the release must be produced
through that fork's GitHub Actions, as `LICENSE.md` requires (see the license
notes below).

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

## Local validation performed

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
  No public fork, public release or store submission is authorized.
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
  login, VPN connectivity and coexistence with upstream services remain
  UNKNOWN**; downloading and inspecting a binary does not verify its runtime.

## License notes for distribution

`LICENSE.md` (Hiddify Extended GNU GPL v3) requires, among other conditions:
publishing the source as a public GitHub fork kept up to date with any
published app release, producing all releases with GitHub Actions, attribution
to the Hiddify project with the original license linked and changes documented
in the Readme, noncommercial use only, and no app-store publication with a
similar name/UI. Development uses a local checkout and an authorized private
repository for Windows test builds. No public fork or public release exists. Before a public
distribution it has to become a public fork, releases have to be produced
through that fork's GitHub Actions, the attribution links in `constants.dart`/
`README.md` have to stay, and app stores stay out of scope. Whether this
satisfies every clause is not asserted here — double-check before public
distribution.
