import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilOperations

/// F4 on a server: the edited copy goes back, and a file changed on the server meanwhile is
/// asked about. A local folder stands in for the server (the operation only uses providers).
@MainActor
@Suite struct UploadEditedCopyTests {
    let registry: ProviderRegistry = {
        let r = ProviderRegistry()
        r.register(LocalProvider())
        return r
    }()

    func run(_ queue: FileOperationQueue, _ op: any QueueOperation) async -> QueueItem {
        let item = queue.add(op)
        _ = await waitUntil { item.state.isDone }
        return item
    }

    func fingerprint(_ p: VFSPath) async throws -> FileFingerprint {
        try await registry.writableProvider(for: p.location).fingerprint(of: p)
    }

    @Test(arguments: [true, false])
    func uploadsOverUnchangedFile(secure: Bool) async throws {
        let box = try Sandbox()
        try box.mkdir("server")
        try box.mkdir("copy")
        let server = try box.write("server/notes.txt", Data("old".utf8))
        let downloaded = try await fingerprint(server)
        let copy = try box.write("copy/notes.txt", Data("edited text".utf8))
        let queue = FileOperationQueue()
        var asked = 0
        queue.promptHandler = { _, _ in asked += 1; return .changedOnServer(replace: false) }
        let op = UploadEditedCopyOperation(copy: copy, destination: server, downloaded: downloaded, server: "test",
                                           registry: registry, options: SecureCopyOptions(secure: secure))
        let item = await run(queue, op)
        #expect(item.state == .finished)
        #expect(asked == 0)
        #expect(try contents(server) == Data("edited text".utf8))
        #expect(try contents(copy) == Data("edited text".utf8))
        #expect(op.result.fingerprint == (try await fingerprint(server)))
        #expect(item.kind == .upload)
    }

    @Test(arguments: [false, true])
    func asksWhenTheServerFileChanged(replace: Bool) async throws {
        let box = try Sandbox()
        try box.mkdir("server")
        try box.mkdir("copy")
        let server = try box.write("server/notes.txt", Data("old".utf8))
        let downloaded = try await fingerprint(server)
        try Data("someone else's change".utf8).write(to: URL(fileURLWithPath: server.path))
        let copy = try box.write("copy/notes.txt", Data("mine".utf8))
        let queue = FileOperationQueue()
        var questions: [ChangedOnServer] = []
        queue.promptHandler = { _, prompt in
            guard case .changedOnServer(let c) = prompt else { return .itemFailed(.cancel) }
            questions.append(c)
            return .changedOnServer(replace: replace)
        }
        let op = UploadEditedCopyOperation(copy: copy, destination: server, downloaded: downloaded, server: "test",
                                           registry: registry, options: SecureCopyOptions())
        let item = await run(queue, op)
        #expect(questions.count == 1)
        #expect(questions.first?.path == server)
        #expect(questions.first?.then == downloaded)
        if replace {
            #expect(item.state == .finished)
            #expect(try contents(server) == Data("mine".utf8))
        } else {
            #expect(item.state == .cancelled)
            #expect(try contents(server) == Data("someone else's change".utf8))
            #expect(op.result.fingerprint == nil)
        }
    }

    @Test func uploadsAgainWhenTheServerFileIsGone() async throws {
        let box = try Sandbox()
        try box.mkdir("server")
        try box.mkdir("copy")
        let server = try box.write("server/notes.txt", Data("old".utf8))
        let downloaded = try await fingerprint(server)
        try FileManager.default.removeItem(atPath: server.path)
        let copy = try box.write("copy/notes.txt", Data("mine".utf8))
        let queue = FileOperationQueue()
        let item = await run(queue, UploadEditedCopyOperation(copy: copy, destination: server, downloaded: downloaded,
                                                              server: "test", registry: registry, options: .init()))
        #expect(item.state == .finished)
        #expect(try contents(server) == Data("mine".utf8))
        #expect(item.log.contains { $0.contains("no longer on the server") })
    }

    @Test func sameFingerprintIsUnchanged() {
        let a = FileFingerprint(kind: .file, size: 3, modifiedNanos: 1_000_000_000, changedNanos: 5, fileID: 7)
        var b = a
        b.changedNanos = 9 // servers do not report ctime reliably; not compared
        #expect(!UploadEditedCopyOperation.changed(a, b))
        b.fileID = 8
        #expect(UploadEditedCopyOperation.changed(a, b))
    }
}
