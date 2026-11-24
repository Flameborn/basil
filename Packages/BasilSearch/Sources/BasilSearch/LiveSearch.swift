import BasilCore
import BasilVFS
import Foundation

/// Searches by walking the folders through their provider, like Total Commander: exact and
/// current, works on every provider (servers and archives too), and reads file contents for text
/// searches. Folders are searched level by level, so results close to the start come first.
/// Symlinks are found but never followed.
public struct LiveSearchEngine: SearchEngine {
    public let id = "live"
    public let title = "Live folder walk"
    /// Files read at the same time in a text search.
    let parallelReads: Int

    public init(parallelReads: Int = 4) {
        self.parallelReads = parallelReads
    }

    public func refusal(for query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> String? {
        guard let provider = try? registry.provider(for: folder.location) else { return "\(folder) is not open" }
        if query.searchesText, !provider.capabilities.contains(.read) {
            return "The files in \(folder.displayName) cannot be read, so their text cannot be searched"
        }
        return nil
    }

    /// The walk is always exact, so Automatic takes it when nothing faster prefers the query.
    public func prefersAutomatically(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> Bool {
        false
    }

    public func search(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> AsyncThrowingStream<SearchEvent, Error> {
        let parallel = parallelReads
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await Self.walk(query, from: folder, registry: registry, parallel: parallel) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func walk(_ query: SearchQuery, from start: VFSPath, registry: ProviderRegistry, parallel: Int,
                     emit: @escaping @Sendable (SearchEvent) -> Void) async throws {
        let nameFilter = try query.nameFilter()
        let matcher = try query.text.flatMap { $0.text.isEmpty ? nil : try TextMatcher($0) }
        if matcher != nil, (try? registry.writableProvider(for: start.location)) == nil {
            throw VFSError.unsupported("reading the files in \(start.displayName)")
        }
        var level = [start]
        var isStart = true
        while !level.isEmpty {
            var next: [VFSPath] = []
            for folder in level {
                try Task.checkCancellation()
                emit(.searching(folder))
                var items: [FileItem] = []
                do {
                    // Folders inside archives have their archive's provider.
                    let provider = try registry.provider(for: folder.location)
                    for try await batch in provider.list(folder) {
                        try Task.checkCancellation()
                        items += batch
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isStart { throw error }
                    emit(.skipped(folder, error.localizedDescription))
                    continue
                }
                isStart = false
                var candidates: [FileItem] = []
                for item in items {
                    if query.subfolders, case .directory = item.kind, query.includeHidden || !item.isHidden {
                        next.append(item.path)
                    }
                    if query.matches(item, nameFilter: nameFilter) { candidates.append(item) }
                    // Search archives: an archive is searched like a folder (its own folders only
                    // with subfolders on), also archives inside archives.
                    if query.searchArchives, registry.isContainer(item), query.includeHidden || !item.isHidden {
                        do {
                            if let root = try await registry.openContainer(item) { next.append(root) }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            emit(.skipped(item.path, error.localizedDescription))
                        }
                    }
                }
                guard let matcher else {
                    if !candidates.isEmpty { emit(.found(candidates)) }
                    continue
                }
                var readers: [ProviderLocation: any WritableProvider] = [:]
                for location in Set(candidates.map(\.path.location)) {
                    readers[location] = try? registry.writableProvider(for: location)
                }
                let readable = readers
                let found = try await withThrowingTaskGroup(of: FileItem?.self) { group in
                    var found: [FileItem] = []
                    var pending = candidates[...]
                    var running = 0
                    func startNext() {
                        guard let item = pending.popFirst() else { return }
                        running += 1
                        group.addTask {
                            do {
                                guard let reader = readable[item.path.location] else {
                                    throw VFSError.unsupported("reading \(item.name)")
                                }
                                let file = try await reader.openForReading(item.path, bypassCache: false)
                                let matches: Bool
                                do { matches = try await matcher.matches(file) } catch {
                                    await file.close()
                                    throw error
                                }
                                await file.close()
                                return matches ? item : nil
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                emit(.skipped(item.path, error.localizedDescription))
                                return nil
                            }
                        }
                    }
                    for _ in 0..<parallel { startNext() }
                    while running > 0, let result = try await group.next() {
                        running -= 1
                        if let result { found.append(result) }
                        startNext()
                    }
                    return found
                }
                if !found.isEmpty { emit(.found(found)) }
            }
            level = next
        }
    }
}
