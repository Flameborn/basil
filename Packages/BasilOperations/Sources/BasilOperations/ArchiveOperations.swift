import BasilCore
import BasilVFS
import Foundation

/// Option+Shift+F9 (Total Commander's Alt+Shift+F9): reads every entry of the archives and
/// checks them. Fails when any archive has problems; the log lists each one.
public struct TestArchiveOperation: QueueOperation {
    public let archives: [VFSPath]
    let registry: ProviderRegistry

    public init(archives: [VFSPath], registry: ProviderRegistry) {
        self.archives = archives
        self.registry = registry
    }

    public var kind: OperationKind { .testArchive }
    public var title: String {
        archives.count == 1 ? "Test \(archives[0].name)" : "Test \(archives.count) archives"
    }

    public struct Problems: LocalizedError {
        public let count: Int
        public let archives: Int
        public var errorDescription: String? {
            let problems = count == 1 ? "1 problem" : "\(count) problems"
            return archives == 1 ? "\(problems) found" : "\(problems) found in \(archives) archives"
        }
    }

    public func run(_ context: OperationContext) async throws {
        var problems = 0
        var damaged = 0
        context.items(done: 0, total: archives.count)
        for (n, archive) in archives.enumerated() {
            try await context.checkpoint()
            guard let opener = registry.containerOpener(forFile: archive) else {
                context.log("\(archive.name): not an archive")
                problems += 1
                damaged += 1
                continue
            }
            let total = archives.count
            do {
                let found = try await opener.test(archive, registry: registry) { fraction, entry in
                    context.progress((Double(n) + fraction) / Double(total), entry)
                }
                for problem in found { context.log("\(archive.name): \(problem)") }
                if found.isEmpty { context.log("\(archive.name): no problems") }
                problems += found.count
                if !found.isEmpty { damaged += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                context.log("\(archive.name): \(error.localizedDescription)")
                problems += 1
                damaged += 1
            }
            context.items(done: n + 1, total: total)
        }
        if problems > 0 { throw Problems(count: problems, archives: damaged) }
    }
}
