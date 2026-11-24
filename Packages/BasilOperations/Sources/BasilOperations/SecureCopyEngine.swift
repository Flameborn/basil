// SecureCopyEngine
//
// Copies and moves files so that no write to the source is lost, while reading the data as
// few times as possible. The strategy depends on where source and destination are:
//
//   Move, same volume       rename(). Writers keep writing to the same inode, so nothing is lost.
//   Copy, same APFS volume  clonefile(). The source fingerprint is checked afterwards; if it
//                           changed during the clone, the clone is thrown away and redone.
//   Anything else           One pass that reads, hashes (BLAKE3, per chunk) and writes into a
//                           .basil-partial-* file next to the destination. If the source
//                           fingerprint changed during the pass, the source is read again and only
//                           chunks whose hash differs are rewritten (a file that only grew gets
//                           just its tail written). This repeats with backoff, then asks the user.
//
// Then: copy metadata, F_FULLFSYNC, rename into place atomically. Optional read-back
// verification runs on the partial file before it is renamed, so a bad copy never appears
// under the real name. A move removes the source only once the copy of it was stable.
//
// With `secure` off (the default in settings) the engine works like Total Commander: same-volume
// moves still rename and same-volume copies still clone, but other copies write straight to the
// target name in one pass, nothing checks whether the source changed, there is no F_FULLFSYNC,
// and a move deletes the source right after copying it. A failed or cancelled copy removes the
// incomplete target. Read-back verification still works when it is turned on.

import BasilCore
import BasilVFS
import BLAKE3
import Foundation

public enum TransferMode: Sendable { case copy, move }

public enum TransferStrategy: String, Sendable { case rename, clone, stream }

/// Shown to the user when the source keeps changing after all automatic retries.
public struct UnstableSource: Sendable {
    public let path: VFSPath
    /// Number of re-reads so far.
    public let attempts: Int
}

public enum UnstableSourceDecision: Sendable {
    /// Retry again (the retry count starts over).
    case keepRetrying
    /// Keep the copy from the last pass. A move then keeps the source.
    case acceptLatest
    /// Leave this file out; nothing is written for it.
    case skip
    /// Stop the whole operation.
    case cancel
}

/// How the engine talks to whoever runs it (a queue operation, or a test).
public protocol TransferMonitor: Sendable {
    /// Waits while paused; throws CancellationError when cancelled.
    func checkpoint() async throws
    func log(_ message: String)
    /// Bytes newly copied (first pass only), for progress.
    func transferred(bytes: Int64)
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision
    /// The target file exists. Without an implementation the copy fails with `.alreadyExists`
    /// (or replaces it when `replaceExisting` is set).
    func resolveConflict(_ conflict: FileConflict) async throws -> ConflictResolution
    /// One file, symlink or folder step failed. Return `.retry` to run that step again or `.skip`
    /// to leave the item out and go on; throw to stop the whole transfer. Without an
    /// implementation the error is rethrown, so the transfer stops.
    func handleError(_ error: any Error, at path: VFSPath) async throws -> ItemErrorDecision
    /// A file's transfer starts (again, after a retry): its size and where it goes.
    func fileStarted(_ source: VFSPath, to destination: VFSPath, size: Int64)
    /// Bytes of the current file read so far in the current pass or verification.
    func fileProgress(bytes: Int64)
    /// The current file entered another phase (reading again, verifying, finishing).
    func phase(_ phase: TransferProgress.Phase)
    /// The current file is done. `skipped`: it was left out or failed, so its bytes count as
    /// done without having been transferred.
    func fileFinished(skipped: Bool)
}

extension TransferMonitor {
    public func fileStarted(_ source: VFSPath, to destination: VFSPath, size: Int64) {}
    public func fileProgress(bytes: Int64) {}
    public func phase(_ phase: TransferProgress.Phase) {}
    public func fileFinished(skipped: Bool) {}
    public func resolveConflict(_ conflict: FileConflict) async throws -> ConflictResolution { .fail }
    public func handleError(_ error: any Error, at path: VFSPath) async throws -> ItemErrorDecision { throw error }
}

/// What to do after one item of a multi-item operation failed.
public enum ItemErrorDecision: Sendable, Equatable {
    case retry
    case skip
}

/// A file that would be written over an existing one.
public struct FileConflict: Sendable {
    public let source: VFSPath
    public let destination: VFSPath
    public let sourceFingerprint: FileFingerprint
    public let destinationFingerprint: FileFingerprint
}

public enum ConflictResolution: Sendable, Equatable {
    case overwrite
    case skip
    /// Write under this name (in the same folder) instead.
    case rename(String)
    /// Fail with `VFSError.alreadyExists`.
    case fail
}

public struct SecureCopyOptions: Sendable {
    /// Read the destination back and compare chunk hashes (off by default).
    public var verifyDestination = false
    /// Automatic re-reads of a changing source before asking.
    public var unstableRetries = 3
    /// Wait before the first re-read; doubles with each attempt.
    public var retryDelay: Duration = .milliseconds(500)
    /// Replace an existing destination file. Without it, an existing file fails with `.alreadyExists`.
    public var replaceExisting = false
    /// Secure mode (source-change detection, partial file, F_FULLFSYNC). Off means Total Commander style.
    public var secure = true

    public init(verifyDestination: Bool = false, unstableRetries: Int = 3,
                retryDelay: Duration = .milliseconds(500), replaceExisting: Bool = false, secure: Bool = true) {
        self.verifyDestination = verifyDestination
        self.unstableRetries = unstableRetries
        self.retryDelay = retryDelay
        self.replaceExisting = replaceExisting
        self.secure = secure
    }
}

public enum CopyError: Error, Sendable, Equatable, LocalizedError {
    case sameItem(VFSPath)
    case intoItself(VFSPath)
    case verificationFailed(VFSPath)
    case sourceTypeChanged(VFSPath)
    case unsupportedItem(VFSPath)

    public var errorDescription: String? {
        switch self {
        case .sameItem(let p): "Source and destination are the same: \(p)"
        case .intoItself(let p): "Cannot copy a folder into itself: \(p)"
        case .verificationFailed(let p): "Verification failed: the copy of \(p) does not match what was read"
        case .sourceTypeChanged(let p): "\(p) was replaced by a different kind of item during the copy"
        case .unsupportedItem(let p): "\(p) is not a file, folder or symbolic link"
        }
    }
}

/// What happened to one file.
public struct FileTransferResult: Sendable {
    public enum Outcome: Sendable, Equatable {
        case completed
        /// The source kept changing and the user accepted the last pass.
        case acceptedUnstable
        case skipped
    }

    public var outcome: Outcome
    public var strategy: TransferStrategy
    /// Re-reads after the first pass (stream) or re-clones (clone).
    public var retries = 0
    /// Bytes written by re-reads (delta passes).
    public var bytesRewritten: Int64 = 0
    /// For a move: whether the source was removed.
    public var sourceRemoved = false
}

/// Totals for a whole transfer (file, symlink or folder tree).
public struct TransferSummary: Sendable {
    public var files = 0
    public var directories = 0
    public var symlinks = 0
    public var skipped: [VFSPath] = []
    /// Items that failed and were skipped (Skip or Skip All after an error).
    public var failed: [VFSPath] = []
    public var acceptedUnstable: [VFSPath] = []
    /// Move sources that were left in place (unstable, skipped, or a folder that still has items).
    public var sourcesKept: [VFSPath] = []
    public var bytesRewritten: Int64 = 0

    public init() {}

    mutating func add(_ r: FileTransferResult, source: VFSPath) {
        switch r.outcome {
        case .completed: files += 1
        case .acceptedUnstable: files += 1; acceptedUnstable.append(source)
        case .skipped: skipped.append(source)
        }
        bytesRewritten += r.bytesRewritten
    }
}

/// Test-only hooks to change the source at exact points of a copy.
struct EngineHooks: Sendable {
    /// Called after each chunk has been read and written. `pass` is 0 for the first pass.
    var afterChunk: (@Sendable (_ pass: Int, _ index: Int) async -> Void)?
    /// Called after each clone, before the fingerprint is checked again.
    var afterClone: (@Sendable (_ attempt: Int) async -> Void)?
    /// Strategies the engine may use (tests force the stream path on one volume).
    var allowed: Set<TransferStrategy> = [.rename, .clone, .stream]
}

public struct SecureCopyEngine: Sendable {
    let registry: ProviderRegistry
    let options: SecureCopyOptions
    let monitor: any TransferMonitor
    let hooks: EngineHooks

    public init(registry: ProviderRegistry, options: SecureCopyOptions = .init(), monitor: any TransferMonitor) {
        self.init(registry: registry, options: options, monitor: monitor, hooks: EngineHooks())
    }

    init(registry: ProviderRegistry, options: SecureCopyOptions, monitor: any TransferMonitor, hooks: EngineHooks) {
        self.registry = registry
        self.options = options
        self.monitor = monitor
        self.hooks = hooks
    }

    // MARK: Chunk size

    static let mebibyte = 1 << 20

    /// Chosen once per file: under 64 MB 1 MB, up to 1 GB 4 MB, larger 8 MB; capped by the providers.
    static func chunkSize(forFileSize size: Int64, limit: Int?) -> Int {
        let mb = Int64(mebibyte)
        let size = size < 64 * mb ? mebibyte : size <= 1024 * mb ? 4 * mebibyte : 8 * mebibyte
        return limit.map { max(64 * 1024, min(size, $0)) } ?? size
    }

    // MARK: Trees

    /// Copies or moves `source` (file, symlink or folder) to `destination`, the full target path.
    /// An existing destination folder is merged into.
    public func transfer(_ source: VFSPath, to destination: VFSPath, mode: TransferMode) async throws -> TransferSummary {
        if source == destination { throw CopyError.sameItem(source) }
        let src = try registry.writableProvider(for: source.location)
        let dst = try registry.writableProvider(for: destination.location)
        let fp = try await src.fingerprint(of: source)
        if fp.kind == .directory, destination.hasPrefix(source) { throw CopyError.intoItself(source) }

        var summary = TransferSummary()
        if mode == .move, hooks.allowed.contains(.rename), try await canRename(source, to: destination, src, dst) {
            do {
                try await dst.rename(source, to: destination, replacing: options.replaceExisting && fp.kind != .directory)
                monitor.log("Moved \(source.name) by renaming")
                switch fp.kind {
                case .directory: summary.directories += 1
                case .symlink: summary.symlinks += 1
                default: summary.files += 1
                }
                if fp.kind == .file {
                    monitor.fileStarted(source, to: destination, size: fp.size)
                    monitor.transferred(bytes: fp.size)
                    monitor.fileProgress(bytes: fp.size)
                    monitor.fileFinished(skipped: false)
                }
                return summary
            } catch VFSError.unsupported {
                // Different volume after all: fall through to copy and delete.
            } catch VFSError.alreadyExists where fp.kind == .directory || fp.kind == .file {
                // Target folder exists: merge item by item below. Target file exists: the
                // file transfer below asks how to resolve the conflict.
            }
        }
        try await transferItem(source, fp, to: destination, mode: mode, src, dst, &summary)
        return summary
    }

    private func transferItem(_ source: VFSPath, _ fp: FileFingerprint, to destination: VFSPath, mode: TransferMode,
                              _ src: any WritableProvider, _ dst: any WritableProvider,
                              _ summary: inout TransferSummary) async throws {
        try await monitor.checkpoint()
        switch fp.kind {
        case .file:
            guard let r = try await attempt(source, {
                monitor.fileStarted(source, to: destination, size: fp.size)
                return try await transferFile(source, to: destination, mode: mode, src, dst)
            }) else {
                monitor.fileFinished(skipped: true)
                return summary.failed.append(source)
            }
            monitor.fileFinished(skipped: r.outcome == .skipped)
            summary.add(r, source: source)
            if mode == .move, !r.sourceRemoved { summary.sourcesKept.append(source) }
        case .symlink:
            guard try await attempt(source, {
                if (try? await dst.fingerprint(of: destination))?.kind == .symlink,
                   (try? await dst.readSymlink(destination)) == (try await src.readSymlink(source)) {
                    return // made by an earlier attempt that failed later
                }
                try await copySymlink(source, to: destination, src, dst)
            }) != nil else { return summary.failed.append(source) }
            summary.symlinks += 1
            if mode == .move, try await attempt(source, { try await src.remove(source) }) == nil {
                summary.failed.append(source)
            }
        case .directory:
            try await copyDirectory(source, to: destination, mode: mode, src, dst, &summary)
        case .other:
            if try await attempt(source, { throw CopyError.unsupportedItem(source) }) == nil {
                summary.failed.append(source)
            }
        }
    }

    /// Runs one step for `path`. When it fails, the monitor decides: run it again, or skip it
    /// (nil). Cancellation always goes through.
    private func attempt<T>(_ path: VFSPath, _ body: () async throws -> T) async throws -> T? {
        while true {
            do {
                return try await body()
            } catch let error as CancellationError {
                throw error
            } catch {
                switch try await monitor.handleError(error, at: path) {
                case .retry:
                    monitor.log("Retrying \(path.path)")
                case .skip:
                    return nil
                }
            }
        }
    }

    private func copyDirectory(_ source: VFSPath, to destination: VFSPath, mode: TransferMode,
                               _ src: any WritableProvider, _ dst: any WritableProvider,
                               _ summary: inout TransferSummary) async throws {
        let made: Void? = try await attempt(source) {
            do {
                try await dst.makeDirectory(destination)
            } catch VFSError.alreadyExists {
                guard try await dst.fingerprint(of: destination).kind == .directory else {
                    throw VFSError.alreadyExists(destination)
                }
            }
        }
        guard made != nil, let children = try await attempt(source, {
            var children: [FileItem] = []
            for try await batch in src.list(source) { children += batch }
            return children
        }) else { return summary.failed.append(source) }
        for child in children {
            guard let fp = try await attempt(child.path, { try await src.fingerprint(of: child.path) }) else {
                summary.failed.append(child.path)
                continue
            }
            try await transferItem(child.path, fp, to: destination.appending(child.name), mode: mode, src, dst, &summary)
        }
        // Dates and permissions last: writing the children would change the folder's dates,
        // and a read-only folder could not receive them.
        let warnings = try await attempt(source) {
            try await dst.applyMetadata(try await src.metadata(of: source), to: destination)
        }
        guard let warnings else { return summary.failed.append(source) }
        for warning in warnings { monitor.log("\(destination.name): \(warning)") }
        summary.directories += 1
        if mode == .move {
            let removed = try await attempt(source) { () async throws -> Bool in
                do {
                    try await src.remove(source)
                    return true
                } catch VFSError.directoryNotEmpty {
                    return false
                }
            }
            if removed != true {
                summary.sourcesKept.append(source)
                monitor.log("Kept folder \(source) because it still contains items that were not moved")
            }
        }
    }

    private func copySymlink(_ source: VFSPath, to destination: VFSPath,
                             _ src: any WritableProvider, _ dst: any WritableProvider) async throws {
        let target = try await src.readSymlink(source)
        if options.replaceExisting, (try? await dst.fingerprint(of: destination))?.kind == .symlink {
            try await dst.remove(destination)
        }
        try await dst.createSymlink(destination, target: target)
        var metadata = try await src.metadata(of: source)
        metadata.permissions = nil
        for warning in try await dst.applyMetadata(metadata, to: destination) { monitor.log("\(destination.name): \(warning)") }
    }

    private func canRename(_ source: VFSPath, to destination: VFSPath,
                           _ src: any WritableProvider, _ dst: any WritableProvider) async throws -> Bool {
        guard source.location == destination.location, src.capabilities.contains(.rename),
              let parent = destination.parent else { return false }
        let a = try await src.volumeIdentifier(of: source)
        let b = try await dst.volumeIdentifier(of: parent)
        return a != nil && a == b
    }

    // MARK: Files

    /// Copies or moves one regular file to `destination` (the full target path).
    public func transferFile(_ source: VFSPath, to destination: VFSPath, mode: TransferMode,
                             _ src: any WritableProvider, _ dst: any WritableProvider) async throws -> FileTransferResult {
        guard let parent = destination.parent else { throw VFSError.alreadyExists(destination) }
        var destination = destination
        var replace = options.replaceExisting
        if !replace, let existing = try? await dst.fingerprint(of: destination) {
            let sourceFingerprint = try await src.fingerprint(of: source)
            let conflict = FileConflict(source: source, destination: destination,
                                        sourceFingerprint: sourceFingerprint, destinationFingerprint: existing)
            switch try await monitor.resolveConflict(conflict) {
            case .overwrite:
                replace = true
            case .skip:
                monitor.log("Skipped \(source.name): the target exists")
                return FileTransferResult(outcome: .skipped, strategy: .stream)
            case .rename(let name):
                destination = parent.appending(name)
                if (try? await dst.fingerprint(of: destination)) != nil { throw VFSError.alreadyExists(destination) }
            case .fail:
                throw VFSError.alreadyExists(destination)
            }
        }
        if mode == .move, hooks.allowed.contains(.rename), try await canRename(source, to: destination, src, dst) {
            // Same volume: a rename keeps writes from open handles, in both modes.
            do {
                try await dst.rename(source, to: destination, replacing: replace)
                monitor.log("Moved \(source.name) by renaming")
                let size = (try? await dst.fingerprint(of: destination))?.size ?? 0
                monitor.transferred(bytes: size)
                monitor.fileProgress(bytes: size)
                return FileTransferResult(outcome: .completed, strategy: .rename, sourceRemoved: true)
            } catch VFSError.unsupported {
                // Different volume after all (a folder that is a link into another drive):
                // copy and delete below.
            }
        }
        if !options.secure {
            return try await plainTransferFile(source, to: destination, mode: mode, replacing: replace, src, dst)
        }
        let partial = parent.appending(Self.partialName(for: destination.name))

        var result: FileTransferResult
        var stableFingerprint: FileFingerprint?
        do {
            let sameVolume = try await canRename(source, to: destination, src, dst)
            if sameVolume, hooks.allowed.contains(.clone), src.capabilities.contains(.clone),
               let r = try await cloneFile(source, partial: partial, src) {
                (result, stableFingerprint) = r
            } else {
                (result, stableFingerprint) = try await streamFile(source, partial: partial, src, dst)
            }
            if result.outcome == .skipped {
                monitor.log("Skipped \(source.name)")
                return result
            }
            try await dst.rename(partial, to: destination, replacing: replace)
        } catch {
            try? await dst.remove(partial)
            throw error
        }

        let metadata = try await src.metadata(of: source)
        if let flags = metadata.flags, flags != 0 {
            for warning in try await dst.applyMetadata(FileMetadata(flags: flags), to: destination) {
                monitor.log("\(destination.name): \(warning)")
            }
        }

        if mode == .move {
            if let stable = stableFingerprint {
                // Last check right before removing: anything written since the copy was
                // verified stable would otherwise be lost.
                if try await src.fingerprint(of: source) == stable {
                    try await src.remove(source)
                    result.sourceRemoved = true
                } else {
                    monitor.log("Kept \(source.name): it changed after it was copied")
                }
            } else {
                monitor.log("Kept \(source.name): its copy was accepted while the file was still changing")
            }
        }
        return result
    }

    /// Total Commander style: clone on the same volume, otherwise one pass straight into the
    /// target. No source-change check and no F_FULLFSYNC. The incomplete target is removed on failure.
    private func plainTransferFile(_ source: VFSPath, to destination: VFSPath, mode: TransferMode, replacing: Bool,
                                   _ src: any WritableProvider, _ dst: any WritableProvider) async throws -> FileTransferResult {
        try await monitor.checkpoint()
        let fp = try await src.fingerprint(of: source)
        guard fp.kind == .file else { throw CopyError.sourceTypeChanged(source) }
        var result = FileTransferResult(outcome: .completed, strategy: .stream)

        var cloned = false
        if hooks.allowed.contains(.clone), src.capabilities.contains(.clone),
           try await canRename(source, to: destination, src, dst), let parent = destination.parent {
            // Clone next to the target and rename over it, so an overwrite never leaves no file at all.
            let partial = parent.appending(Self.partialName(for: destination.name))
            do {
                try await src.clone(source, to: partial)
                do {
                    try await dst.rename(partial, to: destination, replacing: replacing)
                } catch {
                    try? await dst.remove(partial)
                    throw error
                }
                cloned = true
                result.strategy = .clone
                monitor.transferred(bytes: fp.size)
                monitor.fileProgress(bytes: fp.size)
            } catch VFSError.unsupported {}
        }

        if !cloned {
            if replacing { try await dst.remove(destination) }
            let limit = [src.maxTransferChunkSize, dst.maxTransferChunkSize].compactMap { $0 }.min()
            let chunk = Self.chunkSize(forFileSize: fp.size, limit: limit)
            let writer = try await dst.createFile(destination)
            do {
                var hashes: [BLAKE3Digest] = []
                _ = try await pass(source, src, writer, chunk: chunk, hashes: &hashes, number: 0,
                                   hashing: options.verifyDestination)
                if options.verifyDestination {
                    try await writer.synchronize()
                    try await verify(destination, dst, chunk: chunk, hashes: hashes)
                }
                monitor.phase(.finishing)
                let metadata = try await src.metadata(of: source)
                for warning in try await writer.apply(metadata) { monitor.log("\(source.name): \(warning)") }
                await writer.close()
            } catch {
                await writer.close()
                try? await dst.remove(destination)
                throw error
            }
        }

        let metadata = try await src.metadata(of: source)
        if let flags = metadata.flags, flags != 0 {
            for warning in try await dst.applyMetadata(FileMetadata(flags: flags), to: destination) {
                monitor.log("\(destination.name): \(warning)")
            }
        }
        if mode == .move {
            try await src.remove(source)
            result.sourceRemoved = true
        }
        return result
    }

    /// Returns nil when the volume can't clone (the caller then streams).
    private func cloneFile(_ source: VFSPath, partial: VFSPath, _ provider: any WritableProvider)
        async throws -> (FileTransferResult, FileFingerprint?)? {
        var result = FileTransferResult(outcome: .completed, strategy: .clone)
        var attempts = 0
        while true {
            try await monitor.checkpoint()
            let before = try await provider.fingerprint(of: source)
            guard before.kind == .file else { throw CopyError.sourceTypeChanged(source) }
            do {
                try await provider.clone(source, to: partial)
            } catch VFSError.unsupported {
                return nil
            }
            await hooks.afterClone?(attempts)
            let after = try await provider.fingerprint(of: source)
            if after == before {
                try await provider.synchronize(partial)
                if attempts == 0 { monitor.transferred(bytes: after.size) }
                monitor.fileProgress(bytes: after.size)
                return (result, after)
            }

            attempts += 1
            result.retries = attempts
            monitor.log("\(source.name) changed while it was cloned, cloning again (attempt \(attempts))")
            if attempts > options.unstableRetries {
                switch await monitor.decide(UnstableSource(path: source, attempts: attempts)) {
                case .keepRetrying: attempts = 1
                case .acceptLatest:
                    try await provider.synchronize(partial)
                    result.outcome = .acceptedUnstable
                    return (result, nil)
                case .skip:
                    try await provider.remove(partial)
                    result.outcome = .skipped
                    return (result, nil)
                case .cancel:
                    throw CancellationError()
                }
            }
            try await provider.remove(partial)
            try await backoff(attempts)
        }
    }

    private func streamFile(_ source: VFSPath, partial: VFSPath,
                            _ src: any WritableProvider, _ dst: any WritableProvider)
        async throws -> (FileTransferResult, FileFingerprint?) {
        var result = FileTransferResult(outcome: .completed, strategy: .stream)
        var before = try await src.fingerprint(of: source)
        guard before.kind == .file else { throw CopyError.sourceTypeChanged(source) }
        let limit = [src.maxTransferChunkSize, dst.maxTransferChunkSize].compactMap { $0 }.min()
        let chunk = Self.chunkSize(forFileSize: before.size, limit: limit)
        let randomWrite = dst.capabilities.contains(.randomAccessWrite)

        var writer = try await dst.createFile(partial)
        var hashes: [BLAKE3Digest] = []
        var stable: FileFingerprint?
        do {
            var length = try await pass(source, src, writer, chunk: chunk, hashes: &hashes, number: 0).length
            var attempts = 0
            while true {
                let after = try await src.fingerprint(of: source)
                if after == before, after.size == length {
                    stable = after
                    break
                }
                attempts += 1
                result.retries = attempts
                if attempts > options.unstableRetries {
                    switch await monitor.decide(UnstableSource(path: source, attempts: attempts - 1)) {
                    case .keepRetrying: attempts = 1
                    case .acceptLatest: result.outcome = .acceptedUnstable
                    case .skip:
                        await writer.close()
                        try await dst.remove(partial)
                        result.outcome = .skipped
                        return (result, nil)
                    case .cancel: throw CancellationError()
                    }
                    if result.outcome == .acceptedUnstable { break }
                }
                monitor.log("\(source.name) changed during the copy, reading it again (attempt \(attempts))")
                monitor.phase(.rereading(attempt: attempts))
                try await backoff(attempts)
                before = try await src.fingerprint(of: source)
                guard before.kind == .file else { throw CopyError.sourceTypeChanged(source) }
                if !randomWrite {
                    // Without random-access writes the partial file is rewritten from the start.
                    await writer.close()
                    try await dst.remove(partial)
                    writer = try await dst.createFile(partial)
                    hashes = []
                }
                let r = try await pass(source, src, writer, chunk: chunk, hashes: &hashes, number: attempts)
                length = r.length
                result.bytesRewritten += r.rewritten
            }

            if options.verifyDestination {
                try await writer.synchronize()
                try await verify(partial, dst, chunk: chunk, hashes: hashes)
            }
            monitor.phase(.finishing)
            let metadata = try await src.metadata(of: source)
            for warning in try await writer.apply(metadata) { monitor.log("\(source.name): \(warning)") }
            try await writer.synchronize()
            await writer.close()
        } catch {
            await writer.close()
            throw error
        }
        return (result, stable)
    }

    /// One read pass. The first pass writes every chunk; later passes write only chunks whose
    /// hash differs from the one recorded, then cut the file to the new length.
    /// Reading the next chunk overlaps with hashing and writing the current one.
    private func pass(_ source: VFSPath, _ src: any WritableProvider, _ writer: any WritableFile,
                      chunk: Int, hashes: inout [BLAKE3Digest], number: Int,
                      hashing: Bool = true) async throws -> (length: Int64, rewritten: Int64) {
        if number == 0 { monitor.phase(.transferring) }
        monitor.fileProgress(bytes: 0)
        let reader = try await src.openForReading(source, bypassCache: false)
        let first = hashes.isEmpty
        var offset: Int64 = 0
        var index = 0
        var rewritten: Int64 = 0
        var next: Task<Data, Error>? = Task { try await reader.read(at: 0, count: chunk) }
        defer { next?.cancel() }
        do {
            while let pending = next {
                let data = try await pending.value
                next = nil
                try await monitor.checkpoint()
                let isLast = data.count < chunk
                if !isLast {
                    let at = offset + Int64(data.count)
                    next = Task { try await reader.read(at: at, count: chunk) }
                }
                if !data.isEmpty {
                    if first, !hashing {
                        try await writer.write(data, at: offset)
                        monitor.transferred(bytes: Int64(data.count))
                    } else if first {
                        async let digest = Self.hash(data)
                        try await writer.write(data, at: offset)
                        hashes.append(await digest)
                        monitor.transferred(bytes: Int64(data.count))
                    } else {
                        let digest = await Self.hash(data)
                        if index >= hashes.count || hashes[index] != digest {
                            try await writer.write(data, at: offset)
                            rewritten += Int64(data.count)
                            if index >= hashes.count { hashes.append(digest) } else { hashes[index] = digest }
                        }
                    }
                    offset += Int64(data.count)
                    index += 1
                    monitor.fileProgress(bytes: offset)
                    await hooks.afterChunk?(number, index - 1)
                }
            }
            if hashes.count > index { hashes.removeLast(hashes.count - index) }
            if !first { try await writer.truncate(to: offset) }
        } catch {
            if let next { _ = await next.result }
            await reader.close()
            throw error
        }
        await reader.close()
        return (offset, rewritten)
    }

    private func verify(_ partial: VFSPath, _ dst: any WritableProvider, chunk: Int, hashes: [BLAKE3Digest]) async throws {
        monitor.phase(.verifying)
        monitor.fileProgress(bytes: 0)
        let reader = try await dst.openForReading(partial, bypassCache: true)
        do {
            var offset: Int64 = 0
            for expected in hashes {
                try await monitor.checkpoint()
                let data = try await reader.read(at: offset, count: chunk)
                guard await Self.hash(data) == expected else { throw CopyError.verificationFailed(partial) }
                offset += Int64(data.count)
                monitor.fileProgress(bytes: offset)
            }
            guard try await reader.read(at: offset, count: 1).isEmpty else { throw CopyError.verificationFailed(partial) }
        } catch {
            await reader.close()
            throw error
        }
        await reader.close()
    }

    @concurrent
    private static func hash(_ data: Data) async -> BLAKE3Digest {
        BLAKE3.hash(data)
    }

    private func backoff(_ attempt: Int) async throws {
        let factor = 1 << min(attempt - 1, 10)
        try await Task.sleep(for: options.retryDelay * factor)
        try await monitor.checkpoint()
    }

    /// `.basil-partial-<random>-<name>`, kept within the 255-byte name limit.
    static func partialName(for name: String) -> String {
        let prefix = ".basil-partial-" + String(UInt32.random(in: .min ... .max), radix: 16) + "-"
        var kept = ""
        var bytes = prefix.utf8.count
        for character in name {
            let n = character.utf8.count
            if bytes + n > 255 { break }
            kept.append(character)
            bytes += n
        }
        return prefix + kept
    }
}
