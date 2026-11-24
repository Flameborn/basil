import BasilCore
import BasilVFS
import Foundation

/// Fills the Git column: the status of each item of a folder inside a working tree. Only
/// local folders (also on a mounted share) can be asked; elsewhere it does not apply.
public struct GitAnnotator: ColumnAnnotator {
    public let git: GitService
    public var column: ColumnID { .git }

    public init(git: GitService) { self.git = git }

    public func annotations(for directory: VFSPath, registry: ProviderRegistry) async -> ColumnAnnotation? {
        guard let local = registry.localPath(of: directory), Self.mayBeInRepository(local.path) else { return nil }
        guard let root = await git.repositoryRoot(of: local.path),
              let folder = GitService.relative(local.path, to: root),
              let status = try? await git.status(root: root, below: local.path) else { return nil }
        let column = status.column(forFolder: folder)
        return ColumnAnnotation(byName: column.byName, everything: column.everything)
    }

    /// Whether a ".git" (folder, or file for worktrees and submodules) is in `path` or above it.
    /// A few stat calls, so folders outside any repository never start git.
    static func mayBeInRepository(_ path: String) -> Bool {
        var current = path
        while true {
            if (current as NSString).lastPathComponent == ".git" { return false }
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }
}
