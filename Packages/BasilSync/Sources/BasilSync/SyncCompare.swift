import BasilCore
import BasilVFS
import Foundation

/// The comparison's settings (remembered between uses).
public struct SyncOptions: Codable, Sendable, Equatable {
    /// Compare subfolders too (otherwise only the files of the two folders).
    public var subfolders = true
    /// Files of the same size are read on both sides and compared.
    public var byContent = false
    /// Dates this many seconds apart count as equal (they are compared in whole seconds).
    public var toleranceSeconds = 0
    /// Dates exactly one hour apart (within the tolerance) count as equal: daylight saving time on FAT disks.
    public var ignoreHour = false
    /// The right side becomes like the left: files only on the right are deleted, files newer on
    /// the right are left alone.
    public var asymmetric = false
    /// Files to compare, in quick-filter syntax ("*.jpg;*.png | tmp*"); empty: all.
    public var filter = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SyncOptions()
        subfolders = try c.decodeIfPresent(Bool.self, forKey: .subfolders) ?? d.subfolders
        byContent = try c.decodeIfPresent(Bool.self, forKey: .byContent) ?? d.byContent
        toleranceSeconds = try c.decodeIfPresent(Int.self, forKey: .toleranceSeconds) ?? d.toleranceSeconds
        ignoreHour = try c.decodeIfPresent(Bool.self, forKey: .ignoreHour) ?? d.ignoreHour
        asymmetric = try c.decodeIfPresent(Bool.self, forKey: .asymmetric) ?? d.asymmetric
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? d.filter
    }
}

/// How the two sides of one entry compare.
public enum SyncState: Sendable, Equatable {
    case equal
    case leftNewer
    case rightNewer
    /// Different, but the dates do not say which is newer (or one is a folder, the other a file).
    case different
    case leftOnly
    case rightOnly
}

/// What synchronizing does with an entry.
public enum SyncAction: Sendable, Equatable {
    case none
    case copyRight
    case copyLeft
    /// Asymmetric mode: delete the item on the right.
    case deleteRight
}

/// One file (or a folder found on one side only) of a comparison.
public struct SyncEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    /// The path below the compared folders ("Music/Live/show.mp3").
    public let relative: String
    public let left: FileItem?
    public let right: FileItem?
    public let state: SyncState
    /// What comparing proposed.
    public let proposed: SyncAction
    /// What the user chose (starts as `proposed`).
    public var action: SyncAction
    /// A folder on one side only, taken whole: its files and bytes.
    public let folderFiles: Int?

    public var isFolder: Bool { (left ?? right)?.isDirectoryLike == true && folderFiles != nil }
    public var name: String { (relative as NSString).lastPathComponent }
    public var folder: String { (relative as NSString).deletingLastPathComponent }

    /// Bytes a copy moves.
    public var copyBytes: Int64 {
        switch action {
        case .copyRight: left?.size ?? 0
        case .copyLeft: right?.size ?? 0
        default: 0
        }
    }

    /// Which actions make sense: nothing to copy from a side that has no item.
    public func allows(_ action: SyncAction) -> Bool {
        switch action {
        case .none: true
        case .copyRight: left.map { l in right.map { $0.isDirectoryLike == l.isDirectoryLike } ?? true } ?? false
        case .copyLeft: right.map { r in left.map { $0.isDirectoryLike == r.isDirectoryLike } ?? true } ?? false
        case .deleteRight: right != nil
        }
    }
}

/// Compares two folder trees by name, size and date (and content when asked), like Total
/// Commander's Synchronize directories. Stateless: an item on one side only is offered as a
/// copy, never taken for a deletion (except in asymmetric mode).
public enum SyncComparer {
    /// - Parameter progress: the number of entries so far and the folder being compared.
    public static func compare(left: VFSPath, right: VFSPath, options: SyncOptions, registry: ProviderRegistry,
                               progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }) async throws -> [SyncEntry] {
        let filter = options.filter.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try NameFilter(options.filter)
        var walker = Walker(options: options, filter: filter, registry: registry, progress: progress)
        try await walker.folder("", left, right)
        return walker.entries
    }

    /// The key two names are matched by: macOS disks ignore case and Unicode normalisation.
    static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    struct Walker {
        let options: SyncOptions
        let filter: NameFilter?
        let registry: ProviderRegistry
        let progress: @Sendable (Int, String) -> Void
        var entries: [SyncEntry] = []

        mutating func add(_ relative: String, _ left: FileItem?, _ right: FileItem?, _ state: SyncState, folderFiles: Int? = nil) {
            let proposed = SyncComparer.proposal(state, asymmetric: options.asymmetric)
            entries.append(SyncEntry(id: entries.count, relative: relative, left: left, right: right, state: state,
                                     proposed: proposed, action: proposed, folderFiles: folderFiles))
        }

        func list(_ folder: VFSPath?) async throws -> [FileItem] {
            guard let folder else { return [] }
            var items: [FileItem] = []
            for try await batch in try registry.provider(for: folder.location).list(folder) {
                try Task.checkCancellation()
                items += batch
            }
            return items
        }

        func wanted(_ item: FileItem) -> Bool {
            if item.isDirectoryLike { return true }
            return filter?.matches(item.name) ?? true
        }

        mutating func folder(_ relative: String, _ left: VFSPath?, _ right: VFSPath?) async throws {
            try Task.checkCancellation()
            progress(entries.count, relative)
            let leftItems = try await list(left).filter(wanted)
            let rightItems = try await list(right).filter(wanted)
            var rightByKey: [String: FileItem] = [:]
            for item in rightItems { rightByKey[SyncComparer.key(item.name)] = item }
            var seen: Set<String> = []
            var pairs: [(FileItem?, FileItem?)] = []
            for item in leftItems {
                let key = SyncComparer.key(item.name)
                seen.insert(key)
                pairs.append((item, rightByKey[key]))
            }
            for item in rightItems where !seen.contains(SyncComparer.key(item.name)) { pairs.append((nil, item)) }
            pairs.sort { a, b in
                let x = (a.0 ?? a.1)!, y = (b.0 ?? b.1)!
                if x.isDirectoryLike != y.isDirectoryLike { return !x.isDirectoryLike }
                return x.name.localizedStandardCompare(y.name) == .orderedAscending
            }
            for (l, r) in pairs {
                let name = (l ?? r)!.name
                let path = relative.isEmpty ? name : relative + "/" + name
                let isFolder = { (item: FileItem?) in item.map { $0.kind == .directory } ?? false }
                switch (l, r) {
                case let (l?, r?) where isFolder(l) && isFolder(r):
                    if options.subfolders { try await folder(path, l.path, r.path) }
                case let (l?, r?) where isFolder(l) != isFolder(r):
                    if options.subfolders { add(path, l, r, .different) }
                case let (l?, r?):
                    add(path, l, r, try await SyncComparer.state(l, r, options: options, registry: registry))
                case let (l?, nil):
                    try await oneSided(path, l, left: true)
                case let (nil, r?):
                    try await oneSided(path, r, left: false)
                default:
                    break
                }
            }
        }

        /// An item on one side only: a file, or a folder taken whole (walked file by file when a
        /// filter limits what is compared).
        mutating func oneSided(_ path: String, _ item: FileItem, left: Bool) async throws {
            let state: SyncState = left ? .leftOnly : .rightOnly
            guard item.kind == .directory else {
                add(path, left ? item : nil, left ? nil : item, state)
                return
            }
            guard options.subfolders else { return }
            if filter != nil {
                let before = entries.count
                try await folder(path, left ? item.path : nil, left ? nil : item.path)
                if entries.count > before { return }
            }
            let totals = try await registry.provider(for: item.path.location).totals(of: item.path)
            let whole = item.withSize(totals.bytes)
            add(path, left ? whole : nil, left ? nil : whole, state, folderFiles: totals.files)
        }
    }

    /// Size, then dates (newer wins), then content when asked.
    static func state(_ l: FileItem, _ r: FileItem, options: SyncOptions, registry: ProviderRegistry) async throws -> SyncState {
        let sameSize = l.size == r.size
        let dates = dateOrder(l.modified, r.modified, options: options)
        if sameSize, options.byContent {
            if try await sameContent(l.path, r.path, registry: registry) { return .equal }
            return dates ?? .different
        }
        if sameSize, dates == nil, l.modified != nil, r.modified != nil { return .equal }
        return dates ?? .different
    }

    /// nil when the dates count as equal (or one is unknown); else which side is newer.
    static func dateOrder(_ l: Date?, _ r: Date?, options: SyncOptions) -> SyncState? {
        guard let l, let r else { return nil }
        let a = Int64(l.timeIntervalSince1970.rounded(.down)), b = Int64(r.timeIntervalSince1970.rounded(.down))
        let difference = a - b
        let tolerance = Int64(max(0, options.toleranceSeconds))
        if abs(difference) <= tolerance { return nil }
        if options.ignoreHour, abs(abs(difference) - 3600) <= tolerance { return nil }
        return difference > 0 ? .leftNewer : .rightNewer
    }

    static func proposal(_ state: SyncState, asymmetric: Bool) -> SyncAction {
        switch state {
        case .equal, .different: .none
        case .leftNewer, .leftOnly: .copyRight
        case .rightNewer: asymmetric ? .none : .copyLeft
        case .rightOnly: asymmetric ? .deleteRight : .copyLeft
        }
    }

    /// Reads both files in 1 MB chunks at the same offsets until they differ or end.
    static func sameContent(_ a: VFSPath, _ b: VFSPath, registry: ProviderRegistry) async throws -> Bool {
        let fa = try await registry.writableProvider(for: a.location).openForReading(a, bypassCache: false)
        let fb = try await registry.writableProvider(for: b.location).openForReading(b, bypassCache: false)
        defer {
            Task {
                await fa.close()
                await fb.close()
            }
        }
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let at = offset
            async let x = fa.read(at: at, count: 1 << 20)
            async let y = fb.read(at: at, count: 1 << 20)
            let (da, db) = try await (x, y)
            if da != db { return false }
            if da.isEmpty { return true }
            offset += Int64(da.count)
        }
    }
}
