# Progress

Status legend: ☐ not started · ◐ in progress · ☑ done

## Current state (2026-11-18)

M0 skeleton done: git repo, XcodeGen project, 11 module packages, app showing an empty dual-pane window, UI accessibility-audit test passing. Next: M1 (core browsing). `scripts/bootstrap.sh` waits on the vendoring open questions.

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
| 2026-11-18 | Keybindings: TC defaults, Mac-adapted (F-keys as TC; Ctrl/Alt → Cmd/Option where natural; Space selects; all remappable) |
| 2026-11-18 | Quick filter: Cmd+S pops up an edit field for the filter (live filtering); typing directly in the pane jumps to matching names instead, `;`-separated patterns + `\|` exclusions, optional regex mode, cleared on directory change |
| 2026-11-18 | TC-style colour scheme with light and dark variants (follows system appearance) |
| 2026-11-18 | Commit to git whenever a feature is done |

## Open questions (ask before implementing the related part)

- [ ] Copy chunk size: fixed 1 MB, or adaptive by file size and volume type?

- [ ] Multi-rename: should the first version include all of Total Commander's placeholders (incl. EXIF/ID3 metadata fields), or start with the core set?
- [ ] Crypto backend for libssh2: OpenSSL 3 or mbedTLS?
- [ ] FTP implementation: system libcurl, or a custom client?
- [ ] Dropbox: official SwiftyDropbox SDK, or direct REST via URLSession?
- [ ] 7-Zip integration: bundled `7zz` CLI (password fed via stdin/pty), or link 7-Zip sources through a C/C++ bridge?
- [ ] UnRAR integration: link the UnRAR library (`dll.hpp` API), or the `unrar` CLI?
- [ ] How should LuaJIT be built and linked (prebuilt static lib/xcframework from `scripts/bootstrap.sh`)?
- [ ] Should the operation queue persist across app restarts, and resume or ask?
- [ ] Should there be several queues in parallel (for example one per destination device), or strictly one global queue?
- [ ] Lua plugin sandbox: which APIs plugins can reach (filesystem only through VFS? network? shell?)
- [ ] Sound effects: which operations play sounds, which sound files are bundled, and per-event configuration?
- [ ] Themes: should users be able to edit/create colour themes (and import/export them)?

- [ ] Git scope for the first version: status/commit/pull/push/checkout/branch. Also diff, stash, log, blame?

## Milestones

### M0 — Foundation
- [x] `git init`, `.gitignore`, `project.yml`, app target, package skeletons (Basil* packages)
- [ ] `scripts/bootstrap.sh` for vendored deps (blocked: libssh2 crypto, 7-Zip, UnRAR, LuaJIT build questions)
- [x] Signing with stable local identity `dev` (Config/Base.xcconfig)
- [ ] Document / prompt for the Full Disk Access flow in-app
- [x] Local build + test commands working (in CLAUDE.md)

### M1 — Core browsing
- [ ] BasilCore models, VFSPath, ProviderRegistry, LocalProvider
- [ ] Dual-pane AppKit UI, streamed listing, sorting, FSEvents diffs (benchmark with 200k+ entries)
- [ ] Full VoiceOver support for panes + accessibility audit UI test
- [ ] Keyboard model, CommandRegistry, keybindings
- [ ] Quick filter for the current pane (wildcard / substring, announced match count)

### M2 — Operations
- [ ] Operation queue (serial, pause/reorder/cancel, per-item log) + queue window
- [ ] SecureCopyEngine: rename / clonefile / single-pass chunked copy + delta re-copy; tests for appended, truncated and rewritten sources in each strategy
- [ ] Optional destination read-back verification setting
- [ ] Copy, move, delete, mkdir, rename; conflict dialogs
- [ ] Sound effects for operation events
- [ ] Multi-rename tool (masks, counter, search/replace + regex, case, preview grid, presets, undo, cycle-safe batch op)

### M3 — View/Edit/Terminal
- [ ] F3 Quick Look
- [ ] F4 editor associations (global / per-extension / popup)
- [ ] Open terminal here (configurable terminals)

### M4 — Archives
- [ ] ArchiveBackend protocol + libarchive backend; browse archives as directories
- [ ] 7-Zip backend (create with options: solid, level, AES, header encryption)
- [ ] UnRAR backend; password prompts + Keychain
- [ ] Test archive; edit-in-archive → repack prompt

### M5 — Remote
- [ ] SFTP (libssh2) — password, keys, agent, known_hosts
- [ ] FTP/FTPS
- [ ] Dropbox
- [ ] WebDAV, SMB, S3-compatible, Google Drive, OneDrive

### M6 — Git
- [ ] GitService (CLI), status column/badges, commit/pull/push/checkout/branch UI

### M7 — Plugins
- [ ] LuaJIT bridge, plugin manifest + loader, API for commands/columns/providers
- [ ] Example plugins

### M8 — Search
- [ ] Search protocol + live directory-walk engine
- [ ] Spotlight engine (NSMetadataQuery)
- [ ] Own index: initial scan (searchfs/getattrlistbulk), custom binary store, FSEvents event-ID replay, instant matcher
- [ ] Search UI (results as a virtual pane, fully accessible)

### M9 — Sync (later)
- [ ] Directory compare (date with tolerance / size / BLAKE3 content, optional subdirs)
- [ ] Results view: per-file arrows you can change, category filters, asymmetric mode
- [ ] Run as queue operations through the secure copy engine
