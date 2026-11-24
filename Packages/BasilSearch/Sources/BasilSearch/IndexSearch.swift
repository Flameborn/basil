import BasilCore
import BasilVFS
import Foundation

/// Searches names in Basil's own index: instant, but only for the indexed tree (the startup
/// disk), only once the index is built, and without text. Automatic picks it for name searches
/// in folders it covers.
public struct IndexSearchEngine: SearchEngine {
    public let id = "index"
    public let title = "Basil's index"
    public let index: FilenameIndex

    public init(index: FilenameIndex) {
        self.index = index
    }

    /// The index stores real paths: /var is /private/var there.
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    public func refusal(for query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> String? {
        guard folder.location == .local, index.covers(folder.path) || index.covers(Self.realPath(folder.path)) else {
            return "Basil's index covers only the startup disk"
        }
        if query.searchesText { return "Basil's index has names only. Choose Automatic or Live folder walk to search text" }
        if query.searchArchives { return "Basil's index does not look inside archives. Choose Automatic or Live folder walk" }
        switch index.state {
        case .ready: return nil
        case .scanning(let count): return "Basil's index is still being built (\(count.formatted()) items so far)"
        case .loading: return "Basil's index is being loaded"
        case .off: return "Basil's index is turned off in Settings"
        case .failed(let reason): return "Basil's index could not be built: \(reason)"
        }
    }

    public func prefersAutomatically(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> Bool {
        refusal(for: query, in: folder, registry: registry) == nil
    }

    public func search(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> AsyncThrowingStream<SearchEvent, Error> {
        let index = index
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.searching(folder))
                    // The index stores real paths; found items are named under the folder as typed.
                    let real = Self.realPath(folder.path)
                    var items = try await index.search(query, in: index.covers(real) ? real : folder.path)
                    if real != folder.path, index.covers(real) {
                        items = items.map { Self.renamed($0, from: real, to: folder.path) }
                    }
                    var start = 0
                    while start < items.count {
                        try Task.checkCancellation()
                        let end = min(items.count, start + 2000)
                        continuation.yield(.found(Array(items[start..<end])))
                        start = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func renamed(_ item: FileItem, from real: String, to shown: String) -> FileItem {
        guard item.path.path.hasPrefix(real) else { return item }
        let path = shown + item.path.path.dropFirst(real.count)
        return FileItem(path: .local(path), kind: item.kind, size: item.size, modified: item.modified, created: item.created,
                        permissions: item.permissions, isHidden: item.isHidden, fileID: item.fileID)
    }
}
