import BasilCore
import Foundation

/// A provider whose items are files on this Mac underneath, such as an SMB share mounted in
/// /Volumes. Features that need a real file (Quick Look, editors, the terminal, archives read
/// in place) use the local path instead of a temporary copy.
public protocol LocalBackedProvider: FileSystemProvider {
    /// The local path holding `path`, or nil when there is none right now (the list of shares,
    /// a share that is not mounted).
    func localPath(of path: VFSPath) -> String?
}

extension ProviderRegistry {
    /// `path` itself when it is local, the local file a local-backed provider keeps it in, or nil.
    public func localPath(of path: VFSPath) -> VFSPath? {
        if path.location == .local { return path }
        guard path.location.container == nil,
              let provider = try? provider(for: path.location) as? any LocalBackedProvider,
              let local = provider.localPath(of: path) else { return nil }
        return .local(local)
    }
}
