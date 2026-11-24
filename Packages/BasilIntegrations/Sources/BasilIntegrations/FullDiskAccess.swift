import AppKit
import Darwin
import Foundation

/// Whether macOS lets Basil read every file (Privacy and Security > Full Disk Access).
///
/// There is no API that answers this. The check opens files that only processes with Full Disk
/// Access may read: the TCC databases (the system one exists on every Mac) and a few files in
/// the user's Library (files only: a protected folder itself may open). Opening one of them
/// proves access; a refusal (EPERM or EACCES) proves the opposite. Files that do not exist say
/// nothing and the next one is tried.
public enum FullDiskAccess {
    public enum Status: Sendable, Equatable {
        case granted
        case notGranted
        /// None of the protected files exist, so nothing could be checked (not seen on a real Mac).
        case unknown

        /// Basil may go on: granted, or nothing could be checked.
        public var allowsContinuing: Bool { self != .notGranted }
    }

    /// Files readable only with Full Disk Access, most reliable first.
    public static func protectedFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            home.appendingPathComponent("Library/Safari/Bookmarks.plist").path,
            home.appendingPathComponent("Library/Safari/CloudTabs.db").path,
            home.appendingPathComponent("Library/Messages/chat.db").path,
        ]
    }

    /// Checks the files in order. Cheap (a few open calls), so it can run every second.
    public static func status(files: [String] = protectedFiles()) -> Status {
        var refused = false
        for path in files {
            switch probe(path) {
            case .readable: return .granted
            case .refused: refused = true
            case .missing: continue
            }
        }
        return refused ? .notGranted : .unknown
    }

    enum Probe { case readable, refused, missing }

    static func probe(_ path: String) -> Probe {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        // EPERM is TCC's answer; EACCES the file's own permissions. Either way Basil can't read it.
        default: return .refused
        }
    }

    /// Opens System Settings at Privacy and Security > Full Disk Access.
    @MainActor
    public static func openSettings() {
        let addresses = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for address in addresses {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
    }
}
