# Basil and Dropbox: Privacy Policy

Effective date: 22 November 2026

Basil is a free, open-source dual-pane file manager for macOS. This policy explains what happens to your information when you connect Basil to your Dropbox account. It covers only the Dropbox connection. Everything else Basil does stays on your Mac.

## Summary

- Basil runs only on your Mac. The Basil project has no servers, and none of your Dropbox data or account details ever reach the project or anyone else.
- Basil talks to Dropbox directly from your Mac, and only to do what you ask it to do: list folders, copy, move, rename, delete and create files and folders.
- You sign in on Dropbox's own website. Basil never sees or stores your Dropbox password.
- The sign-in token is kept in the macOS Keychain on your Mac. You can remove it at any time.
- Basil has no analytics, tracking, advertising or crash reporting, and it does not sell or share any data.

## Who is responsible

Basil is written and maintained by an individual developer as an open-source project. Its source code is public, so anyone can check that it does what this policy says. Questions go through the project's issue tracker on GitHub (see "Contact" below).

## What Basil accesses in your Dropbox

When you connect a Dropbox account, Dropbox asks you to allow Basil the following permissions (scopes):

| Permission | What Basil uses it for |
|---|---|
| `account_info.read` | Showing which account a connection belongs to (your name and email address in the connection list and when you disconnect) |
| `files.metadata.read` | Listing folders: names, sizes, dates and other file information shown in the panes |
| `files.metadata.write` | Creating folders, and renaming, moving and deleting files and folders when you ask for it |
| `files.content.read` | Reading file contents when you copy files to your Mac or another location, preview them (F3) or open them in an editor (F4) |
| `files.content.write` | Writing file contents when you copy or move files into your Dropbox |

Basil asks for full Dropbox access because it is a file manager: you choose which folders to browse, and it needs to reach them. Basil reads and changes your files only as a direct result of a command you give, such as opening a folder or starting a copy. It does not scan, index or upload anything in the background. Basil does not ask for permission to share files, manage shared links, read team information or change account settings.

## Where your data goes

- **Between your Mac and Dropbox only.** Every request goes over HTTPS straight from Basil on your Mac to Dropbox's API servers. No other server is involved.
- **On your Mac.** Files you copy or move are written to the place you choose. To preview or edit a file stored in Dropbox, Basil may put a temporary copy in its cache folder (`~/Library/Caches/Basil`). It deletes these copies when they are no longer needed, and every time Basil starts or quits. While Basil is running, the listings it shows are held in memory only.
- **Saved connections.** If you save a Dropbox connection, its name and the account's display name and email address are stored in Basil's preferences on your Mac, so you can see which account a saved connection uses.
- **Logs.** Basil's operation queue keeps a log of each operation (for example "Copied report.pdf to /Projects"). The log is kept in memory and is gone when Basil quits.

None of this information is sent to the Basil project, its developer or anyone else.

## Signing in and tokens

Basil uses Dropbox's standard OAuth 2 sign-in with PKCE:

1. When you connect, Basil opens Dropbox's sign-in page in your web browser.
2. You sign in on Dropbox's website and choose whether to allow Basil. Your password and any two-factor codes go only to Dropbox.
3. Dropbox sends Basil a token that lets it act on your behalf with the permissions listed above.

Basil stores this token in the macOS Keychain on your Mac, one entry for each Dropbox account you connect. It is used only to talk to Dropbox for you, and it is never written to any other file, printed in logs or sent anywhere other than Dropbox.

## Removing access

You can stop Basil's access at any time, in either of these ways:

- **In Basil:** delete the saved Dropbox connection. Basil removes the token from the Keychain and asks Dropbox to revoke it.
- **On Dropbox:** open your Dropbox account settings, go to "Connected apps" and remove Basil. The token then stops working at once, even if it is still in your Keychain.

Uninstalling Basil does not delete Keychain entries by itself. To remove them, delete the Dropbox connections in Basil before you uninstall it, or remove the entries starting with "dropbox:" from the Keychain Access app.

## What Basil does not do

- It has no analytics, telemetry, usage statistics or crash reporting.
- It shows no advertising and does not track you.
- It does not sell, rent, share or transfer your data or Dropbox content to anyone.
- It does not use your data to train any machine-learning model.
- It does not give anyone else access to your Dropbox account.

## Dropbox's own handling of your data

Your files and account stay subject to Dropbox's own terms and privacy policy, which you can read at https://www.dropbox.com/privacy. This policy covers only what Basil does.

## Children

Basil is a general-purpose tool and is not aimed at children. It collects no personal information from anyone, children included.

## Changes to this policy

If Basil's handling of Dropbox data changes, this file is updated in the project's repository and the effective date above is changed. The history of the file shows every earlier version. If a change needs new Dropbox permissions, Dropbox asks you to allow them again before Basil can use them.

## Contact

For questions about this policy or about how Basil handles your data, open an issue in the Basil repository on GitHub.
