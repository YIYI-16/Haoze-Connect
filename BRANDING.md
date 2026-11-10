# Haoze branding

The Android and Windows display name is **Haoze**. The source HZ mark is the
original `www.zhouhaoze.com/favicon.png`, retained unchanged at
`assets_source/images/icon/haoze.png`.

Regenerate launcher, app, Windows ICO, notification, TV banner and status-tray
assets with:

```sh
dart --packages=.dart_tool/package_config.json tool/generate_haoze_branding.dart
```

The light tile uses a dark HZ mark with generous whitespace: a 320 px mark
canvas centered in a 512 px tile. The original source geometry is retained,
with stronger strokes for small sizes. Android adaptive icons use 32 dp insets
so their visible mark has matching whitespace after system masking; monochrome
notification icons preserve its alpha mask. Connection-status badges retain
separate stopped, proxy and TUN colors; the safe-mode diagnostic icon is kept.
The existing status-icon generator reapplies the Haoze branding last.

Windows uses **Haoze** for the executable (`Haoze.exe`), product metadata,
installer, default installation directory and Start Menu shortcut. The Android
package and signing certificate and the Windows installer AppId remain stable.
Before storage plugins initialize, Windows moves the previous product's Roaming
and Local application data directories to `Haoze/Haoze`, preserving encrypted
credentials and settings. An existing destination is never overwritten; a failed
move stops startup. Startup integration and WebDAV collection keys remain stable.
The installer removes its previous named Start Menu shortcut on upgrade.

Download asset names and repository URLs remain compatible with the existing
6.0.x/6.1.x updater contract. This is a 6.1.3 application update; Android ARM64
uses version code 64103.
