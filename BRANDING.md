# Haoze branding

The Android and Windows display name is **Haoze**. The source HZ mark is the
original `www.zhouhaoze.com/favicon.png`, retained unchanged at
`assets_source/images/icon/haoze.png`.

Regenerate launcher, app, Windows ICO, notification, TV banner and status-tray
assets with:

```sh
dart --packages=.dart_tool/package_config.json tool/generate_haoze_branding.dart
```

The navy background keeps the light HZ strokes readable. Android adaptive icons
use the transparent original mark inside the native safe zone; monochrome
notification icons preserve its alpha mask. Connection-status badges retain
separate stopped, proxy and TUN colors; the safe-mode diagnostic icon is kept.
The existing status-icon generator reapplies the Haoze branding last.

Display-name changes preserve existing application identity: the Android package
and certificate, Windows binary and installer AppId, application data directory,
secure-storage keys, startup integration key and WebDAV collection remain stable.
Windows `ProductName` deliberately keeps its original value because both
path_provider and flutter_secure_storage derive the existing data directory
from it; the window title, FileDescription, installed-app name and Start Menu
shortcut display **Haoze**. The installer removes its previous named Start Menu
shortcut on upgrade.

Download asset names and repository URLs remain compatible with the existing
6.0.x/6.1.x updater contract. This is a 6.1.1 application update; Android ARM64
uses version code 64101.
