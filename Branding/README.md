# Basil icon

The app icon is the Icon Composer document `App/Resources/AppIcon.icon`: a basil leaf folded along its midrib like a folder, with two parchment scrolls tucked in. It has three layers (`Assets/back.svg`, `scrolls.svg`, `front.svg`) on a cream to sage background. Xcode compiles it into the app's icon (`AppIcon.icns` and `Assets.car`).

The PNGs here are exported from it with Icon Composer's `ictool` (macOS, Default rendition):

- `basil-icon-64.png` and `basil-icon-256.png`: the two sizes the Dropbox App Console asks for (Branding tab).
- `basil-icon-48.png` and `basil-icon-215.png`: the logo of the OneDrive app registration (Microsoft Entra admin center, App registrations, Branding and properties). Entra takes PNG, JPG or BMP up to 100 KB.
- `basil-icon-1024.png`: full size, for documentation.

To export them again after changing the icon:

```bash
T="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
for n in 48 64 215 256 1024; do
  "$T" App/Resources/AppIcon.icon --export-image --output-file Branding/basil-icon-$n.png \
    --platform macOS --rendition Default --width $n --height $n --scale 1
done
```

The icon uses no Dropbox or Microsoft logo, colours or shapes, as their branding guidelines require for apps that connect to them.
