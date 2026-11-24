import BasilCore
import BasilOperations
import BasilVFS
import Foundation

/// A plugin's column: the pane asks it for each folder it shows (off the main thread), Lua's
/// fill(folder, items) answers a table of text by item name, or nil where the column does not apply.
struct PluginColumnAnnotator: ColumnAnnotator {
    let column: ColumnID
    weak var plugin: Plugin?
    let fill: Int32

    func annotations(for directory: VFSPath, registry: ProviderRegistry) async -> ColumnAnnotation? {
        guard let plugin, let provider = try? registry.provider(for: directory.location) else { return nil }
        var items: [FileItem] = []
        do { for try await batch in provider.list(directory) { items += batch } } catch { return nil }
        do {
            let answer = try await plugin.runtime.call(fill, [plugin.value(directory), .array(items.map(plugin.value))])
            guard let table = answer.first, case .table = table else { return nil }
            return ColumnAnnotation(byName: table.fields.compactMapValues(\.string))
        } catch {
            plugin.report(error, while: "filling a column")
            return nil
        }
    }
}

/// A folder tree a plugin's Lua code lists (basil.provider): browsed like any folder, read with
/// F3 and copied out with F5 when the plugin gives a read function. It cannot be changed.
final class LuaProvider: WritableProvider, @unchecked Sendable {
    let location: ProviderLocation
    let title: String
    weak var plugin: Plugin?
    let listFunction: Int32
    let readFunction: Int32?
    let itemFunction: Int32?

    init(location: ProviderLocation, title: String, plugin: Plugin, list: Int32, read: Int32?, item: Int32?) {
        self.location = location
        self.title = title
        self.plugin = plugin
        listFunction = list
        readFunction = read
        itemFunction = item
    }

    var capabilities: ProviderCapabilities { readFunction == nil ? [] : [.read] }

    private func live() throws -> Plugin {
        guard let plugin else { throw VFSError.failed("The plugin of \(title) is turned off") }
        return plugin
    }

    /// One entry of a listing from Lua: { name =, kind = "file" | "folder" | "link", size =, modified =, created =, hidden = }.
    static func item(_ value: LuaValue, at path: VFSPath) -> FileItem {
        let kind: FileItem.Kind = switch value["kind"].string ?? "file" {
        case "folder", "directory": .directory
        case "link": .symlink(target: .unknown)
        case "folderlink": .symlink(target: .directory)
        case "other": .other
        default: .file
        }
        return FileItem(path: path, kind: kind, size: value["size"].number.map { Int64($0) },
                        modified: value["modified"].number.map { Date(timeIntervalSince1970: $0) },
                        created: value["created"].number.map { Date(timeIntervalSince1970: $0) },
                        isHidden: value["hidden"].bool ?? path.name.hasPrefix("."))
    }

    func entries(_ directory: VFSPath) async throws -> [FileItem] {
        let plugin = try live()
        let answer = try await plugin.runtime.call(listFunction, [plugin.value(directory)])
        guard let list = answer.first else { return [] }
        if case .nil = list { throw VFSError.notFound(directory) }
        return list.list.compactMap { entry -> FileItem? in
            guard let name = entry["name"].string, !name.isEmpty, !name.contains("/") else { return nil }
            return Self.item(entry, at: directory.appending(name))
        }
    }

    func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await self.entries(directory))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func item(at path: VFSPath) async throws -> FileItem {
        if path.isRoot { return FileItem(path: path, kind: .directory) }
        let plugin = try live()
        if let itemFunction {
            let answer = try await plugin.runtime.call(itemFunction, [plugin.value(path)])
            guard let value = answer.first, case .table = value else { throw VFSError.notFound(path) }
            return Self.item(value, at: path)
        }
        guard let parent = path.parent, let found = try await entries(parent).first(where: { $0.name == path.name }) else {
            throw VFSError.notFound(path)
        }
        return found
    }

    func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }

    // MARK: Reading

    func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        let item = try await item(at: path)
        let kind: FileFingerprint.Kind = switch item.kind {
        case .file: .file
        case .directory: .directory
        case .symlink: .symlink
        case .other: .other
        }
        return FileFingerprint(kind: kind, size: item.size ?? 0,
                               modifiedNanos: item.modified.map { Int64($0.timeIntervalSince1970 * 1_000_000_000) })
    }

    func metadata(of path: VFSPath) async throws -> FileMetadata {
        let item = try await item(at: path)
        var metadata = FileMetadata()
        if let date = item.modified {
            metadata.modified = timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)
        }
        return metadata
    }

    func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        guard let readFunction else { throw VFSError.unsupported("reading files of \(title)") }
        let plugin = try live()
        let answer = try await plugin.runtime.call(readFunction, [plugin.value(path)])
        guard let data = answer.first?.data else { throw VFSError.notFound(path) }
        return BytesFile(data: data)
    }

    func volumeIdentifier(of path: VFSPath) async throws -> String? { location.provider.rawValue }
    func readSymlink(_ path: VFSPath) async throws -> String { throw VFSError.unsupported("links of \(title)") }

    // MARK: Changes (none)

    private var readOnly: VFSError { .unsupported("changing \(title)") }
    func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] { throw readOnly }
    func createFile(_ path: VFSPath) async throws -> any WritableFile { throw readOnly }
    func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws { throw readOnly }
    func clone(_ from: VFSPath, to: VFSPath) async throws { throw readOnly }
    func remove(_ path: VFSPath) async throws { throw readOnly }
    func makeDirectory(_ path: VFSPath) async throws { throw readOnly }
    func synchronize(_ path: VFSPath) async throws {}
    func createSymlink(_ path: VFSPath, target: String) async throws { throw readOnly }
}

/// File contents a plugin handed over.
struct BytesFile: ReadableFile {
    let data: Data
    func read(at offset: Int64, count: Int) async throws -> Data {
        let start = Int(min(offset, Int64(data.count)))
        return data.subdata(in: start..<min(data.count, start + count))
    }
    func close() async {}
}

/// A queue item written in Lua (basil.operation): run(op) runs off the main actor in the
/// plugin's state and reports through op.progress, op.log, op.items and op.checkpoint.
struct PluginOperation: QueueOperation {
    let title: String
    let kind: OperationKind
    let plugin: Plugin
    let run: Int32

    func run(_ context: OperationContext) async throws {
        let id = plugin.add(context)
        defer { plugin.removeContext(id) }
        context.log("Plugin \(plugin.manifest.name)")
        do {
            _ = try await plugin.runtime.call(plugin.runtime.operationRunner, [.function(run), .number(Double(id))])
        } catch {
            if context.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
