# Changelog

Write new entries under "Unreleased" as you go. `scripts/release.sh` turns that section into the next version's notes.

## Unreleased

- Find Files (Option+F7, Commands > Find Files...), like Total Commander: search by name (wildcards, several patterns, exclusions or a regular expression), for text inside files (case, regular expression, whole words, files not containing it, UTF-8, UTF-16 and Windows-1252), by size and by date, in the current folder and its subfolders, and optionally inside archives (zip, 7z, RAR, tar and the rest, also archives in archives). Results appear as they are found; Return goes to a file, Show in Pane lists all results in the pane, where copy, move, delete, Quick Look, edit, rename and Multi-Rename work on them and Backspace goes back.
- Basil keeps its own index of the startup disk, like Everything on Windows, so Find Files finds names at once. It is built in the background the first time and kept up to date, also with changes made while Basil was closed. Settings, Navigation shows its status, rebuilds it or turns it off. Spotlight can be chosen as the search engine too.
- WebDAV over HTTP and HTTPS: saved connections and Quick Connect (http:// and https:// addresses work), Basic and Digest logins with the password asked only when the server wants one, untrusted certificates asked about and remembered, copy and move both ways through the secure copy engine, server-side copies and moves.
- Nextcloud is found automatically: its user's files are the top folder, large uploads go in checked chunks with their dates kept, F8 moves to the Nextcloud trash bin and Shift+F8 also removes the item from there.
- SMB (Windows shares, Samba, NAS boxes, Macs): connect with Cmd+K, the server's shares show as folders, Enter on a share mounts it in /Volumes like Finder, and Disconnect unmounts what Basil mounted. Guest logins work. Copy and move go through the secure copy engine; F3, F4, the terminal and archives work on shares like on local files.
- S3: Amazon S3 and S3-compatible services (Cloudflare R2, Backblaze B2, Wasabi, MinIO and others). Log in with an access key and its secret (Keychain optional) or with a profile from ~/.aws/credentials. The top folder lists the buckets (F7 there makes a bucket); folders work like in Cyberduck. Uploads are checked with SHA-256 by the server, large files go up in parts, dates are kept, and copies, moves and renames inside a bucket happen on the server.
- Google Drive: sign in on Google's website (Basil never sees the password), several accounts as saved connections. The top folder holds My Drive, Shared with me and Shared drives. Google Docs, Sheets and Slides are listed and copied as .docx, .xlsx and .pptx (Drawings as PDF); shortcuts open their targets; two items with the same name show as "notes.txt" and "notes (2).txt". Copy and move both ways through the secure copy engine (uploads checked by size and MD5), server-side copies and moves inside a drive, F8 moves to the Drive trash, Shift+F8 deletes for good, dates are kept, Copy Link copies the item's Drive link.
- Updates from GitHub releases: Basil looks for a new version when it starts and once a day (Settings, Navigation, "Check for updates automatically"; Basil > Check for Updates... any time), shows what changed, and on Install and Relaunch downloads the DMG, checks it against GitHub's checksum and checks that the new app is signed like the running one, then swaps it in and relaunches. Skip This Version and Remind Me Later are there too.
- A new About window: the app icon, version, developer, a button for the GitHub page, the license, and the open source projects Basil is built with.
- OneDrive: sign in on Microsoft's website with a personal, work or school account, several accounts as saved connections. Shared folders added to My files open like folders. Copy and move both ways through the secure copy engine (uploads checked with OneDrive's own hash), server-side copies and moves inside a drive, F8 moves to the recycle bin, dates are kept, Copy Link copies the item's OneDrive link. Personal Vault stays listed and explains that other apps cannot open it.
- The Files menu now comes before Edit, like on other Mac apps. Cmd+C copies the selected names, Cmd+Option+C their paths, Cmd+Option+Shift+C a share link where the service makes one.
- Enter opens apps and other packages (.app, .rtfd) like Finder; Show Package Contents (Files menu and context menu) or Cmd+PageDown goes inside.
- New setting "Space calculates folder sizes" (Settings, Navigation; off by default): Space on a folder also calculates its size, like Total Commander.
- Keys tab in Settings: every command with its keys, a filter, and buttons to remove a key, record a new one, assign it (Basil says which command loses it), reset one command or all keys.
- Compare by Content (Files menu), like Total Commander: two files compared as text (by line) or binary (by byte), in an accessible window where each difference reads as one sentence; F8 and Shift+F8 jump between differences. Identical files just get a short alert.
- Shift+F5 duplicates the selected items in the same folder as "name (2).ext".
- F4 on servers: the file is downloaded and opened in your editor; once you save and come back to Basil, it asks to upload it, and asks before replacing a file that changed on the server meanwhile.
- Git: a Git column in Full view shows each item's status inside repositories (Modified, Staged, Untracked, ...), and the window title shows the branch ("Beta (main) - Basil"). Changes made in a terminal show at once.
- Git, Commands > Git and the context menu: a Commit window (stage and unstage with Space, the diff of each file as readable lines, amend, discard changes, push after committing), Pull, Push and Fetch in the queue (logins asked by Basil, Keychain optional; a branch without an upstream is offered for publishing, also to a new remote), a Branches window (check out, new, rename, delete, merge), a Log window for the repository or one file with each commit's changed files and diffs, and Blame.
- Full Disk Access: when Basil does not have it, a window at launch says why a file manager needs it and how to grant it, shows the status, and offers Quit Basil, Open System Settings and Continue, which becomes available the moment access is granted.
- Command line like Total Commander: Left or Right in a pane opens an edit field for the pane's folder. cd changes the pane's folder; other commands run in your login shell, with their output in an accessible window (Stop, Run Again; the result is spoken). Up and Down go through earlier commands, Ctrl+Return inserts the cursor item's name, Ctrl+Shift+Return its path.

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
- Remote connections: SFTP (with multiple ssh-agent support), FTP and FTPS, Dropbox.
- Context menu, Copy Path, Copy Name and Copy Link; Quick Look (F3), editor rules (F4), terminal (Cmd+Shift+T); leftovers cleanup when deleting an app.
