import BasilCore
import Foundation

/// What Find Files looks for (Total Commander's Find Files dialog). Every part that is set must
/// match. Saved as the last search, so it is Codable.
public struct SearchQuery: Codable, Sendable, Equatable {
    public enum Kinds: String, Codable, Sendable, CaseIterable {
        case filesAndFolders, files, folders

        public var title: String {
            switch self {
            case .filesAndFolders: "Files and folders"
            case .files: "Files only"
            case .folders: "Folders only"
            }
        }
    }

    /// Names in quick-filter syntax ("*.mp3;*.flac | live*", "apple"); empty finds every name.
    public var name: String
    /// `name` is one regular expression.
    public var nameIsRegex: Bool
    /// Also searches every folder below the start folder.
    public var subfolders: Bool
    public var kinds: Kinds
    /// Hidden items are found, and hidden folders searched.
    public var includeHidden: Bool
    /// Bytes. A size limit finds files only.
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    /// Items modified at or after this date.
    public var modifiedAfter: Date?
    /// Items modified before this date.
    public var modifiedBefore: Date?
    /// Text inside files. A search with text finds files only.
    public var text: TextQuery?

    public init(name: String = "", nameIsRegex: Bool = false, subfolders: Bool = true,
                kinds: Kinds = .filesAndFolders, includeHidden: Bool = true,
                minimumSize: Int64? = nil, maximumSize: Int64? = nil,
                modifiedAfter: Date? = nil, modifiedBefore: Date? = nil, text: TextQuery? = nil) {
        self.name = name
        self.nameIsRegex = nameIsRegex
        self.subfolders = subfolders
        self.kinds = kinds
        self.includeHidden = includeHidden
        self.minimumSize = minimumSize
        self.maximumSize = maximumSize
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.text = text
    }

    /// The name matcher; throws for an invalid regular expression.
    public func nameFilter() throws -> NameFilter? {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try NameFilter(name, regex: nameIsRegex)
    }

    /// Whether the search looks inside files.
    public var searchesText: Bool { !(text?.text.isEmpty ?? true) }

    /// Everything but the text: kind, hidden, name, size and date.
    public func matches(_ item: FileItem, nameFilter: NameFilter?) -> Bool {
        let isFolder = item.isDirectoryLike
        if searchesText {
            guard case .file = item.kind else { return false }
        } else {
            switch kinds {
            case .filesAndFolders: break
            case .files: if isFolder { return false }
            case .folders: if !isFolder { return false }
            }
        }
        if !includeHidden, item.isHidden { return false }
        if let nameFilter, !nameFilter.matches(item.name) { return false }
        if minimumSize != nil || maximumSize != nil {
            // A size limit finds files only.
            guard !isFolder, let size = item.size else { return false }
            if let minimumSize, size < minimumSize { return false }
            if let maximumSize, size > maximumSize { return false }
        }
        if modifiedAfter != nil || modifiedBefore != nil {
            guard let modified = item.modified else { return false }
            if let modifiedAfter, modified < modifiedAfter { return false }
            if let modifiedBefore, modified >= modifiedBefore { return false }
        }
        return true
    }

    /// A short description for titles and speech: "*.mp3 containing "live"".
    public var summary: String {
        var parts: [String] = []
        let shownName = name.trimmingCharacters(in: .whitespaces)
        parts.append(shownName.isEmpty ? "All items" : shownName)
        if let text, !text.text.isEmpty {
            parts.append(text.notContaining ? "not containing \"\(text.text)\"" : "containing \"\(text.text)\"")
        }
        return parts.joined(separator: " ")
    }
}

/// Text to find inside files (TC's "Find text").
public struct TextQuery: Codable, Sendable, Equatable {
    public enum Encodings: String, Codable, Sendable, CaseIterable {
        /// UTF-8, UTF-16 (both byte orders) and Windows-1252.
        case all, utf8, utf16, windows1252

        public var title: String {
            switch self {
            case .all: "All (UTF-8, UTF-16, Windows-1252)"
            case .utf8: "UTF-8"
            case .utf16: "UTF-16"
            case .windows1252: "Windows-1252"
            }
        }
    }

    public var text: String
    public var caseSensitive: Bool
    public var regex: Bool
    public var wholeWords: Bool
    public var encodings: Encodings
    /// Finds the files that do not contain the text.
    public var notContaining: Bool

    public init(text: String, caseSensitive: Bool = false, regex: Bool = false, wholeWords: Bool = false,
                encodings: Encodings = .all, notContaining: Bool = false) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWords = wholeWords
        self.encodings = encodings
        self.notContaining = notContaining
    }
}
