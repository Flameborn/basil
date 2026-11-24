import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilUI

/// F4 copies of server files: the download remembers the server file's fingerprint, a saved
/// copy counts as changed, and putting it back resets both. A local folder stands in for the
/// server (TemporaryCopies only goes through providers).
@MainActor
@Suite struct TemporaryCopiesTests {
    @Test func editedServerCopyIsWatchedWithItsServerFingerprint() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("basil-copies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let serverFolder = base.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: serverFolder, withIntermediateDirectories: true)
        let serverFile = serverFolder.appendingPathComponent("notes.txt")
        try Data("old".utf8).write(to: serverFile)
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let copies = TemporaryCopies(root: base.appendingPathComponent("copies"), registry: registry)
        let entry = VFSPath.local(serverFile.path)

        let copy = try await copies.extractForEditing(entry, watch: true)
        #expect(copy != entry)
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy.path)) == Data("old".utf8))
        let edit = try #require(copies.edits.first)
        #expect(edit.isRemote)
        let downloaded = try await registry.writableProvider(for: entry.location).fingerprint(of: entry)
        #expect(edit.server == downloaded)
        #expect(copies.changedEdits().isEmpty)

        try Data("edited".utf8).write(to: URL(fileURLWithPath: copy.path))
        #expect(copies.changedEdits().map(\.id) == [edit.id])
        #expect(copies.unsavedEdits().count == 1)

        copies.dismiss(edit.id)
        #expect(copies.changedEdits().isEmpty)
        #expect(copies.unsavedEdits().count == 1)

        let stamp = try #require(copies.currentStamp(of: edit.id))
        let uploaded = FileFingerprint(kind: .file, size: 6, modifiedNanos: 42, fileID: 9)
        copies.markPutBack(edit.id, at: stamp, server: uploaded)
        #expect(copies.unsavedEdits().isEmpty)
        #expect(copies.edits.first?.server == uploaded)
        copies.removeAll()
    }
}
