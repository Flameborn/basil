import Foundation
import Testing
@testable import BasilCore

@Suite struct ViewOptionsTests {
    func item(_ name: String, dir: Bool = false, mod: TimeInterval = 0) -> FileItem {
        FileItem(path: .local("/t/\(name)"), kind: dir ? .directory : .file, modified: Date(timeIntervalSince1970: mod))
    }

    @Test func foldersMixInWithFilesWhenNotOnTop() {
        let items = [item("old.txt", mod: 1), item("Docs", dir: true, mod: 2), item("new.txt", mod: 3)]
        let mixed = ListSortOrder(key: .modified, ascending: false, foldersFirst: false)
        #expect(ItemSorter.sorted(items, by: mixed).map(\.name) == ["new.txt", "Docs", "old.txt"])
        #expect(ItemSorter.sorted(items, by: ListSortOrder(key: .modified, ascending: false)).map(\.name)
                == ["Docs", "new.txt", "old.txt"])
        let byName = ListSortOrder(key: .name, foldersFirst: false)
        #expect(ItemSorter.sorted(items, by: byName).map(\.name) == ["Docs", "new.txt", "old.txt"])
        // Inserting keeps the mixed order.
        let sorted = ItemSorter.sorted(items, by: mixed)
        let index = ItemSorter.insertionIndex(of: item("Mid", dir: true, mod: 2.5), in: sorted, by: mixed)
        #expect(index == 1)
        // By extension, folders sort like files without one.
        let ext = ListSortOrder(key: .ext, foldersFirst: false)
        #expect(ItemSorter.sorted([item("a.zip"), item("b", dir: true), item("c")], by: ext).map(\.name) == ["b", "c", "a.zip"])
        // Unsorted keeps the listing order.
        #expect(ItemSorter.sorted(items, by: ListSortOrder(key: .unsorted, foldersFirst: false)).map(\.name)
                == ["old.txt", "Docs", "new.txt"])
    }

    @Test func oldSortOrdersAndDateSettingsDecode() throws {
        let order = try JSONDecoder().decode(ListSortOrder.self, from: Data(#"{"key":"size","ascending":false}"#.utf8))
        #expect(order == ListSortOrder(key: .size, ascending: false, foldersFirst: true))
        let date = try JSONDecoder().decode(DateFormatSettings.self, from: Data(#"{"datePattern":"yyyy","time":"hidden"}"#.utf8))
        #expect(date == DateFormatSettings(datePattern: "yyyy", time: .hidden, relative: false))
        let settings = try JSONDecoder().decode(BasilSettings.self, from: Data("{}".utf8))
        #expect(settings.foldersFirst && !settings.showHidden)
    }

    @Test func relativeDates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func text(_ ago: TimeInterval) -> String? { DateFormatSettings.relativeText(now.addingTimeInterval(-ago), now: now) }
        #expect(text(10) == "just now")
        #expect(text(60) == "1 minute ago")
        #expect(text(5 * 60 + 30) == "5 minutes ago")
        #expect(text(3_600) == "1 hour ago")
        #expect(text(23 * 3_600) == "23 hours ago")
        #expect(text(86_400) == "1 day ago")
        #expect(text(6 * 86_400) == "6 days ago")
        #expect(text(7 * 86_400) == nil)
        #expect(text(-3_600) == nil)
        let f = DisplayFormatters(size: SizeFormat(), date: DateFormatSettings(datePattern: "yyyy-MM-dd", time: .hidden, relative: true))
        #expect(f.date(now.addingTimeInterval(-120), now: now) == "2 minutes ago")
        #expect(f.date(Date(timeIntervalSince1970: 0), now: now).hasPrefix("19"))
        let plain = DisplayFormatters(size: SizeFormat(), date: DateFormatSettings(datePattern: "yyyy", time: .hidden))
        #expect(plain.date(now.addingTimeInterval(-120), now: now) == "1970")
    }

    @Test func optionsEqualToTheGlobalSettingsAreDropped() {
        var global = BasilSettings()
        global.foldersFirst = false
        let view = ListView.full
        var options = PaneViewOptions(columns: view.columns, foldersFirst: false, showHidden: true,
                                      date: global.date, size: SizeFormat(unit: .bytes))
        options = options.normalized(global: global, view: view)
        #expect(options == PaneViewOptions(showHidden: true, size: SizeFormat(unit: .bytes)))
        #expect(!options.isEmpty)
        #expect(options.formatters(global: global).size.string(2048) == "2,048 B")
        #expect(PaneViewOptions(showHidden: false).normalized(global: global, view: view).isEmpty)
        let decoded = try? JSONDecoder().decode(PaneViewOptions.self, from: Data("{}".utf8))
        #expect(decoded?.isEmpty == true)
    }
}
