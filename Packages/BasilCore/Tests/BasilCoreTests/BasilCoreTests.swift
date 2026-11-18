import Foundation
import Testing
@testable import BasilCore

@Suite struct VFSPathTests {
    @Test func normalises() {
        #expect(VFSPath.local("").path == "/")
        #expect(VFSPath.local("/a//b/./c/../d/").path == "/a/b/d")
        #expect(VFSPath.local("/..").path == "/")
    }

    @Test func parentAndAppending() {
        let p = VFSPath.local("/Users/x")
        #expect(p.parent == .local("/Users"))
        #expect(VFSPath.local("/").parent == nil)
        #expect(VFSPath.local("/").appending("a") == .local("/a"))
        #expect(p.appending("y").path == "/Users/x/y")
        #expect(p.name == "x")
    }

    @Test func prefixRespectsComponentBoundaries() {
        #expect(VFSPath.local("/a/bc").hasPrefix(.local("/a")))
        #expect(!VFSPath.local("/ab").hasPrefix(.local("/a")))
        #expect(VFSPath.local("/a").hasPrefix(.local("/")))
    }

    @Test func nestedLocationDescription() {
        let zip = VFSPath.local("/tmp/x.zip")
        let inner = VFSPath(location: ProviderLocation(provider: ProviderID("archive"), container: zip), path: "/dir/f.txt")
        #expect(inner.description == "/tmp/x.zip#/dir/f.txt")
        #expect(inner.location.container == zip)
    }
}

@Suite struct FileItemTests {
    @Test(arguments: [
        ("song.mp3", false, "song", "mp3"),
        ("archive.tar.gz", false, "archive.tar", "gz"),
        (".zshrc", false, ".zshrc", ""),
        ("noext", false, "noext", ""),
        ("trailing.", false, "trailing.", ""),
        ("My.App", true, "My.App", ""),
    ])
    func splitsExtension(name: String, isDir: Bool, base: String, ext: String) {
        let r = FileItem.splitExtension(name, isDirectory: isDir)
        #expect(r.base == base)
        #expect(r.ext == ext)
    }
}

@Suite struct ItemSorterTests {
    func item(_ name: String, dir: Bool = false, size: Int64? = nil, mod: TimeInterval = 0) -> FileItem {
        FileItem(path: .local("/t/\(name)"), kind: dir ? .directory : .file, size: size,
                 modified: Date(timeIntervalSince1970: mod))
    }

    @Test func directoriesFirstThenNaturalNameOrder() {
        let items = [item("file10"), item("Zed", dir: true), item("file2"), item("alpha", dir: true), item("File1")]
        let names = ItemSorter.sorted(items, by: .default).map(\.name)
        #expect(names == ["alpha", "Zed", "File1", "file2", "file10"])
    }

    @Test func descendingKeepsDirectoriesFirst() {
        let items = [item("a"), item("b"), item("d", dir: true)]
        let names = ItemSorter.sorted(items, by: ListSortOrder(key: .name, ascending: false)).map(\.name)
        #expect(names == ["d", "b", "a"])
    }

    @Test func sortsBySizeExtAndDate() {
        let items = [item("x.b", size: 30, mod: 1), item("y.a", size: 10, mod: 3), item("z.c", size: 20, mod: 2)]
        #expect(ItemSorter.sorted(items, by: ListSortOrder(key: .size)).map(\.name) == ["y.a", "z.c", "x.b"])
        #expect(ItemSorter.sorted(items, by: ListSortOrder(key: .ext)).map(\.name) == ["y.a", "x.b", "z.c"])
        #expect(ItemSorter.sorted(items, by: ListSortOrder(key: .modified, ascending: false)).map(\.name) == ["y.a", "z.c", "x.b"])
    }

    @Test func insertionIndexMatchesFullSort() {
        let sorted = ItemSorter.sorted([item("a"), item("c"), item("e"), item("dir", dir: true)], by: .default)
        let new = item("d")
        let idx = ItemSorter.insertionIndex(of: new, in: sorted, by: .default)
        var copy = sorted
        copy.insert(new, at: idx)
        #expect(copy.map(\.name) == ItemSorter.sorted(copy, by: .default).map(\.name))
    }
}

@Suite struct NameFilterTests {
    func f(_ s: String, regex: Bool = false) throws -> NameFilter { try NameFilter(s, regex: regex) }

    @Test func substringIsCaseInsensitive() throws {
        let filter = try f("apple")
        #expect(filter.matches("Big APPLE pie.txt"))
        #expect(!filter.matches("pear.txt"))
    }

    @Test func wildcardMatchesWholeName() throws {
        let filter = try f("*.mp3")
        #expect(filter.matches("song.MP3"))
        #expect(!filter.matches("song.mp3.bak"))
        #expect(try f("a?c").matches("abc"))
        #expect(!(try f("a?c").matches("abbc")))
        #expect(try f("*a*b*").matches("xxaxxbxx"))
    }

    @Test func multiplePatternsAndExclusions() throws {
        let filter = try f("*.mp3; *.flac | live*")
        #expect(filter.matches("a.mp3"))
        #expect(filter.matches("b.flac"))
        #expect(!filter.matches("c.wav"))
        #expect(!filter.matches("live set.mp3"))
        let excludeOnly = try f("| *.tmp")
        #expect(excludeOnly.matches("doc.txt"))
        #expect(!excludeOnly.matches("x.TMP"))
    }

    @Test func regexMode() throws {
        #expect(try f("^IMG_\\d{4}", regex: true).matches("img_1234.jpg"))
        #expect(!(try f("^IMG_\\d{4}", regex: true).matches("x_IMG_1234")))
        #expect(throws: NameFilter.ParseError.self) { try NameFilter("(", regex: true) }
    }
}

@MainActor
@Suite struct CommandRegistryTests {
    final class Ctx: WorkspaceContext {
        var activeDirectory: VFSPath? = nil
        var otherDirectory: VFSPath? = nil
        var cursorItem: FileItem? = nil
        var targetItems: [FileItem] = []
        func navigate(to directory: VFSPath) {}
        func announce(_ message: String) {}
    }

    @Test func dispatchesDefaultAndRemappedChords() {
        let registry = CommandRegistry()
        var ran: [String] = []
        registry.register(.init(id: "copy", title: "Copy", defaultKeys: [KeyChord(.function(5))]) { _ in ran.append("copy") })
        registry.register(.init(id: "filter", title: "Filter", defaultKeys: [KeyChord(.character("S"), .command)]) { _ in ran.append("filter") })
        let ctx = Ctx()
        #expect(registry.perform(KeyChord(.function(5)), in: ctx))
        #expect(registry.perform(KeyChord(.character("s"), .command), in: ctx))
        #expect(!registry.perform(KeyChord(.function(6)), in: ctx))

        registry.bind(KeyChord(.function(6)), to: "copy")
        registry.bind(KeyChord(.function(5)), to: nil)
        #expect(registry.perform(KeyChord(.function(6)), in: ctx))
        #expect(!registry.perform(KeyChord(.function(5)), in: ctx))
        #expect(ran == ["copy", "filter", "copy"])
        #expect(registry.chords(for: "copy") == [KeyChord(.function(6))])
    }

    @Test func disabledCommandsDoNotRun() {
        let registry = CommandRegistry()
        registry.register(.init(id: "x", title: "X", defaultKeys: [KeyChord(.enter)], isEnabled: { _ in false }) { _ in Issue.record("ran") })
        #expect(!registry.perform(KeyChord(.enter), in: Ctx()))
    }
}
