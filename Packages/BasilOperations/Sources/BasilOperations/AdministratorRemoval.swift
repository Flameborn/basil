import BasilVFS
import Foundation
import Synchronization

/// Removes local items the user may not remove (root-owned apps in /Applications, items in
/// /Library), after macOS's own administrator password dialog (`osascript ... with administrator
/// privileges`, the dialog Finder shows too). The password goes to macOS, never through Basil.
/// In the Trash mode the items are moved into the user's Trash and given to the user.
/// Operations get one only from the UI; without it a permission error is just an error (tests).
public struct AdministratorRemoval: Sendable {
    /// Removes (or with `toTrash` moves to the Trash) every path, after one password prompt.
    /// Throws `Declined` when the password dialog was cancelled, `CancellationError` when
    /// `isCancelled` turned true meanwhile (the script is stopped).
    public let remove: @Sendable (_ paths: [String], _ toTrash: Bool, _ isCancelled: @escaping @Sendable () -> Bool) async throws -> Void

    public init(remove: @escaping @Sendable (_ paths: [String], _ toTrash: Bool,
                                             _ isCancelled: @escaping @Sendable () -> Bool) async throws -> Void) {
        self.remove = remove
    }

    /// The password dialog was cancelled.
    public struct Declined: Error {}

    /// The administrator step failed for another reason. `message` is the end of what the
    /// commands wrote (one line per file can be very long).
    public struct Failed: LocalizedError {
        public let message: String
        public let paths: [String]

        public var errorDescription: String? {
            let lines = message.split(separator: "\n")
            let refused = lines.filter { $0.contains("Operation not permitted") }.count
            var text = "Could not remove it as an administrator"
            if refused > 0 {
                text += ": macOS refused \(refused == 1 ? "1 item" : "\(refused) items") (Operation not permitted)"
                if paths.contains(where: { $0.hasSuffix(".app") }) {
                    text += ". macOS protects apps: allow Basil under Privacy and Security, App Management in System Settings"
                }
            } else if let last = lines.last {
                text += ": \(last)"
            }
            return text
        }
    }

    public static let system = AdministratorRemoval { paths, toTrash, isCancelled in
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
        do {
            try await runAppleScript(script(for: paths, toTrash: toTrash, trash: trash), isCancelled: isCancelled)
        } catch let failed as Failed {
            throw Failed(message: failed.message, paths: paths)
        }
    }

    /// One `do shell script` with every path quoted by AppleScript's `quoted form of`. Trash mode
    /// moves each item into the user's Trash under a free name. It stays the administrator's:
    /// changing the owner of what is inside an app is refused by macOS (App Management), and
    /// Finder empties the Trash with a password for such items.
    static func script(for paths: [String], toTrash: Bool, trash: String) -> String {
        script(for: paths, toTrash: toTrash, trash: trash, prompt: prompt(for: paths, toTrash: toTrash))
    }

    /// The text of macOS's password dialog: what Basil is about to do and why it needs the
    /// password ("Basil wants to move CommanderOne.app to the Trash. It belongs to the system,
    /// so an administrator password is needed."). Without it macOS only says that a script
    /// wants to make changes.
    static func prompt(for paths: [String], toTrash: Bool) -> String {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let what = switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names.count) items"
        }
        let action = toTrash ? "move \(what) to the Trash" : "delete \(what) permanently"
        let reason = names.count == 1 ? "It belongs to the system" : "They belong to the system"
        return "Basil wants to \(action). \(reason), so an administrator password is needed."
    }

    static func script(for paths: [String], toTrash: Bool, trash: String, prompt: String) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["set cmd to \"\""]
        for (i, path) in paths.enumerated() {
            let more = i < paths.count - 1 ? " & \" && \"" : ""
            if toTrash {
                let name = (path as NSString).lastPathComponent
                let target = (trash as NSString).appendingPathComponent("\(name) \(UUID().uuidString.prefix(8))")
                lines.append("set cmd to cmd & \"/bin/mv -n -- \" & quoted form of \(literal(path)) & \" \" & quoted form of \(literal(target))\(more)")
            } else {
                lines.append("set cmd to cmd & \"/bin/rm -rf -- \" & quoted form of \(literal(path))\(more)")
            }
        }
        // Errors go to the end of the output only once (do shell script reports stderr itself).
        lines.append("do shell script cmd with prompt \(literal(prompt)) with administrator privileges")
        return lines.joined(separator: "\n")
    }

    /// Runs a script through osascript, fed on stdin. stderr is read on its own thread while the
    /// script runs: read only at the end, a full pipe (one error line per file of a big app)
    /// blocked osascript for ever. A cancelled password dialog (-128) is `Declined`; a cancelled
    /// operation stops osascript and throws `CancellationError`.
    static func runAppleScript(_ script: String, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let collected = ErrorText()
        let reader = Thread {
            let handle = errors.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                collected.append(chunk)
            }
            collected.finish()
        }
        reader.start()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { p in
                let message = collected.waitForText()
                if p.terminationReason == .uncaughtSignal, isCancelled() {
                    continuation.resume(throwing: CancellationError())
                } else if p.terminationStatus == 0 {
                    continuation.resume()
                } else if message.contains("-128") {
                    continuation.resume(throwing: Declined())
                } else {
                    continuation.resume(throwing: Failed(message: message, paths: []))
                }
            }
            do {
                try process.run()
                try? errors.fileHandleForWriting.close()
                input.fileHandleForWriting.write(Data(script.utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                try? errors.fileHandleForWriting.close()
                continuation.resume(throwing: error)
                return
            }
            let watcher = Thread {
                while process.isRunning {
                    if isCancelled() { process.terminate(); return }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            watcher.start()
        }
    }
}

/// What osascript wrote to stderr: the last 64 KB, handed over once the pipe is closed.
final class ErrorText: Sendable {
    private let state = Mutex<(data: Data, done: Bool)>((Data(), false))
    private let ended = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        state.withLock { s in
            s.data.append(chunk)
            if s.data.count > 65_536 { s.data = s.data.suffix(65_536) }
        }
    }

    func finish() {
        state.withLock { $0.done = true }
        ended.signal()
    }

    func waitForText() -> String {
        ended.wait()
        return String(decoding: state.withLock { $0.data }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
