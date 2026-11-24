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
        #expect(KeyChord(.numpad("-")) != KeyChord(.character("-")))
        #expect(KeyChord(.numpad("-")).description == "Numpad Minus")

        registry.bind(KeyChord(.function(6)), to: "copy")
        registry.bind(KeyChord(.function(5)), to: nil)
        #expect(registry.perform(KeyChord(.function(6)), in: ctx))
        #expect(!registry.perform(KeyChord(.function(5)), in: ctx))
        #expect(ran == ["copy", "filter", "copy"])
        #expect(registry.chords(for: "copy") == [KeyChord(.function(6))])
    }

    @Test func assignRemoveResetAndSaveKeys() throws {
        let registry = CommandRegistry()
        registry.register(.init(id: "name", title: "Copy Name", defaultKeys: [KeyChord(.character("c"), .command)]) { _ in })
        registry.register(.init(id: "path", title: "Copy Path", defaultKeys: [KeyChord(.character("c"), [.command, .option])]) { _ in })
        var changes = 0
        registry.onKeymapChange = { changes += 1 }
        let cmdC = KeyChord(.character("c"), .command), cmdOptC = KeyChord(.character("c"), [.command, .option])
        let f9 = KeyChord(.function(9))

        // Taking another command's key warns first, then moves it.
        #expect(registry.command(using: cmdC, otherThan: "path")?.title == "Copy Name")
        #expect(registry.command(using: cmdC, otherThan: "name") == nil)
        registry.assign(cmdC, to: "path")
        registry.assign(f9, to: "path")
        #expect(registry.chords(for: "name").isEmpty)
        #expect(Set(registry.chords(for: "path")) == [cmdC, cmdOptC, f9])
        #expect(registry.hasChangedKeys("name") && registry.hasChangedKeys("path"))

        // Removing a default key leaves it unbound; removing an added key forgets it.
        registry.removeKey(cmdOptC, from: "path")
        registry.removeKey(f9, from: "path")
        #expect(registry.chords(for: "path") == [cmdC])
        #expect(registry.commandID(for: cmdOptC) == nil && registry.commandID(for: f9) == nil)

        // Saved and restored.
        let saved = try JSONDecoder().decode([KeyBindingOverride].self, from: JSONEncoder().encode(registry.keyOverrides))
        let restored = CommandRegistry()
        restored.register(.init(id: "name", title: "Copy Name", defaultKeys: [cmdC]) { _ in })
        restored.register(.init(id: "path", title: "Copy Path", defaultKeys: [cmdOptC]) { _ in })
        restored.keyOverrides = saved
        #expect(restored.chords(for: "path") == [cmdC] && restored.chords(for: "name").isEmpty)

        // Reset takes the default keys back; reset all restores everything.
        registry.resetKeys(of: "name")
        #expect(registry.chords(for: "name") == [cmdC])
        #expect(registry.chords(for: "path").isEmpty)
        registry.resetAllKeys()
        #expect(registry.chords(for: "path") == [cmdOptC] && registry.keyOverrides.isEmpty)
        #expect(changes == 6)
    }

    @Test func disabledCommandsDoNotRun() {
        let registry = CommandRegistry()
        registry.register(.init(id: "x", title: "X", defaultKeys: [KeyChord(.enter)], isEnabled: { _ in false }) { _ in Issue.record("ran") })
        #expect(!registry.perform(KeyChord(.enter), in: Ctx()))
    }
}

@Suite struct SizeFormatTests {
    @Test func dynamicPicksLargestFittingUnit() {
        let f = SizeFormat(unit: .dynamic, base: 1024)
        #expect(f.string(0) == "0 B")
        #expect(f.string(1023) == "1,023 B")
        #expect(f.string(1024) == "1 KB")
        #expect(f.string(1536) == "1.5 KB")
        #expect(f.string(5 * 1024 * 1024) == "5 MB")
        #expect(f.string(900 * 1024 * 1024) == "900 MB")
        #expect(f.string(Int64(2.5 * 1024 * 1024 * 1024)) == "2.5 GB")
    }

    @Test func fixedUnitsAndDecimalBase() {
        #expect(SizeFormat(unit: .bytes).string(1_234_567) == "1,234,567 B")
        #expect(SizeFormat(unit: .kilobytes).string(10) == "0.1 KB")
        #expect(SizeFormat(unit: .megabytes).string(150 * 1024 * 1024) == "150 MB")
        #expect(SizeFormat(unit: .dynamic, base: 1000).string(1_500_000) == "1.5 MB")
        #expect(SizeFormat(unit: .gigabytes, base: 1000).string(250_000_000) == "0.3 GB")
    }
}

@Suite struct DateFormatTests {
    let locale = Locale(identifier: "en_US_POSIX")
    let date = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-18 ... UTC

    @Test func patternCombinesDateAndTime() {
        #expect(DateFormatSettings(datePattern: "yyyy-MM-dd", time: .twentyFourHour).pattern(locale: locale) == "yyyy-MM-dd HH:mm")
        #expect(DateFormatSettings(datePattern: "MM-dd-yyyy", time: .twelveHour).pattern(locale: locale) == "MM-dd-yyyy h:mm a")
        #expect(DateFormatSettings(datePattern: "dd.MM.yyyy", time: .hidden).pattern(locale: locale) == "dd.MM.yyyy")
        #expect(!DateFormatSettings().pattern(locale: locale).isEmpty)
    }

    @Test func formattersUseSettings() {
        let f = DisplayFormatters(size: SizeFormat(), date: DateFormatSettings(datePattern: "yyyy-MM-dd", time: .hidden), locale: locale)
        #expect(f.date(date).count == 10)
        #expect(f.date(nil) == "")
    }
}

@Suite struct ColumnTests {
    let ctx = ColumnDefinition.Context(formatters: DisplayFormatters(size: SizeFormat(), date: DateFormatSettings()))

    @Test func nameAlwaysIncludesTheExtension() throws {
        let file = FileItem(path: .local("/t/song.mp3"), kind: .file, size: 1)
        let name = try #require(ColumnCatalog.definition(.name))
        #expect(name.text(file, ctx) == "song.mp3")
        let ext = try #require(ColumnCatalog.definition(.ext))
        #expect(ext.text(file, ctx) == "mp3")
        // Ext is optional: Full lists it, hidden.
        #expect(ListView.full.columns.first { $0.id == .ext }?.isVisible == false)
    }

    @Test func savedFullViewLosesItsExtColumnOnce() throws {
        var old = BasilSettings()
        let extIndex = try #require(old.views[1].columns.firstIndex { $0.id == .ext })
        old.views[1].columns[extIndex].isVisible = true
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "viewsVersion")
        let migrated = try JSONDecoder().decode(BasilSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated.view(id: "full").columns.first { $0.id == .ext }?.isVisible == false)
        #expect(migrated.viewsVersion == BasilSettings.currentViewsVersion)
        // Shown again by the user later, it stays.
        var current = migrated
        current.views[1].columns[extIndex].isVisible = true
        let again = try JSONDecoder().decode(BasilSettings.self, from: JSONEncoder().encode(current))
        #expect(again.view(id: "full").columns.first { $0.id == .ext }?.isVisible == true)
    }

    @Test func savedFullViewGetsTheGitColumnAfterNameOnce() throws {
        var old = BasilSettings()
        old.views[1].columns.removeAll { $0.id == .git }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["viewsVersion"] = 2
        let migrated = try JSONDecoder().decode(BasilSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated.view(id: "full").columns.map(\.id).prefix(2) == [.name, .git])
        // Removed by the user later, it stays away.
        var current = migrated
        current.views[1].columns.removeAll { $0.id == .git }
        let again = try JSONDecoder().decode(BasilSettings.self, from: JSONEncoder().encode(current))
        #expect(!again.view(id: "full").columns.contains { $0.id == .git })
        #expect(ColumnCatalog.definition(.git)?.onlyWhenAnnotated == true)
    }

    @Test func directorySizeShowsDirAndSpeaksDir() throws {
        let dir = FileItem(path: .local("/t/test"), kind: .directory)
        let size = try #require(ColumnCatalog.definition(.size))
        #expect(size.text(dir, ctx) == "<DIR>")
        #expect(size.spoken(dir, ctx) == "dir")
    }

    @Test func nameColumnCannotBeHidden() {
        var view = ListView.full
        view.columns[0].isVisible = false
        #expect(view.visibleColumns.first?.id == .name)
    }
}

@MainActor
@Suite struct SettingsTests {
    @Test func persistsAndToleratesMissingKeys() throws {
        // A suite named by a path keeps its domain in that file (nothing in ~/Library/Preferences).
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("basil-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = try #require(UserDefaults(suiteName: folder.appendingPathComponent("settings").path))
        let store = SettingsStore(defaults: defaults)
        var changed = 0
        store.onChange { _ in changed += 1 }
        store.settings.size = SizeFormat(unit: .megabytes, base: 1000)
        store.settings.bookmarks.append(Bookmark(name: "Tmp", path: .local("/tmp")))
        #expect(changed == 2)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings == store.settings)

        let partial = try JSONDecoder().decode(BasilSettings.self, from: Data(#"{"goToRootOnVolumeSwitch":true}"#.utf8))
        #expect(partial.goToRootOnVolumeSwitch)
        #expect(partial.views.map(\.id) == ["brief", "full"])
    }
}

@MainActor
@Suite struct FeedbackTests {
    let copy = OperationKindInfo(kind: .copy, name: "Move", pastTense: "moved")

    @Test func rendersDefaultTexts() {
        let f = FeedbackSettings()
        let done = FeedbackValues(kind: copy, title: "Move 2 items", done: 2, total: 2)
        #expect(FeedbackText.render(f.feedback(for: .move, .finished).text, done) == "Move complete, 2 items moved")
        let failed = FeedbackValues(kind: copy, title: "", done: 1, total: 3, reason: "Permission denied.")
        #expect(FeedbackText.render(f.feedback(for: .move, .failed).text, failed) == "Move failed, 1 of 3 items moved. Permission denied")
        let noReason = FeedbackValues(kind: copy, title: "", done: 0, total: 1)
        #expect(FeedbackText.render("{operation} failed. {reason}", noReason) == "Move failed")
    }

    @Test func overridesReplaceDefaultsAndDecodeTolerantly() throws {
        var f = FeedbackSettings()
        let custom = EventFeedback(sound: .file("/tmp/a.aiff"), speak: false, text: "x")
        f.setOverride(custom, for: .delete, .finished)
        #expect(f.feedback(for: .delete, .finished) == custom)
        #expect(f.feedback(for: .copy, .finished).sound == .system("Glass"))
        f.setOverride(nil, for: .delete, .finished)
        #expect(f.overrides.isEmpty)

        let partial = try JSONDecoder().decode(FeedbackSettings.self, from: Data(#"{"defaults":{}}"#.utf8))
        #expect(partial.feedback(for: .copy, .failed).sound == .system("Basso"))
        var s = BasilSettings()
        s.feedback = f
        s.secureCopy = true
        let round = try JSONDecoder().decode(BasilSettings.self, from: JSONEncoder().encode(s))
        #expect(round == s)
        #expect(BasilSettings().secureCopy == false)
    }
}

@Suite struct MultiRenameTests {
    func item(_ name: String, dir: Bool = false, modified: Date? = nil) -> FileItem {
        FileItem(path: .local("/music/album/\(name)"), kind: dir ? .directory : .file, modified: modified)
    }

    func rename(_ name: String, _ configure: (inout RenameRule) -> Void, index: Int = 0) -> String? {
        var rule = RenameRule()
        configure(&rule)
        return MultiRename.newName(for: RenameInput(item: item(name), index: index), rule: rule)
    }

    @Test func defaultRuleKeepsTheName() {
        #expect(rename("song.mp3") { _ in } == "song.mp3")
        #expect(rename("README") { _ in } == "README")
        #expect(rename(".profile") { _ in } == ".profile")
        #expect(rename("a.tar.gz") { _ in } == "a.tar.gz")
    }

    @Test func nameAndExtensionRanges() {
        #expect(rename("abcdefgh.txt") { $0.nameMask = "[N3]" } == "c.txt")
        #expect(rename("abcdefgh.txt") { $0.nameMask = "[N2-5]" } == "bcde.txt")
        #expect(rename("abcdefgh.txt") { $0.nameMask = "[N6-]" } == "fgh.txt")
        #expect(rename("abcdefgh.txt") { $0.nameMask = "[N2,3]" } == "bcd.txt")
        #expect(rename("abcdefgh.txt") { $0.nameMask = "[N-3-]" } == "fgh.txt")
        #expect(rename("abcdefgh.txt") { $0.nameMask = "[N2--2]" } == "bcdefg.txt")
        #expect(rename("abc.txt") { $0.nameMask = "[N2-10]" } == "bc.txt")
        #expect(MultiRename.newName(for: RenameInput(item: item("My.Folder", dir: true), index: 0), rule: RenameRule()) == "My.Folder")
        #expect(rename("abc.txt") { $0.nameMask = "[N9]" } == ".txt")
        #expect(rename("abc.jpeg") { $0.extensionMask = "[E1-3]" } == "abc.jpe")
        #expect(rename("abc.txt") { $0.extensionMask = "" } == "abc")
        #expect(rename("abc") { $0.extensionMask = "bak" } == "abc.bak")
    }

    @Test func folderNamesCounterLiteralsAndUnknown() {
        #expect(rename("x.mp3") { $0.nameMask = "[G] - [P] - [N]" } == "music - album - x.mp3")
        #expect(rename("x.mp3", { $0.nameMask = "[C] [N]"; $0.counterStart = 1; $0.counterDigits = 2 }, index: 4) == "05 x.mp3")
        #expect(rename("x.mp3", { $0.nameMask = "[C10+5:3]" }, index: 2) == "020.mp3")
        #expect(rename("x.mp3") { $0.nameMask = "[[N]] [Q] [N" } == "[N] [Q] [N.mp3")
    }

    @Test func datePlaceholders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC
        var rule = RenameRule()
        rule.nameMask = "[Y]-[M]-[D] [h].[m].[s] [y] [N]"
        let name = MultiRename.newName(for: RenameInput(item: item("a.jpg", modified: date), index: 0), rule: rule, calendar: calendar)
        #expect(name == "2023-11-14 22.13.20 23 a.jpg")
    }

    @Test func searchReplaceAndCase() {
        #expect(rename("My Song.MP3") { $0.search = "song"; $0.replace = "Track" } == "My Track.MP3")
        #expect(rename("My Song.MP3") { $0.search = "song"; $0.replace = "x"; $0.caseSensitive = true } == "My Song.MP3")
        #expect(rename("track 07.mp3") { $0.search = " (\\d+)\\."; $0.replace = " #$1."; $0.regex = true } == "track #07.mp3")
        #expect(rename("a.mp3") { $0.search = "("; $0.regex = true } == nil)
        #expect(rename("My Song.MP3") { $0.nameCase = .lower } == "my song.mp3")
        #expect(rename("my song.mp3") { $0.nameCase = .upper } == "MY SONG.MP3")
        #expect(rename("mY sONG.mp3") { $0.nameCase = .firstUpper } == "My song.mp3")
        #expect(rename("the beatles - let it be.mp3") { $0.nameCase = .wordsUpper } == "The Beatles - Let It Be.Mp3")
    }

    @Test func pluginPlaceholder() {
        MultiRenamePlaceholders.register(.init(name: "test.len", title: "Name length") { "\($0.item.name.count)" })
        #expect(rename("abc.txt") { $0.nameMask = "[N]-[=test.len]" } == "abc-7.txt")
        #expect(rename("abc.txt") { $0.nameMask = "[=missing]" } == "[=missing].txt")
    }

    @Test func previewChecksNamesPerFolder() {
        // Search results: the same new name in two folders is fine; a clash counts only in its own folder.
        let a = FileItem(path: .local("/one/a.txt"), kind: .file), b = FileItem(path: .local("/two/b.txt"), kind: .file)
        var rule = RenameRule()
        rule.nameMask = "x"
        let entries = MultiRenamePreview.make(items: [a, b], rule: rule,
                                              existingNamesByFolder: [.local("/one"): ["a.txt"], .local("/two"): ["b.txt", "y.txt"]])
        #expect(entries.allSatisfy { $0.problem == nil })
        rule.nameMask = "y"
        let clash = MultiRenamePreview.make(items: [a, b], rule: rule,
                                            existingNamesByFolder: [.local("/one"): ["a.txt"], .local("/two"): ["b.txt", "y.txt"]])
        #expect(clash[0].problem == nil)
        #expect(clash[1].problem == .exists)
    }

    @Test func previewFindsProblems() {
        let items = ["a.txt", "b.txt", "c.txt"].map { item($0) }
        var rule = RenameRule()
        rule.nameMask = "x"
        let dup = MultiRenamePreview.make(items: items, rule: rule, existingNames: ["a.txt", "b.txt", "c.txt"])
        #expect(dup.allSatisfy { $0.problem == .duplicate })

        rule.nameMask = "[N]2"
        let exists = MultiRenamePreview.make(items: [items[0]], rule: rule, existingNames: ["a.txt", "A2.TXT"])
        #expect(exists[0].problem == .exists)

        // A swap inside the batch is fine (the operation goes through temporary names).
        rule.nameMask = "[N]"
        rule.search = "a"; rule.replace = "b"
        let ok = MultiRenamePreview.make(items: [item("a.txt")], rule: rule, existingNames: ["a.txt", "b.txt"])
        #expect(ok[0].problem == .exists) // b.txt is not part of the batch
        let alone = MultiRenamePreview.make(items: [item("a.txt")], rule: rule, existingNames: ["a.txt"])
        #expect(alone[0].problem == nil && alone[0].newName == "b.txt")
        // A swap inside the batch is fine (the operation goes through temporary names).
        rule.search = "^(a|b)"; rule.replace = "x"; rule.regex = true
        var swap = RenameRule()
        swap.nameMask = "[N]"
        let pair = MultiRenamePreview.make(items: [item("a.txt"), item("b.txt")], rule: swap, existingNames: ["a.txt", "b.txt"])
        #expect(pair.allSatisfy { $0.problem == nil })

        rule = RenameRule()
        rule.nameMask = "a/b"
        #expect(MultiRenamePreview.make(items: [items[0]], rule: rule, existingNames: [])[0].problem == .invalidCharacter)
        rule.nameMask = ""; rule.extensionMask = ""
        #expect(MultiRenamePreview.make(items: [items[0]], rule: rule, existingNames: [])[0].problem == .empty)
    }

    @Test func caseOnlyRenameIsNotAConflict() {
        var rule = RenameRule()
        rule.nameCase = .upper
        let entries = MultiRenamePreview.make(items: [item("a.txt")], rule: rule, existingNames: ["a.txt"])
        #expect(entries[0].problem == nil && entries[0].newName == "A.TXT")
    }

    @Test func rulesDecodeWithMissingKeys() throws {
        let rule = try JSONDecoder().decode(RenameRule.self, from: Data(#"{"nameMask":"[C]"}"#.utf8))
        #expect(rule.nameMask == "[C]" && rule.extensionMask == "[E]" && rule.counterDigits == 1)
    }
}

@Suite struct EditorRuleTests {
    @Test func firstMatchingRuleWithAppsWins() {
        let rules = [
            EditorRule(patterns: "*.md", apps: []),
            EditorRule(patterns: "*.txt;*.md", apps: ["/Applications/A.app", "/Applications/B.app"]),
            EditorRule(patterns: "*.md", apps: ["/Applications/C.app"]),
        ]
        #expect(EditorRules.apps(for: "Notes.MD", in: rules) == ["/Applications/A.app", "/Applications/B.app"])
        #expect(EditorRules.apps(for: "a.swift", in: rules) == nil)
    }

    @Test func exclusionsAndEmptyPatterns() {
        #expect(EditorRule(patterns: "*.txt | secret*", apps: ["x"]).matches("secret.txt") == false)
        #expect(EditorRule(patterns: "*.txt | secret*", apps: ["x"]).matches("open.txt"))
        #expect(EditorRule(patterns: "  ", apps: ["x"]).matches("a.txt") == false)
    }

    @Test func settingsDecodeWithoutEditorRules() throws {
        let s = try JSONDecoder().decode(BasilSettings.self, from: Data("{}".utf8))
        #expect(s.editorRules.isEmpty && s.terminalID == "terminal" && s.terminalCommand.isEmpty)
    }
}
