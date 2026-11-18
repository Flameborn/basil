import BasilCore
import Foundation

/// The recursive size of a folder (Total Commander's "calculate occupied space").
public struct DirectoryTotals: Sendable, Equatable {
    /// Sum of the logical sizes of all files inside.
    public var bytes: Int64 = 0
    public var files = 0
    /// Folders inside, not counting the folder itself.
    public var folders = 0
    /// Folders inside that could not be read; their contents are missing from the totals.
    public var unreadable = 0

    public init() {}

    public static func + (a: Self, b: Self) -> Self {
        var r = a
        r.bytes += b.bytes
        r.files += b.files
        r.folders += b.folders
        r.unreadable += b.unreadable
        return r
    }
}

extension FileSystemProvider {
    /// Walks `directory` recursively through `list` and adds up file sizes. Symlinks are counted
    /// as files of their own size and never followed. Throws `CancellationError` when cancelled,
    /// and the error of `directory` itself when it can't be read; unreadable subfolders are counted
    /// in `unreadable` and skipped.
    public func totals(of directory: VFSPath) async throws -> DirectoryTotals {
        var totals = DirectoryTotals()
        var pending = [directory]
        var isRoot = true
        while let folder = pending.popLast() {
            try Task.checkCancellation()
            do {
                for try await batch in list(folder) {
                    try Task.checkCancellation()
                    for item in batch {
                        if case .directory = item.kind {
                            totals.folders += 1
                            pending.append(item.path)
                        } else {
                            totals.files += 1
                            totals.bytes += item.size ?? 0
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isRoot { throw error }
                totals.unreadable += 1
            }
            isRoot = false
        }
        return totals
    }
}
