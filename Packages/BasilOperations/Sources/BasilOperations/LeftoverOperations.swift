import BasilCore
import BasilVFS
import Foundation

/// Removes what a deleted app left behind (ForkLift-style app cleanup). Items the user can remove
/// go to the Trash (or are deleted) through the local provider, like F8. Items that need an
/// administrator (in /Library, root-owned) are removed together after one administrator prompt
/// from macOS (`osascript ... with administrator privileges`); the password goes to macOS's own
/// dialog, never through Basil. In the Trash mode they are moved into the user's Trash.
public struct RemoveLeftoversOperation: QueueOperation {
    public let appName: String
    public let paths: [VFSPath]
    public let adminPaths: [VFSPath]
    public let toTrash: Bool
    let registry: ProviderRegistry

    public init(appName: String, paths: [VFSPath], adminPaths: [VFSPath], toTrash: Bool, registry: ProviderRegistry) {
        self.appName = appName
        self.paths = paths
        self.adminPaths = adminPaths
        self.toTrash = toTrash
        self.registry = registry
    }

    public var kind: OperationKind { toTrash ? .trash : .delete }

    public var title: String {
        let count = paths.count + adminPaths.count
        let what = count == 1 ? "1 leftover" : "\(count) leftovers"
        return toTrash ? "Move \(what) of \(appName) to the Trash" : "Delete \(what) of \(appName)"
    }

    public func run(_ context: OperationContext) async throws {
        if !paths.isEmpty {
            try await DeleteOperation(paths: paths, toTrash: toTrash, registry: registry).run(context)
        }
        guard !adminPaths.isEmpty else { return }
        try await context.checkpoint()
        context.progress(nil, "Waiting for the administrator password")
        let script = Self.adminScript(for: adminPaths.map(\.path), toTrash: toTrash,
                                      trash: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path)
        try await Self.runAppleScript(script)
        for p in adminPaths { context.log(toTrash ? "Moved \(p.path) to the Trash" : "Deleted \(p.path)") }
        context.progress(1, "Done")
    }

    /// One `do shell script` with every path quoted by AppleScript's `quoted form of`. Trash mode
    /// moves each item into the user's Trash under a free name and gives it to the user.
    static func adminScript(for paths: [String], toTrash: Bool, trash: String) -> String {
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["set cmd to \"\""]
        for (i, path) in paths.enumerated() {
            if toTrash {
                let name = (path as NSString).lastPathComponent
                let target = (trash as NSString).appendingPathComponent("\(name) \(UUID().uuidString.prefix(8))")
                lines.append("set cmd to cmd & \"/bin/mv -n -- \" & quoted form of \(literal(path)) & \" \" & quoted form of \(literal(target)) & \" && /usr/sbin/chown -R \(getuid()) \" & quoted form of \(literal(target))\(i < paths.count - 1 ? " & \" && \"" : "")")
            } else {
                lines.append("set cmd to cmd & \"/bin/rm -rf -- \" & quoted form of \(literal(path))\(i < paths.count - 1 ? " & \" && \"" : "")")
            }
        }
        lines.append("do shell script cmd with administrator privileges")
        return lines.joined(separator: "\n")
    }

    /// Runs a script through osascript, fed on stdin. A cancelled password prompt is a cancellation.
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
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: AdminRemovalError(message: message))
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

/// The administrator step failed (not a cancelled password prompt).
struct AdminRemovalError: LocalizedError {
    let message: String
    var errorDescription: String? {
        "Could not remove the items that need an administrator" + (message.isEmpty ? "" : ": \(message)")
    }
}
