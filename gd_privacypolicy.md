# Basil and Google Drive: Privacy Policy

Effective date: 23 November 2026

Basil is a free, open-source dual-pane file manager for macOS. This policy explains what happens to your information when you connect Basil to your Google Drive. It covers only the Google Drive connection. Everything else Basil does stays on your Mac.

## Summary

- Basil runs only on your Mac. The Basil project has no servers, and none of your Google Drive data or account details ever reach the project or anyone else.
- Basil talks to Google directly from your Mac, and only to do what you ask it to do: list folders, copy, move, rename, trash, delete and create files and folders, and copy a file's Drive link when you choose Copy Link.
- You sign in on Google's own website. Basil never sees or stores your Google password.
- The sign-in token is kept in the macOS Keychain on your Mac. You can remove it at any time.
- Basil has no analytics, tracking, advertising or crash reporting, and it does not sell or share any data.
- Basil's use of information received from Google APIs adheres to the Google API Services User Data Policy, including the Limited Use requirements.

## Who is responsible

Basil is written and maintained by an individual developer as an open-source project. Its source code is public, so anyone can check that it does what this policy says. Questions go through the project's issue tracker on GitHub (see "Contact" below). The source code is at https://github.com/Flameborn/basil.

## What Basil accesses in your Google Drive

When you connect a Google account, Google asks you to allow Basil one permission (scope):

| Permission | What Basil uses it for |
|---|---|
| `https://www.googleapis.com/auth/drive` | Seeing, creating, changing and deleting your Google Drive files and folders when you ask for it: listing folders in the panes, copying files to and from your Drive, previewing (F3) or editing (F4) files, renaming, moving, trashing and deleting, and copying an item's Drive link |

With this permission Basil also reads the account's name, email address and Google's permission ID from the Drive API's "about" request. It uses them to show which account a connection belongs to and to tell several connected accounts apart.

Basil asks for full Drive access because it is a file manager: you choose which folders to browse, including My Drive, Shared with me and shared drives, and it needs to reach them. Narrower permissions would only let Basil see files it created itself or that you pick one at a time in a Google dialog, which a file manager cannot work with. Basil reads and changes your files only as a direct result of a command you give, such as opening a folder or starting a copy. It does not scan, index or upload anything in the background.

Google documents (Docs, Sheets, Slides, Drawings, Apps Script) have no file of their own, so when you copy or preview one, Basil asks Google to export it (as .docx, .xlsx, .pptx, .pdf or .json) and downloads the export. Basil never changes Google documents, except to rename, move, trash or delete them when you ask.

Copy Link copies the link Google already shows for the item (its "web view link") to your clipboard. Basil does not create sharing permissions, change who can open the item, or send the link anywhere.

## Where your data goes

- **Between your Mac and Google only.** Every request goes over HTTPS straight from Basil on your Mac to Google's servers (accounts.google.com for signing in, oauth2.googleapis.com for tokens, www.googleapis.com for the Drive API). No other server is involved.
- **On your Mac.** Files you copy or move are written to the place you choose. To preview or edit a file stored in Google Drive, Basil may put a temporary copy in its cache folder (`~/Library/Caches/Basil`). It deletes these copies when they are no longer needed, and every time Basil starts or quits. While Basil is running, the listings it shows and the last few document exports are held in memory only.
- **Saved connections.** If you save a Google Drive connection, its name, the account's email address and Google's permission ID for the account are stored in Basil's preferences on your Mac, so you can see which account a saved connection uses.
- **Logs.** Basil's operation queue keeps a log of each operation (for example "Copied report.pdf to /My Drive/Projects"). The log is kept in memory and is gone when Basil quits.

None of this information is sent to the Basil project, its developer or anyone else.

## Limited Use

Basil's use and transfer to any other app of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements. In particular:

- Basil uses your Google Drive data only to provide the file manager features you use, on your Mac.
- It does not transfer the data to anyone, except as needed to do what you ask (for example writing a copy to a place you chose), to comply with the law, or as part of a merger or sale of the project with your consent.
- It does not use the data for advertising, including retargeting or interest-based ads.
- No person reads your data. The developer has no way to reach it.
- It does not use the data to develop, improve or train any machine-learning or AI model.

## Signing in and tokens

Basil uses Google's standard OAuth 2 sign-in for desktop apps, with PKCE:

1. When you connect, Basil opens Google's sign-in page in your web browser.
2. You sign in on Google's website and choose whether to allow Basil. Your password and any two-step verification codes go only to Google.
3. Google sends your browser back to a page that Basil shows from your Mac (`http://127.0.0.1` on a free port, which only your Mac can reach, and only while the sign-in is waiting). It tells you that you can close the tab.
4. Basil exchanges the one-time code from that page for tokens that let it act on your behalf with the permission listed above.

Basil stores the refresh token, and the list of permissions Google granted, in the macOS Keychain on your Mac, one entry for each Google account you connect. The short-lived access tokens made from it are kept in memory only. Tokens are used only to talk to Google for you, and they are never written to any other file, printed in logs or sent anywhere other than Google. If Google grants less than the Drive permission, Basil revokes the sign-in at once and does not connect.

## Removing access

You can stop Basil's access at any time, in either of these ways:

- **In Basil:** delete the saved Google Drive connection. Basil removes the token from the Keychain and asks Google to revoke it (unless another saved connection uses the same account).
- **On Google:** open your Google Account, go to "Security", then "Your connections to third-party apps and services", and remove Basil. The token then stops working at once, even if it is still in your Keychain.

Uninstalling Basil does not delete Keychain entries by itself. To remove them, delete the Google Drive connections in Basil before you uninstall it, or remove the entries starting with "gdrive:" from the Keychain Access app.

## What Basil does not do

- It has no analytics, telemetry, usage statistics or crash reporting.
- It shows no advertising and does not track you.
- It does not sell, rent, share or transfer your data or Google Drive content to anyone.
- It does not use your data to train any machine-learning or AI model.
- It does not give anyone else access to your Google account or change who can open your files.

## Google's own handling of your data

Your files and account stay subject to Google's own terms and privacy policy, which you can read at https://policies.google.com/privacy. This policy covers only what Basil does.

## Children

Basil is a general-purpose tool and is not aimed at children. It collects no personal information from anyone, children included.

## Changes to this policy

If Basil's handling of Google Drive data changes, this file is updated in the project's repository and the effective date above is changed. The history of the file shows every earlier version. If a change needs new Google permissions, Google asks you to allow them again before Basil can use them.

## Contact

For questions about this policy or about how Basil handles your data, open an issue at https://github.com/Flameborn/basil/issues.
