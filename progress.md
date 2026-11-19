# Progress

## Current state (2026-11-18)

M0 done. M2 in progress: queue, SecureCopyEngine, and now F5 copy, F6 move, Shift+F6 rename, F7 new folder, F8 Trash / Shift+F8 delete as queue operations, with the TC conflict dialog, the changing-source prompt, a "Secure copy and move" setting (off = TC style, default) and customisable sounds and speech per operation and outcome. Item errors now ask Retry / Skip / Skip All / Cancel, and the Multi-Rename tool (Cmd+M) is done. Added on 2026-11-19: Cmd+G go to folder or file with suggestions, Finder Go keys, Cmd+Shift+S folder sizes, Cmd+I Info sheet with default-app change, Shift+F4 new file in the editor of choice, Shift+F6 opens Multi-Rename for several selected items, and a column grid in the Multi-Rename preview. M3 done for local files on 2026-11-19: F3 Quick Look (follows the cursor), F4 with per-pattern editor rules, Cmd+Shift+T open terminal here. Next: the user trying out the speech wording and dialogs with VoiceOver; the dark-mode contrast audit failures (open questions). M1 mostly done: working dual-pane browser (local files) with keyboard commands, selection, sorting, type-ahead, quick filter, live updates, configurable views/columns, settings window, locations menu with bookmarks, and VoiceOver labels. Remaining in M1: user verification with real VoiceOver, and explaining Full Disk Access in the app. `scripts/bootstrap.sh` waits on the vendoring open questions.

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
| 2026-11-18 | Minimal speech: nothing announced on Tab or folder change; Cmd+I reads the status bar (moved to Option+I on 2026-11-19) |
| 2026-11-18 | "Selected" replaces "marked" everywhere; Space says "Selected, 2 items" / "Deselected, 1 item" / "Deselected" |
| 2026-11-18 | Rows read like TC columns ("test, dir, ..."); no "file"/"folder" word added to names |
| 2026-11-18 | Customisable columns: views (Brief, Full, custom) as ordered checkable column lists in Settings, columns can be added; Brief = single Name column |
| 2026-11-18 | Keys: Cmd+F1/F2 locations menu for left/right pane, Cmd+D for current pane, Cmd+I status, Ctrl+F1 Brief, Ctrl+F2 Full, Ctrl+F3+ custom views |
| 2026-11-18 | Locations menu: Home, volumes, bookmarks; setting to go to the volume root instead of the last folder visited there |
| 2026-11-18 | Size column: bytes / KB / MB / GB / dynamic (default dynamic), 1 KB = 1024 by default (setting: 1000) |
| 2026-11-18 | Pane rows keep per-column cells for VoiceOver, but empty cells are not exposed (an empty cell made VoiceOver say "column 2, row 1") |
| 2026-11-18 | After Tab, Up/Down reads the whole row (the cursor row takes VoiceOver focus from the first cursor move); Tab itself still reads the pane name. Rows read without a "table row" suffix |
| 2026-11-18 | The operation queue does not survive app restarts |
| 2026-11-18 | Queue panel: Cmd+J, floating window (panes stay usable); new operations start right away when the queue is idle |
| 2026-11-18 | Queue list keys: Space pause/resume, Cmd+Up/Down move, Delete cancel and remove; same as buttons and VoiceOver actions |
| 2026-11-18 | BLAKE3: official C sources (portable + NEON, tag 1.8.7) vendored unmodified in `Vendor/BLAKE3` as a SwiftPM package; no build script needed |
| 2026-11-18 | Copy chunk size is adaptive by file size, chosen once per file: under 64 MB 1 MB, 64 MB to 1 GB 4 MB, over 1 GB 8 MB; remote providers capped at 1 MB (`maxTransferChunkSize`) |
| 2026-11-18 | Copy conflicts (for F5/F6): Total Commander set: Overwrite, Skip, Overwrite all older, Overwrite all, Skip all, Rename (auto-number), sizes and dates shown, Cancel |
| 2026-11-18 | Read-back verification runs on the partial file before it is renamed into place, so a bad copy never appears under the real name |
| 2026-11-18 | "Accept latest stable snapshot" keeps the last pass's copy; a move then keeps the source. A move re-checks the source fingerprint right before deleting it |
| 2026-11-18 | Settings has a Copying tab: verify copies (off), retries for a changing source (default 3) |
| 2026-11-18 | F2 rereads the pane (replaces Cmd+R) |
| 2026-11-18 | Cmd+W closes the settings window |
| 2026-11-18 | "Secure copy and move" setting, off by default: off = Total Commander style copy (straight to the target, no source-change check); on = secure engine |
| 2026-11-18 | TC-style mode details (decided by Claude, change if wrong): no F_FULLFSYNC, same-volume move still renames, same-volume copy still clones (into a temp name, then renamed over the target), an incomplete target is removed on failure or cancel, overwriting removes the old file first |
| 2026-11-18 | Queue sounds and speech: per operation kind and outcome (finished, failed, cancelled, needs a decision), with "Any operation" defaults and per-kind overrides; sound = none / system sound / any audio file; editable text with placeholders; defaults Glass, Basso, none, Funk, all spoken |
| 2026-11-18 | Speech goes to VoiceOver as an announcement when VoiceOver runs, otherwise to the system voice |
| 2026-11-18 | F8 / Forward Delete moves to the Trash, Shift+F8 / Shift+Forward Delete deletes permanently (TC: recycle bin by default) |
| 2026-11-18 | F5/F6/F7/Shift+F6/F8 dialogs are NSAlert sheets with a text field (rename: sheet, not TC's inline edit; decided by Claude, change if wrong) |
| 2026-11-18 | Speech counts top-level items ("2 items copied"), not every file inside folders |
| 2026-11-18 | Multi-rename starts with the core placeholders ([N], [E], ranges, [C] counter, date/time), search and replace, case; EXIF/ID3 fields later |
| 2026-11-18 | Item errors in copy, move and delete ask Retry / Skip / Skip All / Cancel (TC); the operation still ends "finished" when items were skipped, the log lists them. New folder and rename just fail (one item) |
| 2026-11-18 | Question sheets (conflict, changing source, item error) open with the first button focused, like TC (Retry / Overwrite / Keep Retrying) |
| 2026-11-18 | Multi-rename: own modal window (like TC), Undo button only inside the tool, works on the selected items or the cursor item |
| 2026-11-18 | Cmd+M is Multi-Rename; the Window menu's Minimize has no shortcut (registry chords beat menu items) |
| 2026-11-18 | Multi-rename details (decided by Claude, change if wrong): "Insert" menus append the placeholder at the end of the mask; names are compared without case for conflicts; a colon is allowed in new names; Start is disabled while any row has a problem; "First letter uppercase" lowercases the rest |
| 2026-11-18 | Date column: pattern presets (yyyy-MM-dd, dd.MM.yyyy, MM-dd-yyyy, ...) or custom pattern; time: system / 24-hour / 12-hour / none |
| 2026-11-19 | Cmd+G (and Finder's Cmd+Shift+G) goes to a folder or file: path field with a suggestion list, Tab completes, a file opens its folder with the cursor on it |
| 2026-11-19 | Finder Go keys in the current pane: Cmd+Shift+H/D/O/A/U/I/C, Cmd+Option+L; Cmd+Shift+A is Applications (Finder wins), Deselect All moves to Numpad Minus and Cmd+Shift+Minus |
| 2026-11-19 | Cmd+I is Basil's own Info sheet (with Open with and "Use for All .ext Files" to change the system default app); the status bar is read with Option+I |
| 2026-11-19 | Folder size: Cmd+Shift+S calculates the selected or cursor folders (Space keeps only selecting); the size shows in the Size column until the pane changes folder |
| 2026-11-19 | Shift+F4 new file like TC: name prefilled with the cursor file, existing files just open, editor = chosen app or system default (Settings, Editing tab); F4 waits for M3 |
| 2026-11-19 | Shift+F6 with more than one selected item opens Multi-Rename; Cmd+M stays |
| 2026-11-19 | Multi-Rename preview is a grid with columns Old name, New name, Status, Modified |
| 2026-11-19 | F3 Quick Look shows the selected items (or the cursor item when none are selected) and follows the cursor while open, like Finder |
| 2026-11-19 | Open terminal here: Cmd+Shift+T, Terminal.app by default; Settings picks Terminal, iTerm2, Ghostty, Warp, WezTerm, Kitty, Alacritty or a custom shell command with {dir} |
| 2026-11-19 | F4 editor rules are TC-style pattern lists ("*.txt;*.md") with one or more apps; first match wins, several apps show a menu, no match uses the global editor |
| 2026-11-19 | Decided by Claude, change if wrong: the Quick Look panel takes key focus and passes keys to the pane (Escape and F3 close it); the name of each newly previewed item is announced. F4 on a folder says "is a folder". The Editing settings tab is now "Editor and Terminal". Only installed terminals are offered |
| 2026-11-19 | Main window title is the active pane's folder name, a dash, then the product: "Downloads - Basil". Decided by Claude, change if wrong: at a volume root it shows "/ - Basil" |
| 2026-11-19 | Decided by Claude, change if wrong: Go-to suggestions list prefix matches then substring matches (max 200), hidden items only once something is typed, dot files only after a dot; the count is announced after a 0.7 s pause and only when it changed. Folder size result is spoken as "Alpha, 1.5 MB, 120 files, 8 folders", "Calculating" only after 1 s; symlinks are not followed. New files get rw-r--r--. Files no app opens go to TextEdit. Info shows the cursor item only (not every selected item). Finder's Cmd+Shift+C (Computer) goes to /Volumes |

## Open questions (ask before implementing the related part)

- [ ] Crypto backend for libssh2: OpenSSL 3 or mbedTLS?
- [ ] FTP implementation: system libcurl, or a custom client?
- [ ] Dropbox: official SwiftyDropbox SDK, or direct REST via URLSession?
- [ ] 7-Zip integration: bundled `7zz` CLI (password fed via stdin/pty), or link 7-Zip sources through a C/C++ bridge?
- [ ] UnRAR integration: link the UnRAR library (`dll.hpp` API), or the `unrar` CLI?
- [ ] How should LuaJIT be built and linked (prebuilt static lib/xcframework from `scripts/bootstrap.sh`)?
- [ ] Should there be several queues in parallel (for example one per destination device), or strictly one global queue?
- [ ] Lua plugin sandbox: which APIs plugins can reach (filesystem only through VFS? network? shell?)
- [ ] Themes: should users be able to edit/create colour themes (and import/export them)?

- [ ] Dark mode: the UI-test accessibility audits fail "Contrast" in many tests (also at commit a1850d4, so not new): the path header under a sheet (covered, likely a false positive), queue panel rows, the Multi-Rename Modified column, and SwiftUI picker labels in Settings. Needs a look at which are real (WCAG is a requirement) and which are covered elements. Light mode passed before.
- [x] Fixed 2026-11-19: a watcher refresh right after a navigation could replace the load's rows with the old cursor, so the cursor landed on the first row instead of the requested item (`PaneModel.pendingLoadCursor`).
- [x] Fixed 2026-11-18: panes never watched their start folder, and watcher changes never removed deleted or renamed-away items from a pane.
- [ ] UI tests are timing-flaky in the full suite (2026-11-19: tests now wait for sheet field focus before typing; a full run still shows about one different flake per run, `testQuickFilterAndHiddenToggle` or `testSoundsAndSpeechTab`, each passing alone; typing in other apps during a run also injects keys) (`testQuickFilterAndHiddenToggle` failed once in a full run on 2026-11-18 and passes alone; `testFinishedItemsCanBeRemoved` failed again in a full run on 2026-11-18, test operation stuck at 2 percent; passes alone): `testFinishedItemsCanBeRemoved` and `testColumnsAreConfigurableInSettings` each failed once in a full run and pass when run alone. Once, `app.debugDescription` (full-app snapshot) hung for 10 minutes inside NSTableView's own cell mock elements of a pane table; it did not happen again. Watch for it: it could mean VoiceOver can hang on the panes too.

- [ ] Git scope for the first version: status/commit/pull/push/checkout/branch. Also diff, stash, log, blame?

## Milestones

### M0 - Foundation
- [x] `git init`, `.gitignore`, `project.yml`, app target, package skeletons (Basil* packages)
- [ ] `scripts/bootstrap.sh` for vendored deps (blocked: libssh2 crypto, 7-Zip, UnRAR, LuaJIT build questions). BLAKE3 needs none: vendored as sources in `Vendor/BLAKE3`
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
- [x] Read status bar (Option+I)
- [x] Go to folder or file (Cmd+G) with suggestions; Finder Go keys
- [x] Folder sizes (Cmd+Shift+S); Info sheet (Cmd+I) with default-app change
- [ ] Explain the Full Disk Access permission in the app (currently only an error message in the status line)

### M2 - Operations
- [x] Operation queue (serial, pause/reorder/cancel, per-item log) + queue window (Cmd+J); tested with a Debug-menu test operation until real operations exist
- [x] SecureCopyEngine: rename / clonefile / single-pass chunked copy + delta re-copy; tests for appended, truncated and rewritten sources in each strategy (`WritableProvider` API in BasilVFS, BLAKE3 vendored)
- [x] Optional destination read-back verification setting (Settings, Copying tab; engine option)
- [x] Queue integration of the engine: copy/move queue operation, unstable-source prompt (Keep retrying / Accept / Skip / Cancel) shown from the queue
- [x] Copy (F5), move (F6), delete (F8 Trash, Shift+F8 permanent), mkdir (F7), rename (Shift+F6); TC-style conflict dialog
- [x] "Secure copy and move" setting (off = TC style)
- [x] Sounds and speech for operation events (Settings, Sounds and Speech tab)
- [x] Retry / Skip / Skip All / Cancel prompt when an item of a copy, move or delete fails
- [ ] Verified by the user with VoiceOver: dialogs, speech wording
- [x] Multi-rename tool (masks, counter, search/replace + regex, case, preview, presets, undo, cycle-safe batch op); core placeholders, EXIF/ID3 later

### M3 - View/Edit/Terminal
- [x] Shift+F4 new file in the editor (chosen app or system default)
- [x] F3 Quick Look (selected or cursor items, follows the cursor)
- [x] F4 editor associations (global / per-pattern rules / popup menu)
- [x] Open terminal here (Cmd+Shift+T, configurable terminals and custom command)
- [ ] F4 for files in archives or on remotes (temp copy, repack/upload prompt; needs M4/M5)

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
