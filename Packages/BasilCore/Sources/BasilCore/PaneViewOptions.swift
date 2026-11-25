import Foundation

/// What one pane tab changes of the global display settings (View Options, Cmd+J, like Finder's
/// Show View Options). Nil follows Settings. The tab's view and sort order are its own anyway.
public struct PaneViewOptions: Codable, Equatable, Sendable {
    /// The tab's own column list (order, visibility, widths), replacing the view's while set.
    /// Choosing another view drops it.
    public var columns: [ColumnSpec]?
    public var foldersFirst: Bool?
    public var showHidden: Bool?
    public var date: DateFormatSettings?
    public var size: SizeFormat?

    public init(columns: [ColumnSpec]? = nil, foldersFirst: Bool? = nil, showHidden: Bool? = nil,
                date: DateFormatSettings? = nil, size: SizeFormat? = nil) {
        self.columns = columns
        self.foldersFirst = foldersFirst
        self.showHidden = showHidden
        self.date = date
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decodeIfPresent([ColumnSpec].self, forKey: .columns)
        foldersFirst = try c.decodeIfPresent(Bool.self, forKey: .foldersFirst)
        showHidden = try c.decodeIfPresent(Bool.self, forKey: .showHidden)
        date = try c.decodeIfPresent(DateFormatSettings.self, forKey: .date)
        size = try c.decodeIfPresent(SizeFormat.self, forKey: .size)
    }

    public var isEmpty: Bool { self == PaneViewOptions() }

    /// Drops what equals the global settings (and the view's own columns), so "Reset to Global
    /// Settings" only shows when something really differs.
    public func normalized(global: BasilSettings, view: ListView) -> PaneViewOptions {
        var o = self
        if o.columns == view.columns { o.columns = nil }
        if o.foldersFirst == global.foldersFirst { o.foldersFirst = nil }
        if o.showHidden == global.showHidden { o.showHidden = nil }
        if o.date == global.date { o.date = nil }
        if o.size == global.size { o.size = nil }
        return o
    }

    public func formatters(global: BasilSettings) -> DisplayFormatters {
        DisplayFormatters(size: size ?? global.size, date: date ?? global.date)
    }
}
