# Stable release and in-app updates

6.0.3 begins the fixed Android signing identity. Production builds use
`APP_ENV=stable`; the PRE ribbon is absent. SAFE MODE retains its warning.

## Android identity and key custody

- Package: `com.haoze.connect.mihomo`.
- Certificate SHA-256: `ac3b825909077a50ce17e3e3889b739d111b5293556fbe82a52c3fda3cd88736`.
- Public pin: `android/release-certificate.sha256`.
- Encrypted PKCS12 backup and recovery credentials are outside Git under
  `/home/zhou/Haoze-Connect-Android-Signing/`, owned by zhou with directory
  permission 0700 and file permission 0600. Keep an additional offline backup.
- Actions secrets: `HAOZE_ANDROID_KEYSTORE_BASE64`,
  `HAOZE_ANDROID_STORE_PASSWORD`, `HAOZE_ANDROID_KEY_ALIAS`, and
  `HAOZE_ANDROID_KEY_PASSWORD`. Restore these from the same backup when
  migrating repositories; never generate a replacement key for a routine update.

`haoze_android_signing.py prepare` verifies the certificate and private-key
password before exporting a temporary signing path. Gradle independently checks
the pin before any release build. Missing or mismatched credentials fail the
build; there is no debug-key fallback. Artifacts contain only the APK and public
verification metadata, and the temporary CI key is deleted after the job.

Flutter adds 2000 to the base version code for the arm64 split APK. For
`6.0.3+62003`, the installed code is 64003. Future updates must keep the package
and certificate and increase both the semantic version and installed code.

Earlier `.dev` packages are separate applications. Users can install 6.0.3 beside
them and sign in again. No compatibility with their changing debug certificates
is promised, and their data is not deleted automatically.

## Update contract

The login page and About page expose the same update dialog without requiring a
panel session. From 6.0.4, the updater reads XBoard's public
`/api/v1/client/app/getVersion` endpoint and uses the platform's APP version and
download URL. It verifies the corresponding tag-specific release in
`YIYI-16/Haoze-Connect`, then its `UPDATE-MANIFEST.json`. It rejects prereleases,
unexpected filenames, insecure URLs, inconsistent package/certificate/version,
and incorrect lengths or SHA-256 hashes. GitHub API failures can fall back only
to the same version's manifest. Panel failures never fall back to GitHub Latest.
The panel must explicitly select a newer version before the client offers it.
See [XBOARD_APP_UPDATES.md](XBOARD_APP_UPDATES.md) for the panel configuration and
the narrowly scoped backend route patch.

Downloads stay in the application's temporary `haoze-updates` directory. Users
can cancel or retry; a successful download still requires an explicit Install
action. Android rechecks the APK with PackageManager and the pinned certificate,
then opens the system installer through a narrowly scoped FileProvider. Android
installation-source permission and system confirmation remain required.

Windows rechecks the downloaded EXE, requests installer elevation, and runs the
normal application shutdown only after successful installer handoff. Installer
cancellation does not mean an update succeeded. Windows binaries remain unsigned
with respect to Windows code signing; Android's release key does not provide
Windows trust or Smart App Control approval.

## Release procedure

Run `haoze-build.yml` with `platform=all` and a pinned source SHA. Its checks,
Windows, Android, and manifest jobs must all succeed. Publish these six assets:

1. `HaozeConnect-Android-arm64-<version>.apk`
2. `HaozeConnect-Windows-Setup-x64-<version>.exe`
3. `HaozeConnect-Windows-Standalone-x64.zip`
4. `UPDATE-MANIFEST.json`
5. `SHA256SUMS`
6. `BUILD-PROVENANCE.json`

Use the workflow-generated manifest without changing its artifact hashes.
Compare asset digests and source SHA before setting the release as Latest.
After publishing, update the Windows/Android versions and versioned download
URLs in XBoard's System Settings → APP Settings. Existing 6.0.3 clients discover
the first 6.0.4 upgrade through GitHub Latest; 6.0.4 uses panel settings thereafter.
The workflow's 6.0.2 Windows upgrade-baseline artifact is acceptance material,
not a public release asset. Do not upload keystores, recovery credentials,
test-account data, or an aggregate download ZIP.

Automated tests cover update discovery, integrity, cancellation, permission and
installer failure handling, and stable/SAFE MODE banners. Artifact inspection
proves certificate identity and version ordering. A physical Android upgrade,
OEM installation prompts, and the original Windows 11 machine's trust policy
still require device verification; these checks must not be inferred from unit
tests or a Windows Server run.
