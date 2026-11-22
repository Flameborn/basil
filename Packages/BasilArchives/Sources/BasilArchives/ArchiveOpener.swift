import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// Opens archive files as `ArchiveProvider`s. Registered in `ProviderRegistry` as a container
/// opener; backends register here (libarchive by default, 7-Zip and UnRAR ahead of it later).
public final class ArchiveOpener: ContainerOpener {
    public var provider: ProviderID { .archive }
    private let backends: Mutex<[any ArchiveBackend]>

    /// Where copies of archives that are not local files (an archive inside an archive) go.
    let temporaryRoot: URL

    public init(backends: [any ArchiveBackend] = [LibArchiveBackend()],
                temporaryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Basil Archives", isDirectory: true)) {
        self.backends = Mutex(backends)
        self.temporaryRoot = temporaryRoot
    }

    /// Adds a backend; `first` puts it ahead of the existing ones.
    public func register(_ backend: any ArchiveBackend, first: Bool = true) {
        backends.withLock { first ? $0.insert(backend, at: 0) : $0.append(backend) }
    }

    public func recognizes(name: String) -> Bool {
        backends.withLock { list in list.contains { $0.recognizes(name: name) } }
    }

    public func open(_ file: FileItem, byContent: Bool, registry: ProviderRegistry) async throws -> (any FileSystemProvider)? {
        guard case .file = file.kind else { return nil }
        let candidates = backends.withLock { list in byContent ? list : list.filter { $0.recognizes(name: file.name) } }
        guard !candidates.isEmpty else { return nil }
        let (url, temporary) = try await localFile(for: file.path, registry: registry)
        let location = ProviderLocation(provider: .archive, container: file.path)
        do {
            for backend in candidates {
                let entries = try await Self.blocking { try backend.entries(of: url, byContent: byContent) }
                if let entries {
                    return ArchiveProvider(location: location, backend: backend, url: url, byContent: byContent,
                                           entries: entries, temporaryCopy: temporary)
                }
            }
        } catch {
            if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            throw error
        }
        if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return nil
    }

    public func test(_ file: VFSPath, registry: ProviderRegistry,
                     progress: @escaping @Sendable (Double, String) -> Void) async throws -> [String] {
        let item = try await registry.provider(for: file.location).item(at: file)
        let location = ProviderLocation(provider: .archive, container: file)
        let provider: ArchiveProvider
        if let open = try? registry.provider(for: location) as? ArchiveProvider {
            provider = open
        } else if let opened = try await open(item, byContent: true, registry: registry) as? ArchiveProvider {
            provider = opened
        } else {
            throw ArchiveError.damaged("Not an archive Basil can read", archive: file.name)
        }
        return try await provider.test(progress: progress)
    }

    /// A local file for `path`: the file itself, or a temporary copy read through its provider.
    private func localFile(for path: VFSPath, registry: ProviderRegistry) async throws -> (URL, Bool) {
        if path.location == .local { return (URL(fileURLWithPath: path.path), false) }
        let source = try registry.writableProvider(for: path.location)
        let folder = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(path.name)
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw VFSError.permissionDenied(.local(url.path))
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let reader = try await source.openForReading(path, bypassCache: false)
            var offset: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.read(at: offset, count: 1 << 20)
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
            }
            await reader.close()
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (url, true)
    }

    private static let queue = DispatchQueue(label: "basil.archive.open", qos: .userInitiated, attributes: .concurrent)

    static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                UTF8Locale.use() // per thread: a serial queue does not always run on the same one
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
