import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// What a running search reports.
public enum SearchEvent: Sendable {
    /// Items that match, in the order found.
    case found([FileItem])
    /// The folder being searched now (for the status line).
    case searching(VFSPath)
    /// A folder or file that could not be read, with the reason.
    case skipped(VFSPath, String)
}

/// One way of searching (a live folder walk, Spotlight, Basil's own index). Built-in engines and
/// plugins register in `SearchEngines` the same way.
public protocol SearchEngine: Sendable {
    /// Stable ID, saved as the user's choice.
    var id: String { get }
    /// "Live folder walk", "Spotlight"
    var title: String { get }
    /// Why this engine cannot run `query` in `folder` (in words), or nil when it can.
    func refusal(for query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> String?
    /// Whether Automatic should pick this engine: only when it is ready and answers as exactly as
    /// a walk would. Engines are asked in registration order; the live walk comes last.
    func prefersAutomatically(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> Bool
    /// Runs the search. Cancelling the consuming task stops it.
    func search(_ query: SearchQuery, in folder: VFSPath, registry: ProviderRegistry) -> AsyncThrowingStream<SearchEvent, Error>
}

/// The registered search engines, in the order Automatic asks them.
public final class SearchEngines: Sendable {
    /// The ID of the Automatic choice (not an engine).
    public static let automaticID = "automatic"

    private let engines = Mutex<[any SearchEngine]>([])

    public init(_ engines: [any SearchEngine] = []) {
        self.engines.withLock { $0 = engines }
    }

    /// Adds an engine. Automatic asks engines in order, so `first` puts it ahead of the others.
    public func register(_ engine: any SearchEngine, first: Bool = false) {
        engines.withLock { list in
            list.removeAll { $0.id == engine.id }
            first ? list.insert(engine, at: 0) : list.append(engine)
        }
    }

    public var all: [any SearchEngine] { engines.withLock { $0 } }

    public func engine(id: String) -> (any SearchEngine)? { all.first { $0.id == id } }

    /// The engine for `id`, or for Automatic the first one that prefers the query, else the first
    /// one that can run it.
    public func resolve(_ id: String, for query: SearchQuery, in folder: VFSPath,
                        registry: ProviderRegistry) -> (any SearchEngine)? {
        if id != Self.automaticID, let engine = engine(id: id) { return engine }
        let list = all
        return list.first { $0.prefersAutomatically(query, in: folder, registry: registry) }
            ?? list.first { $0.refusal(for: query, in: folder, registry: registry) == nil }
    }
}
