import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilArchives

/// The queue operations that pack and change archives, end to end.
@MainActor
@Suite struct ArchiveOperationTests {
    func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    func run(_ queue: FileOperationQueue, _ op: any QueueOperation) async -> QueueItem {
        let item = queue.add(op)
        _ = await waitUntil { item.state.isDone }
        return item
    }

    func prepared() throws -> Fixture {
        let f = try Fixture()
        let opener = ArchiveOpener(temporaryRoot: f.url.appendingPathComponent("tmp"))
        f.registry.register(writer: opener)
        return f
    }

    @Test func packMovesSourcesOnlyAfterTheArchiveIsWritten() async throws {
        let f = try prepared()
        let queue = FileOperationQueue()
        let folder = f.src.appending("folder")
        let op = PackOperation(jobs: [.init(archive: f.path("out.tar.gz"), sources: [folder, f.src.appending("hello.txt")])],
                               options: PackOptions(format: "tar.gz"), storePaths: true, moveSources: true,
                               unstableRetries: 0, registry: f.registry)
        let item = await run(queue, op)
        #expect(item.state == .finished, "\(item.log)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: f.src.appending("hello.txt").path))
        let root = try await f.open("out.tar.gz")
        #expect(try await f.read(root.appending("folder/big.bin")) == Fixture.big)
        #expect(try await f.names(root) == ["folder", "hello.txt"])
    }

    @Test func packIntoAnExistingArchiveAsksAboutConflicts() async throws {
        let f = try prepared()
        let queue = FileOperationQueue()
        let hello = f.src.appending("hello.txt")
        let first = await run(queue, PackOperation(jobs: [.init(archive: f.path("a.zip"), sources: [hello])],
                                                   options: PackOptions(format: "zip"), storePaths: true, moveSources: false,
                                                   unstableRetries: 0, registry: f.registry))
        #expect(first.state == .finished, "\(first.log)")
        try Data("changed".utf8).write(to: URL(fileURLWithPath: hello.path))
        var asked = 0
        queue.promptHandler = { _, prompt in
            if case .conflict = prompt { asked += 1 }
            return .conflict(.rename)
        }
        let second = await run(queue, PackOperation(jobs: [.init(archive: f.path("a.zip"), sources: [hello, f.src.appending(".hidden")])],
                                                    options: PackOptions(format: "zip"), storePaths: true, moveSources: false,
                                                    unstableRetries: 0, registry: f.registry))
        #expect(second.state == .finished, "\(second.log)")
        #expect(asked == 1)
        let root = try await f.open("a.zip")
        #expect(try await f.names(root) == [".hidden", "hello (2).txt", "hello.txt"])
        #expect(try await f.read(root.appending("hello (2).txt")) == Data("changed".utf8))
        #expect(try await f.read(root.appending("hello.txt")) == Data("hello".utf8))
    }

    @Test func updateActionsInsideAnArchive() async throws {
        let f = try prepared()
        let queue = FileOperationQueue()
        _ = try await f.opener.create(f.path("a.zip"), options: PackOptions(format: "zip"), changes: try await f.srcAdds(),
                                      replacing: false, registry: f.registry, monitor: WriteMonitor())
        let root = try await f.open("a.zip")
        let mkdir = await run(queue, ArchiveUpdateOperation(.makeDirectory(root.appending("New")), macMetadata: true,
                                                            unstableRetries: 0, registry: f.registry))
        #expect(mkdir.state == .finished, "\(mkdir.log)")
        let rename = await run(queue, ArchiveUpdateOperation(.rename(from: root.appending("hello.txt"), to: root.appending("hi.txt")),
                                                             macMetadata: true, unstableRetries: 0, registry: f.registry))
        #expect(rename.state == .finished, "\(rename.log)")
        let delete = await run(queue, ArchiveUpdateOperation(.delete([root.appending("folder")]), macMetadata: true,
                                                             unstableRetries: 0, registry: f.registry))
        #expect(delete.state == .finished, "\(delete.log)")
        #expect(try await f.names(root) == [".hidden", "Grüße änd ü.txt", "New", "hi.txt", "link"])

        // F5 into the archive's New folder, then F6 out of it.
        try Data("added".utf8).write(to: f.url.appendingPathComponent("added.txt"))
        let add = await run(queue, ArchiveUpdateOperation(.add(sources: [f.path("added.txt")], into: root.appending("New"), move: true),
                                                          macMetadata: true, unstableRetries: 0, registry: f.registry))
        #expect(add.state == .finished, "\(add.log)")
        #expect(!FileManager.default.fileExists(atPath: f.path("added.txt").path))
        #expect(try await f.read(root.appending("New/added.txt")) == Data("added".utf8))
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("out"), withIntermediateDirectories: true)
        let out = await run(queue, ArchiveUpdateOperation(.moveOut(sources: [root.appending("hi.txt")], target: f.path("out"),
                                                                   options: SecureCopyOptions(secure: true)),
                                                          macMetadata: true, unstableRetries: 0, registry: f.registry))
        #expect(out.state == .finished, "\(out.log)")
        #expect(try Data(contentsOf: f.url.appendingPathComponent("out/hi.txt")) == Data("hello".utf8))
        #expect(!(try await f.names(root)).contains("hi.txt"))
        #expect(try f.leftovers().isEmpty)
    }
}
