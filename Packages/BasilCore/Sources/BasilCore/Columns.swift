import Foundation

/// Identifies a list column. Built-in IDs are below; plugins may register more.
public struct ColumnID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let name: ColumnID = "name"
    public static let ext: ColumnID = "ext"
    public static let size: ColumnID = "size"
    public static let modified: ColumnID = "modified"
    public static let created: ColumnID = "created"
    public static let attributes: ColumnID = "attributes"
    public static let kind: ColumnID = "kind"
    /// Git status, filled by the Git annotator inside repositories.
    public static let git: ColumnID = "git"
}

/// Text a `ColumnAnnotator` (BasilVFS) supplies for the items of one folder, for a column whose
/// value is not part of `FileItem` (Git status).
public struct ColumnAnnotation: Sendable, Equatable {
    /// Text by item name; items without one are left out.
    public var byName: [String: String]
    /// The same text for every item (all of an ignored folder), when set.
    public var everything: String?
    /// Local folders whose changes make the answer stale (a repository's .git folder): the pane
    /// watches them while it shows this folder and asks again when they change.
    public var watch: [String]
    /// Facts about the folder as a whole, for other parts of the window (Git: "branch").
    public var details: [String: String]

    public init(byName: [String: String] = [:], everything: String? = nil, watch: [String] = [],
                details: [String: String] = [:]) {
        self.byName = byName
        self.everything = everything
        self.watch = watch
        self.details = details
    }

    public func text(for name: String) -> String? { everything ?? byName[name] }
}

/// How one column of a view is shown.
public struct ColumnSpec: Codable, Hashable, Sendable {
    public var id: ColumnID
    public var isVisible: Bool
    public var width: Double

    public init(_ id: ColumnID, visible: Bool = true, width: Double? = nil) {
        self.id = id
        self.isVisible = visible
        self.width = width ?? ColumnCatalog.definition(id)?.defaultWidth ?? 100
    }
}

/// A named list view (Total Commander "Brief", "Full", or a custom columns view).
public struct ListView: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Ordered; hidden columns stay in the list so they keep their position when re-enabled.
    public var columns: [ColumnSpec]
    public var isBuiltin: Bool

    public init(id: String, name: String, columns: [ColumnSpec], isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.columns = columns
        self.isBuiltin = isBuiltin
    }

    public var visibleColumns: [ColumnSpec] {
        let visible = columns.filter(\.isVisible)
        // The name column can't be hidden: a list without names is useless.
        return visible.contains { $0.id == .name } ? visible : [ColumnSpec(.name)] + visible
    }

    public static let brief = ListView(id: "brief", name: "Brief", columns: [
        ColumnSpec(.name, width: 360),
    ], isBuiltin: true)

    public static let full = ListView(id: "full", name: "Full", columns: [
        ColumnSpec(.name), ColumnSpec(.git), ColumnSpec(.ext, visible: false), ColumnSpec(.size), ColumnSpec(.modified), ColumnSpec(.attributes),
        ColumnSpec(.created, visible: false), ColumnSpec(.kind, visible: false),
    ], isBuiltin: true)

    public static let defaults: [ListView] = [.brief, .full]
}

/// What a column shows. Text and spoken text are computed per visible row only.
public struct ColumnDefinition: Sendable {
    public enum Alignment: Sendable { case leading, trailing }

    /// Context a column needs to render a row.
    public struct Context: Sendable {
        public let formatters: DisplayFormatters
        /// What annotators supplied for the pane's folder, by column.
        public let annotations: [ColumnID: ColumnAnnotation]
        public init(formatters: DisplayFormatters, annotations: [ColumnID: ColumnAnnotation] = [:]) {
            self.formatters = formatters
            self.annotations = annotations
        }

        public func annotation(_ column: ColumnID, for item: FileItem) -> String? {
            annotations[column]?.text(for: item.name)
        }
    }

    public let id: ColumnID
    public let title: String
    public let defaultWidth: Double
    public let alignment: Alignment
    public let sortKey: SortKey?
    public let text: @Sendable (FileItem, Context) -> String
    /// What VoiceOver reads; nil means the visible text. "" means silent.
    public let spoken: @Sendable (FileItem, Context) -> String?
    /// Shown only in folders where an annotator supplied this column (the Git column outside a
    /// repository is left out, though the view lists it).
    public let onlyWhenAnnotated: Bool

    public init(id: ColumnID, title: String, defaultWidth: Double, alignment: Alignment = .leading,
                sortKey: SortKey?, onlyWhenAnnotated: Bool = false, text: @escaping @Sendable (FileItem, Context) -> String,
                spoken: @escaping @Sendable (FileItem, Context) -> String? = { _, _ in nil }) {
        self.id = id
        self.onlyWhenAnnotated = onlyWhenAnnotated
        self.title = title
        self.defaultWidth = defaultWidth
        self.alignment = alignment
        self.sortKey = sortKey
        self.text = text
        self.spoken = spoken
    }
}

/// All known columns. Built-ins are registered here; plugins add more with `register`.
public enum ColumnCatalog {
    private static let storage = ColumnStorage()

    public static func definition(_ id: ColumnID) -> ColumnDefinition? { storage.get(id) }
    public static var all: [ColumnDefinition] { storage.all() }
    public static func register(_ definition: ColumnDefinition) { storage.set(definition) }
}

private final class ColumnStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [ColumnID] = []
    private var defs: [ColumnID: ColumnDefinition] = [:]

    init() {
        for d in ColumnStorage.builtins { set(d) }
    }

    func get(_ id: ColumnID) -> ColumnDefinition? { lock.withLock { defs[id] } }
    func all() -> [ColumnDefinition] { lock.withLock { order.compactMap { defs[$0] } } }
    func set(_ d: ColumnDefinition) {
        lock.withLock {
            if defs[d.id] == nil { order.append(d.id) }
            defs[d.id] = d
        }
    }

    static let builtins: [ColumnDefinition] = [
        // The full name, extension included, also in views that show the Ext column.
        ColumnDefinition(id: .name, title: "Name", defaultWidth: 300, sortKey: .name) { item, _ in item.name },
        ColumnDefinition(id: .ext, title: "Ext", defaultWidth: 52, sortKey: .ext) { item, _ in
            item.isDirectoryLike ? "" : item.nameAndExtension.ext
        },
        ColumnDefinition(id: .size, title: "Size", defaultWidth: 96, alignment: .trailing, sortKey: .size, text: { item, ctx in
            // A folder shows its size once it has been calculated (Cmd+Shift+S), like Total Commander.
            if item.isDirectoryLike, item.size == nil { return "<DIR>" }
            return item.size.map(ctx.formatters.size.string) ?? ""
        }, spoken: { item, ctx in
            guard item.isDirectoryLike else { return nil }
            return item.size.map { "dir, \(ctx.formatters.size.string($0))" } ?? "dir"
        }),
        // "Modified", "Staged", "Untracked", "Changes" (a folder with changes inside); empty when clean.
        ColumnDefinition(id: .git, title: "Git", defaultWidth: 110, sortKey: nil, onlyWhenAnnotated: true) { item, ctx in
            ctx.annotation(.git, for: item) ?? ""
        },
        ColumnDefinition(id: .modified, title: "Date", defaultWidth: 128, sortKey: .modified) { item, ctx in
            ctx.formatters.date(item.modified)
        },
        ColumnDefinition(id: .created, title: "Created", defaultWidth: 128, sortKey: .created) { item, ctx in
            ctx.formatters.date(item.created)
        },
        ColumnDefinition(id: .attributes, title: "Attr", defaultWidth: 82, sortKey: nil) { item, _ in
            Attributes.string(item)
        },
        ColumnDefinition(id: .kind, title: "Kind", defaultWidth: 90, sortKey: nil) { item, _ in
            switch item.kind {
            case .directory: "Folder"
            case .symlink(.directory): "Link to folder"
            case .symlink(.broken): "Broken link"
            case .symlink: "Link"
            case .file: "File"
            case .other: "Special"
            }
        },
    ]
}

/// "drwxr-xr-x"-style attribute string.
public enum Attributes {
    public static func string(_ item: FileItem) -> String {
        let type: Character = switch item.kind {
        case .directory: "d"
        case .symlink: "l"
        case .file: "-"
        case .other: "?"
        }
        guard let p = item.permissions else { return String(type) }
        var s = String(type)
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (p >> UInt16(shift)) & 0o7
            s += bits & 0o4 != 0 ? "r" : "-"
            s += bits & 0o2 != 0 ? "w" : "-"
            s += bits & 0o1 != 0 ? "x" : "-"
        }
        return s
    }
}
