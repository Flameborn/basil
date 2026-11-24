import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilArchives

/// Like an SMB share mounted in /Volumes: its own location, with every item a file in a local
/// folder underneath (`LocalBackedProvider`).
private struct FakeShare: LocalBackedProvider {
    let root: String
    let location = ProviderLocation(provider: ProviderID("fakeshare"), instance: "nas")
    let local = LocalProvider()
    var capabilities: ProviderCapabilities { local.capabilities }

    func localPath(of path: VFSPath) -> String? { root + (path.isRoot ? "" : path.path) }

    func mapped(_ item: FileItem) -> FileItem {
        let path = VFSPath(location: location, path: item.path.path == root ? "/" : String(item.path.path.dropFirst(root.count)))
        return FileItem(path: path, kind: item.kind, size: item.size, modified: item.modified, created: item.created,
                        permissions: item.permissions, isHidden: item.isHidden, fileID: item.fileID)
    }

    func list(_ directory: VFSPath) -> AsyncThrowingStream<[FileItem], Error> {
        let inner = local.list(.local(localPath(of: directory)!))
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await batch in inner { continuation.yield(batch.map(mapped)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func item(at path: VFSPath) async throws -> FileItem { mapped(try await local.item(at: .local(localPath(of: path)!))) }
    func watch(_ directory: VFSPath) -> AsyncStream<VFSChange>? { nil }
}

@MainActor
@Suite struct MountedShareTests {
    @Test func packsAndChangesArchivesInPlaceOnAMountedShare() async throws {
        let f = try Fixture()
        let opener = ArchiveOpener(temporaryRoot: f.url.appendingPathComponent("tmp"))
        f.registry.register(writer: opener)
        let shareFolder = f.url.appendingPathComponent("share")
        try FileManager.default.createDirectory(at: shareFolder, withIntermediateDirectories: true)
        let share = FakeShare(root: shareFolder.path)
        f.registry.register(share)
        let archive = VFSPath(location: share.location, path: "/packed.zip")

        // Option+F5 into the share: written there directly.
        _ = try await opener.create(archive, options: PackOptions(format: "zip"), changes: try await f.srcAdds(),
                                    replacing: false, registry: f.registry, monitor: WriteMonitor())
        #expect(FileManager.default.fileExists(atPath: shareFolder.appendingPathComponent("packed.zip").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: shareFolder.path) == ["packed.zip"])
        let root = try #require(try await f.registry.openContainer(try await share.item(at: archive), byContent: false))
        #expect(try await f.names(root).contains("hello.txt"))

        // Changing it in place (F7 inside), as on a local disk.
        #expect(opener.updateRefusal(for: archive, registry: f.registry) == nil)
        let queue = FileOperationQueue()
        let item = queue.add(ArchiveUpdateOperation(.makeDirectory(root.appending("New")), macMetadata: true,
                                                    unstableRetries: 0, registry: f.registry))
        for _ in 0..<400 where !item.state.isDone { try await Task.sleep(for: .milliseconds(25)) }
        #expect(item.state == .finished, "\(item.log)")
        #expect(try await f.names(root).contains("New"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: shareFolder.path) == ["packed.zip"])

        // A server without a local file (SFTP and the like) still cannot be written.
        let elsewhere = VFSPath(location: ProviderLocation(provider: ProviderID("sftp"), instance: "x"), path: "/a.zip")
        await #expect(throws: VFSError.self) {
            _ = try await opener.create(elsewhere, options: PackOptions(format: "zip"), changes: try await f.srcAdds(),
                                        replacing: false, registry: f.registry, monitor: WriteMonitor())
        }
        #expect(opener.updateRefusal(for: elsewhere, registry: f.registry) == "Archives on servers cannot be changed yet.")
    }
}
