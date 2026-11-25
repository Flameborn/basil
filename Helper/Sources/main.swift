// BasilHelper: Basil's administrator helper, a launchd daemon (SMAppService) that runs as root.
// It does local file calls for Basil when the user gave an administrator password for an
// operation (copying or moving into /Applications or /Library, for example). It accepts only
// Basil signed with the same certificate, asks for the password through macOS for every
// connection, and quits after two minutes without connections; launchd starts it again on demand.

import BasilVFS
import Foundation

HelperAuthorization.ensureRight()
guard let listener = PrivilegedHelperListener(onIdle: { exit(0) }) else {
    FileHandle.standardError.write(Data("BasilHelper: not signed with a certificate, refusing to run\n".utf8))
    exit(1)
}
listener.resume()
dispatchMain()
