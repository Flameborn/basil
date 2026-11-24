import BasilCore
import Foundation

/// A provider that can hand out a link to one of its files or folders that other people can
/// open in a browser (Dropbox shared links, S3 presigned addresses). Files > Copy Link asks for
/// it; the pane context menu offers it only where the provider conforms.
public protocol SharedLinkProvider: FileSystemProvider {
    /// How long a new link may work, shortest first, when links expire (S3); empty when they do
    /// not, and Copy Link then asks nothing.
    var linkLifetimes: [LinkLifetime] { get }
    /// The link for `path`: an existing one, or a new one when there is none yet. `lifetime` is
    /// one of `linkLifetimes` (nil when there are none).
    func sharedLink(for path: VFSPath, lifetime: LinkLifetime?) async throws -> URL
}

extension SharedLinkProvider {
    public var linkLifetimes: [LinkLifetime] { [] }

    public func sharedLink(for path: VFSPath) async throws -> URL {
        try await sharedLink(for: path, lifetime: linkLifetimes.last)
    }
}

/// How long an expiring link works.
public struct LinkLifetime: Sendable, Hashable {
    public var seconds: Int
    /// "1 hour", "7 days"
    public var title: String

    public init(seconds: Int, title: String) {
        self.seconds = seconds
        self.title = title
    }

    public static let hour = LinkLifetime(seconds: 3600, title: "1 hour")
    public static let day = LinkLifetime(seconds: 86_400, title: "1 day")
    public static let week = LinkLifetime(seconds: 604_800, title: "7 days")
}
