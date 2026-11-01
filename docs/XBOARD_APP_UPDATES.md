# XBoard APP settings

Haoze Connect 6.0.4 uses System Settings → APP Settings to select the offered
Windows/Android version and installer. The same check works from the login page
and Tools → About without an account or subscription token.

For 6.0.4, the four fields are:

| Setting | Value |
| --- | --- |
| Windows version | `6.0.4` |
| Windows download URL | `https://github.com/YIYI-16/Haoze-Connect/releases/download/v6.0.4/HaozeConnect-Windows-Setup-x64-6.0.4.exe` |
| Android version | `6.0.4` |
| Android download URL | `https://github.com/YIYI-16/Haoze-Connect/releases/download/v6.0.4/HaozeConnect-Android-arm64-6.0.4.apk` |

Use a plain stable `X.Y.Z` version and its exact versioned installer URL. Windows
uses the EXE installer; the portable ZIP is available for manual distribution.
macOS settings remain independent and are unused by this client.

## Publishing subsequent versions

1. Build and verify the new release with the existing fixed Android key.
2. Publish the installer, APK, portable ZIP, manifest, checksums and provenance
   in `YIYI-16/Haoze-Connect` using the normal stable release process.
3. Set each platform's version and matching download URL in XBoard APP Settings.
4. Check from a client on an earlier version. Downloading and installation still
   require user confirmation.

Windows and Android can select different published versions. A panel version at
or below the installed version produces no update. A newer GitHub Latest does
not override the panel selection. Missing fields, denied access and malformed
settings are visible errors, never an “already current” result.

Installer distribution currently trusts the versioned URLs in the fixed GitHub
repository. Custom mirrors, a Release landing page and `latest` URLs do not meet
this contract. The tag-specific manifest supplies size, SHA-256 and Android
identity metadata. The native Android installer also verifies the production
package, increasing version code and fixed certificate before handoff.

## Public version endpoint

The inspected XBoard baseline `8e4864b4c7f6240e3ef08ecd7b59447e5d9dd363`
requires a subscription token for all `client` routes. The patch at
`tool/xboard/public-app-version.patch` registers only
`/api/v1/client/app/getVersion` and `/api/v2/client/app/getVersion` outside that
middleware group. Existing controllers return only the six public platform
version/download fields. Subscription and `app/getConfig` routes retain their
existing authentication.

Review and check the patch against the deployed source before applying it.
For image-based Docker installations, use persistent read-only mounts for the
two patched route files and preserve the existing image, service definition and
data volumes. A temporary `docker cp` edit disappears when a container is recreated.
Back up the Compose file before adding mounts and keep the backup private.
When upgrading XBoard, merge this small patch into the new version's route files
and rerun the tests. Existing route mounts otherwise continue to override the
new image's route definitions.

`tool/xboard/test_public_app_version.php` runs against the deployment image's
actual Composer dependencies. Run it in a temporary container with networking
disabled, a read-only filesystem, no capabilities and the patched route files
mounted read-only. It tests both anonymous version responses and all three
protected subscription/configuration paths, using fixture settings and no database.

After deployment, verify anonymous version requests return HTTP 200 and the
unchanged protected routes return HTTP 403. Docker recreation causes a short
service interruption; the existing data volumes must remain attached. Rolling
back consists of restoring the reviewed Compose backup and recreating only the
XBoard service with its previous image and mounts.

6.0.3 clients continue to discover 6.0.4 through GitHub Latest. Install 6.0.4 once
to adopt panel-controlled updates; the fixed Android signing identity starts
at 6.0.3 and remains unchanged.
