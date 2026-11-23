# Basil

Basil is a native macOS dual-pane file manager in the spirit of Total Commander, written in Swift (AppKit for the panes, SwiftUI for dialogs and settings). VoiceOver accessibility is a core requirement: every pane, dialog and command is designed to work fully with VoiceOver and the keyboard alone.

Features include Total Commander style keys and menus, tabs, quick filter, multi-rename, an operation queue with a secure copy and move engine, archives (zip, tar, 7z, RAR and more, including passwords), checksums, split and combine, and remote connections (SFTP, FTP/FTPS, WebDAV and Nextcloud, SMB, S3, Dropbox and Google Drive).

Basil is a personal project. It is not sandboxed, notarized or sold.

## Requirements

- macOS 27 or later, Apple Silicon
- Xcode 27 (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Homebrew, only for the FTP tests (they build a local pure-ftpd)

## Setup

```sh
git clone https://github.com/Flameborn/basil.git
cd basil
scripts/bootstrap.sh    # builds the vendored OpenSSL + libssh2 and 7zz (run once, before anything else)
xcodegen generate       # creates Basil.xcodeproj (not committed; run again after editing project.yml)
```

All other third-party code (libarchive, UnRAR, BLAKE3, xxHash, SwiftyDropbox) is vendored as source in `Vendor/` and built by SwiftPM.

### Code signing

Basil must be signed with a stable identity, not ad hoc: an ad-hoc signature changes on every build and macOS then forgets the Full Disk Access grant. By default the project signs with an identity named `dev`. Either create a self-signed code-signing certificate called `dev` in Keychain Access (Certificate Assistant > Create a Certificate, type Code Signing), or point the build at your own identity in `Config/Signing.local.xcconfig` (gitignored):

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

After the first launch, grant Basil Full Disk Access in System Settings > Privacy and Security.

### Dropbox app key (optional)

Dropbox support needs an app key from the [Dropbox App Console](https://www.dropbox.com/developers/apps). Without one the app builds and runs fine, it just does not offer Dropbox.

1. Create an app: Scoped access, Full Dropbox.
2. Permissions: `account_info.read`, `files.metadata.read`, `files.metadata.write`, `files.content.read`, `files.content.write`, `sharing.read`, `sharing.write`.
3. OAuth 2 redirect URI: `http://localhost:21745/dropbox`
4. Put the key in `Config/Dropbox.local.xcconfig` (gitignored):

```
BASIL_DROPBOX_APP_KEY = your_app_key
```

No app secret is needed and none should be committed: Basil signs in with OAuth 2 PKCE, which uses only the public app key. Tokens are stored in the macOS Keychain.

### Google Drive OAuth client (optional)

Google Drive support needs an OAuth client from the [Google Cloud Console](https://console.cloud.google.com/). Without one the app builds and runs fine, it just does not offer Google Drive.

1. Create a project and enable the Google Drive API (APIs and Services > Library).
2. OAuth consent screen (Google Auth Platform): External, add the scope `https://www.googleapis.com/auth/drive`, and add your Google account as a test user.
3. Set the publishing status to "In production". In "Testing" Google ends every sign-in after 7 days. An unverified app in production shows a "Google hasn't verified this app" warning at sign-in (Advanced > Go to Basil), which is fine for personal use.
4. Credentials > Create credentials > OAuth client ID, type Desktop app. No redirect URI is needed: Basil receives the sign-in on `http://127.0.0.1` with a free port, which Google allows for desktop clients.
5. Put the client ID and secret in `Config/GoogleDrive.local.xcconfig` (gitignored):

```
BASIL_GOOGLE_CLIENT_ID = 1234-abc.apps.googleusercontent.com
BASIL_GOOGLE_CLIENT_SECRET = GOCSPX-...
```

Google documents the secret of a desktop client as not confidential (it is built into every copy of the app); Basil still signs in with PKCE. Tokens are stored in the macOS Keychain.

## Building

Debug:

```sh
xcodebuild -project Basil.xcodeproj -scheme Basil -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Basil.app
```

Release:

```sh
xcodebuild -project Basil.xcodeproj -scheme Basil -configuration Release \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Basil.app
```

You can also open `Basil.xcodeproj` in Xcode and run the Basil scheme.

## Releases

```sh
scripts/build-dmg.sh          # Release build into build/dist/Basil-<version>.dmg (no version change)
scripts/release.sh            # release the version in project.yml if it has no tag yet (the first one, 0.1.0)
scripts/release.sh minor      # 0.1.0 -> 0.2.0 (also patch, major, or an exact x.y.z)
scripts/release.sh patch --dry-run   # build the DMG and show the notes, change nothing
```

The version is `CFBundleShortVersionString` in `project.yml`; the build number goes up with each release. Write changes under `## Unreleased` in `docs/changelog.md` as you go. `release.sh` renames that section to the new version and date, builds the DMG, commits, tags `v<version>`, pushes, and publishes a GitHub release with the DMG and those entries as notes (needs `gh auth login`, a clean tree on master and in step with origin). The Dropbox app key, when set, is built into the DMG; that is fine, it is not a secret.

The DMG is signed with your local identity, not notarized, so on another Mac Gatekeeper blocks the first launch: right-click Basil and choose Open, or run `xattr -dr com.apple.quarantine /Applications/Basil.app`.

## Tests

Each module is a local Swift package under `Packages/` with its own tests (Swift Testing):

```sh
swift test --package-path Packages/BasilOperations                 # one package
swift test --package-path Packages/BasilOperations --filter SecureCopyTests   # one suite
for p in Packages/*/; do swift test --package-path "$p"; done      # all packages
```

UI tests (XCUITest, including accessibility audits) run against the app:

```sh
xcodebuild -project Basil.xcodeproj -scheme Basil -derivedDataPath build/DerivedData test
```

Notes:

- The UI tests use their own fixture folder and preferences domain and never touch your real settings.
- The SFTP tests start macOS's own `sshd` on a free port as your user; the FTP tests build pure-ftpd with `scripts/build-test-ftpd.sh` on first use (needs Homebrew).
- Dropbox and Google Drive tests run against in-memory fake servers and need no app key, OAuth client or network.

## Project layout

```
App/          app target (entry point, menus, wiring)
Packages/     one SwiftPM package per module (Core, VFS, Operations, Archives, Remote, UI, ...)
Tests/        UI tests
Vendor/       third-party sources and their build scripts
Config/       shared build settings and local overrides
scripts/      bootstrap and test helper scripts
```

`CLAUDE.md` describes the architecture in detail, and `progress.md` tracks milestones and decisions.

## License

Basil is released under the [MIT License](LICENSE). The third-party code in `Vendor/` keeps its own licenses (see each folder).
