# Changelog

Write new entries under "Unreleased" as you go. `scripts/release.sh` turns that section into the next version's notes.

## Unreleased

- WebDAV over HTTP and HTTPS: saved connections and Quick Connect (http:// and https:// addresses work), Basic and Digest logins with the password asked only when the server wants one, untrusted certificates asked about and remembered, copy and move both ways through the secure copy engine, server-side copies and moves.
- Nextcloud is found automatically: its user's files are the top folder, large uploads go in checked chunks with their dates kept, F8 moves to the Nextcloud trash bin and Shift+F8 also removes the item from there.

## 0.1.0 - 2026-11-22

First release.

- Dual-pane file manager with Total Commander keys and menus, adapted to the Mac, built for VoiceOver and the keyboard.
- Tabs, path bar, quick filter (Cmd+S), type-ahead, Brief and Full views plus custom views, sorting on Ctrl+Shift+F keys.
- Operation queue with progress window, sounds and speech; copy, move, delete, rename, new folder and new file all run through it.
- Copy and move engine with an optional secure mode that catches sources changing during the copy.
- Multi-Rename tool with masks, counters, search and replace, presets and undo.
- Archives: browse, extract, pack and test zip, tar (gz, bz2, xz, zstd), 7z and more; RAR extraction; passwords and encrypted names; Unpack dialog.
- Checksums: create and verify CRC32, MD5, SHA-1, SHA-2, SHA-3, BLAKE3, XXH3 and XXH128.
- Split and combine files; file lists (.lst).
- Remote connections: SFTP, FTP and FTPS, Dropbox.
- Context menu, Copy Path, Copy Name and Copy Link; Quick Look (F3), editor rules (F4), terminal (Cmd+Shift+T); leftovers cleanup when deleting an app.
