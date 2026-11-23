# Basil and OneDrive: Privacy Policy

Effective date: 23 November 2026

Basil is a free, open-source dual-pane file manager for macOS. This policy explains what happens to your information when you connect Basil to your Microsoft OneDrive. It covers only the OneDrive connection. Everything else Basil does stays on your Mac.

## Summary

- Basil runs only on your Mac. The Basil project has no servers, and none of your OneDrive data or account details ever reach the project or anyone else.
- Basil talks to Microsoft directly from your Mac, and only to do what you ask it to do: list folders, copy, move, rename, delete and create files and folders, and copy a file's OneDrive link when you choose Copy Link.
- You sign in on Microsoft's own website. Basil never sees or stores your Microsoft password.
- The sign-in token is kept in the macOS Keychain on your Mac. You can remove it at any time.
- Basil has no analytics, tracking, advertising or crash reporting, and it does not sell or share any data.

## Who is responsible

Basil is written and maintained by an individual developer as an open-source project. Its source code is public, so anyone can check that it does what this policy says. Questions go through the project's issue tracker on GitHub (see "Contact" below). The source code is at https://github.com/Flameborn/basil.

## What Basil accesses in your OneDrive

When you connect a Microsoft account (a personal account, or a work or school account), Microsoft asks you to allow Basil the following permissions:

| Permission | What Basil uses it for |
|---|---|
| `Files.ReadWrite.All` | Seeing, creating, changing and deleting your OneDrive files and folders when you ask for it: listing folders in the panes, copying files to and from your OneDrive, previewing (F3) or editing (F4) files, renaming, moving, deleting, and copying an item's OneDrive link. It also lets Basil open shared folders that you added to your own OneDrive |
| `User.Read` | Showing which account a connection belongs to (your name and email address in the connection list and when you disconnect), and telling several connected accounts apart |
| `offline_access` | Staying signed in, so you do not have to sign in again every time Basil connects |

Basil asks for full OneDrive access because it is a file manager: you choose which folders to browse, and it needs to reach them. Basil reads and changes your files only as a direct result of a command you give, such as opening a folder or starting a copy. It does not scan, index or upload anything in the background. From your account it reads only your name, email address, user ID and the ID of your OneDrive.

Copy Link copies the link OneDrive already shows for the item (its web address) to your clipboard. Basil does not create sharing links, change who can open the item, or send the link anywhere.

Work or school accounts may need an administrator to allow Basil before it can connect. Basil does not ask for any administrator permission, and it cannot read anything in your organisation beyond the files you yourself can reach.

## Where your data goes

- **Between your Mac and Microsoft only.** Every request goes over HTTPS straight from Basil on your Mac to Microsoft's servers: login.microsoftonline.com for signing in and tokens, graph.microsoft.com for the Microsoft Graph API, and the Microsoft download and upload addresses that Graph hands out for a single file transfer. No other server is involved.
- **On your Mac.** Files you copy or move are written to the place you choose. To preview or edit a file stored in OneDrive, Basil may put a temporary copy in its cache folder (`~/Library/Caches/Basil`). It deletes these copies when they are no longer needed, and every time Basil starts or quits. While a file larger than 4 MB is being uploaded, Basil keeps its data in a temporary file ("Basil OneDrive uploads" in your Mac's temporary folder, readable only by you), because OneDrive needs to know the full size before the upload starts; the temporary file is deleted as soon as the upload ends or is cancelled. While Basil is running, the listings it shows are held in memory only.
- **Saved connections.** If you save a OneDrive connection, its name, the account's email address and Microsoft's user ID for the account are stored in Basil's preferences on your Mac, so you can see which account a saved connection uses.
- **Logs.** Basil's operation queue keeps a log of each operation (for example "Copied report.pdf to /Projects"). The log is kept in memory and is gone when Basil quits.

None of this information is sent to the Basil project, its developer or anyone else.

## Signing in and tokens

Basil uses Microsoft's standard OAuth 2 sign-in for public desktop apps, with PKCE. It has no client secret:

1. When you connect, Basil opens Microsoft's sign-in page in your web browser.
2. You sign in on Microsoft's website and choose whether to allow Basil. Your password and any two-step verification codes go only to Microsoft.
3. Microsoft sends your browser back to a page that Basil shows from your Mac (`http://localhost` on a free port, which only your Mac can reach, and only while the sign-in is waiting). It tells you that you can close the tab.
4. Basil exchanges the one-time code from that page for tokens that let it act on your behalf with the permissions listed above.

Basil stores the refresh token, and the list of permissions Microsoft granted, in the macOS Keychain on your Mac, one entry for each Microsoft account you connect. Microsoft replaces the refresh token from time to time, and Basil then replaces the Keychain entry. The short-lived access tokens made from it are kept in memory only. Tokens are used only to talk to Microsoft for you, and they are never written to any other file, printed in logs or sent anywhere other than Microsoft. The download and upload addresses Microsoft hands out for a single file already carry their own permission, so Basil does not send your token to them. If Microsoft grants less than access to your files, Basil does not connect.

## Removing access

You can stop Basil's access at any time:

- **In Basil:** delete the saved OneDrive connection. Basil removes the token from the Keychain (unless another saved connection uses the same account). Microsoft offers apps no way to revoke a single sign-in, so to end the access on Microsoft's side as well, also do the next step.
- **On Microsoft:** for a personal account, open https://account.live.com/consent/Manage and remove Basil. For a work or school account, open https://myapps.microsoft.com, or ask your administrator. The token then stops working, even if it is still in your Keychain.

Uninstalling Basil does not delete Keychain entries by itself. To remove them, delete the OneDrive connections in Basil before you uninstall it, or remove the entries starting with "onedrive:" from the Keychain Access app.

## What Basil does not do

- It has no analytics, telemetry, usage statistics or crash reporting.
- It shows no advertising and does not track you.
- It does not sell, rent, share or transfer your data or OneDrive content to anyone.
- It does not use your data to train any machine-learning or AI model.
- It does not give anyone else access to your Microsoft account or change who can open your files.

## Microsoft's own handling of your data

Your files and account stay subject to Microsoft's own terms and privacy statement, which you can read at https://privacy.microsoft.com/privacystatement. For work or school accounts, your organisation's policies apply as well. This policy covers only what Basil does.

## Children

Basil is a general-purpose tool and is not aimed at children. It collects no personal information from anyone, children included.

## Changes to this policy

If Basil's handling of OneDrive data changes, this file is updated in the project's repository and the effective date above is changed. The history of the file shows every earlier version. If a change needs new Microsoft permissions, Microsoft asks you to allow them again before Basil can use them.

## Contact

For questions about this policy or about how Basil handles your data, open an issue at https://github.com/Flameborn/basil/issues.
