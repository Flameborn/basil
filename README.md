# Basil

Basil is a native macOS dual-pane file manager in the spirit of Total Commander, written in Swift (AppKit for the panes, SwiftUI for dialogs and settings). VoiceOver accessibility is a core requirement: every pane, dialog and command is designed to work fully with VoiceOver and the keyboard alone.

Features include Total Commander style keys and menus, tabs, quick filter, multi-rename, an operation queue with a secure copy and move engine, archives (zip, tar, 7z, RAR and more, including passwords), checksums, split and combine, and remote connections (SFTP, FTP/FTPS and Dropbox).

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
- Dropbox tests run against an in-memory fake server and need no app key or network.

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
