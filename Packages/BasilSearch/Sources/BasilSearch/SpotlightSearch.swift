import BasilCore
import BasilVFS
import CoreServices
import Foundation

/// Searches with Spotlight (MDQuery) in local folders. Spotlight narrows the search (names and
/// text it has indexed); every hit is then looked up on disk and checked against the whole query,
/// so names, sizes, dates and hidden items follow the same rules as the walk. Spotlight does not
/// index everything (system and hidden folders, excluded disks), and its text search matches
/// words, not any part of the text. It is used only when chosen.
public struct SpotlightSearchEngine: SearchEngine {
    public let id = "spotlight"
    public let title = "Spotlight"

    public init() {}

    public func refusal(for query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> String? {
        guard folder.location == .local else { return "Spotlight searches only folders on this Mac's disks" }
        if query.searchArchives { return "Spotlight does not look inside archives" }
        if let text = query.text, query.searchesText {
            if text.regex { return "Spotlight cannot search text with a regular expression" }
            if text.notContaining { return "Spotlight cannot find files that do not contain a text" }
        }
        return nil
    }

    public func prefersAutomatically(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> Bool {
        false
    }

    public func search(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> AsyncThrowingStream<SearchEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let provider = try registry.provider(for: folder.location)
                    let filter = try query.nameFilter()
                    let run = SpotlightRun(query: Self.queryString(for: query), scope: folder.path)
                    continuation.yield(.searching(folder))
                    for try await paths in run.paths() {
                        var found: [FileItem] = []
                        for path in paths {
                            try Task.checkCancellation()
                            let vfs = VFSPath.local(path)
                            guard vfs != folder, vfs.hasPrefix(folder) else { continue }
                            if !query.subfolders, vfs.parent != folder { continue }
                            if !query.includeHidden, Self.isInHiddenFolder(vfs, below: folder) { continue }
                            guard let item = try? await provider.item(at: vfs), query.matches(item, nameFilter: filter) else { continue }
                            found.append(item)
                        }
                        if !found.isEmpty { continuation.yield(.found(found)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A folder between `folder` and the item starts with a dot.
    static func isInHiddenFolder(_ path: VFSPath, below folder: VFSPath) -> Bool {
        path.components.dropFirst(folder.components.count).dropLast().contains { $0.hasPrefix(".") }
    }

    /// The Spotlight query: the name patterns that Spotlight can express (the exact check comes
    /// later), and the text as words.
    static func queryString(for query: SearchQuery) -> String {
        var parts: [String] = []
        let patterns = query.nameIsRegex ? [] : namePatterns(query.name)
        if patterns.isEmpty {
            parts.append("kMDItemFSName == \"*\"")
        } else {
            parts.append("(" + patterns.map { "kMDItemFSName == \"\(escape($0))\"cd" }.joined(separator: " || ") + ")")
        }
        if let text = query.text, query.searchesText {
            var modifiers = text.caseSensitive ? "" : "cd"
            if text.wholeWords { modifiers += "w" }
            let value = text.wholeWords ? escape(text.text) : "*" + escape(text.text) + "*"
            parts.append("kMDItemTextContent == \"\(value)\"\(modifiers)")
        }
        return parts.joined(separator: " && ")
    }

    /// The include patterns of a quick-filter text as Spotlight wildcards: "apple" -> "*apple*",
    /// "?" -> "*" (Spotlight only knows "*"). Exclusions are left to the exact check.
    static func namePatterns(_ text: String) -> [String] {
        let include = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return include.split(separator: ";").compactMap { raw in
            let pattern = raw.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return nil }
            if pattern.contains("*") || pattern.contains("?") { return pattern.replacingOccurrences(of: "?", with: "*") }
            return "*" + pattern + "*"
        }
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// One MDQuery, used only on its own serial queue. Paths are handed out in batches while
/// Spotlight gathers them; the stream ends when gathering is complete.
final class SpotlightRun: @unchecked Sendable {
    private let queryString: String
    private let scope: String
    private let queue = DispatchQueue(label: "Basil Spotlight query")

    init(query: String, scope: String) {
        queryString = query
        self.scope = scope
    }

    func paths() -> AsyncThrowingStream<[String], Error> {
        AsyncThrowingStream { continuation in
            let state = State()
            queue.async { [self] in
                guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
                    return continuation.finish(throwing: VFSError.failed("Spotlight did not accept the search"))
                }
                state.query = query
                MDQuerySetSearchScope(query, [scope] as CFArray, 0)
                MDQuerySetDispatchQueue(query, queue)
                guard MDQueryExecute(query, 0) else {
                    return continuation.finish(throwing: VFSError.failed("Spotlight could not start the search. Is Spotlight turned off for this disk?"))
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                state.timer = timer
                timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(200))
                timer.setEventHandler {
                    let done = MDQueryIsGatheringComplete(query)
                    MDQueryDisableUpdates(query)
                    let count = MDQueryGetResultCount(query)
                    var batch: [String] = []
                    while state.delivered < count {
                        if let raw = MDQueryGetResultAtIndex(query, state.delivered) {
                            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { batch.append(path) }
                        }
                        state.delivered += 1
                    }
                    MDQueryEnableUpdates(query)
                    if !batch.isEmpty { continuation.yield(batch) }
                    if done {
                        state.stop()
                        continuation.finish()
                    }
                }
                timer.resume()
            }
            continuation.onTermination = { [queue] _ in queue.async { state.stop() } }
        }
    }

    /// Confined to the run's queue.
    private final class State: @unchecked Sendable {
        var query: MDQuery?
        var timer: DispatchSourceTimer?
        var delivered = 0

        func stop() {
            timer?.cancel()
            timer = nil
            if let query { MDQueryStop(query) }
            query = nil
        }
    }
}
