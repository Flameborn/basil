# Progress

## Current state (2026-11-18)

M0 done. M2 started: the operation queue and its panel are done; real operations (copy engine etc.) are next. M1 mostly done: working dual-pane browser (local files) with keyboard commands, selection, sorting, type-ahead, quick filter, live updates, configurable views/columns, settings window, locations menu with bookmarks, and VoiceOver labels. Remaining in M1: user verification with real VoiceOver, and explaining Full Disk Access in the app. `scripts/bootstrap.sh` waits on the vendoring open questions.

## Decisions log

| Date | Decision |
|---|---|
| 2026-11-18 | Swift 6, Xcode 27, macOS 27 minimum |
| 2026-11-18 | AppKit for panes and main window, SwiftUI for dialogs and settings (needed for 100k+ items and fine VoiceOver control) |
| 2026-11-18 | XcodeGen + local SPM packages per module |
| 2026-11-18 | Personal use: not sandboxed, stable local signing identity (not ad hoc, so the Full Disk Access grant survives rebuilds) |
| 2026-11-18 | Archives: libarchive + 7-Zip (`7zz`) + UnRAR behind one `ArchiveBackend` protocol |
| 2026-11-18 | SSH/SFTP: libssh2 |
| 2026-11-18 | Git: system `git` CLI |
| 2026-11-18 | Plugins: LuaJIT |
| 2026-11-18 | Unstable copy source: retry N times (default 3), then pause and ask the user |
| 2026-11-18 | Remotes: SFTP, FTP/FTPS, Dropbox first, then WebDAV, SMB, S3-compatible, Google Drive, OneDrive |
| 2026-11-18 | App name **Basil**, bundle ID `com.erion.basil` |
| 2026-11-18 | Secure copy redesigned for speed: same-volume move = `rename()`, same-APFS copy = `clonefile()`, cross-volume = single pass with per-chunk hashing + fingerprint recheck, delta re-copy only when the source changed (replaces the read-source-twice design) |
| 2026-11-18 | Destination read-back verification off by default for copy and move (setting) |
| 2026-11-18 | Search: Spotlight + own Everything-style index in a custom binary format, kept current via FSEvents event-ID replay |
| 2026-11-18 | Sync works like Total Commander's "Synchronize directories": stateless compare (date/size/content), arrows you can change per file, asymmetric mode, copies through the secure copy engine; librsync not used |
| 2026-11-18 | Chunk hash: BLAKE3 (no known collisions, SIMD-fast, pipelined so it adds no wait) |
| 2026-11-18 | Search index: local boot volume by default, other volumes added later; stores name, size, dates, attributes |
| 2026-11-18 | New feature: quick filter in the current pane (wildcards / substring) |
| 2026-11-18 | New feature: multi-rename like Total Commander's Multi-Rename Tool |
| 2026-11-18 | Modules are local packages named `Basil<Module>`; package tests use Swift Testing, UI tests use XCUITest; signing identity `dev` |
| 2026-11-18 | Visual style: Total Commander-like (flat dense grid, custom colour scheme, drive/button bar, function-key bar at bottom) |
| 2026-11-18 | Keybindings: TC defaults, Mac-adapted (F-keys as TC; Ctrl/Alt -> Cmd/Option where natural; Space selects; all remappable) |
| 2026-11-18 | Quick filter: Cmd+S pops up an edit field for the filter (live filtering); typing directly in the pane jumps to matching names instead, `;`-separated patterns + `\|` exclusions, optional regex mode, cleared on directory change |
| 2026-11-18 | TC-style colour scheme with light and dark variants (follows system appearance) |
| 2026-11-18 | Commit to git whenever a feature is done |
| 2026-11-18 | No emojis, symbol glyphs or decorative Unicode anywhere (UI, VoiceOver text, docs, comments) |
| 2026-11-18 | No ".." row in panes; Backspace / Cmd+Up go to the parent |
| 2026-11-18 | Pane lists are announced only as "Left pane" / "Right pane" (no folder name in the label) |
| 2026-11-18 | Minimal speech: nothing announced on Tab or folder change; Cmd+I reads the status bar |
| 2026-11-18 | "Selected" replaces "marked" everywhere; Space says "Selected, 2 items" / "Deselected, 1 item" / "Deselected" |
| 2026-11-18 | Rows read like TC columns ("test, dir, ..."); no "file"/"folder" word added to names |
| 2026-11-18 | Customisable columns: views (Brief, Full, custom) as ordered checkable column lists in Settings, columns can be added; Brief = single Name column |
| 2026-11-18 | Keys: Cmd+F1/F2 locations menu for left/right pane, Cmd+D for current pane, Cmd+I status, Ctrl+F1 Brief, Ctrl+F2 Full, Ctrl+F3+ custom views |
| 2026-11-18 | Locations menu: Home, volumes, bookmarks; setting to go to the volume root instead of the last folder visited there |
| 2026-11-18 | Size column: bytes / KB / MB / GB / dynamic (default dynamic), 1 KB = 1024 by default (setting: 1000) |
| 2026-11-18 | Pane rows are read as one element ("name, ext, size, date, attributes"); no cell position ("column 2, row 1") is spoken |
| 2026-11-18 | The operation queue does not survive app restarts |
| 2026-11-18 | Queue panel: Cmd+J, floating window (panes stay usable); new operations start right away when the queue is idle |
| 2026-11-18 | Queue list keys: Space pause/resume, Cmd+Up/Down move, Delete cancel and remove; same as buttons and VoiceOver actions |
| 2026-11-18 | Date column: pattern presets (yyyy-MM-dd, dd.MM.yyyy, MM-dd-yyyy, ...) or custom pattern; time: system / 24-hour / 12-hour / none |

## Open questions (ask before implementing the related part)

- [ ] Copy chunk size: fixed 1 MB, or adaptive by file size and volume type?

- [ ] Multi-rename: should the first version include all of Total Commander's placeholders (incl. EXIF/ID3 metadata fields), or start with the core set?
- [ ] Crypto backend for libssh2: OpenSSL 3 or mbedTLS?
- [ ] FTP implementation: system libcurl, or a custom client?
- [ ] Dropbox: official SwiftyDropbox SDK, or direct REST via URLSession?
- [ ] 7-Zip integration: bundled `7zz` CLI (password fed via stdin/pty), or link 7-Zip sources through a C/C++ bridge?
- [ ] UnRAR integration: link the UnRAR library (`dll.hpp` API), or the `unrar` CLI?
- [ ] How should LuaJIT be built and linked (prebuilt static lib/xcframework from `scripts/bootstrap.sh`)?
- [ ] Should there be several queues in parallel (for example one per destination device), or strictly one global queue?
- [ ] Lua plugin sandbox: which APIs plugins can reach (filesystem only through VFS? network? shell?)
- [ ] Sound effects: which operations play sounds, which sound files are bundled, and per-event configuration?
- [ ] Themes: should users be able to edit/create colour themes (and import/export them)?

- [ ] Git scope for the first version: status/commit/pull/push/checkout/branch. Also diff, stash, log, blame?

## Milestones

### M0 - Foundation
- [x] `git init`, `.gitignore`, `project.yml`, app target, package skeletons (Basil* packages)
- [ ] `scripts/bootstrap.sh` for vendored deps (blocked: libssh2 crypto, 7-Zip, UnRAR, LuaJIT build questions)
- [x] Signing with stable local identity `dev` (Config/Base.xcconfig)
- [ ] Document / prompt for the Full Disk Access flow in-app
- [x] Local build + test commands working (in CLAUDE.md)

### M1 - Core browsing
- [x] BasilCore models (VFSPath, FileItem, capabilities), ProviderRegistry, LocalProvider (getattrlistbulk streaming), FSEvents DirectoryWatcher
- [x] Dual-pane AppKit UI (TC-style theme, drive bar, path header, status line, function-key bar), sorting, FSEvents diffs; 200k items: load+sort 0.87 s, filter 0.04 s
- [x] VoiceOver basics for panes (labelled lists, spoken cell labels, announcements) + accessibility audit UI test
- [ ] VoiceOver verified by the user with real VoiceOver (speech wording, row reading, focus)
- [x] Keyboard model, CommandRegistry, keybindings, type-ahead
- [x] Quick filter (Cmd+S): wildcards, substring, `;` patterns, `|` exclusions, regex, cleared on directory change
- [x] Settings window (Cmd+,): views and columns, size and date formats, navigation, bookmarks
- [x] Brief / Full / custom views with configurable columns (incl. Created, Kind)
- [x] Locations menu (Cmd+D, Cmd+F1, Cmd+F2) with volumes and bookmarks; per-volume last folder
- [x] Read status bar (Cmd+I)
- [ ] Explain the Full Disk Access permission in the app (currently only an error message in the status line)

### M2 - Operations
- [x] Operation queue (serial, pause/reorder/cancel, per-item log) + queue window (Cmd+J); tested with a Debug-menu test operation until real operations exist
- [ ] SecureCopyEngine: rename / clonefile / single-pass chunked copy + delta re-copy; tests for appended, truncated and rewritten sources in each strategy
- [ ] Optional destination read-back verification setting
- [ ] Copy, move, delete, mkdir, rename; conflict dialogs
- [ ] Sound effects for operation events
- [ ] Multi-rename tool (masks, counter, search/replace + regex, case, preview grid, presets, undo, cycle-safe batch op)

### M3 - View/Edit/Terminal
- [ ] F3 Quick Look
- [ ] F4 editor associations (global / per-extension / popup)
- [ ] Open terminal here (configurable terminals)

### M4 - Archives
- [ ] ArchiveBackend protocol + libarchive backend; browse archives as directories
- [ ] 7-Zip backend (create with options: solid, level, AES, header encryption)
- [ ] UnRAR backend; password prompts + Keychain
- [ ] Test archive; edit-in-archive -> repack prompt

### M5 - Remote
- [ ] SFTP (libssh2) - password, keys, agent, known_hosts
- [ ] FTP/FTPS
- [ ] Dropbox
- [ ] WebDAV, SMB, S3-compatible, Google Drive, OneDrive

### M6 - Git
- [ ] GitService (CLI), status column/badges, commit/pull/push/checkout/branch UI

### M7 - Plugins
- [ ] LuaJIT bridge, plugin manifest + loader, API for commands/columns/providers
- [ ] Example plugins

### M8 - Search
- [ ] Search protocol + live directory-walk engine
- [ ] Spotlight engine (NSMetadataQuery)
- [ ] Own index: initial scan (searchfs/getattrlistbulk), custom binary store, FSEvents event-ID replay, instant matcher
- [ ] Search UI (results as a virtual pane, fully accessible)

### M9 - Sync (later)
- [ ] Directory compare (date with tolerance / size / BLAKE3 content, optional subdirs)
- [ ] Results view: per-file arrows you can change, category filters, asymmetric mode
- [ ] Run as queue operations through the secure copy engine
