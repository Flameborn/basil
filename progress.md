# Progress

## Current state (2026-11-22)

All eight features requested on 2026-11-22 are done: TC-style menus (Files, Mark, Commands, Net, Show, Tabs) built from the command registry, TC numpad selection keys, one Name column with the extension, views and sorting on Ctrl+Shift+F keys, checksum files (create and verify, eleven algorithms), test archive after packing, a path bar with a button per folder (Cmd+L), and folder tabs per pane. M4 started on 2026-11-22: libarchive 3.8.11 (with zstd, lz4 and liblzma) is built from vendored sources in `Vendor/libarchive`; archives open as folders (Enter, or Cmd+PageDown for any file by content), F5 extracts through the copy engine, Option+Shift+F9 tests archives in the queue. Also on 2026-11-22: writing archives. Option+F5 packs (zip, tar family, single gz/xz/zst, cpio, xar, iso), F5/F6 into an archive pane, F6 out of it, F7, F8 and Shift+F6 inside it rewrite the archive safely; macOS metadata is stored and restored. 7z archives are read (browsed, extracted, tested) through a 7zz built from vendored 7-Zip 26.06 sources and bundled in the app. Archive passwords work for 7z (also with encrypted names) and zip (ZipCrypto and AES): a prompt with "Remember in Keychain", checked before any data is extracted. 7z archives are also written (Option+F5 with solid, levels up to Ultra, AES-256 password, encrypted names; encrypted zip is AES-256 through 7zz) and changed in place like zip (F5/F6 into, F7, F8, Shift+F6 inside, also encrypted ones). RAR archives (RAR 1.5 to 7: solid, multi-volume, encrypted data and names, links) are read through the UnRAR 7.2.7 library built from vendored sources: browsed, extracted, tested, with the same password prompt; they are read-only. The Commands > Go To menu no longer lists First Item and Last Item (Home, End). F3 and F4 work on files inside archives (temporary copies; F4 asks on return to Basil whether to put the changed copy back). A TC-style progress window (Background, Pause, Cancel) follows the running queue item. Deleting an app offers to remove its leftovers, ForkLift style. Also on 2026-11-22: file lists (.lst) like TC's DiskDir (an optimised binary and a text format, DiskDir lists read too; browsed like folders, sizes calculate, nothing else works in them), Split File and Combine Files (presets and typed sizes, SFV with part and whole-file CRC32, checked combine), and Unpack (Option+F9) with a smart own-folder option, a mask, flat unpacking and delete-after. Unused archives are closed again (their memory and temporary copies freed). Next: M5 remotes (blocked on the libssh2 crypto question). M0 done. M2 in progress: queue, SecureCopyEngine, and now F5 copy, F6 move, Shift+F6 rename, F7 new folder, F8 Trash / Shift+F8 delete as queue operations, with the TC conflict dialog, the changing-source prompt, a "Secure copy and move" setting (off = TC style, default) and customisable sounds and speech per operation and outcome. Item errors now ask Retry / Skip / Skip All / Cancel, and the Multi-Rename tool (Cmd+M) is done. Added on 2026-11-19: Cmd+G go to folder or file with suggestions, Finder Go keys, Cmd+Shift+S folder sizes, Cmd+I Info sheet with default-app change, Shift+F4 new file in the editor of choice, Shift+F6 opens Multi-Rename for several selected items, and a column grid in the Multi-Rename preview. M3 done for local files on 2026-11-19: F3 Quick Look (follows the cursor), F4 with per-pattern editor rules, Cmd+Shift+T open terminal here. Next: the user trying out the speech wording and dialogs with VoiceOver; the dark-mode contrast audit failures (open questions). M1 mostly done: working dual-pane browser (local files) with keyboard commands, selection, sorting, type-ahead, quick filter, live updates, configurable views/columns, settings window, locations menu with bookmarks, and VoiceOver labels. Remaining in M1: user verification with real VoiceOver, and explaining Full Disk Access in the app. `scripts/bootstrap.sh` waits on the vendoring open questions.

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
| 2026-11-19 | Contrast fixes, decided by Claude, change if wrong: secondary text in dialogs, settings and the queue uses a theme token (AppKit `Theme.secondaryText`, SwiftUI `Theme.secondaryTextColor` = primary at 75 percent) instead of the system secondary colour, which is about 3.5:1 in light mode. Multi-Rename problem text uses `Theme.errorText` instead of system red. The queue progress bar is a themed outline-and-fill bar below the row's text element. The Multi-Rename preview columns share the window width. The View and Operation pickers in Settings have a separate visible label |
| 2026-11-22 | Next milestone after M3: M4 Archives |
| 2026-11-22 | libarchive is built from source: vendored in `Vendor/libarchive` as a SwiftPM package with zstd 1.5.7, lz4 1.11.1 and xz/liblzma 5.8.4 (macOS has no headers for these); zlib, bzip2, iconv, libxml2 and CommonCrypto come from the SDK |
| 2026-11-22 | Git first version: status, commit, pull, push, checkout, branch, plus log and blame |
| 2026-11-22 | Enter on an archive enters it as a folder (TC); Backspace at its root goes back with the cursor on the archive. Cmd+PageDown (TC Ctrl+PageDown) enters any file whose content is a readable archive (docx, jar, apk) |
| 2026-11-22 | libarchive does not open 7z or RAR: they wait for the 7-Zip and UnRAR backends |
| 2026-11-22 | Encrypted archive entries: no password prompt yet; reading one fails with "is encrypted. Encrypted archives are not supported yet." |
| 2026-11-22 | Decided by Claude, change if wrong: Enter recognises zip, tar and tar.gz/bz2/xz/zst/lz4/lzma/Z (and tgz, tbz, txz, tzst, tlz, taz), single gz/bz2/xz/zst/lz4/lzma/Z files (one entry, the name without the suffix), cpio, iso, xar, cab, lha/lzh; zip-based formats (docx, jar, apk, odt) only with Cmd+PageDown. Archives are read-only for now: F5 out of them works, F6 (move out), F7, F8, Shift+F6, Shift+F4, Cmd+M inside say "pack.zip is read-only. Changing archives is not supported yet." Test archives: Option+Shift+F9 (TC Alt+Shift+F9), a queue operation of its own kind "Test Archive" (fails when problems are found, the log lists them). An archive inside an archive is copied to a temporary file first. Archives are not watched; a changed archive file is indexed again when it is listed (F2). A pane inside an archive is remembered at quit as the folder holding the archive. An absolute path typed in the F5 dialog while inside an archive means a local folder. Names without a charset flag are read as UTF-8 |
| 2026-11-22 | Pack dialog (Option+F5): archive name, format, compression level, "Store folder paths", "One archive per item", "Move to archive" |
| 2026-11-22 | Changing an existing archive writes the whole new archive next to it as .basil-partial-*, F_FULLFSYNCs it, reads it back and checks it, then renames it over the old one |
| 2026-11-22 | macOS metadata (extended attributes, Finder tags, resource forks) in zip and tar archives: Settings, Copying tab, "Store macOS metadata in archives", on by default; zip stores it like Finder (__MACOSX/._name), tar as ._name |
| 2026-11-22 | libarchive writes zip, tar, tar.gz, tar.xz, tar.zst, tar.bz2, tar.lz4, single gz/xz/zst, cpio, xar and ISO 9660 |
| 2026-11-22 | Decided by Claude, change if wrong: the pack dialog starts with the format and level used last (zip, Normal at first) and the other pane's folder (the active one if the other is not local); the name is the item's name without extension, or the current folder's name for several items; changing the format changes the extension. Levels are Store (zip only), Fast, Normal, Maximum, mapped per format (deflate 1/6/9, gzip and bzip2 1/6/9, xz 1/6/9, zstd 1/3/19, lz4 1/3/9). Packing into an archive that exists adds to it (TC) and asks the conflict question per file. A source that changes while it is packed is packed again (the copy retry count), then asks Keep Retrying / Accept / Skip / Cancel; Skip is treated like Accept, and accepted sources are not deleted by "Move to archive". Without folder paths, a second file with a name already used is left out (logged). Restoring metadata on extraction comes from the AppleDouble data libarchive reads (__MACOSX and ._ entries are not listed). The security attributes com.apple.quarantine, provenance and macl are not packed. Shift+F4 and Cmd+M still do not work inside archives. Archives inside archives and single compressed files cannot be changed. F8 inside an archive asks "Delete X from pack.zip?" and deletes (no Trash) |
| 2026-11-22 | New features before the rest of M4, in this order: TC-style menus, TC numpad keys, one Name column, Ctrl+Shift+F views and sorting, checksums, test after packing, path bar, pane tabs (details in CLAUDE.md, "Planned features") |
| 2026-11-22 | Menus: TC top-level names adapted to the Mac (Basil, Files, Mark, Commands, Net, Show, Tabs, Window, Help) with Extended Menus-style submenus, built from the command registry |
| 2026-11-22 | Option+F keys are actions (pack, test); Ctrl+Shift+F keys are views and sorting (F1 Brief, F2 Full, F3-F7 sort name/ext/date/size/unsorted, F8-F12 custom views 1-5); Cmd+F3-F6 and Ctrl+F1-F11 removed |
| 2026-11-22 | Numpad: full TC set (Num+ / Num- group dialogs, Num* invert, Num/ restore, Cmd+Num+/- all, Option+Num+/- same extension) |
| 2026-11-22 | Name column shows name and extension; Ext optional, in no built-in view |
| 2026-11-22 | Checksums: CRC32 (.sfv), MD5, SHA-1, SHA-256/384/512, SHA3-256/512, BLAKE3, XXH3, XXH128 (xxHash vendored); no Meow hash |
| 2026-11-22 | Path bar: one button per path part; Cmd+L focuses it, Left/Right move, Return/Space go, Escape/Tab back to the list |
| 2026-11-22 | Pane tabs: Cmd+T, Cmd+W (not the last tab), Ctrl+Tab / Ctrl+Shift+Tab, Cmd+1-9, Cmd+Option+Up opens the cursor folder in a new tab; duplicate, close others, rename, lock; restored at launch; "Tab 2 of 3, Downloads" spoken |
| 2026-11-22 | Decided by Claude, change if wrong: menu items show keys but never take them (keys stay with the panes and registry); a standard Edit menu for text fields was added (it was missing, so paste did not work in dialogs); the Help menu holds only macOS's menu search; Unpack, checksum, group-select and tab items appear once those commands exist; Hide Others and Show All added to the Basil menu; "Show or Hide Hidden Files" is now "Show Hidden Files" with a checkmark |
| 2026-11-22 | Decided by Claude, change if wrong: Select Group starts with the last mask (or "*"), folders only with "Include folders" (off); invert leaves selected folders selected; restore works by name; Option+Num+/- on a folder says "No file"; saved Full views lose their Ext column once (shown again by the user, it stays); the accessibility audit now skips "Label not human-readable" on list cells showing a file name with an extension (a false positive: VoiceOver reads file names fine) |
| 2026-11-22 | Decided by Claude, change if wrong: Unsorted keeps folders first (like every other order) and has no reverse; choosing it rereads the folder to get the listing order back |
| 2026-11-22 | xxHash 0.8.4 vendored unmodified in `Vendor/xxHash` (BSD 2-Clause library only, not the GPL CLI) |
| 2026-11-22 | Decided by Claude, change if wrong: checksum lines use the sha256sum/b3sum two-space format (so command-line tools can check them); XXH3 lines use xxhsum's XXH3_ prefix; SHA3 files are .sha3-256/.sha3-512; the create dialog starts with SHA-256, then the last algorithm used; per-file checksum files replace existing ones without asking, a single file asks; symlinks to files are hashed, other non-files skipped and logged; unreadable files are left out and fail the item; Create and Verify have no default keys and are not allowed inside archives (Create) |
| 2026-11-22 | Decided by Claude, change if wrong: path bar parts start with the volume name (Macintosh HD, or a /Volumes volume); separators are drawn slashes; going to a part puts the cursor on the folder that leads back and focus on the list; the current folder's part rereads; "Go to Path Bar" is in the Commands menu |
| 2026-11-22 | Decided by Claude, change if wrong: the tab row appears only with two or more tabs; new tabs open right after the current one; "New Tab" is the current folder, "Duplicate Tab" also keeps the custom name and lock; a locked tab shows "(locked)" after its name; each tab keeps its own sort and view; Cmd+W on the only tab says "This is the only tab"; closing a tab switches to the one after it |
| 2026-11-22 | 7-Zip: the 7zz command-line tool built from vendored 7-Zip 26.06 sources (`Vendor/7zip`), bundled in the app and run as a subprocess; passwords go to it through standard input, never argv |
| 2026-11-22 | UnRAR: the official UnRAR library source (`dll.hpp` API) linked through a small C target; passwords through its callback |
| 2026-11-22 | Archive passwords: the prompt has "Remember in Keychain" (off by default); saved passwords are found by the archive's path; unsaved ones stay in memory while the archive is open |
| 2026-11-22 | Decided by Claude, change if wrong: 7zz gets the password through a plain stdin pipe rather than a pty (it reads one line from stdin and does not need a terminal; a pipe is just as invisible to other processes). 7zz is built for arm64 only (macOS 27 runs on Apple silicon only). The 7-Zip backend opens only 7z archives for now (zip, tar and the rest stay with libarchive, also with Cmd+PageDown); formats only 7-Zip reads (dmg, wim, vhd and others) could be added later |
| 2026-11-22 | Pack dialog for 7z: Solid archive (on), password (AES-256), Encrypt file names (only with a password), and an Ultra level after Maximum. The password is typed once, with a Show password checkbox. Encrypted zip is AES-256 only (written by 7zz). Packing with a password offers "Remember in Keychain" (off) |
| 2026-11-22 | Decided by Claude, change if wrong: 7z levels map to 7-Zip's -mx 0 (Store), 1 (Fast), 5 (Normal), 7 (Maximum), 9 (Ultra); 7z is listed second in the format pop-up, after zip; "Encrypt file names" is off at first and remembered, "Solid archive" on and remembered; the password itself is never saved in settings; after packing, the password is kept in memory for the session (Keychain only with the box ticked), so the new archive opens and tests without asking. Adding to an encrypted 7z encrypts the new files with the archive's password (and the names when they were encrypted). Zip files libarchive cannot read are opened by 7-Zip. Packing into 7z stores no macOS metadata (7-Zip has no place for it on macOS) |
| 2026-11-22 | Decided by Claude, change if wrong: the password prompt is a sheet "Password for secret.7z:" with a secure field and "Remember in Keychain"; a wrong password asks again with "Wrong password for secret.7z. Try again." until it works or Cancel; a password is checked on the smallest possible part of the archive before anything is extracted; a saved Keychain password is tried first without asking; Cancel fails that read ("No password was given for secret.7z.") and the next read asks again (so Retry in the error dialog asks again, Skip All skips the rest); encrypted archives cannot be changed yet |
| 2026-11-22 | Home and End (first and last item) are not in the menus: VoiceOver reads a menu item's title when its key is pressed, which repeats what the cursor move already says |
| 2026-11-22 | Decided by Claude, change if wrong: RAR is read-only (UnRAR cannot write RAR); a change inside a RAR archive says "old.rar is a RAR archive, which Basil can only read." Opening a later volume (name.part3.rar, name.r00) opens the whole set from its first volume when that is next to it; a missing volume fails the open or test with "The next volume X is missing". One password per archive, like 7z and zip: a file with its own different password fails its read ("wrong password") instead of asking again. Testing without a password lists encrypted files as "encrypted, not tested". Dictionaries over 4 GB (RAR 7) are refused instead of allocating the memory. UnRAR's global error state is made per thread by a build define, without changing its sources (`Vendor/unrar/VERSION`) |
| 2026-11-22 | Decided by Claude, change if wrong: "Test archive after packing" is off by default and remembered like the format; the test is a separate Test Archive queue item added when packing finished (not after a failed or cancelled pack) |
| 2026-11-22 | F4 on a file inside an archive edits a temporary copy; when Basil becomes active again and the copy changed, it asks once (Update / Not Now / Stop Watching); "Not Now" asks again only after a further save. F3 inside archives extracts each file when the preview reaches it and keeps the copy while a pane shows the archive. Copies live in ~/Library/Caches/Basil/Copies and are removed at launch and at quit |
| 2026-11-22 | Decided by Claude, change if wrong: F4 in an archive Basil cannot change (RAR, encrypted zip) still opens a copy and says the changes stay in it; quitting with edited copies not yet put back asks "Don't Quit" / "Quit Anyway" (Don't Quit then offers the updates); putting a copy back is a Pack queue item "Update notes.txt in archive.zip" |
| 2026-11-22 | Progress window like TC (requested): shown right away for a running operation, takes keyboard and VoiceOver focus, buttons Background, Pause, Cancel; one window that follows the running item ("2 more waiting"); an item sent to the background stays hidden, the next item shows the window again |
| 2026-11-22 | Decided by Claude, change if wrong: the progress window opens at once for copy, move, delete, Trash, pack (and archive updates), test archive, checksums and plugin/other operations; new folder, rename (also multi-rename) and new file show it only when still running after 1 s, so instant ones never take focus. Return is Background (the default button), Escape is Cancel (like TC); the close button is Background; the queue key (Cmd+J) in it sends it to the background and opens the queue; it is not shown while the queue panel is open; after a conflict or error prompt on the main window it takes focus again. A setting "Show a progress window for operations" (Copying tab, on) turns it off; UI tests turn it off except `ProgressUITests` |
| 2026-11-22 | App cleanup like ForkLift (requested): after F8 / Shift+F8 of an .app, Basil searches its leftovers in user and system places (also /var/folders and installer receipts) and shows a checklist with everything checked; Space toggles, Return removes the checked items the way the app went (Trash or permanently) as one queue item. Also Files > Delete > Find App Leftovers (cursor app, or a name or bundle ID for an app that is already gone) |
| 2026-11-22 | Decided by Claude, change if wrong: leftovers match strictly because everything starts checked: a name equal to a bundle ID or starting with one plus a dot; helper IDs only when they start with the app's ID (a bundled Sparkle-style updater has a shared ID); app names (whole, any case) only in Application Support, Caches and Logs, labelled "found by name"; crash reports by the app's executable and helpers named after it; launchd plists by label or a program inside the app; group containers from the code signature's app groups, but one another installed app also uses (scanned in /Applications, /System/Applications, ~/Applications) starts unchecked with "also used by Excel". Nothing is offered while another copy of the app is installed. Items that need an administrator are removed after one macOS password prompt (osascript "with administrator privileges"; in Trash mode moved into ~/.Trash and given to the user). The checkbox speaks "name, in Caches" instead of the whole path. Check All / Uncheck All buttons |
| 2026-11-19 | Decided by Claude, change if wrong: Go-to suggestions list prefix matches then substring matches (max 200), hidden items only once something is typed, dot files only after a dot; the count is announced after a 0.7 s pause and only when it changed. Folder size result is spoken as "Alpha, 1.5 MB, 120 files, 8 folders", "Calculating" only after 1 s; symlinks are not followed. New files get rw-r--r--. Files no app opens go to TextEdit. Info shows the cursor item only (not every selected item). Finder's Cmd+Shift+C (Computer) goes to /Volumes |
| 2026-11-22 | File lists (.lst, requested): Basil's own text format (UTF-8, forward slashes, full timestamps, folder dates) plus DiskDir lists read; created from the pack dialog (Option+F5) as a format; delete, copy, move, edit and view in a list are refused, folder sizes work |
| 2026-11-22 | Optimised file list (requested): a binary .lst format next to the text one, both in the pack dialog's format pop-up, told apart by content |
| 2026-11-22 | Decided by Claude, change if wrong: the optimised (binary) list is listed first; DiskDir is only tried for files named .lst (it has no header); "Move to archive" is hidden for lists; a list made of selected items records their folder as its root; an existing .lst is not added to (Option+F5 onto it says it cannot be changed) |
| 2026-11-22 | Split and combine (requested): Files > Split submenu; Create SFV option; size presets (CD, DVD, ...) and custom sizes typed like "512 MB" with a separate Units pop-up (binary 1024 / decimal 1000); the SFV lists each part's CRC32 and, in comments, the original's name, size and CRC32; Combine checks parts and result |
| 2026-11-22 | Decided by Claude, change if wrong: parts are named name.ext.001 (7-Zip/HJSplit style, keeps the name; TC uses name.001 and its .crc is read too); presets CD 650/700/800 MB, DVD 4.7 GB, DVD DL 8.5 GB, Blu-ray 25 and 50 GB, FAT32 largest file, Custom (exact sector sizes); first preset CD 700 MB and Create SFV on, both remembered; a size without a unit is refused; a file not larger than one part is refused; the cursor file is split into the other pane's folder; existing parts ask Replace; leftover parts from an earlier larger split are removed; Combine starts from the cursor part (or the SFV) and writes into the other pane's folder; no default keys |
| 2026-11-22 | Unpack (requested): Option+F9 dialog with target, "Extract into its own folder" when the archive has several items at the top, file mask, folder paths on/off, delete archive after with a Trash / permanently pop-up; an existing folder of that name asks |
| 2026-11-22 | Decided by Claude, change if wrong: the folder question offers Unpack into It / Use "name (2)" / Skip / Cancel and "Do the same for the other archives"; it is also asked when the archive's single top folder exists; an existing file with that name gets "name (2)" without asking; `__MACOSX` is never unpacked and `.DS_Store` does not count as a top item; the delete box always starts off, the delete mode is remembered; the archive (all volumes of a RAR set) is deleted only when nothing failed or was skipped; archives inside archives are never deleted; the target folder is created when missing; without folder paths a second file with the same name is left out and logged |
| 2026-11-22 | Remotes (asked): libssh2 uses OpenSSL 3 as its crypto backend (vendored sources); FTP/FTPS is Basil's own client on Network.framework; Dropbox uses the official SwiftyDropbox SDK |
| 2026-11-22 | Decided by Claude, change if wrong: SwiftUI secondary text is now the primary colour at 85 percent (was 75): the audit flagged a wrapped hint as "nearly passed" |

## Open questions (ask before implementing the related part)

- [x] Crypto backend for libssh2: OpenSSL 3 (2026-11-22)
- [x] FTP implementation: own client on Network.framework (2026-11-22)
- [x] Dropbox: official SwiftyDropbox SDK (2026-11-22)
- [ ] How should LuaJIT be built and linked (prebuilt static lib/xcframework from `scripts/bootstrap.sh`)?
- [ ] Should there be several queues in parallel (for example one per destination device), or strictly one global queue?
- [ ] Lua plugin sandbox: which APIs plugins can reach (filesystem only through VFS? network? shell?)
- [ ] Themes: should users be able to edit/create colour themes (and import/export them)?

- [x] Fixed 2026-11-19: dark-mode contrast audit failures. Real ones: system secondary text (3.3 to 3.9:1 in light mode), the faint system progress-bar track inside the queue row (1.4:1), the Multi-Rename Modified column running past the window edge. False positives now skipped in tests, each checked against the audit's own screenshot: the main window dimmed behind a sheet, inactive window titles, elements of other windows or scrolled out of the audited window, the system delete alert's "This cannot be undone." (7.7:1 on glass). All 26 UI tests pass in dark mode.
- [ ] Light mode: on macOS 27.2 the contrast audit flags text that measures 6 to 15:1 in its own element screenshots (main-window status line, Info sheet values, Settings hints, the Multi-Rename "Case" label, panel titles). The main-window failure also happens at commit 12ef346, so it is not caused by the fixes. Light-mode audits currently fail; pixel checks of the same elements pass. Revisit after an OS or Xcode update. The audit also misreads SwiftUI text drawn with `Color(nsColor:)` of a custom dynamic colour (fails in dark mode at 6:1), so SwiftUI text colours should derive from system styles.
- [x] Fixed 2026-11-19: a watcher refresh right after a navigation could replace the load's rows with the old cursor, so the cursor landed on the first row instead of the requested item (`PaneModel.pendingLoadCursor`).
- [x] Fixed 2026-11-18: panes never watched their start folder, and watcher changes never removed deleted or renamed-away items from a pane.
- [ ] UI tests are timing-flaky in the full suite (2026-11-22, after the progress window: `testArchiveBrowseChangeAndExtract` lost the first keys typed into the F7 sheet, "Made" became "e"; passes alone) (2026-11-22, after 7z writing: one different test per full run, `testFileOperationsWithKeyboard` then `testCopySettingsTab`, each passing alone; a failure also ends the run, so later tests do not run) (2026-11-22: `testArchiveBrowseChangeAndExtract`, the first test of the run, failed once on its first Enter in a full run despite the retry, and passes alone) (2026-11-19: tests now wait for sheet field focus before typing; a full run still shows about one different flake per run, `testQuickFilterAndHiddenToggle` or `testSoundsAndSpeechTab`, each passing alone; typing in other apps during a run also injects keys) (`testQuickFilterAndHiddenToggle` failed once in a full run on 2026-11-18 and passes alone; `testFinishedItemsCanBeRemoved` failed again in a full run on 2026-11-18, test operation stuck at 2 percent; passes alone): `testFinishedItemsCanBeRemoved` and `testColumnsAreConfigurableInSettings` each failed once in a full run and pass when run alone. Once, `app.debugDescription` (full-app snapshot) hung for 10 minutes inside NSTableView's own cell mock elements of a pane table; it did not happen again. Watch for it: it could mean VoiceOver can hang on the panes too.

- [x] Git scope for the first version (2026-11-22): status/commit/pull/push/checkout/branch plus log and blame.
- [ ] `testInfoSheet` fails its contrast audit in dark mode on the Info sheet's "Created" value (seen 2026-11-22, also at commit 8feafcc, so not caused by the archive work). To look into Its failure also ends the whole UI run after 19 tests; run the rest with `-skip-testing:BasilUITests/PaneUITests/testInfoSheet` (2026-11-22: the other 34 pass).
- [x] Fixed 2026-11-22: UI tests saved window frames into the user's real preferences (frame autosave uses the standard domain), and the main window could start partly off screen, which made tests flaky. UI-test launches no longer save frames (`BasilWindows.savesFrames`); without a saved frame the main window is 1280 by 800, or smaller to fit the screen, centred.
- [ ] The contrast audit fails a pane's status line while it shows an error (`report`, `Theme.errorText`, about 6:1 on the bar in dark mode; still failed at 8:1), seen 2026-11-22 in `testRarArchiveBrowsesAndIsReadOnly`, which now audits before the refusal. Possibly the same misreading as the light-mode entry above; check against the audit's screenshot.
- [ ] `PlainCopyTests/doesNotCheckSourceForChanges` failed once in a full BasilOperations run (2026-11-22; then 5 of 5 runs passed): in plain mode the append after chunk 1 can race with the read of the last chunk, so the copy may include the appended bytes. A timing race in the test, not the engine contract (plain mode does not promise anything about later writes)
- [x] Fixed 2026-11-22: archive providers stayed registered (with their index, open sessions and temporary copies) until the app quit. `ProviderRegistry.closeContainers(keeping:)` now closes the ones nothing uses, called by the main window on every folder change and when the queue has run everything (kept: pane folders, every tab's folder, loads in progress, F4 copies being watched, extractions; nothing is closed while queue items wait). A closed archive opens again fresh; passwords stay remembered in memory.

## Milestones

### M0 - Foundation
- [x] `git init`, `.gitignore`, `project.yml`, app target, package skeletons (Basil* packages)
- [ ] `scripts/bootstrap.sh` for vendored deps (blocked: libssh2 crypto, LuaJIT build questions). BLAKE3, libarchive, UnRAR and 7-Zip need none: vendored as sources in `Vendor/BLAKE3`, `Vendor/libarchive`, `Vendor/unrar` (SwiftPM) and `Vendor/7zip` (its own build.sh)
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
- [x] F4 for files in archives (temp copy, update prompt on return to Basil) (2026-11-22)
- [ ] F4 for files on remotes (upload prompt; needs M5)

### M4 - Archives
- [x] ArchiveBackend protocol + libarchive backend (built from vendored sources); browse archives as read-only folders (Enter, Cmd+PageDown), nested archives, extract with F5 through the copy engine
- [x] Test archive (Option+Shift+F9) as a queue operation
- [x] Write archives: pack (Option+F5), copy and move into, move out of, new folder, delete and rename inside an archive (rewrite through a checked temporary file); macOS metadata stored and restored
- [x] 7-Zip backend: reading 7z (browse, extract with F5, test) through the bundled 7zz (2026-11-22)
- [x] 7-Zip writing: pack with solid, levels, AES-256, encrypted names; encrypted zip (AES-256); changing 7z archives in place (2026-11-22)
- [x] Password prompts + Keychain for 7z and zip (2026-11-22)
- [x] UnRAR backend: RAR 1.5 to 7 read (browse, extract, test), solid, multi-volume, passwords through the same prompt (2026-11-22)
- [x] Edit-in-archive -> repack prompt; F3 / F4 on files inside archives (temporary copy) (2026-11-22)

### Features requested 2026-11-22 (after M4)
- [x] Progress window like TC (Background, Pause, Cancel) (2026-11-22)
- [x] App cleanup like ForkLift: deleting an .app offers to delete its leftovers (caches, logs, launch agents, preferences) (2026-11-22)
- [x] File lists (.lst) like TC's DiskDir, optimised binary and text formats, DiskDir read (2026-11-22)
- [x] Split File / Combine Files with SFV (2026-11-22)
- [x] Unpack (Option+F9) with a smart own folder, mask, flat unpacking, delete after (2026-11-22)

### Features added 2026-11-22 (before the rest of M4)
- [x] TC-style menus with submenus (2026-11-22)
- [x] Numpad keys like TC (2026-11-22)
- [x] One Name column (name and extension) (2026-11-22)
- [x] Ctrl+Shift+F views and sorting, spoken (2026-11-22)
- [x] Checksums: create and verify (2026-11-22)
- [x] Test archive after packing (2026-11-22)
- [x] Path bar (2026-11-22)
- [x] Pane tabs (2026-11-22)

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
