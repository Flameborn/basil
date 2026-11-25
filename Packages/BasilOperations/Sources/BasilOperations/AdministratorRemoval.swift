import BasilVFS
import Foundation

/// Removes local items the user may not remove (root-owned apps in /Applications, items in
/// /Library), after macOS's own administrator password dialog (`osascript ... with administrator
/// privileges`, the dialog Finder shows too). The password goes to macOS, never through Basil.
/// In the Trash mode the items are moved into the user's Trash and given to the user.
/// Operations get one only from the UI; without it a permission error is just an error (tests).
public struct AdministratorRemoval: Sendable {
    /// Removes (or with `toTrash` moves to the Trash) every path, after one password prompt.
    /// Throws `Declined` when the password dialog was cancelled.
    public let remove: @Sendable (_ paths: [String], _ toTrash: Bool) async throws -> Void

    public init(remove: @escaping @Sendable (_ paths: [String], _ toTrash: Bool) async throws -> Void) {
        self.remove = remove
    }

    /// The password dialog was cancelled.
    public struct Declined: Error {}

    /// The administrator step failed for another reason (osascript's message).
    public struct Failed: LocalizedError {
        public let message: String
        public var errorDescription: String? {
            "Could not remove it as an administrator" + (message.isEmpty ? "" : ": \(message)")
        }
    }

    public static let system = AdministratorRemoval { paths, toTrash in
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        try await runAppleScript(script(for: paths, toTrash: toTrash, trash: trash))
    }

    /// One `do shell script` with every path quoted by AppleScript's `quoted form of`. Trash mode
    /// moves each item into the user's Trash under a free name and gives it to the user.
    static func script(for paths: [String], toTrash: Bool, trash: String) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["set cmd to \"\""]
        for (i, path) in paths.enumerated() {
            let more = i < paths.count - 1 ? " & \" && \"" : ""
            if toTrash {
                let name = (path as NSString).lastPathComponent
                let target = (trash as NSString).appendingPathComponent("\(name) \(UUID().uuidString.prefix(8))")
                lines.append("set cmd to cmd & \"/bin/mv -n -- \" & quoted form of \(literal(path)) & \" \" & quoted form of \(literal(target)) & \" && /usr/sbin/chown -R \(getuid()) \" & quoted form of \(literal(target))\(more)")
            } else {
                lines.append("set cmd to cmd & \"/bin/rm -rf -- \" & quoted form of \(literal(path))\(more)")
            }
        }
        lines.append("do shell script cmd with administrator privileges")
        return lines.joined(separator: "\n")
    }

    /// Runs a script through osascript, fed on stdin. A cancelled password dialog (-128) is `Declined`.
    static func runAppleScript(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            let input = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { p in
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else if message.contains("-128") {
                    continuation.resume(throwing: Declined())
                } else {
                    continuation.resume(throwing: Failed(message: message))
                }
            }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(script.utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Copies and moves as an administrator, through Basil's helper (the UI's `HelperAccess`).
/// `begin` asks for the password (installing or approving the helper first when needed) and
/// registers `PrivilegedLocalProvider` under `.localAdministrator` until `end`.
public protocol AdministratorFiles: Sendable {
    /// Throws `PrivilegedAccessDeclined` when the user said no.
    func begin(prompt: String) async throws
    func end() async
}
