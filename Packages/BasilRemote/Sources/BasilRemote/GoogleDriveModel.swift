import BasilCore
import BasilVFS
import Foundation

/// One item as the Drive API (v3) describes it.
struct DriveFile: Decodable, Sendable, Equatable {
    var id: String
    var name: String
    var mimeType: String
    /// Bytes, as a decimal string; missing for folders and Google's own documents.
    var size: String?
    var modifiedTime: String?
    var createdTime: String?
    var md5Checksum: String?
    /// Goes up with every change to the item.
    var version: String?
    var trashed: Bool?
    var parents: [String]?
    /// The shared drive holding the item; nil in My Drive and in other users' drives.
    var driveId: String?
    var webViewLink: String?
    var shortcutDetails: Shortcut?

    struct Shortcut: Decodable, Sendable, Equatable {
        var targetId: String?
        var targetMimeType: String?
    }

    /// What Basil asks for with every item.
    static let fields = "id,name,mimeType,size,modifiedTime,createdTime,md5Checksum,version,trashed,parents,driveId,webViewLink,shortcutDetails(targetId,targetMimeType)"

    static let folderType = "application/vnd.google-apps.folder"
    static let shortcutType = "application/vnd.google-apps.shortcut"

    var isFolder: Bool { mimeType == Self.folderType }
    var isShortcut: Bool { mimeType == Self.shortcutType }
    /// Google Docs, Sheets, Slides and the other types without content of their own.
    var isGoogleType: Bool { Self.isGoogleType(mimeType) }
    static func isGoogleType(_ mime: String) -> Bool {
        mime.hasPrefix("application/vnd.google-apps.") && mime != folderType && mime != shortcutType
    }

    var byteCount: Int64? { size.flatMap { Int64($0) } }
    var modified: Date? { modifiedTime.flatMap(DriveDate.parse) }
    var created: Date? { createdTime.flatMap(DriveDate.parse) }
}

/// A Google document's download: the export format Basil uses for its type.
struct DriveExport: Sendable, Equatable {
    var mimeType: String
    /// Added to the name in listings ("Report" is listed as "Report.docx").
    var fileExtension: String

    /// The export with the default formats (Office for Docs, Sheets and Slides, PDF for Drawings).
    static func of(_ googleType: String) -> DriveExport? { DriveExportFormats().export(for: googleType) }

    /// "Google Forms", for messages about types that cannot be downloaded.
    static func typeName(_ googleType: String) -> String {
        let kind = googleType.replacingOccurrences(of: "application/vnd.google-apps.", with: "")
        switch kind {
        case "form": return "Google Forms"
        case "site": return "Google Sites"
        case "map": return "Google My Maps"
        case "jam": return "Jamboard"
        case "fusiontable": return "Fusion Tables"
        default: return "Google " + kind
        }
    }
}

/// The export format of each kind of Google document, chosen per connection in the editor
/// (`RemoteTarget.options`, keys like "exportDocuments" holding the extension).
struct DriveExportFormats: Sendable, Equatable {
    struct Format: Sendable, Equatable {
        var fileExtension: String
        var mimeType: String
        var title: String
    }

    struct Kind: Sendable {
        var googleType: String
        var optionKey: String
        var title: String
        /// The first is the default.
        var formats: [Format]
    }

    static let kinds: [Kind] = [
        Kind(googleType: "application/vnd.google-apps.document", optionKey: "exportDocuments", title: "Google Docs as", formats: [
            Format(fileExtension: "docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", title: "Word (docx)"),
            Format(fileExtension: "odt", mimeType: "application/vnd.oasis.opendocument.text", title: "OpenDocument (odt)"),
            Format(fileExtension: "pdf", mimeType: "application/pdf", title: "PDF"),
            Format(fileExtension: "txt", mimeType: "text/plain", title: "Plain text (txt)"),
            Format(fileExtension: "md", mimeType: "text/markdown", title: "Markdown (md)"),
            Format(fileExtension: "rtf", mimeType: "application/rtf", title: "Rich Text (rtf)"),
            Format(fileExtension: "epub", mimeType: "application/epub+zip", title: "EPUB"),
        ]),
        Kind(googleType: "application/vnd.google-apps.spreadsheet", optionKey: "exportSpreadsheets", title: "Google Sheets as", formats: [
            Format(fileExtension: "xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", title: "Excel (xlsx)"),
            Format(fileExtension: "ods", mimeType: "application/vnd.oasis.opendocument.spreadsheet", title: "OpenDocument (ods)"),
            Format(fileExtension: "pdf", mimeType: "application/pdf", title: "PDF"),
            Format(fileExtension: "csv", mimeType: "text/csv", title: "CSV, first sheet only"),
            Format(fileExtension: "tsv", mimeType: "text/tab-separated-values", title: "TSV, first sheet only"),
        ]),
        Kind(googleType: "application/vnd.google-apps.presentation", optionKey: "exportPresentations", title: "Google Slides as", formats: [
            Format(fileExtension: "pptx", mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", title: "PowerPoint (pptx)"),
            Format(fileExtension: "odp", mimeType: "application/vnd.oasis.opendocument.presentation", title: "OpenDocument (odp)"),
            Format(fileExtension: "pdf", mimeType: "application/pdf", title: "PDF"),
            Format(fileExtension: "txt", mimeType: "text/plain", title: "Plain text (txt)"),
        ]),
        Kind(googleType: "application/vnd.google-apps.drawing", optionKey: "exportDrawings", title: "Google Drawings as", formats: [
            Format(fileExtension: "pdf", mimeType: "application/pdf", title: "PDF"),
            Format(fileExtension: "svg", mimeType: "image/svg+xml", title: "SVG"),
            Format(fileExtension: "png", mimeType: "image/png", title: "PNG"),
            Format(fileExtension: "jpg", mimeType: "image/jpeg", title: "JPEG"),
        ]),
    ]

    /// Chosen extension by Google type; missing ones take the default.
    var chosen: [String: String] = [:]

    init(options: [String: String]? = nil) {
        for kind in Self.kinds {
            if let value = options?[kind.optionKey], kind.formats.contains(where: { $0.fileExtension == value }) {
                chosen[kind.googleType] = value
            }
        }
    }

    func export(for googleType: String) -> DriveExport? {
        if googleType == "application/vnd.google-apps.script" {
            return DriveExport(mimeType: "application/vnd.google-apps.script+json", fileExtension: "json")
        }
        guard let kind = Self.kinds.first(where: { $0.googleType == googleType }) else { return nil }
        let format = kind.formats.first { $0.fileExtension == chosen[googleType] } ?? kind.formats[0]
        return DriveExport(mimeType: format.mimeType, fileExtension: format.fileExtension)
    }

    /// The extensions exports of this connection get (names Basil made end in one).
    var extensions: Set<String> {
        Set(Self.kinds.compactMap { export(for: $0.googleType)?.fileExtension } + ["json"])
    }

    /// The editor's pop-ups.
    static var options: [RemoteOption] {
        kinds.map { kind in
            RemoteOption(key: kind.optionKey, title: kind.title,
                         kind: .choice(kind.formats.map { RemoteOption.Choice(value: $0.fileExtension, title: $0.title) },
                                       default: kind.formats[0].fileExtension))
        }
    }
}

enum DriveDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func parse(_ text: String) -> Date? { (try? fractional.parse(text)) ?? (try? whole.parse(text)) }

    /// RFC 3339 with milliseconds, as Drive writes it.
    static func format(_ date: Date) -> String { fractional.format(date) }

    static func format(seconds: Int, nanos: Int = 0) -> String {
        format(Date(timeIntervalSince1970: Double(seconds) + Double(nanos / 1_000_000) / 1000))
    }
}

/// Where a path of a Google Drive connection leads.
///
/// The top folder ("/") holds three places: "My Drive", "Shared with me" and "Shared drives"
/// (one folder per shared drive). Below them every path names a Drive item by its listed name.
struct DriveRef: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case top, sharedWithMe, sharedDrives
        case folder
        case file
        /// A shortcut to a folder: listed as a link to a folder, so opening it shows the target
        /// but deleting or moving it never reaches the target's contents.
        case folderShortcut
    }

    var kind: Kind
    /// The item's own ID (the shortcut's, for a shortcut): renamed, moved, deleted.
    var ownID: String?
    /// The ID of what the item shows (a shortcut's target): listed, read, copied.
    var contentID: String?
    /// The content's type.
    var mimeType: String = DriveFile.folderType
    /// "my", "shared" (other users' items) or a shared drive's ID: moves and server-side copies
    /// stay inside one.
    var volume: String = "top"
    /// The shared drive the content is in.
    var driveID: String?
    /// My Drive or a shared drive itself: cannot be renamed or deleted.
    var isRoot = false
    /// The extension Basil added to a Google document's name ("docx").
    var addedExtension: String?
    /// The content's metadata when it was listed.
    var content: DriveFile?

    var isPlace: Bool { kind == .top || kind == .sharedWithMe || kind == .sharedDrives }
    var isFolderLike: Bool { kind != .file }
    /// A Google document Basil downloads as an export, in the connection's format.
    func export(_ formats: DriveExportFormats) -> DriveExport? {
        DriveFile.isGoogleType(mimeType) ? formats.export(for: mimeType) : nil
    }
    var isGoogleType: Bool { DriveFile.isGoogleType(mimeType) }
}

enum DriveNames {
    static let myDrive = "My Drive"
    static let sharedWithMe = "Shared with me"
    static let sharedDrives = "Shared drives"

    /// "notes (2).txt" for the second "notes.txt"; folders are numbered at the end.
    static func numbered(_ name: String, _ number: Int, folder: Bool) -> String {
        if !folder, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return "\(name[..<dot]) (\(number))\(name[dot...])"
        }
        return "\(name) (\(number))"
    }

    /// A name for the API's query language: in single quotes, with ' and \ escaped.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Gives every item of a listing its own name. Drive allows several items of one name in a
    /// folder: the oldest keeps it, the others get " (2)", " (3)" (skipping names that exist).
    static func unique<T>(_ entries: [(name: String, folder: Bool, created: Date?, id: String, value: T)]) -> [(String, T)] {
        let taken = Set(entries.map(\.name))
        var used = Set<String>()
        var result: [(String, T)] = []
        let groups = Dictionary(grouping: entries, by: \.name)
        for name in groups.keys.sorted() {
            let group = groups[name]!.sorted {
                let a = $0.created ?? .distantPast, b = $1.created ?? .distantPast
                return a != b ? a < b : $0.id < $1.id
            }
            for (index, entry) in group.enumerated() {
                if index == 0 {
                    used.insert(name)
                    result.append((name, entry.value))
                    continue
                }
                var number = index + 1
                var candidate = numbered(name, number, folder: entry.folder)
                while taken.contains(candidate) || used.contains(candidate) {
                    number += 1
                    candidate = numbered(name, number, folder: entry.folder)
                }
                used.insert(candidate)
                result.append((candidate, entry.value))
            }
        }
        return result
    }
}

/// An error answer of the Drive API: {"error": {"code": 403, "message": "...", "errors": [{"reason": "..."}]}}.
struct DriveProblem: Sendable {
    var status: Int
    var message: String
    var reason: String?

    init(_ response: HTTPResponse) {
        status = response.status
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        message = (error?["message"] as? String) ?? "HTTP \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))"
        reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (error?["status"] as? String)
    }

    var isRateLimit: Bool {
        status == 429 || (status == 403 && ["rateLimitExceeded", "userRateLimitExceeded"].contains(reason ?? ""))
    }
}
