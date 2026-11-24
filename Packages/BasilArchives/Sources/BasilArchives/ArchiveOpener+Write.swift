import BasilCore
import BasilVFS
import CArchive
import Darwin
import Foundation

/// Creating and changing archives with libarchive. Both write the whole new archive next to the
/// target as ".basil-partial-*", F_FULLFSYNC it, read it back and check it, and only then rename
/// it into place, so the old archive is intact until the last step.
extension ArchiveOpener: ContainerWriter {
    /// libarchive's formats, and with 7zz also 7z (second, after zip) and zip with a password.
    public var packFormats: [PackFormat] {
        let formats = LibArchiveFormats.packFormats
        guard sevenZip.withLock({ $0 }) != nil else { return formats }
        var result = formats.map { $0.id == "zip" ? $0.withEncryption() : $0 }
        result.insert(SevenZipWriter.sevenZipFormat, at: min(1, result.count))
        return result
    }

    public func create(_ destination: VFSPath, options: PackOptions, changes: [ContainerChange], replacing: Bool,
                       registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult {
        // A folder on a mounted share (SMB) is written in place, like a local one.
        let destination = registry.localPath(of: destination) ?? destination
        if SevenZipWriter.creates(options) {
            guard let writer = sevenZip.withLock({ $0 }) else { throw VFSError.unsupported("the format \(options.format)") }
            return try await writer.create(destination, options: options, changes: changes, replacing: replacing,
                                           registry: registry, monitor: monitor)
        }
        guard destination.location == .local, let folder = destination.parent else {
            throw VFSError.unsupported("creating archives outside local folders")
        }
        guard let spec = LibArchiveFormats.spec(for: options) else { throw VFSError.unsupported("the format \(options.format)") }
        let target = URL(fileURLWithPath: destination.path)
        if !replacing, FileManager.default.fileExists(atPath: target.path) { throw VFSError.alreadyExists(destination) }
        let partial = URL(fileURLWithPath: folder.appending(Self.partialName(destination.name)).path)
        let rewrite = ArchiveRewrite(output: partial, spec: spec, base: nil,
                                     rawName: LibArchiveBackend.rawEntryName(for: target))
        do {
            let result = try await rewrite.write(changes, macMetadata: options.macMetadata, registry: registry, monitor: monitor)
            try await finish(rewrite, into: target, replacing: replacing, path: destination)
            return result
        } catch {
            unlink(partial.path)
            throw error
        }
    }

    public func updateRefusal(for container: VFSPath, registry: ProviderRegistry) -> String? {
        if registry.localPath(of: container) == nil {
            return container.location.container != nil ? "Archives inside archives cannot be changed yet."
                : "Archives on servers cannot be changed yet."
        }
        let location = ProviderLocation(provider: .archive, container: container)
        if let provider = try? registry.provider(for: location) as? ArchiveProvider {
            if provider.isSingleCompressedFile { return "\(container.name) is a single compressed file and cannot be changed." }
            if provider.backendIs(SevenZipBackend.self) {
                return sevenZip.withLock({ $0 }) == nil ? "\(container.name) cannot be changed: 7-Zip is missing." : nil
            }
            if provider.backendIs(UnRARBackend.self) { return "\(container.name) is a RAR archive, which Basil can only read." }
            if !(provider.backendIs(LibArchiveBackend.self)) { return "\(container.name) cannot be changed yet." }
            if provider.hasEncryptedEntries { return "\(container.name) is encrypted and cannot be changed yet." }
        }
        return nil
    }

    public func update(_ container: VFSPath, changes: [ContainerChange], macMetadata: Bool,
                       registry: ProviderRegistry, monitor: any ContainerWriteMonitor) async throws -> ContainerWriteResult {
        if let refusal = updateRefusal(for: container, registry: registry) { throw VFSError.unsupported(refusal) }
        let location = ProviderLocation(provider: .archive, container: container)
        if let provider = try? registry.provider(for: location) as? ArchiveProvider, provider.backendIs(SevenZipBackend.self),
           let writer = sevenZip.withLock({ $0 }) {
            return try await writer.update(container, provider: provider, changes: changes, registry: registry, monitor: monitor)
        }
        guard let local = registry.localPath(of: container), let folder = local.parent else { throw VFSError.notFound(container) }
        let url = URL(fileURLWithPath: local.path)
        let before = ArchiveProvider.stamp(url)
        let format = try await Self.blocking { () -> (Int32, [Int32]) in
            guard let reader = try LibArchiveReader(url: url, raw: false) else {
                throw ArchiveError.damaged("Not an archive Basil can change", archive: url.lastPathComponent)
            }
            _ = try reader.nextHeader() // the format is known once the first header is read
            return (reader.formatCode, reader.filterCodes)
        }
        guard [ARCHIVE_FORMAT_ZIP, ARCHIVE_FORMAT_TAR, ARCHIVE_FORMAT_CPIO, ARCHIVE_FORMAT_XAR, ARCHIVE_FORMAT_ISO9660]
            .contains(format.0 & ARCHIVE_FORMAT_BASE_MASK) else {
            throw VFSError.unsupported("changing this kind of archive (\(container.name))")
        }
        // Filters are added innermost first.
        let spec = LibArchiveFormats.Spec(container: .existing(format: format.0), filters: format.1.reversed())
        let partial = URL(fileURLWithPath: folder.appending(Self.partialName(container.name)).path)
        let rewrite = ArchiveRewrite(output: partial, spec: spec, base: url, rawName: container.name)
        do {
            let result = try await rewrite.write(changes, macMetadata: macMetadata, registry: registry, monitor: monitor)
            guard ArchiveProvider.stamp(url) == before else {
                throw ArchiveError.damaged("The archive changed while it was being updated. Nothing was changed; try again.",
                                           archive: container.name)
            }
            var st = Darwin.stat()
            if stat(url.path, &st) == 0 { chmod(partial.path, st.st_mode & 0o7777) }
            try await finish(rewrite, into: url, replacing: true, path: container)
            return result
        } catch {
            unlink(partial.path)
            throw error
        }
    }

    private func finish(_ rewrite: ArchiveRewrite, into target: URL, replacing: Bool, path: VFSPath) async throws {
        try await rewrite.synchronize()
        try await rewrite.verify(backend: LibArchiveBackend())
        let r = replacing ? rename(rewrite.output.path, target.path)
                          : renamex_np(rewrite.output.path, target.path, UInt32(RENAME_EXCL))
        if r != 0 {
            if errno == EEXIST { throw VFSError.alreadyExists(path) }
            throw VFSError.posix(code: errno, path: path)
        }
    }

    static func partialName(_ name: String) -> String {
        ".basil-partial-\(UUID().uuidString.prefix(8))-\(name)"
    }
}
