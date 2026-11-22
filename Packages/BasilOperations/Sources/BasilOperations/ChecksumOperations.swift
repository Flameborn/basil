import BasilCore
import BasilVFS
import Foundation

/// Reads a whole file through its provider and returns its digest.
private func digest(of path: VFSPath, algorithm: ChecksumAlgorithm, registry: ProviderRegistry,
                    context: OperationContext, progress: (Int64) -> Void) async throws -> String {
    let provider = try registry.writableProvider(for: path.location)
    let file = try await provider.openForReading(path, bypassCache: false)
    let hasher = algorithm.makeHasher()
    let chunk = min(provider.maxTransferChunkSize ?? 4 << 20, 4 << 20)
    var offset: Int64 = 0
    do {
        while true {
            try await context.checkpoint()
            let data = try await file.read(at: offset, count: chunk)
            if data.isEmpty { break }
            hasher.update(data)
            offset += Int64(data.count)
            progress(Int64(data.count))
            if data.count < chunk { break }
        }
    } catch {
        await file.close()
        throw error
    }
    await file.close()
    return hasher.finalize()
}

/// Files > Checksums > Create Checksum Files: hashes the files among `items` (folders are
/// walked, names are stored relative to `directory`) into one checksum file, or one per file
/// next to it, like Total Commander.
public struct CreateChecksumsOperation: QueueOperation {
    public enum Output: Sendable, Equatable {
        /// One checksum file for everything.
        case single(VFSPath)
        /// `name.ext` next to each file.
        case perFile
    }

    public let items: [FileItem]
    public let directory: VFSPath
    public let algorithm: ChecksumAlgorithm
    public let output: Output
    let registry: ProviderRegistry

    public init(items: [FileItem], directory: VFSPath, algorithm: ChecksumAlgorithm, output: Output,
                registry: ProviderRegistry) {
        self.items = items
        self.directory = directory
        self.algorithm = algorithm
        self.output = output
        self.registry = registry
    }

    public var kind: OperationKind { .createChecksums }
    public var title: String {
        switch output {
        case .single(let path): "Create \(path.name)"
        case .perFile: "Create \(algorithm.title) checksums for \(items.count == 1 ? items[0].name : "\(items.count) items")"
        }
    }

    public func run(_ context: OperationContext) async throws {
        let provider = try registry.writableProvider(for: directory.location)
        context.progress(nil, "Counting files")
        var files: [(path: VFSPath, name: String, size: Int64)] = []
        for item in items { try await collect(item, relative: item.name, into: &files, provider: provider, context: context) }
        if case .single(let target) = output { files.removeAll { $0.path == target } }

        let totalBytes = max(files.reduce(0) { $0 + $1.size }, 1)
        var done: Int64 = 0
        var entries: [(path: VFSPath, entry: ChecksumFile.Entry)] = []
        context.items(done: 0, total: files.count)
        for (n, file) in files.enumerated() {
            do {
                let hash = try await digest(of: file.path, algorithm: algorithm, registry: registry, context: context) { bytes in
                    done += bytes
                    context.progress(Double(done) / Double(totalBytes), file.name)
                }
                entries.append((file.path, ChecksumFile.Entry(name: file.name, hash: hash)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Like TC: a file that can't be read is left out, and the log says so.
                context.log("\(file.name): \(error.localizedDescription)")
            }
            context.items(done: n + 1, total: files.count)
        }

        switch output {
        case .single(let target):
            try await write(ChecksumFile.contents(entries.map(\.entry), algorithm: algorithm), to: target, provider: provider)
            context.log("Wrote \(target.name) with \(entries.count) \(entries.count == 1 ? "file" : "files")")
        case .perFile:
            for (path, entry) in entries {
                let target = (path.parent ?? directory).appending("\(path.name).\(algorithm.fileExtension)")
                let single = ChecksumFile.Entry(name: path.name, hash: entry.hash)
                try await write(ChecksumFile.contents([single], algorithm: algorithm), to: target,
                                provider: try registry.writableProvider(for: target.location))
            }
            context.log("Wrote \(entries.count) checksum \(entries.count == 1 ? "file" : "files")")
        }
        let failed = files.count - entries.count
        if failed > 0 { throw ChecksumProblems.unreadable(failed) }
    }

    private func collect(_ item: FileItem, relative: String, into files: inout [(path: VFSPath, name: String, size: Int64)],
                         provider: any WritableProvider, context: OperationContext) async throws {
        try await context.checkpoint()
        switch item.kind {
        case .file, .symlink(target: .file):
            guard !item.name.hasPrefix(".basil-partial-") else { return }
            files.append((item.path, relative, item.size ?? 0))
        case .directory:
            var children: [FileItem] = []
            for try await batch in try registry.provider(for: item.path.location).list(item.path) { children += batch }
            for child in children.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                try await collect(child, relative: relative + "/" + child.name, into: &files, provider: provider, context: context)
            }
        default:
            context.log("\(relative): skipped (not a file)")
        }
    }

    /// Writes through a partial file renamed into place, so a checksum file is never half written.
    private func write(_ text: String, to target: VFSPath, provider: any WritableProvider) async throws {
        let partial = (target.parent ?? directory).appending(".basil-partial-\(UUID().uuidString)")
        let file = try await provider.createFile(partial)
        do {
            try await file.write(Data(text.utf8), at: 0)
            _ = try await file.apply(FileMetadata(permissions: 0o644))
            await file.close()
            try await provider.rename(partial, to: target, replacing: true)
        } catch {
            await file.close()
            try? await provider.remove(partial)
            throw error
        }
    }
}

public enum ChecksumProblems: LocalizedError, Equatable {
    case unreadable(Int)
    /// failed of total files did not match or could not be read.
    case mismatched(failed: Int, total: Int)
    case notAChecksumFile(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let n): n == 1 ? "1 file could not be read" : "\(n) files could not be read"
        case .mismatched(let failed, let total): "\(failed) of \(total) \(total == 1 ? "file" : "files") failed"
        case .notAChecksumFile(let name): "\(name) has no checksums Basil can read"
        }
    }
}

/// Files > Checksums > Verify Checksums: checks every file a checksum file lists. Fails when a
/// file differs, is missing or can't be read; the log lists each one.
public struct VerifyChecksumsOperation: QueueOperation {
    public let checksumFiles: [VFSPath]
    let registry: ProviderRegistry

    public init(checksumFiles: [VFSPath], registry: ProviderRegistry) {
        self.checksumFiles = checksumFiles
        self.registry = registry
    }

    public var kind: OperationKind { .verifyChecksums }
    public var title: String {
        checksumFiles.count == 1 ? "Verify \(checksumFiles[0].name)" : "Verify \(checksumFiles.count) checksum files"
    }

    public func run(_ context: OperationContext) async throws {
        var lists: [(file: VFSPath, algorithm: ChecksumAlgorithm, entries: [ChecksumFile.Entry])] = []
        for file in checksumFiles {
            try await context.checkpoint()
            let text = try await readText(file)
            let ext = file.name.split(separator: ".").last.map(String.init) ?? ""
            let parsed = ChecksumFile.parse(text, algorithm: ChecksumAlgorithm(fileExtension: ext))
            guard let algorithm = parsed.algorithm, !parsed.entries.isEmpty else {
                throw ChecksumProblems.notAChecksumFile(file.name)
            }
            lists.append((file, algorithm, parsed.entries))
        }

        let total = lists.reduce(0) { $0 + $1.entries.count }
        var checked = 0, failed = 0
        context.items(done: 0, total: total)
        for list in lists {
            for entry in list.entries {
                try await context.checkpoint()
                let path = entry.name.split(separator: "/").reduce(list.file.parent ?? list.file) { $0.appending(String($1)) }
                let label = lists.count == 1 ? entry.name : "\(list.file.name): \(entry.name)"
                context.progress(Double(checked) / Double(max(total, 1)), entry.name)
                do {
                    let hash = try await digest(of: path, algorithm: list.algorithm, registry: registry, context: context) { _ in }
                    if hash.caseInsensitiveCompare(entry.hash) != .orderedSame {
                        context.log("\(label): does not match")
                        failed += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch VFSError.notFound {
                    context.log("\(label): missing")
                    failed += 1
                } catch {
                    context.log("\(label): \(error.localizedDescription)")
                    failed += 1
                }
                checked += 1
                context.items(done: checked, total: total)
            }
        }
        if failed > 0 { throw ChecksumProblems.mismatched(failed: failed, total: total) }
        context.log(total == 1 ? "1 file OK" : "All \(total) files OK")
    }

    private func readText(_ path: VFSPath) async throws -> String {
        let provider = try registry.writableProvider(for: path.location)
        let file = try await provider.openForReading(path, bypassCache: false)
        var data = Data()
        while true {
            let chunk = try await file.read(at: Int64(data.count), count: 1 << 20)
            data += chunk
            if chunk.count < 1 << 20 { break }
        }
        await file.close()
        return String(decoding: data, as: UTF8.self)
    }
}
