# Changelog

Write new entries under "Unreleased" as you go. `scripts/release.sh` turns that section into the next version's notes.

## Unreleased

## 0.3.0 - 2026-11-25

This is possibly the last release before the 1.0 version.

- Lua plugins (LuaJIT): a plugin is a folder with a plugin.json and Lua files in Basil's Plugins folder. Plugins can add commands (with keys and menu items, also in the context menu), columns, places to browse, Multi-Rename placeholders and their own queue items, and they work with files through Basil's own copy, move, delete and dialogs. They run in a sandbox; network, shell and native code access are permissions the plugin names and you grant when you turn it on. Settings, Plugins turns each plugin on or off, reloads it and shows its log. Three example plugins and a guide for plugin authors come with Basil, in the Plugins folder.
- Synchronize Directories (Commands menu), like Total Commander: compares the left and right panes' folders, with subfolders, by size and date (with a tolerance and an option to ignore 1-hour differences) or by content, with a file filter. Each file reads as one sentence with what will happen to it; comma or < copies it to the left, period or > to the right, = leaves it alone, minus leaves it out, and Space selects several to change at once. Checkboxes show or hide each kind of difference. The asymmetric mode deletes files that exist only on the right. Synchronize Now asks with a summary, runs in the queue through the copy engine and compares again when done. S3 files are compared by their kept dates.
- Settings is now a sidebar of sections, with a new General section (updates) and a Search section (the index).
- Themes (Settings, Themes): duplicate Basil's theme and change any colour for light and dark mode, import and export themes as .basiltheme files. Every change is checked for WCAG contrast; a colour that would make text or outlines too hard to read is refused, with the reason said. Two of Basil's own colours were raised to pass the same check.
- The search index can also cover other disks and network volumes, ticked one by one in Settings, Search. Local disks catch up with changes made while Basil was closed; network volumes are scanned again when they are mounted and every few hours (6 by default).
- Plain FTP, WebDAV over HTTP and S3 over HTTP warn once per server before connecting, because the password and files go over the network unencrypted. "Do not ask again for this server" is there.
- Bookmarks of server folders connect first, through the saved connection, then open the folder. The F5 and F6 target field accepts server addresses such as sftp://alice@host/path.
- Dropbox, Google Drive and OneDrive folders stay live while a pane shows them: changes made elsewhere appear on their own (Dropbox within seconds, Drive and OneDrive within about 10 seconds).
- Nextcloud: sign in in the browser (works with two-factor logins; Basil gets its own app password, kept in the Keychain and revoked when the connection is deleted). Copy Link on Nextcloud and ownCloud gives a read-only public link, reusing one that exists.
- ownCloud 10: large uploads in checked chunks, dates kept, F8 to its trash bin, like Nextcloud.
- Copy Link on S3 gives a download address that works for 1 hour, 1 day or 7 days (Basil asks and remembers the choice).
- S3 in secure copy mode uploads straight to the final name, so big files are no longer copied a second time on the server. The old object stays until the new one is complete.
- Google Drive: the format for Google Docs, Sheets, Slides and Drawings can be chosen per connection (Office, OpenDocument, PDF, plain text, Markdown, CSV and more). Documents larger than Google's 10 MB export limit can be copied too. F5 on a shortcut to a folder copies the folder it leads to.
- Multi-Rename has photo and audio fields, like Total Commander's plugins: the date a photo was taken ([=exif.year], [=exif.month], [=exif.day], [=exif.hour], [=exif.minute], [=exif.second]), the camera ([=exif.make], [=exif.model]) and the size ([=exif.width], [=exif.height]); a song's [=audio.artist], [=audio.title], [=audio.album], [=audio.track], [=audio.year] and [=audio.genre] (MP3, M4A, AIFF, FLAC and more). They are in the Insert menus.
- Dropbox team accounts with a team space open at the team space, like Dropbox's own apps: the team folders and your member folder side by side.
- OneDrive: large uploads go up while they are copied when the size is known, without a temporary copy on the Mac.
- Archives on mounted SMB shares are packed and changed in place, like local ones.
- Copies inside an SMB share are made by the server when it can (Windows servers, Samba with fruit:copyfile), so the data does not travel to the Mac and back. This also works on shares mounted by Finder.
- SMB: a password to remember is saved only after the server has really checked it (macOS accepts any password for a few seconds after a share of that server was unmounted).
- Administrator rights, like Finder and ForkLift: copying or moving into a folder you may not change (such as /Applications), and deleting or trashing items that belong to the system, asks for an administrator password once and runs through Basil's own helper, which keeps the copy engine's checks. The dialog says what Basil is about to do and why. The password is remembered for 5 minutes, so several operations in a row ask once. The first time, macOS asks you to allow the helper in System Settings; Settings, Copying shows its status and can remove it.
- The pane command line can run in another shell than the login shell, for example fish with its functions and plugins: Settings, Editor and Terminal, Command line, Shell (the shells found on this Mac, or Other with a path).
- Questions during an operation (Retry, Skip, replace) open on the progress window and take focus; Cancel there also closes a waiting question.
- View Options (Cmd+J), like Finder: each pane tab can have its own view and columns, sorting, Folders on top (off mixes folders in with the files, for example newest first), hidden files, date format and size format. Changes apply at once and are remembered with the tab across restarts. Settings, Display holds the global values every tab starts with; Reset to Global Settings appears when a tab differs.
- Dates can be relative: "just now", "5 minutes ago", "3 hours ago", "2 days ago" for the last week (Settings, Display, or per tab in View Options).
- The operation queue moved to Cmd+Shift+J. Go to Folder or File is Cmd+Shift+G only.
- Fixed: Backspace out of a Git repository put the cursor on the first item instead of the folder just left.
- Fixed: VoiceOver could read the cursor row twice when entering or leaving a folder, or when the folder was refreshed. In a Git repository the row is read once, with its Git status.
- Fixed: deleting an app that belongs to the system could stay at "Moving to the Trash" for ever.
- Fixed: Basil could quit unexpectedly when a server connection was closed while a request to it was still being made.

## 0.2.0 - 2026-11-24

- Progress window like Total Commander's: From, To, the current file with its own bar, the total with bytes and files, speed, time left and time taken. Time left leaves out pauses and questions and allows for the time each file takes, so many small files on a server are estimated fairly.
- Deleting an app also finds what its installer packages put elsewhere, plug-ins it installed in both Library folders, legacy startup items, background downloads and crash reports. Folders shared with other software are never offered whole.
- SFTP logins also use the SSH agents of 1Password, Bitwarden, Secretive, Strongbox and GnuPG, and follow IdentityAgent in ~/.ssh/config.
- In secure copy mode, the queue log says what a server cannot guarantee (for example a file rewritten at the same size within one second, or no way to flush to disk).
- Help, Report an Issue on GitHub opens the new-issue page.

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
