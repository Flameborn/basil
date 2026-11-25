import BasilCore
import BasilVFS
import Darwin
import Foundation
import Synchronization
import Testing
@testable import BasilOperations

// The copy engine through the administrator helper's provider. The helper's service runs in this
// process (as this user, not root), so these check that every call crosses the wire intact and
// the engine keeps its strategies and guarantees; root itself is not tested here.

func adminProvider(authorized: Bool = true) async throws -> PrivilegedLocalProvider {
    let provider = PrivilegedLocalProvider(transport: PrivilegedFileService { _, _ in })
    if authorized { try await provider.authorize(authorization: Data(), prompt: "test") }
    return provider
}

func admin(_ p: VFSPath) -> VFSPath { VFSPath(location: .localAdministrator, path: p.path) }

func makeAdminEngine(_ provider: PrivilegedLocalProvider, _ monitor: TestMonitor = TestMonitor(),
                     hooks: EngineHooks = EngineHooks()) -> SecureCopyEngine {
    let registry = ProviderRegistry()
    registry.register(local)
    registry.register(provider)
    return SecureCopyEngine(registry: registry, options: .init(retryDelay: .milliseconds(1)), monitor: monitor, hooks: hooks)
}

@Suite struct PrivilegedCopyTests {
    @Test func nothingIsAnsweredBeforeTheAuthorization() async throws {
        let box = try Sandbox()
        try box.write("a.txt", Data("a".utf8))
        let provider = try await adminProvider(authorized: false)
        await #expect(throws: VFSError.self) { _ = try await provider.item(at: admin(box.path("a.txt"))) }
        let declining = PrivilegedLocalProvider(transport: PrivilegedFileService { _, _ in throw WireError.declined })
        await #expect(throws: PrivilegedAccessDeclined.self) {
            try await declining.authorize(authorization: Data(), prompt: "test")
        }
    }

    @Test func streamCopyKeepsDataAndMetadata() async throws {
        let box = try Sandbox()
        let data = randomData(3 * mb + 512 * 1024)
        let src = try box.write("a.bin", data)
        #expect(setxattr(src.path, "com.basil.test", "tag", 3, 0, 0) == 0)
        #expect(chmod(src.path, 0o640) == 0)
        var times = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_100_000_000, tv_usec: 0)]
        #expect(utimes(src.path, &times) == 0)
        let provider = try await adminProvider()
        let dst = box.path("b.bin")
        let r = try await makeAdminEngine(provider, hooks: streamOnly())
            .transferFile(admin(src), to: admin(dst), mode: .copy, provider, provider)
        #expect(r.outcome == .completed && r.strategy == .stream)
        #expect(try contents(dst) == data)
        var st = Darwin.stat()
        lstat(dst.path, &st)
        #expect(st.st_mode & 0o777 == 0o640)
        #expect(st.st_mtimespec.tv_sec == 1_100_000_000)
        var value = [UInt8](repeating: 0, count: 8)
        #expect(getxattr(dst.path, "com.basil.test", &value, 8, 0, 0) == 3)
        #expect(try noPartials(box))
    }

    @Test func sourceAppendedDuringCopy() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb + 512 * 1024))
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 3 { try! once { try append(src, randomData(mb + 512 * 1024)) } }
        }
        let provider = try await adminProvider()
        let dst = box.path("b.bin")
        let r = try await makeAdminEngine(provider, hooks: hooks).transferFile(admin(src), to: admin(dst), mode: .copy, provider, provider)
        #expect(try contents(dst) == contents(src))
        #expect(r.retries == 1 && r.bytesRewritten == Int64(2 * mb))
        #expect(try noPartials(box))
    }

    @Test func sourceTruncatedDuringCopy() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(4 * mb))
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 0 { once { truncateFile(src, to: Int64(mb + 200_000)) } }
        }
        let provider = try await adminProvider()
        let dst = box.path("b.bin")
        let r = try await makeAdminEngine(provider, hooks: hooks).transferFile(admin(src), to: admin(dst), mode: .copy, provider, provider)
        #expect(try contents(dst) == contents(src))
        #expect(try contents(dst).count == mb + 200_000)
        #expect(r.retries == 1)
    }

    @Test func sourceRewrittenInTheMiddleDuringCopy() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(4 * mb))
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 2 { try! once { try overwrite(src, at: UInt64(mb + mb / 2), randomData(1000)) } }
        }
        let provider = try await adminProvider()
        let dst = box.path("b.bin")
        let r = try await makeAdminEngine(provider, hooks: hooks).transferFile(admin(src), to: admin(dst), mode: .copy, provider, provider)
        #expect(try contents(dst) == contents(src))
        #expect(r.retries == 1 && r.bytesRewritten == Int64(mb))
    }

    func cloneAfterChange(_ change: @escaping @Sendable (VFSPath) throws -> Void) async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(3 * mb))
        let once = Once()
        let hooks = EngineHooks(afterChunk: nil, afterClone: { _ in try! once { try change(src) } })
        let provider = try await adminProvider()
        let dst = box.path("b.bin")
        let r = try await makeAdminEngine(provider, hooks: hooks).transferFile(admin(src), to: admin(dst), mode: .copy, provider, provider)
        #expect(r.strategy == .clone && r.retries == 1)
        #expect(try contents(dst) == contents(src))
        #expect(try noPartials(box))
    }

    @Test func sourceAppendedDuringClone() async throws {
        try await cloneAfterChange { try append($0, randomData(1234)) }
    }

    @Test func sourceTruncatedDuringClone() async throws {
        try await cloneAfterChange { truncateFile($0, to: 100) }
    }

    @Test func sourceRewrittenInTheMiddleDuringClone() async throws {
        try await cloneAfterChange { try overwrite($0, at: UInt64(mb), randomData(100)) }
    }

    @Test func sameVolumeMoveOfATreeRenames() async throws {
        let box = try Sandbox()
        try box.mkdir("tree/sub")
        try box.write("tree/sub/x", Data("x".utf8))
        try box.mkdir("into")
        let provider = try await adminProvider()
        let summary = try await makeAdminEngine(provider).transfer(admin(box.path("tree")), to: admin(box.path("into/tree")), mode: .move)
        #expect(summary.failed.isEmpty)
        #expect(try box.names() == ["into"])
        #expect(try contents(box.path("into/tree/sub/x")) == Data("x".utf8))
    }

    @Test func streamedMoveRemovesTheSourceOnlyWhenStable() async throws {
        let box = try Sandbox()
        let src = try box.write("a.bin", randomData(2 * mb + 10))
        let once = Once()
        let hooks = streamOnly { pass, index in
            if pass == 0, index == 0 { try! once { try append(src, randomData(500)) } }
        }
        let provider = try await adminProvider()
        let dst = box.path("b.bin")
        let expected = try contents(src) + Data()
        let r = try await makeAdminEngine(provider, hooks: hooks).transferFile(admin(src), to: admin(dst), mode: .move, provider, provider)
        #expect(r.outcome == .completed)
        #expect(!exists(src))
        #expect(try contents(dst).count == expected.count + 500)
    }
}

/// Stands in for the UI's helper access: records the prompt and makes the locked folders
/// writable while the operation runs (what root could do), or declines.
final class FakeAdministratorFiles: AdministratorFiles, @unchecked Sendable {
    let registry: ProviderRegistry
    let unlock: [String]
    let declines: Bool
    private let state = Mutex<(prompts: [String], ended: Int)>(([], 0))

    init(registry: ProviderRegistry, unlock: [String], declines: Bool = false) {
        self.registry = registry
        self.unlock = unlock
        self.declines = declines
    }

    var prompts: [String] { state.withLock { $0.prompts } }
    var ended: Int { state.withLock { $0.ended } }

    func begin(prompt: String) async throws {
        state.withLock { $0.prompts.append(prompt) }
        if declines { throw PrivilegedAccessDeclined() }
        registry.register(try await adminProvider())
        for path in unlock { chmod(path, 0o755) }
    }

    func end() async {
        registry.unregister(.localAdministrator)
        for path in unlock { chmod(path, 0o555) }
        state.withLock { $0.ended += 1 }
    }
}

@MainActor
@Suite struct AdministratorTransferTests {
    func run(_ queue: FileOperationQueue, _ op: any QueueOperation) async -> QueueItem {
        let item = queue.add(op)
        _ = await waitUntil(.seconds(10)) { item.state.isDone }
        return item
    }

    func registry() -> ProviderRegistry {
        let r = ProviderRegistry()
        r.register(LocalProvider())
        return r
    }

    @Test func reasons() throws {
        let box = try Sandbox()
        try box.mkdir("open")
        try box.mkdir("locked")
        try box.mkdir("locked2/inner")
        try box.write("a.txt", Data("a".utf8))
        chmod(box.path("locked").path, 0o555)
        chmod(box.path("locked2/inner").path, 0o555)
        chmod(box.path("locked2").path, 0o555)
        defer { for p in ["locked", "locked2", "locked2/inner"] { chmod(box.path(p).path, 0o755) } }
        let r = registry()
        func op(_ mode: TransferMode, _ sources: [VFSPath], _ target: VFSPath) -> TransferOperation {
            TransferOperation(mode: mode, sources: sources, target: target, registry: r, options: .init())
        }
        #expect(op(.copy, [box.path("a.txt")], box.path("open")).administratorReason() == nil)
        #expect(op(.copy, [box.path("a.txt")], box.path("open/new/b.txt")).administratorReason() == nil)
        #expect(op(.copy, [box.path("a.txt")], box.path("locked")).administratorReason() == "copy a.txt into locked")
        #expect(op(.copy, [box.path("a.txt")], box.path("locked/new/b.txt")).administratorReason() == "copy a.txt into locked")
        #expect(op(.move, [box.path("locked2/inner")], box.path("open")).administratorReason() == "move inner out of locked2")
        #expect(op(.copy, [box.path("locked2/inner")], box.path("open")).administratorReason() == nil)
    }

    @Test func copyIntoALockedFolderAsksOnceAndRunsAsAdministrator() async throws {
        let box = try Sandbox()
        try box.mkdir("locked")
        try box.write("a.txt", Data("a".utf8))
        try box.write("b.txt", Data("b".utf8))
        chmod(box.path("locked").path, 0o555)
        defer { chmod(box.path("locked").path, 0o755) }
        let r = registry()
        let fake = FakeAdministratorFiles(registry: r, unlock: [box.path("locked").path])
        let queue = FileOperationQueue()
        var prompts = 0
        queue.promptHandler = { _, _ in prompts += 1; return .itemFailed(.cancel) }
        let item = await run(queue, TransferOperation(mode: .copy, sources: [box.path("a.txt"), box.path("b.txt")],
                                                      target: box.path("locked"), registry: r, options: .init(),
                                                      administrator: fake))
        #expect(item.state == .finished)
        #expect(fake.prompts == ["Basil wants to copy 2 items into locked. You may not change it as yourself, so an administrator password is needed."])
        #expect(fake.ended == 1)
        #expect(prompts == 0)
        #expect(try box.names("locked") == ["a.txt", "b.txt"])
        #expect(item.log.contains("Working as an administrator"))
        #expect((try? r.provider(for: .localAdministrator)) == nil)
    }

    @Test func aDeclinedPasswordRunsAsTheUserAndAsksAboutTheFailure() async throws {
        let box = try Sandbox()
        try box.mkdir("locked")
        try box.write("a.txt", Data("a".utf8))
        chmod(box.path("locked").path, 0o555)
        defer { chmod(box.path("locked").path, 0o755) }
        let r = registry()
        let fake = FakeAdministratorFiles(registry: r, unlock: [], declines: true)
        let queue = FileOperationQueue()
        var failures = 0
        queue.promptHandler = { _, prompt in
            if case .itemFailed = prompt { failures += 1 }
            return .itemFailed(.skip)
        }
        let item = await run(queue, TransferOperation(mode: .copy, sources: [box.path("a.txt")], target: box.path("locked"),
                                                      registry: r, options: .init(), administrator: fake))
        #expect(item.state == .finished)
        #expect(fake.prompts.count == 1 && fake.ended == 0)
        #expect(failures == 1)
        #expect(try box.names("locked") == [])
    }
}

@MainActor
@Suite struct AdministratorDeleteTests {
    func run(_ queue: FileOperationQueue, _ op: any QueueOperation) async -> QueueItem {
        let item = queue.add(op)
        _ = await waitUntil(.seconds(10)) { item.state.isDone }
        return item
    }

    @Test func helperMovesToTheTrashUnderAFreeNameAndRemovesTrees() async throws {
        let box = try Sandbox()
        try box.mkdir("Trash")
        try box.write("Trash/a.app", Data())
        try box.mkdir("a.app/Contents")
        try box.write("a.app/Contents/x", Data("x".utf8))
        let moved = try PrivilegedFileService.moveToTrash(box.path("a.app").path, folder: box.path("Trash").path, owner: getuid())
        #expect(moved == box.path("Trash/a 2.app").path)
        #expect(try box.names("Trash") == ["a 2.app", "a.app"])
        // A missing Trash folder is made, owner-only.
        try box.write("b.txt", Data())
        _ = try PrivilegedFileService.moveToTrash(box.path("b.txt").path, folder: box.path(".Trashes/501").path, owner: getuid())
        var st = stat()
        lstat(box.path(".Trashes").path, &st)
        #expect(st.st_mode & 0o7777 == 0o1333)
        chmod(box.path(".Trashes").path, 0o755)
        #expect(try box.names(".Trashes/501") == ["b.txt"])

        let provider = try await adminProvider()
        try await provider.removeTree(admin(box.path("Trash")))
        #expect(try box.names() == [".Trashes"])
    }

    @Test func lockedItemsAreDeletedThroughTheHelperAfterOnePassword() async throws {
        let box = try Sandbox()
        try box.mkdir("locked/inner")
        try box.write("locked/inner/x", Data())
        try box.mkdir("locked2/inner")
        try box.write("locked2/inner/y", Data())
        chmod(box.path("locked/inner").path, 0o555)
        chmod(box.path("locked2/inner").path, 0o555)
        defer { chmod(box.path("locked/inner").path, 0o755); chmod(box.path("locked2/inner").path, 0o755) }
        let r = ProviderRegistry()
        r.register(LocalProvider())
        let files = FakeAdministratorFiles(registry: r, unlock: [box.path("locked/inner").path, box.path("locked2/inner").path])
        let script = BasilOperationsDeleteTestsScript()
        let queue = FileOperationQueue()
        var questions = 0
        queue.promptHandler = { _, _ in questions += 1; return .itemFailed(.cancel) }
        let item = await run(queue, DeleteOperation(paths: [box.path("locked"), box.path("locked2")], toTrash: false, registry: r,
                                                    administrator: script.removal, administratorFiles: files))
        #expect(item.state == .finished)
        #expect(files.prompts == ["Basil wants to delete locked and locked2 permanently. They belong to the system, so an administrator password is needed."])
        #expect(script.calls == 0)
        #expect(questions == 0)
        #expect(try box.names() == [])
        #expect(item.itemsDone == 2)
    }

    @Test func withoutTheHelperTheScriptIsUsed() async throws {
        let box = try Sandbox()
        try box.mkdir("locked/inner")
        try box.write("locked/inner/x", Data())
        chmod(box.path("locked/inner").path, 0o555)
        defer { chmod(box.path("locked/inner").path, 0o755) }
        let r = ProviderRegistry()
        r.register(LocalProvider())
        let script = BasilOperationsDeleteTestsScript()
        let item = await run(FileOperationQueue(), DeleteOperation(paths: [box.path("locked")], toTrash: false, registry: r,
                                                                   administrator: script.removal,
                                                                   administratorFiles: UnavailableAdministratorFiles()))
        #expect(item.state == .finished)
        #expect(script.calls == 1)
        #expect(item.log.contains { $0.hasPrefix("The administrator helper cannot be used") })
    }
}

/// A helper that macOS did not allow.
struct UnavailableAdministratorFiles: AdministratorFiles {
    struct NotAllowed: Error {}
    func begin(prompt: String) async throws { throw NotAllowed() }
    func end() async {}
}

/// The osascript fallback, counted; it removes like root would.
final class BasilOperationsDeleteTestsScript: @unchecked Sendable {
    private let count = Mutex(0)
    var calls: Int { count.withLock { $0 } }
    var removal: AdministratorRemoval {
        AdministratorRemoval { paths, _, _ in
            self.count.withLock { $0 += 1 }
            for path in paths {
                _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", path]).waitUntilExit()
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
