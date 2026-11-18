# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Basil** (bundle ID `com.erion.basil`) is a native macOS dual-pane file manager in the spirit of Total Commander, written in Swift. **VoiceOver accessibility is a hard requirement** (not a polish item), and the app must also look good. It is for personal use and won't be sold.

Progress, completed milestones and open questions are tracked in **`progress.md`**. Read it at the start of every session. Update it whenever a milestone, decision or open question changes.

## Working rules (from the project owner)

- **Never guess. If something is unclear, ask** (use AskUserQuestion). This applies to library choices, UX behaviour, defaults, naming and anything not settled below or in `progress.md`. Write every new decision in the "Decisions" section of `progress.md`.
- Everything is modular. New features must plug in through the existing registries (providers, operations, archive backends, commands, plugins) instead of being wired directly into the UI.
- **No emojis, symbol glyphs or decorative Unicode anywhere**: UI text, VoiceOver strings, docs, comments. Use plain words ("Cmd+Shift+F6", "Up", "->"). Symbols are read out badly by VoiceOver. No SF Symbol decoration either; real file-type icons are fine.
- **Commit when a feature is done** (no need to ask). Keep `progress.md` updated in the same commit.
- Copy and move integrity is the most important correctness property in the app (see "Secure copy/move").

## Settled decisions

| Area | Decision |
|---|---|
| Language / toolchain | Swift 6 (strict concurrency), Xcode 27, **macOS 27 minimum** |
| UI | **AppKit** for the main window, panes (view-based `NSTableView`), keyboard handling and command line. **SwiftUI** only for settings, dialogs and the queue window, hosted in `NSHostingView`/`NSHostingController`. Reason: panes must handle hundreds of thousands of rows and need fine-grained VoiceOver and focus control. |
| Project | **XcodeGen** (`project.yml`, the generated `.xcodeproj` is not committed) plus **local SwiftPM packages**, one per module |
| Distribution | Not sandboxed and not notarized. Signed with a **stable local identity** (Apple Development cert from a personal team, or a self-signed code-signing cert), **not ad hoc**. Ad-hoc signatures change on every build, which resets the Full Disk Access (TCC) grant. Users grant Full Disk Access manually. |
| Archives | **libarchive** (zip/tar/gz/bz2/xz/zstd/cpio/iso...) + **7-Zip `7zz`** (7z incl. solid, AES, header encryption, and encrypted zip writing) + **UnRAR** (RAR extraction incl. passwords), all behind one `ArchiveBackend` protocol |
| SSH/SFTP | **libssh2**: password, key files (incl. encrypted, ed25519), ssh-agent, known_hosts verification |
| Git | **System `git` CLI**, parsing porcelain v2 / `-z` output. Do not use libgit2. |
| Plugins | **LuaJIT** (Lua 5.1 semantics + LuaJIT extensions; write plugin APIs against 5.1) |
| Unstable copy source | Retry N times with backoff (configurable, default 3), then pause the queue item and ask: Keep retrying / Accept latest stable snapshot / Skip / Cancel |
| Remote services | SFTP, FTP/FTPS and Dropbox first. Then WebDAV, SMB (NetFS mount), S3-compatible, Google Drive and OneDrive as provider modules, added over time |
| Copy verification | Destination read-back verification is **off by default for both copy and move** and is enabled by a setting. Source-stability checking (below) always runs. |
| Search | Two engines: **Spotlight** (`NSMetadataQuery`/`MDQuery`) and Basil's own **Everything-style filename index** stored in a **custom binary format** |
| Chunk hash | **BLAKE3** (official C implementation with NEON). It is cryptographic, so it has no known collisions, unlike XXH3. Hashing runs in a pipeline alongside the reads and writes, so it never adds wait time. |
| Search index | Covers the **local boot volume by default**. Other volumes, including network ones, can be added later. It stores **name, size, dates and attributes** so results can be filtered. |
| Sync | Works like **Total Commander's "Synchronize directories"** and is stateless. See the Sync section below. It does not use librsync; files are transferred by the secure copy engine. Planned for later. |
| Quick filter | **Cmd+S** pops up an edit field (anchored to the pane) where the filter is typed; the pane filters live as you type. Typing letters directly in a pane does NOT filter - it jumps to the first matching name (type-ahead). Wildcards (`*.mp3`), substring (`apple`), `;`-separated patterns, `\|` exclusions, optional regex mode. Cleared on directory change. |
| Look | **Total Commander-like**: flat dense grid, custom colour scheme, drive/button bar, function-key bar at the bottom. Colours come from theme tokens, never hard-coded, and must meet WCAG contrast. **Light and dark variants** that follow the system appearance. |
| Keybindings | **Total Commander defaults, Mac-adapted**: F3 view, F4 edit, F5 copy, F6 move, Shift+F6 rename, F7 mkdir, F8 delete, Tab switch pane, Space select; Ctrl/Alt combos become Cmd/Option where natural (Cmd+R reread, Cmd+M multi-rename). Everything remappable through CommandRegistry. |
| Multi-rename | Works like **Total Commander's Multi-Rename Tool**. See below. |

## Architecture (target design)

Big picture: **UI -> Commands -> Operations Queue -> VFS Providers**. Plugins and integrations hook in through registries at each layer.

```
project.yml             XcodeGen spec (app target "Basil" + BasilUITests); Basil.xcodeproj is generated, gitignored
Config/Base.xcconfig    shared settings: macOS 27, Swift 6 strict concurrency, signing identity "dev"
                        (override locally in Config/Signing.local.xcconfig, gitignored)
App/Sources/            thin app target: main.swift, AppDelegate, main menu, wiring of registries
Tests/BasilUITests/     XCUITests incl. performAccessibilityAudit()
Packages/               one local SwiftPM package per module, each with a <Name>Tests target
  BasilCore/            shared models (VFSPath, FileItem, capabilities), settings store, logging, Keychain wrapper
  BasilVFS/             FileSystemProvider protocol + ProviderRegistry; LocalProvider            (-> Core)
  BasilOperations/      Operation protocol, serial queue (actor), SecureCopyEngine, conflicts   (-> Core, VFS)
  BasilArchives/        ArchiveBackend protocol; libarchive/7-Zip/UnRAR backends; ArchiveProvider (-> Core, VFS)
  BasilRemote/          one provider per service (SFTP, FTP, Dropbox, WebDAV, S3, GDrive, OneDrive, SMB) (-> Core, VFS)
  BasilGit/             GitService wrapping the git CLI                                          (-> Core)
  BasilSearch/          Spotlight engine + own filename index (scanner, FSEvents, binary store)  (-> Core, VFS)
  BasilSync/            directory compare + sync planning, executed as queue operations          (-> Core, VFS, Operations)
  BasilPlugins/         LuaJIT bridge, plugin manifest/loader, Lua API surface                   (-> Core, VFS)
  BasilIntegrations/    terminal launcher, viewer/editor associations (F3/F4), sound effects     (-> Core)
  BasilUI/              AppKit panes/main window, SwiftUI dialogs and settings                   (-> Core, VFS, Operations)
Vendor/                 third-party sources + build scripts (libarchive, 7-Zip, UnRAR, libssh2, LuaJIT, BLAKE3, ...)
```

Package dependencies flow strictly downward: Core <- VFS <- everything else, and only the app target depends on all packages. Feature packages do not depend on each other except as shown. To add a dependency between packages, edit that package's `Package.swift`. To add a new package, also add it under `packages:` and the app's `dependencies:` in `project.yml`, then run `xcodegen generate`.

Key concepts:

- **VFSPath** names a location as provider + path, and paths can nest. Example: a file inside a zip on an SFTP server. Browsing an archive means pushing an `ArchiveProvider` on top of the parent provider. All pane and operation code works with `VFSPath` and providers, and never with raw `URL`/`FileManager`, except inside `LocalProvider`.
- **Providers declare capabilities** (rename, atomic rename, set permissions, server-side copy, random-access read, checksums, ...). Operations choose a strategy from those capabilities.
- **All mutating actions are Operations** that go through the single queue. This covers copy, move, delete, mkdir, rename, pack, unpack, test archive and repack after edit. The queue runs one item at a time. Items can be paused, reordered and cancelled, and each item has its own progress and log. UI code never performs file I/O directly.
- **Commands** (F-keys, menu items, command palette, Lua plugins) are registered by ID in a `CommandRegistry`, and keybindings map to command IDs. Built-in features use the same registry as plugins.
- **Built-in providers, archive backends and commands register through the same registries Lua plugins use.** New features should be addable without changing the UI module.

### Secure copy/move (critical invariant)

This fixes the ForkLift bug where only the bytes present at the start of the copy are copied.

The goal is to never read data more often than needed. Each case gets a different strategy:

| Case | Strategy |
|---|---|
| Move, same volume | `rename()`. It is instant, and no write is ever lost because writers keep writing to the same inode. |
| Copy, same APFS volume | `clonefile()`, which is instant and shares blocks. Re-check the source fingerprint afterwards and re-clone if it changed. |
| Cross-volume or remote | One pass that reads, hashes per chunk (about 1 MB) and writes into `.basil-partial-*` in the destination directory. |

After the cross-volume pass:

1. Record a source fingerprint before the pass: size, mtime, ctime and file ID. After the pass, compare it again.
   - Unchanged: the copy is done, with no re-read.
   - Changed: re-read the source and compare per-chunk hashes, then rewrite only the chunks that differ. If the file only grew, copy just the tail.
   - Then repeat the check, following the retry-then-ask policy above.
   - Chunk hashes are BLAKE3, computed on a separate task while the next chunk is read or written.
2. `F_FULLFSYNC` the file, copy metadata (xattrs, ACLs, mode, dates, Finder tags) and atomically rename it into place.
3. Optionally read back the destination and compare hashes. This is off by default and controlled by a setting.
4. A cross-volume **move deletes the source only after step 1 reports the source stable** (and after step 3 passes, if it is enabled).

Remote providers without atomic rename, random-access writes or checksums follow the same contract as closely as their capabilities allow. The queue log states when a guarantee could not be met.

Never weaken this path for speed without asking. Engine tests must include sources that are appended to, truncated and rewritten in the middle during the copy, for every strategy.

### Search index

The index works like Everything on Windows:

- **Initial scan:** APFS catalog search (`searchfs`) where available, otherwise `getattrlistbulk`.
- **Live updates:** an FSEvents stream with file-level events. Basil stores the last event ID so it can replay events missed while it wasn't running. This is the macOS counterpart of the NTFS change journal. If the history is unavailable (for example `kFSEventStreamEventFlagMustScanSubDirs`, or the volume UUID changed), rescan only the affected subtree.
- **Storage:** a custom binary format, one index per volume, memory-mapped for instant substring, wildcard and regex filename matching.
- **Searches** can run against Spotlight, the own index, or a live directory walk, and each one is an engine behind a common search protocol.

### Quick filter (current pane)

As you type, the visible pane is filtered by wildcard (`*.mp3`) or substring (`apple`). Filtering runs on the pane's loaded listing, off the main thread, and stays fast at 100k+ items. It does not change the directory or the selection on disk. VoiceOver announces the number of matches, and a visible indicator shows that a filter is active.

### Multi-rename (Total Commander style)

This is a dialog for the selected files. It offers:

- **Name and extension masks** with placeholders: `[N]` name, `[E]` extension, `[N2-5]` character ranges, `[C]` counter (start, step, digits), and date/time placeholders.
- **Search and replace**, with optional regex.
- **Case conversion.**
- A **live preview grid** showing old name and new name, with conflicts highlighted.
- **Saved presets** and **undo** of the last batch.

The batch runs as a single queue operation. It detects target collisions, resolves cycles (for example a->b, b->a) through temporary names, and writes an undo log. Lua plugins can add placeholder fields. The preview grid must be fully accessible.

### Sync (Total Commander style)

Sync compares two directories (left and right panes), optionally including subdirectories. Files are compared by date and size, optionally by content (BLAKE3), with a configurable timestamp tolerance.

- **Results:** each file is marked copy-right, copy-left, equal or different, or as existing on one side only. Filters show or hide each category, and you can flip or exclude the direction of any file.
- **Asymmetric mode:** files that exist only on the target side are deleted.
- **Stateless:** like Total Commander, sync keeps no history database, so a file that exists on one side only is offered as a copy, not detected as a deletion.
- **Execution:** sync turns into queue operations that use the secure copy engine.

### Accessibility requirements

- Every interactive element needs a correct accessibility role, label and value. Panes expose rows and cells as proper table rows and cells.
- Announce state changes VoiceOver can't infer (operation finished or failed, pane switched, selection count, directory loaded) with `NSAccessibility.post(..., .announcementRequested)`.
- Never convey information only through colour, icons or sound effects.
- Everything is reachable and operable by keyboard alone.
- UI tests run `XCUIApplication.performAccessibilityAudit()`.

### Panes (implemented in BasilUI)

- `PaneModel` (one per pane) owns directory, sorted `allItems`, visible `rows` (hidden/filter applied), marks and sort order. All listing, sorting and filtering runs in detached tasks. Every async result is checked against a generation counter, so stale results (older keystroke, older sort, older load) are dropped. Keep this pattern for anything async that writes model state.
- **There is no ".." row.** Backspace or Cmd+Up goes to the parent folder, and the cursor lands on the folder you came from.
- The cursor is the table's single selection. Marks (Total Commander "selection") are separate: `model.marked`, drawn in the marked colour.
- Keys: `PaneTableView.keyDown` translates the event to a `KeyChord` and goes through `CommandRegistry` first. Plain printable characters are type-ahead (jump to the first name with that prefix). Built-in commands and their default keys live in `BuiltinCommands.swift`. Shifted keys bind on the unshifted character (Cmd+Shift+. is `.character(".")` with `.shift`).
- Default keys: Tab switches pane. Enter or Cmd+Down opens. Backspace or Cmd+Up goes to the parent. Cmd+R rereads. Cmd+Shift+. toggles hidden files. Cmd+S opens the quick filter. Home and End jump to the first or last item. Space toggles a mark, and Shift+Up/Down marks while moving. Cmd+A marks all files, and Cmd+Shift+A unmarks all. Cmd+F3, F4, F5 and F6 sort by name, extension, date and size. F3-F8, Shift+F6 and Cmd+M are registered but disabled until their milestones.
- VoiceOver:
  - The lists are labelled only "Left pane" / "Right pane". The pane container is not an accessibility element.
  - Each `PaneCellView` is the accessibility element (static text), with `spokenLabel`, e.g. "song.mp3, file, marked". The inner text field is hidden. Empty cells, or cells with `spokenLabel == ""`, are skipped; for example a folder's "<DIR>" size is silent.
  - State changes are spoken through `WorkspaceContext.announce`: directory loaded, pane switched, mark counts, sort, filter results, errors.
- Colours are drawn in views (`ThemedBox`, row views), not set as layer `cgColor`, so light/dark switches apply immediately.

### Large directories

Panes use view-based `NSTableView` with cell reuse. Listing is streamed off the main thread (`getattrlistbulk` for local volumes), and sorting and filtering happen off the main actor. Updates come from FSEvents and are applied as diffs, not full reloads. Never load the whole directory in memory more than once, and never compute anything per-row on the main thread.

### Security notes

- Credentials and archive passwords live only in the Keychain. **Never pass passwords on a subprocess argv** (`7zz`, `unrar`, `git`), because other processes can read argv. Use stdin, a pty or an API instead.
- SFTP must check known_hosts and prompt on unknown or changed host keys.
- LuaJIT on a hardened runtime needs the `com.apple.security.cs.allow-jit` entitlement.

### F3 / F4 / terminal

- F3 is Quick Look (`QLPreviewPanel`). F4 edits with a global editor, or with a per-extension list of apps: one app opens directly, several apps show a popup menu.
- For files inside archives or on remotes, F4 edits a local temp copy. When the editor saves or closes, the app offers to repack or upload the file, which runs as a queue operation.
- "Open terminal here" uses a configurable terminal (Terminal, iTerm2, WezTerm, Ghostty, ...) through per-terminal launch templates.

## Commands

```bash
xcodegen generate                                      # regenerate Basil.xcodeproj (after editing project.yml or adding app/UI-test files)
xcodebuild -project Basil.xcodeproj -scheme Basil -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Basil.app  # run
xcodebuild -project Basil.xcodeproj -scheme Basil -derivedDataPath build/DerivedData test   # UI tests incl. accessibility audit
swift test --package-path Packages/BasilOperations     # one package's tests (Swift Testing)
swift test --package-path Packages/BasilOperations --filter SecureCopyTests/sourceAppendedDuringCopy   # single test
for p in Packages/*/; do swift test --package-path "$p"; done   # all package tests
```

- UI tests: Xcode sandboxes the test runner, so files it creates are unreadable by Basil. Debug builds launched with `BASIL_UITEST_FIXTURE=1` create the fixture themselves (`App/Sources/UITestFixture.swift`) and start both panes in it. Forced start folders are never saved as the user's start folders.
- 200k-item benchmark (skipped unless `BASIL_PERF_DIR` is set): `BASIL_PERF_DIR=/path/to/big swift test -c release --package-path Packages/BasilUI --filter largeDirectory`. Last result: load and sort 0.87 s, re-sort 0.10 s, filter 0.04 s.
- Package unit tests use **Swift Testing** (`import Testing`). App-level UI tests use XCTest/XCUITest.
- `xcodebuild` prints `DVTCoreDeviceCore` / "CoreSimulator is out of date" plug-in errors on this machine. They are Xcode environment noise and do not affect macOS builds.
- `scripts/bootstrap.sh` (building vendored C deps into `Vendor/`) does not exist yet. It is blocked on open questions in `progress.md`.
