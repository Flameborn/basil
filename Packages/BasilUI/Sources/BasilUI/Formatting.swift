import AppKit
import BasilCore
import UniformTypeIdentifiers

@MainActor
enum Formatting {
    private static let bytes: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static let byteCount: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ item: FileItem) -> String {
        if item.isDirectoryLike { return "<DIR>" }
        guard let size = item.size else { return "" }
        return bytes.string(from: NSNumber(value: size)) ?? "\(size)"
    }

    static func spokenSize(_ item: FileItem) -> String {
        guard !item.isDirectoryLike, let size = item.size else { return "" } // folders: silent
        return byteCount.string(fromByteCount: size)
    }

    static func humanBytes(_ value: Int64) -> String { byteCount.string(fromByteCount: value) }

    static func date(_ value: Date?) -> String {
        guard let value else { return "" }
        return date.string(from: value)
    }

    /// "drwxr-xr-x"-style attributes.
    static func attributes(_ item: FileItem) -> String {
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

    static func kindDescription(_ item: FileItem) -> String {
        switch item.kind {
        case .directory: "folder"
        case .symlink(.directory): "link to folder"
        case .symlink(.broken): "broken link"
        case .symlink: "link"
        case .file: "file"
        case .other: "special file"
        }
    }

    // MARK: Icons (cached by type; only visible rows ask for them)

    private static var iconCache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let key: String
        let type: UTType
        if item.isDirectoryLike {
            key = "/dir"
            type = .folder
        } else {
            let ext = item.nameAndExtension.ext.lowercased()
            key = ext
            type = UTType(filenameExtension: ext) ?? .data
        }
        if let cached = iconCache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        iconCache[key] = image
        return image
    }
}
