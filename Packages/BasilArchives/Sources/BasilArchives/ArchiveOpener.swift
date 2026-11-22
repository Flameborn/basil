import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// Opens archive files as `ArchiveProvider`s. Registered in `ProviderRegistry` as a container
/// opener; backends register here (UnRAR and libarchive by default, 7-Zip ahead of them once
/// its bundled 7zz is found).
public final class ArchiveOpener: ContainerOpener {
    public var provider: ProviderID { .archive }
    private let backends: Mutex<[any ArchiveBackend]>

    /// Where copies of archives that are not local files (an archive inside an archive) go.
    let temporaryRoot: URL

    public init(backends: [any ArchiveBackend] = [UnRARBackend(), LibArchiveBackend()],
                temporaryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Basil Archives", isDirectory: true)) {
        self.backends = Mutex(backends)
        self.temporaryRoot = temporaryRoot
    }

    /// The 7zz that writes 7z (and encrypted zip), once its backend is registered.
    let sevenZip = Mutex<SevenZipWriter?>(nil)

    /// Adds a backend; `first` puts it ahead of the existing ones.
    public func register(_ backend: any ArchiveBackend, first: Bool = true) {
        backends.withLock { first ? $0.insert(backend, at: 0) : $0.append(backend) }
        if let sevenZipBackend = backend as? SevenZipBackend, sevenZipBackend.type == "7z" {
            sevenZip.withLock { $0 = SevenZipWriter(tool: sevenZipBackend.tool) }
        }
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
            var firstError: (any Error)?
            for backend in candidates {
                let listed: ([ArchiveEntry]?, String?)
                do {
                    listed = try await Self.list(url, with: backend, byContent: byContent,
                                                 archive: file.path, passwords: registry.passwords)
                } catch ArchiveError.damaged(let message, let archive) {
                    // A later backend may read what this one cannot (7-Zip after libarchive for zip).
                    firstError = firstError ?? ArchiveError.damaged(message, archive: archive)
                    continue
                }
                let (entries, password) = listed
                if let entries {
                    return ArchiveProvider(location: location, backend: backend, url: url, byContent: byContent,
                                           entries: entries, temporaryCopy: temporary,
                                           passwords: registry.passwords, password: password)
                }
            }
            if let firstError { throw firstError }
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

    /// The volumes of a multi-volume RAR set ("name.part1.rar", "name.part2.rar", or "name.rar",
    /// "name.r00", ...), found next to `file`; any other archive is only itself.
    public func volumes(of file: VFSPath, registry: ProviderRegistry) async -> [VFSPath] {
        guard file.location == .local, let folder = file.parent else { return [file] }
        let first = UnRARBackend.firstVolume(of: URL(fileURLWithPath: file.path)).lastPathComponent
        let pattern: Regex<AnyRegexOutput>
        if let m = first.wholeMatch(of: /(?i)(.*)\.part\d+\.rar/) {
            let base = NSRegularExpression.escapedPattern(for: String(m.1))
            guard let r = try? Regex("(?i)" + base + "\\.part\\d+\\.rar") else { return [file] }
            pattern = r
        } else if let m = first.wholeMatch(of: /(?i)(.*)\.rar/) {
            let base = NSRegularExpression.escapedPattern(for: String(m.1))
            guard let r = try? Regex("(?i)" + base + "\\.(?:rar|[r-z]\\d\\d)") else { return [file] }
            pattern = r
        } else {
            return [file]
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let found = names.filter { $0.wholeMatch(of: pattern) != nil }.sorted().map { folder.appending($0) }
        return found.contains(file) ? found : [file] + found
    }

    /// Lists an archive, asking for its password when the names are encrypted (until one works
    /// or the prompt is cancelled). Returns the password that opened it, if one was needed.
    static func list(_ url: URL, with backend: any ArchiveBackend, byContent: Bool, archive: VFSPath,
                     passwords: (any ContainerPasswords)?) async throws -> ([ArchiveEntry]?, String?) {
        var password: String?
        while true {
            do {
                let given = password
                let entries = try await blocking { try backend.entries(of: url, byContent: byContent, password: given) }
                if let given { passwords?.accepted(given, for: archive) }
                return (entries, given)
            } catch let error as ArchiveError {
                switch error {
                case .passwordNeeded, .wrongPassword:
                    guard let passwords else { throw ArchiveError.passwordNeeded(archive: archive.name) }
                    guard let next = await passwords.password(for: archive, retry: password != nil) else {
                        throw ArchiveError.noPassword(archive: archive.name)
                    }
                    password = next
                default:
                    throw error
                }
            }
        }
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
