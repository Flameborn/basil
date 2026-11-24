import BasilCore
import BasilVFS
import CoreServices
import Foundation
import Testing
@testable import BasilSearch

/// A ReadableFile over bytes in memory.
private struct MemoryFile: ReadableFile {
    let data: [UInt8]
    func read(at offset: Int64, count: Int) async throws -> Data {
        let start = Int(min(offset, Int64(data.count)))
        return Data(data[start..<min(data.count, start + count)])
    }
    func close() async {}
}

private func contains(_ bytes: [UInt8], _ query: TextQuery) async throws -> Bool {
    try await TextMatcher(query).matches(MemoryFile(data: bytes))
}

@Suite struct TextMatcherTests {
    @Test func findsLiteralTextWithoutCase() async throws {
        #expect(try await contains(Array("Hello World".utf8), TextQuery(text: "world")))
        #expect(try await !contains(Array("Hello World".utf8), TextQuery(text: "world", caseSensitive: true)))
        #expect(try await contains(Array("Hello World".utf8), TextQuery(text: "World", caseSensitive: true)))
        #expect(try await !contains(Array("Hello".utf8), TextQuery(text: "planet")))
    }

    @Test func findsUTF16AndWindows1252() async throws {
        let le = "Grüße aus Köln".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let be = "Grüße aus Köln".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        #expect(try await contains(le, TextQuery(text: "köln")))
        #expect(try await contains(be, TextQuery(text: "KÖLN")))
        #expect(try await contains(le, TextQuery(text: "aus", encodings: .utf16)))
        #expect(try await !contains(le, TextQuery(text: "aus", encodings: .utf8)))
        // "Café €5" in Windows-1252: é is 0xE9, the euro sign 0x80.
        let cp1252: [UInt8] = [0x43, 0x61, 0x66, 0xE9, 0x20, 0x80, 0x35]
        #expect(try await contains(cp1252, TextQuery(text: "café €5")))
        #expect(try await contains(cp1252, TextQuery(text: "Café", caseSensitive: true, encodings: .windows1252)))
        #expect(try await !contains(cp1252, TextQuery(text: "Café", encodings: .utf8)))
    }

    @Test func findsTextAcrossChunks() async throws {
        var bytes = [UInt8](repeating: 0x2E, count: TextMatcher.chunkSize - 3)
        bytes += Array("needle".utf8)
        bytes += [UInt8](repeating: 0x2E, count: 100)
        #expect(try await contains(bytes, TextQuery(text: "NEEDLE")))
        #expect(try await contains(bytes, TextQuery(text: "ne+dle", regex: true)))
        // Inside a longer word ("xneedlex") it is not a whole word.
        var inWord = [UInt8](repeating: 0x78, count: TextMatcher.chunkSize - 3)
        inWord += Array("needlex".utf8)
        #expect(try await contains(inWord, TextQuery(text: "needle", wholeWords: true)) == false)
        var words = [UInt8](repeating: 0x20, count: TextMatcher.chunkSize - 2)
        words += Array("needle and".utf8)
        #expect(try await contains(words, TextQuery(text: "needle", wholeWords: true)))
    }

    @Test func notContainingAndInvalidRegex() async throws {
        #expect(try await contains(Array("abc".utf8), TextQuery(text: "x", notContaining: true)))
        #expect(try await !contains(Array("abc".utf8), TextQuery(text: "b", notContaining: true)))
        #expect(throws: TextMatcher.MatcherError.self) { try TextMatcher(TextQuery(text: "(", regex: true)) }
    }
}

@Suite struct SearchQueryTests {
    private func item(_ name: String, folder: Bool = false, size: Int64? = nil, modified: Date? = nil,
                      hidden: Bool = false) -> FileItem {
        FileItem(path: .local("/x/" + name), kind: folder ? .directory : .file, size: size, modified: modified, isHidden: hidden)
    }

    @Test func matchesKindsNamesSizesAndDates() throws {
        var query = SearchQuery(name: "*.mp3")
        let filter = try query.nameFilter()
        #expect(query.matches(item("a.mp3"), nameFilter: filter))
        #expect(!query.matches(item("a.flac"), nameFilter: filter))
        query = SearchQuery(kinds: .folders)
        #expect(query.matches(item("Music", folder: true), nameFilter: nil))
        #expect(!query.matches(item("a.mp3"), nameFilter: nil))
        query = SearchQuery(minimumSize: 10, maximumSize: 20)
        #expect(query.matches(item("a", size: 15), nameFilter: nil))
        #expect(!query.matches(item("a", size: 25), nameFilter: nil))
        #expect(!query.matches(item("folder", folder: true), nameFilter: nil))
        let now = Date()
        query = SearchQuery(modifiedAfter: now.addingTimeInterval(-60))
        #expect(query.matches(item("new", modified: now), nameFilter: nil))
        #expect(!query.matches(item("old", modified: now.addingTimeInterval(-3600)), nameFilter: nil))
        query = SearchQuery(includeHidden: false)
        #expect(!query.matches(item(".hidden", hidden: true), nameFilter: nil))
        query = SearchQuery(text: TextQuery(text: "x"))
        #expect(!query.matches(item("Music", folder: true), nameFilter: nil))
    }
}

@Suite struct LiveSearchTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("basil-search-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Music/Live"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("lyrics about the sea".utf8).write(to: root.appendingPathComponent("Music/song.mp3"))
        try Data("concert".utf8).write(to: root.appendingPathComponent("Music/Live/show.mp3"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data("secret sea".utf8).write(to: root.appendingPathComponent(".hidden/inside.mp3"))
        return root
    }

    private func run(_ query: SearchQuery, in root: URL) async throws -> [String] {
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        var names: [String] = []
        for try await event in LiveSearchEngine().search(query, in: .local(root.path), registry: registry) {
            if case .found(let items) = event { names += items.map(\.name) }
        }
        return names.sorted()
    }

    @Test func walksFoldersAndFindsNamesAndText() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await run(SearchQuery(name: "*.mp3"), in: root) == ["inside.mp3", "show.mp3", "song.mp3"])
        #expect(try await run(SearchQuery(name: "*.mp3", includeHidden: false), in: root) == ["show.mp3", "song.mp3"])
        #expect(try await run(SearchQuery(name: "*.mp3", subfolders: false), in: root) == [])
        #expect(try await run(SearchQuery(kinds: .folders), in: root) == [".hidden", "Live", "Music"])
        #expect(try await run(SearchQuery(text: TextQuery(text: "SEA")), in: root) == ["inside.mp3", "song.mp3"])
        #expect(try await run(SearchQuery(name: "*.mp3", text: TextQuery(text: "sea", notContaining: true)), in: root) == ["show.mp3"])
    }

    @Test func resultsProviderDropsItemsThatAreGone() async throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry()
        let local = LocalProvider()
        registry.register(local)
        var found: [FileItem] = []
        for try await event in LiveSearchEngine().search(SearchQuery(name: "*.mp3"), in: .local(root.path), registry: registry) {
            if case .found(let items) = event { found += items }
        }
        let results = SearchResultsProvider(items: found, origin: .local(root.path), title: "Search results", registry: registry)
        registry.register(listing: results)
        #expect(Listings.info(results.location)?.title == "Search results")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Music/song.mp3"))
        var listed: [FileItem] = []
        for try await batch in results.list(results.root) { listed += batch }
        #expect(listed.map(\.name).sorted() == ["inside.mp3", "show.mp3"])
        #expect(registry.listing(results.location)?.origin == .local(root.path))
        registry.closeListings(keeping: [])
        #expect(registry.listing(results.location) == nil)
        #expect(Listings.info(results.location) == nil)
    }
}

@Suite struct SpotlightTests {
    @Test func buildsQueriesFromQuickFilterPatterns() {
        #expect(SpotlightSearchEngine.namePatterns("*.mp3;apple | live*") == ["*.mp3", "*apple*"])
        #expect(SpotlightSearchEngine.namePatterns("a?c") == ["a*c"])
        #expect(SpotlightSearchEngine.queryString(for: SearchQuery()) == "kMDItemFSName == \"*\"")
        let query = SearchQuery(name: "*.md", text: TextQuery(text: "say \"hi\"", wholeWords: true))
        #expect(SpotlightSearchEngine.queryString(for: query)
            == "(kMDItemFSName == \"*.md\"cd) && kMDItemTextContent == \"say \\\"hi\\\"\"cdw")
        let registry = ProviderRegistry()
        let engine = SpotlightSearchEngine()
        #expect(engine.refusal(for: SearchQuery(text: TextQuery(text: "x", regex: true)), in: .local("/"), registry: registry) != nil)
        #expect(engine.refusal(for: SearchQuery(), in: VFSPath(location: ProviderLocation(provider: ProviderID("sftp")), path: "/"),
                               registry: registry) != nil)
        #expect(SpotlightSearchEngine.isInHiddenFolder(.local("/a/.git/b/c"), below: .local("/a")))
        #expect(!SpotlightSearchEngine.isInHiddenFolder(.local("/a/b/.c"), below: .local("/a")))
    }

    /// Spotlight indexes the system's own apps; skipped when it finds nothing at all (Spotlight off).
    @Test func findsSystemAppsWithSpotlight() async throws {
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        var names: [String] = []
        let query = SearchQuery(name: "Calculator.app", subfolders: false, kinds: .folders)
        for try await event in SpotlightSearchEngine().search(query, in: .local("/System/Applications"), registry: registry) {
            if case .found(let items) = event { names += items.map(\.name) }
        }
        try #require(!names.isEmpty, "Spotlight found nothing; is it turned off?")
        #expect(names == ["Calculator.app"])
    }
}

@Suite struct FilenameIndexTests {
    /// A temporary tree by its real path (FSEvents reports /private/var, not /var).
    private func makeTree() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-index-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Music/Live"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent(".cache"), withIntermediateDirectories: true)
        try Data(count: 100).write(to: url.appendingPathComponent("Music/Song.MP3"))
        try Data(count: 5).write(to: url.appendingPathComponent("Music/Live/show.mp3"))
        try Data("x".utf8).write(to: url.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: url.appendingPathComponent(".cache/inside.mp3"))
        try Data("x".utf8).write(to: url.appendingPathComponent("Ünïcode Ä.txt"))
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return String(cString: realpath(url.path, &buffer))
    }

    private func index(_ root: String) -> FilenameIndex {
        FilenameIndex(file: URL(fileURLWithPath: root + ".basilindex"), root: root,
                      scanner: IndexScanner(skippedPaths: [], devices: nil))
    }

    private func waitReady(_ index: FilenameIndex) async throws {
        for _ in 0..<200 where !index.state.isReady { try await Task.sleep(for: .milliseconds(25)) }
        #expect(index.state.isReady)
    }

    private func names(_ index: FilenameIndex, _ query: SearchQuery, in folder: String) async throws -> [String] {
        try await index.search(query, in: folder).map(\.name).sorted()
    }

    @Test func scansSearchesAndReloads() async throws {
        let root = try makeTree()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: root + ".basilindex")
        }
        let index = index(root)
        await index.start()
        try await waitReady(index)
        #expect(try await names(index, SearchQuery(name: "*.mp3"), in: root) == ["Song.MP3", "inside.mp3", "show.mp3"])
        #expect(try await names(index, SearchQuery(name: "*.mp3", includeHidden: false), in: root) == ["Song.MP3", "show.mp3"])
        #expect(try await names(index, SearchQuery(name: "song"), in: root + "/Music") == ["Song.MP3"])
        #expect(try await names(index, SearchQuery(name: "*.mp3", subfolders: false), in: root + "/Music") == ["Song.MP3"])
        #expect(try await names(index, SearchQuery(name: "ä"), in: root) == ["Ünïcode Ä.txt"])
        #expect(try await names(index, SearchQuery(name: "^s.*3$", nameIsRegex: true), in: root) == ["Song.MP3", "show.mp3"])
        #expect(try await names(index, SearchQuery(kinds: .folders), in: root) == [".cache", "Live", "Music"])
        #expect(try await names(index, SearchQuery(minimumSize: 50), in: root) == ["Song.MP3"])
        let paths = try await index.search(SearchQuery(name: "show"), in: root).map(\.path.path)
        #expect(paths == [root + "/Music/Live/show.mp3"])
        await index.stop()

        // A second start loads the file instead of scanning.
        let again = self.index(root)
        await again.start()
        #expect(again.state.isReady)
        #expect(try await names(again, SearchQuery(name: "*.mp3"), in: root) == ["Song.MP3", "inside.mp3", "show.mp3"])
        await again.stop()
    }

    @Test func appliesChangesAndCompacts() async throws {
        let root = try makeTree()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: root + ".basilindex")
        }
        let index = index(root)
        await index.start()
        try await waitReady(index)
        let fm = FileManager.default
        try fm.removeItem(atPath: root + "/Music/Live")
        try fm.createDirectory(atPath: root + "/New/Deep", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/New/Deep/added.mp3"))
        try Data(count: 300).write(to: URL(fileURLWithPath: root + "/Music/Song.MP3"))
        // Reported like FSEvents does: one event for a whole new folder, one for the removed one.
        await index.apply([FSChange(path: root + "/Music/Live", flags: 0, id: 1),
                           FSChange(path: root + "/New", flags: 0, id: 2),
                           FSChange(path: root + "/Music/Song.MP3", flags: 0, id: 3)])
        #expect(try await names(index, SearchQuery(name: "*.mp3"), in: root) == ["Song.MP3", "added.mp3", "inside.mp3"])
        #expect(try await names(index, SearchQuery(minimumSize: 200), in: root) == ["Song.MP3"])
        #expect(try await names(index, SearchQuery(name: "added"), in: root + "/New") == ["added.mp3"])
        await index.stop()

        // The changes survive a save, and compaction keeps the same answers.
        let store = try IndexStore.read(from: URL(fileURLWithPath: root + ".basilindex"))
        let compact = store.compacted()
        #expect(compact.records.count < store.records.count)
        #expect(compact.lookup(root + "/New/Deep/added.mp3") != nil)
        #expect(compact.lookup(root + "/Music/Live") == nil)
        #expect(compact.path(compact.lookup(root + "/Music/Song.MP3")!) == root + "/Music/Song.MP3")
    }

    @Test func followsLiveChangesThroughFSEvents() async throws {
        let root = try makeTree()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: root + ".basilindex")
        }
        let index = index(root)
        await index.start()
        try await waitReady(index)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/Music/fresh.flac"))
        var found: [String] = []
        for _ in 0..<100 {
            found = try await names(index, SearchQuery(name: "*.flac"), in: root)
            if !found.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(found == ["fresh.flac"])
        await index.stop()
    }

    @Test func foldedMatcherFollowsTheQuickFilterSyntax() throws {
        func match(_ pattern: String, _ name: String) throws -> Bool {
            let matcher = try FoldedNameMatcher(pattern, regex: false)
            return FoldedNameMatcher.fold(name).withUnsafeBufferPointer { matcher.matches(folded: $0) }
        }
        #expect(try match("*.mp3", "Song.MP3"))
        #expect(try match("apple", "Big Apple Pie"))
        #expect(try match("*.mp3;*.flac | live*", "x.flac"))
        #expect(try !match("*.mp3;*.flac | live*", "live.flac"))
        #expect(try match("?berall.txt", "Überall.txt"))
        #expect(try !match("*.txt", "a.txt.bak"))
    }
}

/// Scans the real startup disk (skipped unless BASIL_INDEX_LIVE=1): time, entries and file size.
@Suite struct BootVolumeIndexBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BASIL_INDEX_LIVE"] == "1"))
    func scansTheStartupDisk() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("basil-boot-\(UUID().uuidString).basilindex")
        defer { try? FileManager.default.removeItem(at: file) }
        let started = Date()
        let store = try IndexScanner.bootVolume().scan("/", isCancelled: { false }) { _ in }
        let scanned = Date().timeIntervalSince(started)
        store.volumeUUID = FilenameIndex.volumeUUID(of: "/")
        store.lastEventID = FSEventsGetCurrentEventId()
        try store.write(to: file)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let loadStart = Date()
        let loaded = try IndexStore.read(from: file)
        let loadTime = Date().timeIntervalSince(loadStart)
        let index = FilenameIndex(file: file, root: "/", scanner: .bootVolume())
        await index.start()
        let searchStart = Date()
        let hits = try await index.search(SearchQuery(name: "*.swift"), in: "/")
        let searchTime = Date().timeIntervalSince(searchStart)
        print("BOOT INDEX: \(store.records.count) entries in \(scanned) s, file \(size / 1_000_000) MB, load \(loadTime) s, *.swift \(hits.count) hits in \(searchTime) s")
        #expect(loaded.records.count == store.records.count)
        #expect(store.lookup("/Applications") != nil)
        #expect(store.lookup(FileManager.default.homeDirectoryForCurrentUser.path) != nil)
        await index.stop()
    }
}

/// Scans the folder or volume BASIL_SCAN_ROOT with the getattrlistbulk scanner (skipped without
/// it): used to compare against searchfs, which was not faster (see progress.md, 2026-11-24).
@Suite struct VolumeScanBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BASIL_SCAN_ROOT"] != nil))
    func scansVolume() throws {
        let root = ProcessInfo.processInfo.environment["BASIL_SCAN_ROOT"]!
        let started = Date()
        let store = try IndexScanner(skippedPaths: [], devices: nil).scan(root, isCancelled: { false }) { _ in }
        print("SCAN \(root): \(store.records.count) entries in \(Date().timeIntervalSince(started)) s")
    }
}
