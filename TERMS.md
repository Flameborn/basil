# Basil: Terms of Service

Effective date: 23 November 2026

Basil is a free, open-source dual-pane file manager for macOS. These terms explain the conditions for using it. They cover the whole app, including its connections to remote services such as Dropbox, Google Drive, S3-compatible storage, SFTP, FTP, WebDAV and SMB servers.

## Summary

- Basil is free and open source under the MIT License. You may use, copy, change and share it under that license.
- Basil is provided as is, without any warranty. You are responsible for your own files and backups.
- Basil runs only on your Mac. The Basil project has no servers, no accounts and no service you sign up for.
- When you connect Basil to a remote service, your use of that service stays subject to the service's own terms.
- Basil collects no data about you. See the privacy policy (`db_privacypolicy.md`) for how the Dropbox connection handles your information.

## Who provides Basil

Basil is written and maintained by an individual developer as a personal, non-commercial open-source project. It is not sold, and there is no company behind it. The source code is at https://github.com/Flameborn/basil, so anyone can check what it does.

## Accepting these terms

By downloading, building or using Basil you agree to these terms. If you do not agree, do not use Basil. The MIT License in the repository's `LICENSE` file also applies; where these terms and the license differ, the license decides what you may do with the source code and these terms describe how the app is offered.

## License

Basil's own code is released under the MIT License. Third-party code included with Basil (in the repository's `Vendor` folder) keeps its own license, and you must follow those licenses too. They include libarchive, 7-Zip, UnRAR, libssh2, OpenSSL, BLAKE3, xxHash and the SwiftyDropbox SDK. In particular, the UnRAR license allows using its code to read RAR archives but not to create a RAR compressor; Basil only reads RAR archives.

## No warranty

Basil is provided "as is" and "as available", without warranty of any kind, express or implied, including warranties of merchantability, fitness for a particular purpose and non-infringement. The developer does not promise that Basil is free of errors, that it will work with every file system, archive or service, or that it will keep working after changes to macOS or to a remote service.

A file manager copies, moves, renames and deletes files, so mistakes can lose data. Basil includes safeguards (an optional secure copy and move mode, optional read-back verification, archive tests after packing, confirmation before deleting), but no software can rule out data loss. Keep backups of anything you cannot afford to lose, and check important copies before you delete the originals.

## Limitation of liability

To the fullest extent the law allows, the developer and contributors are not liable for any damages arising from the use of Basil or from being unable to use it. This includes lost, damaged or leaked files, lost data in remote accounts, lost profits and any direct, indirect, incidental or consequential damages, even if the developer was told such damages were possible. Some places do not allow some of these limits; there, they apply only as far as the law allows.

## Your responsibilities

- **Your files and actions.** Basil does what you tell it to do. You are responsible for the commands you give, including deleting files permanently, replacing files on a conflict and changing files on remote servers.
- **Permissions on your Mac.** Basil asks you to grant it Full Disk Access so it can reach all your files. Granting it is your choice, and you can withdraw it at any time in System Settings.
- **Your accounts and credentials.** You are responsible for the accounts you connect to Basil and for keeping your Mac secure. Basil keeps passwords, keys and sign-in tokens in the macOS Keychain on your Mac, where anyone who can unlock your Mac account may be able to reach them.
- **Lawful use.** Use Basil only for files and accounts you are allowed to access. Do not use it to reach servers, accounts or data without permission, to break a service's terms, or to infringe anyone's rights.
- **Host keys and certificates.** When Basil asks whether to trust an unknown or changed SSH host key or TLS certificate, the decision is yours. Accepting one you have not checked can expose your connection to someone else.

## Remote services

Basil can connect to services run by other companies and people, including Dropbox, Google Drive, Amazon S3 and other S3-compatible storage, and servers that speak SFTP, FTP, FTPS, WebDAV (including Nextcloud) or SMB.

- Each service has its own terms, privacy policy, limits and fees. Your use of a service through Basil stays subject to them, and you are responsible for following them. Costs a service charges for storage, requests or transfers (for example on S3) are yours.
- Basil talks to each service directly from your Mac and only when you ask it to. The developer does not see, store or have access to your accounts or files on these services.
- Basil is not made, endorsed or supported by Dropbox, Google, Amazon, Microsoft, Nextcloud or any other service provider. Their names are used only to say which services Basil can connect to, and they remain trademarks of their owners.
- A service may change or stop its API, or end Basil's access, at any time. Basil may then stop working with that service, and the developer cannot promise to restore it.
- You can remove Basil's access to a service at any time: delete the saved connection in Basil, and for services you signed in to through your browser (Dropbox, Google Drive), you can also remove Basil in that service's account settings.

## Privacy

Basil has no analytics, telemetry, crash reporting or advertising, and it sends nothing to the developer. Your settings, saved connections and temporary copies stay on your Mac, and secrets stay in the macOS Keychain. The privacy policy for the Dropbox connection is in `db_privacypolicy.md` in the repository.

## Updates and support

Basil is offered without any promise of updates, fixes or support. Updates, when there are any, are published in the project's repository and releases on GitHub. Questions and bug reports are welcome on the issue tracker, but there is no guarantee of an answer or a fix.

## Ending your use

You can stop using Basil at any time by deleting it. Before you do, delete the remote connections you saved in Basil if you want their passwords and tokens removed from the Keychain and the sign-ins revoked; uninstalling does not remove Keychain entries by itself.

## Changes to these terms

If these terms change, this file is updated in the project's repository and the effective date above is changed. The history of the file shows every earlier version. Using Basil after a change means you accept the new terms.

## Contact

For questions about these terms, open an issue at https://github.com/Flameborn/basil/issues.
