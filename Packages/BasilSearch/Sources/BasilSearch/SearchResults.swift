import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// Search results shown in a pane (Total Commander's "Feed to listbox"): one folder listing the
/// found items with their real paths. Listing it again checks every item, so items deleted or
/// renamed meanwhile drop out and changed sizes and dates show. Other paths (a found folder's
/// contents, for Cmd+Shift+S) are passed to the provider the items come from.
public final class SearchResultsProvider: ListingProvider {
    public static let providerID = ProviderID("search")
    private static let counter = Mutex(0)

    public let location: ProviderLocation
    public let origin: VFSPath
    public let title: String
    private let source: any FileSystemProvider
    private let items: Mutex<[FileItem]>

    /// - Parameter source: the provider the items come from (the search's start folder's).
    public init(items: [FileItem], origin: VFSPath, title: String, source: any FileSystemProvider) {
        let number = Self.counter.withLock { value in
            value += 1
            return value
        }
        location = ProviderLocation(provider: Self.providerID, instance: String(number))
        self.origin = origin
        self.title = title
        self.source = source
        self.items = Mutex(items)
    }

    public var root: VFSPath { VFSPath(location: location, path: "/") }

    public var capabilities: ProviderCapabilities { source.capabilities }

    public var count: Int { items.withLock { $0.count } }

    public func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        guard directory.location == location else { return source.list(directory) }
        let current = items.withLock { $0 }
        let source = source
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard directory.isRoot else {
                    return continuation.finish(throwing: VFSError.notFound(directory))
                }
                var kept: [FileItem] = []
                var batch: [FileItem] = []
                for item in current {
                    if Task.isCancelled { return continuation.finish(throwing: CancellationError()) }
                    let fresh: FileItem?
                    do {
                        fresh = try await source.item(at: item.path)
                    } catch VFSError.notFound {
                        fresh = nil
                    } catch {
                        fresh = item // Unreadable for now (a server that does not answer): keep it.
                    }
                    guard let fresh else { continue }
                    kept.append(fresh)
                    batch.append(fresh)
                    if batch.count >= 1000 {
                        continuation.yield(batch)
                        batch = []
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                self.items.withLock { $0 = kept }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func itemsMoved(_ pairs: [(from: VFSPath, to: VFSPath)]) {
        items.withLock { items in
            items = items.map { item in
                for (from, to) in pairs {
                    guard let moved = Self.path(item.path, movedFrom: from, to: to) else { continue }
                    return FileItem(path: moved, kind: item.kind, size: item.size, modified: item.modified, created: item.created,
                                    permissions: item.permissions, isHidden: item.isHidden, fileID: item.fileID)
                }
                return item
            }
        }
    }

    /// `path` after `from` became `to` (also when `path` is below `from`), or nil when unaffected.
    static func path(_ path: VFSPath, movedFrom from: VFSPath, to: VFSPath) -> VFSPath? {
        if path == from { return to }
        guard path.hasPrefix(from), from.location == to.location else { return nil }
        return VFSPath(location: to.location, path: to.path + path.path.dropFirst(from.path.count))
    }

    public func item(at path: VFSPath) async throws -> FileItem {
        guard path.location == location else { return try await source.item(at: path) }
        guard path.isRoot else { throw VFSError.notFound(path) }
        return FileItem(path: path, kind: .directory)
    }

    public func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }
}
