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
            try await DeleteOperation(paths: paths, toTrash: toTrash, registry: registry, administrator: .system).run(context)
        }
        guard !adminPaths.isEmpty else { return }
        try await context.checkpoint()
        context.progress(nil, "Waiting for the administrator password")
        do {
            try await AdministratorRemoval.system.remove(adminPaths.map(\.path), toTrash)
        } catch is AdministratorRemoval.Declined {
            throw CancellationError()
        }
        for p in adminPaths { context.log(toTrash ? "Moved \(p.path) to the Trash" : "Deleted \(p.path)") }
        context.progress(1, "Done")
    }

    static func adminScript(for paths: [String], toTrash: Bool, trash: String) -> String {
        AdministratorRemoval.script(for: paths, toTrash: toTrash, trash: trash)
    }
}
