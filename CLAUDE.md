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
| Copy verification | Destination read-back verification is **off by default for both copy and move** and is enabled by a setting. |
| Copy mode | Setting **"Secure copy and move", off by default**. Off = Total Commander style (write straight to the target, no source-change check, no F_FULLFSYNC, move deletes the source right after copying; same-volume move still renames, same-volume copy still clones). On = the secure engine below. |
| Queue sounds and speech | Per operation kind (copy, move, delete, Trash, new folder, rename, other; plugins can add kinds) and outcome (finished, failed, cancelled, needs a decision): sound (None, macOS system sound, or any audio file), speak on/off, and text with placeholders. "Any operation" defaults, per-kind overrides. Defaults: Glass / Basso / none / Funk, all spoken. Speech goes to VoiceOver when it runs, otherwise the system voice. |
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
  BasilUI/              AppKit panes/main window, SwiftUI dialogs and settings                   (-> Core, VFS, Operations, Integrations)
Vendor/                 third-party sources + build scripts (libarchive, 7-Zip, UnRAR, libssh2, LuaJIT, BLAKE3, ...)
```

Package dependencies flow strictly downward: Core <- VFS <- everything else, and only the app target depends on all packages. Feature packages do not depend on each other except as shown. To add a dependency between packages, edit that package's `Package.swift`. To add a new package, also add it under `packages:` and the app's `dependencies:` in `project.yml`, then run `xcodegen generate`.

Key concepts:

- **VFSPath** names a location as provider + path, and paths can nest. Example: a file inside a zip on an SFTP server. Browsing an archive means pushing an `ArchiveProvider` on top of the parent provider. All pane and operation code works with `VFSPath` and providers, and never with raw `URL`/`FileManager`, except inside `LocalProvider`.
- **Providers declare capabilities** (rename, atomic rename, set permissions, server-side copy, random-access read, checksums, ...). Operations choose a strategy from those capabilities.
- **All mutating actions are Operations** that go through the single queue. This covers copy, move, delete, mkdir, rename, pack, unpack, test archive and repack after edit. The queue runs one item at a time. Items can be paused, reordered and cancelled, and each item has its own progress and log. UI code never performs file I/O directly.
- **Commands** (F-keys, menu items, command palette, Lua plugins) are registered by ID in a `CommandRegistry`, and keybindings map to command IDs. Built-in features use the same registry as plugins.
- **Built-in providers, archive backends and commands register through the same registries Lua plugins use.** New features should be addable without changing the UI module.

### Secure copy/move (critical invariant, when the "Secure copy and move" setting is on)

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

### Copy engine (implemented)

- `SecureCopyEngine` (BasilOperations, `SecureCopyEngine.swift`) does the work for copy and move. `transfer(_:to:mode:)` handles a file, symlink or folder tree (existing destination folders are merged); `transferFile` does one file. It talks to its runner through `TransferMonitor` (checkpoint, log, bytes transferred, and `decide` for a source that keeps changing).
- Providers that can be written implement `WritableProvider` (BasilVFS, `ProviderIO.swift`): fingerprint, metadata read/apply, volume identifier, open for reading, create file, rename (with or without replacing), clone, remove, mkdir, symlinks, synchronize, `maxTransferChunkSize`. `LocalProvider+Write.swift` does blocking I/O on its own dispatch queue (`LocalIO`), never on the cooperative pool.
- Strategy choice: move on the same volume renames; copy on the same volume clones (falls back to streaming when the volume can't clone); everything else streams. Same volume means same provider location and equal `volumeIdentifier`.
- Stream pass: the next chunk is read while the current one is hashed (BLAKE3) and written. Later passes write only chunks whose hash changed, then truncate. Metadata is applied to the partial file, then F_FULLFSYNC, then rename; BSD flags go on after the rename.
- The engine asks `TransferMonitor.resolveConflict` when a target file exists (default: fail). A move on the same volume renames per file too, also inside merged folders.
- Tests (`SecureCopyTests.swift`) use internal `EngineHooks` to change the source after a given chunk or clone and to force the stream strategy on one volume. Keep adding a test for every new strategy or provider.
- `Vendor/BLAKE3` is an unmodified copy of the official C code (see its `VERSION`); BasilOperations depends on it by path.

### Accessibility requirements

- Every interactive element needs a correct accessibility role, label and value. Panes expose rows and cells as proper table rows and cells.
- Announce state changes VoiceOver can't infer (operation finished or failed, pane switched, selection count, directory loaded) with `NSAccessibility.post(..., .announcementRequested)`.
- Never convey information only through colour, icons or sound effects.
- Everything is reachable and operable by keyboard alone.
- UI tests run `XCUIApplication.performAccessibilityAudit()`.

### Panes (implemented in BasilUI)

- **State and async work:** `PaneModel` (one per pane) owns the directory, sorted `allItems`, visible `rows` (hidden files and the filter applied), the `selected` set and the sort order. Listing, sorting and filtering run in detached tasks. Every async result is checked against a generation counter, so stale results from an older keystroke, sort or load are dropped. Keep this pattern for anything async that writes model state.
- **Navigation:** there is no ".." row. Backspace or Cmd+Up goes to the parent folder, and the cursor lands on the folder you came from.
- **Selection:** the user-facing word is "selected", never "marked". The cursor is the table's single selection; selected items (Total Commander "marking") are separate, in `model.selected`, and drawn in the selection colour.
- **Keys:** `PaneTableView.keyDown` turns the event into a `KeyChord` and tries `CommandRegistry` first. Plain printable characters are type-ahead. Commands and their default keys live in `BuiltinCommands.swift`. Function and navigation keys keep their raw key code; other keys bind on the unshifted character (Cmd+Shift+. is `.character(".")` with `.shift`).
- **Default keys:**
  - Tab switches pane. Enter or Cmd+Down opens. Backspace or Cmd+Up goes to the parent folder.
  - Home and End (Fn+Left/Right on Mac keyboards) jump to the first or last item.
  - F2 rereads. Cmd+Shift+. toggles hidden files. Cmd+S opens the quick filter. Cmd+I reads the status bar.
  - Cmd+D opens the locations menu for the current pane, Cmd+F1 for the left pane, Cmd+F2 for the right.
  - Space selects or deselects. Shift+Up/Down selects while moving. Cmd+A selects all files. Cmd+Shift+A deselects all.
  - Cmd+F3, F4, F5 and F6 sort by name, extension, date and size.
  - Ctrl+F1 is Brief view, Ctrl+F2 Full view, and Ctrl+F3-F11 custom views 1-9.
  - Cmd+, opens Settings, Cmd+W closes it (only the settings window: the main menu has no Close item, so Cmd+W never closes the main window). Cmd+J opens or closes the operation queue panel.
  - F5 copy and F6 move (sheet with the target path, prefilled with the other pane; relative paths and ~ work), Shift+F6 rename (sheet, name without extension preselected), F7 new folder, F8 or Forward Delete moves to the Trash, Shift+F8 or Shift+Forward Delete deletes permanently. Each confirms in a sheet and runs in the queue. Without items they say "No items".
  - F3, F4 and Cmd+M are registered but disabled until their milestones.
- **Views and columns:** a view (`ListView`) is an ordered list of `ColumnSpec` (id, visible, width). Brief and Full are built in; users add custom views in Settings. Columns come from `ColumnCatalog` (BasilCore), which plugins can extend. Each `ColumnDefinition` gives the display text and optionally different spoken text.
  - The Name column shows the full name when the view has no Ext column; otherwise it omits the extension.
  - Resizing or dragging columns in the table header writes back to the view, debounced.
- **Settings:** `SettingsStore` (BasilCore, `@Observable`) is persisted as JSON in UserDefaults and is tolerant of missing keys. AppKit code observes it with `onChange`. It holds size format (unit and 1024/1000 base), date format (pattern plus time format), views, the go-to-root-on-volume-switch flag, and bookmarks. The Settings window is SwiftUI (`SettingsWindow.swift`), with Move Up/Down buttons and also VoiceOver actions for reordering.
- **Locations menu:** an NSMenu listing Home, volumes, bookmarks, "Add Current Folder to Bookmarks" and "Manage Bookmarks...". Choosing a volume restores the last folder visited on it (per pane) unless the go-to-root setting is on.
- **VoiceOver speech rules (the user asked for minimal chatter):**
  - The lists are labelled only "Left pane" / "Right pane". Nothing is announced on Tab or on a folder change; VoiceOver reads the item under the cursor.
  - Rows read like Total Commander columns: "test, dir, date, ..." or "song, mp3, 1.5 MB, ...". No "file" or "folder" word is added. A selected item's name reads "song, selected".
  - Space says "Selected, 2 items", "Deselected, 1 item", or just "Deselected" when nothing is left selected.
  - `PaneTableView` exposes its own accessibility rows and cells (`PaneRowElement`, `PaneCellElement`) instead of NSTableView's, built from the model through `PaneViewController.paneTable(_:spokenTextForRow:column:)`. Cells with no text (a folder's empty extension) are left out: NSTableView's own empty AXCell made VoiceOver say "column 2, row 1". Rows have no label of their own; VoiceOver reads their cells, and VO+arrows moves between them. Only the visible rows and the cursor row are exposed.
  - The path header is an accessible static text labelled "Path".
- **Colours** are drawn in views (`ThemedBox`, row views), not set as layer `cgColor`, so light/dark switches apply immediately.

### Operation queue (implemented)

- `FileOperationQueue` (BasilOperations, `@MainActor @Observable`) is the single global queue, created in `AppDelegate` and owned by `MainWindowController`. It lives in memory only and does not survive restarts. Operations conform to `QueueOperation` (`title`, `run(_ context:) async throws`). `run` executes off the main actor and must call `context.checkpoint()` often: it waits while the item is paused and throws `CancellationError` once it is cancelled. `context.progress(fraction, detail)` is throttled to about 10 updates a second; `context.log` appends to the item's log.
- Items run one at a time and a new item starts right away when the queue is idle. Pausing the running item holds the queue; a paused waiting item is skipped until resumed. Removing the running item cancels it and drops it once it has stopped. Finished, failed and cancelled items stay in the list (with their log) until "Remove Finished".
- Queue events (finished, failed, cancelled) are announced through `MainWindowController.announce`, which posts on `NSApp` so they are heard while the queue panel is key.
- The queue panel (`QueueWindow.swift`) is a floating `NSPanel` hosting SwiftUI. In its list: Space pauses or resumes, Cmd+Up/Down move, Delete cancels and removes. Escape or Cmd+J (whatever is bound to `queue.show`) closes it. Each row is one static-text element ("Copy ..., running, 45 percent, 12 of 40 files") with VoiceOver actions for the same commands.
- Operations declare a `kind` (`OperationKind`, BasilCore) and report `context.items(done:total:)`; `QueueEvent` carries kind, outcome, counts and reason, and `MainWindowController.handle` turns it into sound and speech (`EventFeedbackPlayer`, BasilIntegrations).
- Operations ask questions with `context.ask(.conflict / .unstableSource)`; the queue marks the item "waiting for your decision", sends a `.needsDecision` event and calls `promptHandler` (the UI shows an NSAlert sheet on the main window). Conflict choices are Total Commander's: Overwrite, Skip, Overwrite All Older, Overwrite All, Skip All, Rename ("name (2).ext"), Cancel; "All" answers last for the rest of the operation.
- File operations (`FileOperations.swift`): `TransferOperation` (counts bytes first, progress by bytes), `DeleteOperation` (Trash through the provider's `.trash` capability, or recursive remove), `MakeDirectoryOperation`, `RenameOperation` (a change of case only is allowed). `QueueItem.whenDone` lets the UI put the cursor on a new folder or renamed item.
- An error stops the operation (it fails); there is no retry/skip-on-error prompt yet.
- Debug builds have a "Debug" menu with "Add Test Operation" (a 10-second fake operation in `App/Sources/DebugMenu.swift`), used by `QueueUITests`.

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

- UI tests: Xcode sandboxes the test runner, so files it creates are unreadable by Basil. Debug builds launched with `BASIL_UITEST_FIXTURE=1` create the fixture themselves (`App/Sources/UITestFixture.swift`), start both panes in it, and use an isolated preferences domain (`com.erion.basil.uitests`, wiped each launch). Tests must never touch the user's real settings. Pass `UserDefaults` in explicitly; don't use `UserDefaults.standard` in BasilUI.
- The accessibility audit has two documented exceptions in the tests: SwiftUI Picker pop-ups ("Action is missing", a false positive), and disabled controls. Anything else fails the test.
- 200k-item benchmark (skipped unless `BASIL_PERF_DIR` is set): `BASIL_PERF_DIR=/path/to/big swift test -c release --package-path Packages/BasilUI --filter largeDirectory`. Last result: load and sort 0.87 s, re-sort 0.10 s, filter 0.04 s.
- Package unit tests use **Swift Testing** (`import Testing`). App-level UI tests use XCTest/XCUITest.
- `xcodebuild` prints `DVTCoreDeviceCore` / "CoreSimulator is out of date" plug-in errors on this machine. They are Xcode environment noise and do not affect macOS builds.
- `scripts/bootstrap.sh` (building vendored C deps into `Vendor/`) does not exist yet. It is blocked on open questions in `progress.md`. BLAKE3 does not need it: `Vendor/BLAKE3` is a SwiftPM package of C sources (`swift test --package-path Vendor/BLAKE3`).
- SwiftUI `Toggle` and `Stepper` inside a grouped `Form` expose no label on the switch/stepper itself (the text is a separate static text). Always add `.accessibilityLabel` with the same text.
