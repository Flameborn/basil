import BasilCore
import Foundation

/// A provider that can hand out a link to one of its files or folders that other people can
/// open in a browser (Dropbox shared links). Files > Copy Link asks for it; the pane context
/// menu offers it only where the provider conforms.
public protocol SharedLinkProvider: FileSystemProvider {
    /// The link for `path`: an existing one, or a new one when there is none yet.
    func sharedLink(for path: VFSPath) async throws -> URL
}
