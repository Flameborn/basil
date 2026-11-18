import AppKit
import BasilCore
import UniformTypeIdentifiers

/// File-type icons for the Name column, cached by type (only visible rows ask for them).
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

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
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        cache[key] = image
        return image
    }
}

/// "1 item", "2 items".
func itemCount(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
